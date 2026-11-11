// One Metal compositor shared by the live view and by editing/export: draws an ordered list of layers (game, camera,
// color, RGBA images), each with its crop, shape, border, shadow and opacity, into any canvas (16:9, 9:16, ...), in PQ,
// HLG or SDR output. The live view and the exported video therefore match exactly.
import AVFoundation
import CoreVideo
import Metal

let compositorShader = """
#include <metal_stdlib>
using namespace metal;
struct V { float4 pos [[position]]; float2 uv; };
vertex V vtx(uint id [[vertex_id]]) {
    float2 p[4] = { float2(-1,-1), float2(1,-1), float2(-1,1), float2(1,1) };
    V o; o.pos = float4(p[id], 0, 1); o.uv = float2((p[id].x + 1) * 0.5, 1 - (p[id].y + 1) * 0.5); return o;
}

constant float3x3 m709to2020 = float3x3(float3(0.6274, 0.0691, 0.0164), float3(0.3293, 0.9195, 0.0880), float3(0.0433, 0.0114, 0.8956));
constant float3x3 m2020to709 = float3x3(float3(1.6605, -0.1246, -0.0182), float3(-0.5876, 1.1329, -0.1006), float3(-0.0728, -0.0083, 1.1187));

float3 yuvToRgb(texture2d<float> yT, texture2d<float> cT, float2 uv, int bits, bool bt709) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float y = yT.sample(s, uv).r; float2 c = cT.sample(s, uv).rg;
    float Y, Cb, Cr;
    if (bits == 10) { y *= 65535.0 / 64.0; c *= 65535.0 / 64.0; Y = (y - 64.0) / 876.0; Cb = (c.x - 512.0) / 896.0; Cr = (c.y - 512.0) / 896.0; }
    else { y *= 255.0; c *= 255.0; Y = (y - 16.0) / 219.0; Cb = (c.x - 128.0) / 224.0; Cr = (c.y - 128.0) / 224.0; }
    float3 rgb = bt709
        ? float3(Y + 1.5748 * Cr, Y - 0.1873 * Cb - 0.4681 * Cr, Y + 1.8556 * Cb)
        : float3(Y + 1.4746 * Cr, Y - 0.16455 * Cb - 0.57135 * Cr, Y + 1.8814 * Cb);
    return clamp(rgb, 0.0, 1.0);
}

// Linear light: BT.2020 primaries, 1.0 = 10000 nits. SDR white sits at 203 nits (BT.2408).
constant float m1 = 0.1593017578125, m2 = 78.84375, c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875;
float3 pqToLinear(float3 e) { float3 p = pow(e, 1.0 / m2); return pow(max(p - c1, 0.0) / (c2 - c3 * p), 1.0 / m1); }
float3 linearToPq(float3 l) { float3 p = pow(clamp(l, 0.0, 1.0), m1); return pow((c1 + c2 * p) / (1.0 + c3 * p), m2); }
constant float ha = 0.17883277, hb = 0.28466892, hc = 0.55991073;
float hlgInv(float e) { return e <= 0.5 ? e * e / 3.0 : (exp((e - hc) / ha) + hb) / 12.0; }
float hlgFwd(float l) { return l <= 1.0 / 12.0 ? sqrt(3.0 * l) : ha * log(12.0 * l - hb) + hc; }
float luma2020(float3 c) { return dot(c, float3(0.2627, 0.6780, 0.0593)); }
float3 hlgToLinear(float3 e) {   // HLG reference OOTF for a 1000-nit display
    float3 s = float3(hlgInv(e.r), hlgInv(e.g), hlgInv(e.b));
    return s * pow(max(luma2020(s), 1e-6), 0.2) * 0.1;
}
float3 linearToHlg(float3 l) {
    float3 d = l * 10.0;
    float3 s = d * pow(max(luma2020(d), 1e-6), -0.2 / 1.2);
    return float3(hlgFwd(clamp(s.r, 0.0, 1.0)), hlgFwd(clamp(s.g, 0.0, 1.0)), hlgFwd(clamp(s.b, 0.0, 1.0)));
}
float3 sdrToLinear(float3 e) { return m709to2020 * pow(e, 2.4) * 0.0203; }

// HDR -> SDR: `sdrWhite` nits of the source become SDR white. BT.2408 says 203, but many games keep midtones and UI
// well below that and looked dim; the user's "SDR brightness" setting picks it. Identity below a knee, then a smooth
// roll-off up to a 1000-nit source peak (W in SDR-white units, so highlights still compress at any gain), applied on
// max(RGB) to keep hue. At 203 this is exactly the former fixed curve.
float3 linearToSdr(float3 l, float sdrWhite) {
    float3 c = max(m2020to709 * (l * (203.0 / sdrWhite) / 0.0203), 0.0);
    float m = max(c.r, max(c.g, c.b));
    const float k = 0.7;
    float W = 1000.0 / sdrWhite, a = (1.0 - k) / (W - 1.0);
    if (m > k) {
        float x = min((m - k) / (W - k), 1.0);
        c *= (k + (1.0 - k) * x * (1.0 + a) / (x + a)) / m;
    }
    return pow(clamp(c, 0.0, 1.0), 1.0 / 2.4);
}

float3 toLinear(float3 e, int t) { return t == 0 ? pqToLinear(e) : t == 1 ? hlgToLinear(e) : sdrToLinear(e); }
float3 encodeOut(float3 l, int t, float sdrWhite) { return t == 0 ? linearToPq(l) : t == 1 ? linearToHlg(l) : linearToSdr(l, sdrWhite); }
/// Converts a non-linear color from transfer `from` into the output transfer; untouched if they already match, so
/// SDR sources never reach `linearToSdr` and `sdrWhite` only affects HDR sources drawn into SDR output.
float3 convert(float3 e, int from, int to, float sdrWhite) { return from == to ? e : encodeOut(toLinear(e, from), to, sdrWhite); }
float3 convert(float3 e, int from, int to) { return convert(e, from, to, 203.0); }

float sdRoundRect(float2 p, float2 c, float2 h, float r) {
    float2 q = abs(p - c) - h + r;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

// Mirrors `LayerParams` in Swift. One layer: its source, shape and shadow, drawn source-over onto what lies below.
struct LayerU {
    float4 canvas;      // w, h, SDR white in source nits (HDR into SDR output only), -
    float4 dst, src;    // destination in canvas pixels, normalized source crop (x, y, w, h)
    float4 shape;       // corner radius px, border px, shadow px, opacity
    float4 color;       // color layers: SDR BT.709 code values and alpha
    int4 fmt;           // kind (0 biplanar YCbCr, 1 premultiplied RGBA, 2 color), source transfer, output transfer, bits
    float4 ringColor, ringShape;
    int4 flags;         // source uses BT.709 matrix, mirror, hard edge, -
};

// Returns non-premultiplied colour and alpha for source-over blending. With coverage a and shadow s the result over
// the destination is cc·a + dst·(1 − a)(1 − s), which is the two-step mix(mix(dst, 0, s), cc, a) of the former
// fixed game-plus-camera shader; that identity is why the layer path reproduces its output (and its goldens).
fragment float4 layerFrag(V in [[stage_in]], texture2d<float> tY [[texture(0)]], texture2d<float> tC [[texture(1)]], constant LayerU &u [[buffer(0)]]) {
    float2 p = in.uv * u.canvas.xy;
    int out = u.fmt.z;
    float sdrWhite = u.canvas.z > 0.0 ? u.canvas.z : 203.0;
    float2 h = u.dst.zw * 0.5, c = u.dst.xy + h;
    float r = min(u.shape.x, min(h.x, h.y)), border = u.shape.y, shadow = u.shape.z, opacity = u.shape.w;
    float d = sdRoundRect(p, c, h, r);
    // Hard edge: the former shader's inclusive clip of the game to its rectangle, so no row is half covered.
    float2 e = (p - u.dst.xy) / u.dst.zw;
    float a = (u.flags.z != 0 ? (all(e >= 0.0) && all(e <= 1.0) ? 1.0 : 0.0) : clamp(0.5 - d, 0.0, 1.0)) * opacity;
    float s = 0.0;
    if (shadow > 0.0) s = 0.45 * (1.0 - smoothstep(-shadow * 0.5, shadow, sdRoundRect(p - float2(0.0, shadow * 0.35), c, h, r))) * opacity;
    float3 cc = float3(0.0);
    if (a > 0.0) {
        if (u.fmt.x == 2) {
            cc = convert(u.color.rgb, 2, out); a *= u.color.a;
        } else {
            float2 t = clamp((p - u.dst.xy) / u.dst.zw, 0.0, 1.0);
            if (u.flags.y != 0) t.x = 1.0 - t.x;
            float2 uv = u.src.xy + t * u.src.zw;
            if (u.fmt.x == 1) {
                constexpr sampler ls(filter::linear, address::clamp_to_edge);
                float4 px = tY.sample(ls, uv);
                cc = convert(px.a > 0.0 ? clamp(px.rgb / px.a, 0.0, 1.0) : float3(0.0), 2, out); a *= px.a;
            } else {
                cc = convert(yuvToRgb(tY, tC, uv, u.fmt.w, u.flags.x != 0), u.fmt.y, out, sdrWhite);
            }
        }
        if (border > 0.0) cc = mix(convert(float3(1.0), 2, out), cc, clamp(-(d + border) + 0.5, 0.0, 1.0));
    }
    // Camera and frame partition one coverage mask, avoiding source-over attenuation at their shared edge.
    float ring = max(0.0, clamp(0.5 - d + u.ringShape.x, 0.0, 1.0) - clamp(0.5 - d, 0.0, 1.0));
    float ra = ring * opacity * u.ringColor.a;
    float combined = a + ra;
    cc = combined > 0.0 ? (cc * a + convert(u.ringColor.rgb, 2, out) * ra) / combined : float3(0.0);
    a = combined;
    float A = a + s - a * s;
    return A > 0.0 ? float4(cc * (a / A), A) : float4(0.0);
}

// RGB (output encoding) -> 10-bit video-range BT.2020 YCbCr planes, MSB-aligned in 16 bits (P010 layout).
constant float3 kY = float3(0.2627, 0.6780, 0.0593);
fragment float lumaFrag(V in [[stage_in]], texture2d<float> rgb [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float Y = dot(rgb.sample(s, in.uv).rgb, kY);
    return (64.0 + 876.0 * Y) * 64.0 / 65535.0;
}
fragment float2 chromaFrag(V in [[stage_in]], texture2d<float> rgb [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float3 c = rgb.sample(s, in.uv).rgb;   // sampled between four luma pixels: their average
    float Y = dot(c, kY);
    float Cb = (c.b - Y) / 1.8814, Cr = (c.r - Y) / 1.4746;
    return float2(512.0 + 896.0 * Cb, 512.0 + 896.0 * Cr) * 64.0 / 65535.0;
}
// The same BT.709 video-range luma/chroma math as the planar render passes, fused into one
// dispatch. Each thread owns a 2x2 luma block and its centre-sited chroma sample.
kernel void streamNV12(texture2d<float, access::read> rgb [[texture(0)]],
                       texture2d<float, access::write> yPlane [[texture(1)]],
                       texture2d<float, access::write> cPlane [[texture(2)]], uint2 p [[thread_position_in_grid]]) {
    if (p.x >= cPlane.get_width() || p.y >= cPlane.get_height()) return;
    float3 sum = float3(0.0);
    for (uint dy = 0; dy < 2; ++dy) for (uint dx = 0; dx < 2; ++dx) {
        uint2 q = p * 2 + uint2(dx, dy);
        float3 c = rgb.read(q).rgb;
        float y = dot(c, float3(0.2126, 0.7152, 0.0722));
        yPlane.write(float4((16.0 + 219.0 * y) / 255.0), q);
        sum += c;
    }
    float3 c = sum * 0.25;
    float y = dot(c, float3(0.2126, 0.7152, 0.0722));
    float2 uv = (128.0 + 224.0 * float2((c.b - y) / 1.8556, (c.r - y) / 1.5748)) / 255.0;
    cPlane.write(float4(uv, 0, 1), p);
}

"""

/// Uniforms for `layerFrag`; layout matches the Metal `LayerU` struct.
struct LayerParams {
    var canvas = SIMD4<Float>(1, 1, 0, 0)     // w, h, SDR white nits (0 means 203), -
    var dst = SIMD4<Float>(0, 0, 1, 1), src = SIMD4<Float>(0, 0, 1, 1)
    var shape = SIMD4<Float>(0, 0, 0, 1)
    var color = SIMD4<Float>(0, 0, 0, 1)
    var fmt = SIMD4<Int32>(2, 2, 2, 8)
    var ringColor = SIMD4<Float>(0, 0, 0, 0), ringShape = SIMD4<Float>(0, 0, 0, 0)
    var flags = SIMD4<Int32>(0, 0, 0, 0)
}

struct LayerTextures {
    enum Kind {
        case biplanar(y: MTLTexture, c: MTLTexture, bits: Int32, transfer: Int32, bt709: Bool)
        case rgba(MTLTexture)       // sRGB-encoded, premultiplied alpha
        case none                   // color layers
    }
}
struct DrawLayer {
    var resolved: ResolvedLayer
    var textures: LayerTextures.Kind

    /// Pairs resolved layers with their sources' textures. Color layers need none; a layer whose texture is missing
    /// is dropped.
    static func pair(_ resolved: [ResolvedLayer], _ textures: [SourceKey: LayerTextures.Kind]) -> [DrawLayer] {
        resolved.compactMap { r in r.color != nil ? DrawLayer(resolved: r, textures: .none) : textures[r.key].map { DrawLayer(resolved: r, textures: $0) } }
    }

    /// Fully opaque over all of `rect`.
    func covers(_ rect: CGRect) -> Bool {
        guard resolved.opacity >= 1, resolved.radius == 0, resolved.dst.contains(rect) else { return false }
        switch textures {
        case .biplanar: return true
        case .rgba: return false
        case .none: return (resolved.color?.w ?? 0) >= 1
        }
    }
}

extension ColorMode {
    var transfer: Int32 { switch self { case .pq: 0; case .hlg: 1; case .sdr: 2 } }
}

extension SIMD4 where Scalar == Float {
    init(_ r: CGRect) { self.init(Float(r.minX), Float(r.minY), Float(r.width), Float(r.height)) }
}

/// Device, queue and pipelines shared by the live renderer and the editing compositor.
final class MetalCore {
    static let shared = MetalCore()
    let device: MTLDevice
    let queue: MTLCommandQueue
    let library: MTLLibrary
    let textureCache: CVMetalTextureCache
    private var pipelines: [String: MTLRenderPipelineState] = [:]
    private let lock = NSLock()
    /// Bound to the texture slots a layer does not use so the shader always sees valid textures.
    let blank8: MTLTexture
    let blank8c: MTLTexture

    private init() {
        device = MTLCreateSystemDefaultDevice()!
        queue = device.makeCommandQueue()!
        library = try! device.makeLibrary(source: compositorShader, options: nil)
        var tc: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &tc)
        textureCache = tc!
        let y = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: 1, height: 1, mipmapped: false)
        blank8 = device.makeTexture(descriptor: y)!
        blank8c = device.makeTexture(descriptor: MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg8Unorm, width: 1, height: 1, mipmapped: false))!
    }

    /// `blend`: source-over for non-premultiplied output, as `layerFrag` writes it.
    func pipeline(_ fragment: String, _ format: MTLPixelFormat, blend: Bool = false) -> MTLRenderPipelineState {
        let key = "\(fragment)/\(format.rawValue)/\(blend)"
        lock.lock(); defer { lock.unlock() }
        if let p = pipelines[key] { return p }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = library.makeFunction(name: "vtx"); d.fragmentFunction = library.makeFunction(name: fragment)
        d.colorAttachments[0].pixelFormat = format
        if blend, let a = d.colorAttachments[0] {
            a.isBlendingEnabled = true
            a.sourceRGBBlendFactor = .sourceAlpha; a.destinationRGBBlendFactor = .oneMinusSourceAlpha
            a.sourceAlphaBlendFactor = .one; a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }
        let p = try! device.makeRenderPipelineState(descriptor: d)
        pipelines[key] = p
        return p
    }

    /// Wraps a biplanar pixel buffer (8- or 10-bit) as Y and CbCr textures. Keep the returned refs alive until the GPU is done.
    func planes(_ pb: CVPixelBuffer) -> (MTLTexture, MTLTexture, [CVMetalTexture], Int32)? {
        let fmt = CVPixelBufferGetPixelFormatType(pb)
        let tenBit = fmt == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange || fmt == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        var refs: [CVMetalTexture] = []
        var out: [MTLTexture] = []
        for plane in 0..<2 {
            var t: CVMetalTexture?
            let w = CVPixelBufferGetWidthOfPlane(pb, plane), h = CVPixelBufferGetHeightOfPlane(pb, plane)
            let pf: MTLPixelFormat = plane == 0 ? (tenBit ? .r16Unorm : .r8Unorm) : (tenBit ? .rg16Unorm : .rg8Unorm)
            guard CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, pb, nil, pf, w, h, plane, &t) == kCVReturnSuccess,
                  let ref = t, let tex = CVMetalTextureGetTexture(ref) else { return nil }
            refs.append(ref); out.append(tex)
        }
        return (out[0], out[1], refs, tenBit ? 10 : 8)
    }

    /// How a frame is actually tagged: transfer (0 PQ, 1 HLG, 2 SDR) and whether its matrix is BT.709. AVFoundation
    /// may hand the compositor a layer already converted into another layer's colour space (e.g. the SDR camera into
    /// the game's PQ), so the tags on the buffer, not the source file, are what count. Untagged buffers keep
    /// `transfer` and the matrix that goes with it.
    static func colorTags(_ pb: CVPixelBuffer, fallback transfer: Int32) -> (transfer: Int32, bt709: Bool) {
        var t = transfer
        if let v = CVBufferCopyAttachment(pb, kCVImageBufferTransferFunctionKey, nil) as? String {
            t = v == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String ? 0 : v == kCVImageBufferTransferFunction_ITU_R_2100_HLG as String ? 1 : 2
        }
        let matrix = CVBufferCopyAttachment(pb, kCVImageBufferYCbCrMatrixKey, nil) as? String
        return (t, matrix.map { $0 != kCVImageBufferYCbCrMatrix_ITU_R_2020 as String } ?? (t == 2))
    }

    func texture(_ pb: CVPixelBuffer, _ format: MTLPixelFormat, plane: Int = 0) -> (MTLTexture, CVMetalTexture)? {
        var t: CVMetalTexture?
        let planar = CVPixelBufferIsPlanar(pb)
        let w = planar ? CVPixelBufferGetWidthOfPlane(pb, plane) : CVPixelBufferGetWidth(pb)
        let h = planar ? CVPixelBufferGetHeightOfPlane(pb, plane) : CVPixelBufferGetHeight(pb)
        guard CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, pb, nil, format, w, h, plane, &t) == kCVReturnSuccess,
              let ref = t, let tex = CVMetalTextureGetTexture(ref) else { return nil }
        return (tex, ref)
    }

    typealias LayerPipelines = (blended: MTLRenderPipelineState, opaque: MTLRenderPipelineState)
    // Program targets and pipeline formats do not change while live; prepare this state off the reader.
    func layerRenderPass(target: MTLTexture) -> MTLRenderPassDescriptor {
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = target
        rp.colorAttachments[0].loadAction = .clear; rp.colorAttachments[0].storeAction = .store
        // Alpha 1: blending keeps it there, and the HDR export's intermediate must stay opaque.
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        return rp
    }

    /// Draws the background, then each layer bottom first, into `target` in one render pass, in the output encoding
    /// `outTransfer`. `viewport` places the canvas inside the target (the live view letterboxes it). Every layer is a
    /// full-viewport quad scissored to its frame plus shadow, so small layers on large canvases stay cheap.
    /// `sdrWhiteNits`: the HDR source luminance that becomes SDR white when PQ/HLG layers are drawn into SDR output;
    /// read per frame, so a change shows on the next frame.
    func encodeLayers(_ cb: MTLCommandBuffer, target: MTLTexture, viewport: MTLViewport? = nil,
                      canvas: CGSize, background: SIMD4<Float>, outTransfer: Int32, sdrWhiteNits: Float = SdrBrightness.current, layers: [DrawLayer], renderPass: MTLRenderPassDescriptor? = nil, layerPipelines: LayerPipelines? = nil) {
        let rp = renderPass ?? layerRenderPass(target: target)
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { return }
        defer { enc.endEncoding() }
        guard canvas.width > 0, canvas.height > 0 else { return }
        let vp = viewport ?? MTLViewport(originX: 0, originY: 0, width: Double(target.width), height: Double(target.height), znear: 0, zfar: 1)
        enc.setViewport(vp)
        let blended = layerPipelines?.blended ?? pipeline("layerFrag", target.pixelFormat, blend: true)
        enc.setRenderPipelineState(blended)
        let sx = vp.width / canvas.width, sy = vp.height / canvas.height
        func draw(_ u: LayerParams, area: CGRect, _ t0: MTLTexture, _ t1: MTLTexture) {
            func px(_ v: Double, _ limit: Int) -> Int { Int(min(max(v, 0), Double(limit))) }
            let x0 = px((vp.originX + area.minX * sx).rounded(.down), target.width), x1 = px((vp.originX + area.maxX * sx).rounded(.up), target.width)
            let y0 = px((vp.originY + area.minY * sy).rounded(.down), target.height), y1 = px((vp.originY + area.maxY * sy).rounded(.up), target.height)
            guard x1 > x0, y1 > y0 else { return }
            enc.setScissorRect(MTLScissorRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0))
            var u = u
            enc.setFragmentBytes(&u, length: MemoryLayout<LayerParams>.stride, index: 0)
            enc.setFragmentTexture(t0, index: 0); enc.setFragmentTexture(t1, index: 1)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        let full = CGRect(origin: .zero, size: canvas)
        var base = LayerParams()
        base.canvas = SIMD4(Float(canvas.width), Float(canvas.height), SdrBrightness.clamp(sdrWhiteNits), 0)
        base.fmt.z = outTransfer
        // Nothing beneath an opaque layer that covers the canvas can show, so start there (the live game usually
        // does), and draw it without blending. Exact when canvas pixels are target pixels: every pixel centre then
        // sits half a pixel inside the canvas, where such a layer's coverage and alpha are 1.
        let aligned = vp.originX == vp.originX.rounded() && vp.originY == vp.originY.rounded() && vp.width == canvas.width && vp.height == canvas.height
        let cover = aligned ? layers.lastIndex { $0.covers(full) } : nil
        if cover == nil {
            var bg = base
            bg.dst = SIMD4(full); bg.color = background; bg.fmt.x = 2
            draw(bg, area: full, blank8, blank8c)
        }
        let opaque = cover.map { _ in layerPipelines?.opaque ?? pipeline("layerFrag", target.pixelFormat) }
        for (i, l) in layers.enumerated() where i >= cover ?? 0 {
            if let o = opaque { enc.setRenderPipelineState(i == cover ? o : blended) }
            let r = l.resolved
            var u = base, t0 = blank8, t1 = blank8c
            u.dst = SIMD4(r.dst); u.src = SIMD4(r.src)
            u.shape = SIMD4(Float(r.radius), Float(r.border), Float(r.shadow), Float(r.opacity))
            u.flags.y = r.mirror ? 1 : 0; u.flags.z = r.hardEdge ? 1 : 0
            switch l.textures {
            case let .biplanar(y, c, bits, transfer, bt709):
                u.fmt.x = 0; u.fmt.y = transfer; u.fmt.w = bits; u.flags.x = bt709 ? 1 : 0; t0 = y; t1 = c
            case let .rgba(t): u.fmt.x = 1; t0 = t
            case .none: u.fmt.x = 2; u.color = r.color ?? SIMD4(0, 0, 0, 0)
            }
            // Half a pixel of edge coverage, plus the shadow: it reaches `shadow` past the frame and 0.35·shadow lower.
            u.ringColor = r.frameColor; u.ringShape.x = Float(r.frameWidth)
            let grow = max(r.shadow * 1.35, r.frameWidth) + 1
            draw(u, area: r.dst.insetBy(dx: -grow, dy: -grow), t0, t1)

        }
    }

    func encodeConvert(_ cb: MTLCommandBuffer, fragment: String, source: MTLTexture, target: MTLTexture) {
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = target
        rp.colorAttachments[0].loadAction = .dontCare; rp.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { return }
        enc.setRenderPipelineState(pipeline(fragment, target.pixelFormat))
        enc.setFragmentTexture(source, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
    }
}

