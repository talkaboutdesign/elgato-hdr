// One Metal compositor shared by the live view and by editing/export: draws the game layer and the facecam with
// its shape, border and shadow into any canvas (16:9, 9:16, ...), in PQ, HLG or SDR output. The live view and the
// exported video therefore match exactly.
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

// Mirrors `CompParams` in Swift. Rects are x, y, w, h; destinations in canvas pixels, sources normalized.
struct Comp {
    float4 canvas;      // w, h, -, -
    float4 screenDst, screenSrc, camDst, camSrc;
    float4 shape;       // corner radius px, border px, shadow px, -
    float4 bg;          // background, SDR BT.709 code values
    int4 fmt;           // screen transfer (0 PQ, 1 HLG, 2 SDR), output transfer, screen bits, camera bits
    int4 flags;         // screen visible, camera visible, mirror camera, -
    int4 fmt2;          // camera transfer, screen uses BT.709 matrix, camera uses BT.709 matrix, -
};

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

// HDR -> SDR: identity below a knee, smooth roll-off up to a 1000-nit peak, applied on max(RGB) to keep hue.
float3 linearToSdr(float3 l) {
    float3 c = max(m2020to709 * (l / 0.0203), 0.0);
    float m = max(c.r, max(c.g, c.b));
    const float k = 0.7, W = 1000.0 / 203.0, a = (1.0 - k) / (W - 1.0);
    if (m > k) {
        float x = min((m - k) / (W - k), 1.0);
        c *= (k + (1.0 - k) * x * (1.0 + a) / (x + a)) / m;
    }
    return pow(clamp(c, 0.0, 1.0), 1.0 / 2.4);
}

float3 toLinear(float3 e, int t) { return t == 0 ? pqToLinear(e) : t == 1 ? hlgToLinear(e) : sdrToLinear(e); }
float3 encodeOut(float3 l, int t) { return t == 0 ? linearToPq(l) : t == 1 ? linearToHlg(l) : linearToSdr(l); }
/// Converts a non-linear color from transfer `from` into the output transfer; untouched if they already match.
float3 convert(float3 e, int from, int to) { return from == to ? e : encodeOut(toLinear(e, from), to); }

float sdRoundRect(float2 p, float2 c, float2 h, float r) {
    float2 q = abs(p - c) - h + r;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

float3 composite(float2 p, texture2d<float> sY, texture2d<float> sC, texture2d<float> cY, texture2d<float> cC, constant Comp &u) {
    int out = u.fmt.y;
    float3 col = convert(u.bg.rgb, 2, out);
    if (u.flags.x != 0) {
        float2 t = (p - u.screenDst.xy) / u.screenDst.zw;
        if (all(t >= 0.0) && all(t <= 1.0)) {
            float3 e = yuvToRgb(sY, sC, u.screenSrc.xy + t * u.screenSrc.zw, u.fmt.z, u.fmt2.y != 0);
            col = convert(e, u.fmt.x, out);
        }
    }
    if (u.flags.y != 0) {
        float2 h = u.camDst.zw * 0.5, c = u.camDst.xy + h;
        float r = min(u.shape.x, min(h.x, h.y)), border = u.shape.y, shadow = u.shape.z;
        if (shadow > 0.0) {
            float ds = sdRoundRect(p - float2(0.0, shadow * 0.35), c, h, r);
            float a = 0.45 * (1.0 - smoothstep(-shadow * 0.5, shadow, ds));
            col = mix(col, float3(0.0), a);
        }
        float d = sdRoundRect(p, c, h, r);
        float a = clamp(0.5 - d, 0.0, 1.0);
        if (a > 0.0) {
            float2 t = clamp((p - u.camDst.xy) / u.camDst.zw, 0.0, 1.0);
            if (u.flags.z != 0) t.x = 1.0 - t.x;
            float3 cc = convert(yuvToRgb(cY, cC, u.camSrc.xy + t * u.camSrc.zw, u.fmt.w, u.fmt2.z != 0), u.fmt2.x, out);
            if (border > 0.0) cc = mix(convert(float3(1.0), 2, out), cc, clamp(-(d + border) + 0.5, 0.0, 1.0));
            col = mix(col, cc, a);
        }
    }
    return col;
}

fragment float4 compositeFrag(V in [[stage_in]], texture2d<float> sY [[texture(0)]], texture2d<float> sC [[texture(1)]],
                              texture2d<float> cY [[texture(2)]], texture2d<float> cC [[texture(3)]], constant Comp &u [[buffer(0)]]) {
    return float4(composite(in.uv * u.canvas.xy, sY, sC, cY, cC, u), 1.0);
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
"""

/// Uniforms for `composite`; layout matches the Metal `Comp` struct.
struct CompParams {
    var canvas = SIMD4<Float>(1, 1, 0, 0)
    var screenDst = SIMD4<Float>(0, 0, 1, 1), screenSrc = SIMD4<Float>(0, 0, 1, 1)
    var camDst = SIMD4<Float>(0, 0, 0, 0), camSrc = SIMD4<Float>(0, 0, 1, 1)
    var shape = SIMD4<Float>(0, 0, 0, 0)
    var bg = SIMD4<Float>(0, 0, 0, 1)
    var fmt = SIMD4<Int32>(0, 0, 10, 8)
    var flags = SIMD4<Int32>(1, 0, 0, 0)
    var fmt2 = SIMD4<Int32>(2, 0, 1, 0)

    /// Decode each layer the way its frames are actually tagged. AVFoundation may hand the compositor a layer
    /// already converted into another layer's colour space (e.g. the SDR camera into the game's PQ), so the tags on
    /// the buffer, not the source file, are what count.
    mutating func adopt(screen pb: CVPixelBuffer) {
        if let t = transfer(of: pb) { fmt.x = t }
        fmt2.y = matrixIs709(pb) ?? (fmt.x == 2) ? 1 : 0
    }
    mutating func adopt(camera pb: CVPixelBuffer) {
        fmt2.x = transfer(of: pb) ?? 2
        fmt2.z = matrixIs709(pb) ?? (fmt2.x == 2) ? 1 : 0
    }
    private func transfer(of pb: CVPixelBuffer) -> Int32? {
        guard let v = CVBufferCopyAttachment(pb, kCVImageBufferTransferFunctionKey, nil) as? String else { return nil }
        if v == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String { return 0 }
        if v == kCVImageBufferTransferFunction_ITU_R_2100_HLG as String { return 1 }
        return 2
    }
    private func matrixIs709(_ pb: CVPixelBuffer) -> Bool? {
        guard let v = CVBufferCopyAttachment(pb, kCVImageBufferYCbCrMatrixKey, nil) as? String else { return nil }
        return v != kCVImageBufferYCbCrMatrix_ITU_R_2020 as String
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
    /// Bound when a layer is absent so the shader always sees valid textures.
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

    func pipeline(_ fragment: String, _ format: MTLPixelFormat) -> MTLRenderPipelineState {
        let key = "\(fragment)/\(format.rawValue)"
        lock.lock(); defer { lock.unlock() }
        if let p = pipelines[key] { return p }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = library.makeFunction(name: "vtx"); d.fragmentFunction = library.makeFunction(name: fragment)
        d.colorAttachments[0].pixelFormat = format
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

    func texture(_ pb: CVPixelBuffer, _ format: MTLPixelFormat, plane: Int = 0) -> (MTLTexture, CVMetalTexture)? {
        var t: CVMetalTexture?
        let planar = CVPixelBufferIsPlanar(pb)
        let w = planar ? CVPixelBufferGetWidthOfPlane(pb, plane) : CVPixelBufferGetWidth(pb)
        let h = planar ? CVPixelBufferGetHeightOfPlane(pb, plane) : CVPixelBufferGetHeight(pb)
        guard CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, pb, nil, format, w, h, plane, &t) == kCVReturnSuccess,
              let ref = t, let tex = CVMetalTextureGetTexture(ref) else { return nil }
        return (tex, ref)
    }

    /// Encodes the composite into `target` as a full-screen pass.
    func encodeComposite(_ cb: MTLCommandBuffer, target: MTLTexture, viewport: MTLViewport? = nil, clear: Bool = true,
                         screen: (MTLTexture, MTLTexture)?, camera: (MTLTexture, MTLTexture)?, params: CompParams) {
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = target
        rp.colorAttachments[0].loadAction = clear ? .clear : .load; rp.colorAttachments[0].storeAction = .store
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { return }
        if let v = viewport { enc.setViewport(v) }
        enc.setRenderPipelineState(pipeline("compositeFrag", target.pixelFormat))
        enc.setFragmentTexture(screen?.0 ?? blank8, index: 0); enc.setFragmentTexture(screen?.1 ?? blank8c, index: 1)
        enc.setFragmentTexture(camera?.0 ?? blank8, index: 2); enc.setFragmentTexture(camera?.1 ?? blank8c, index: 3)
        var p = params
        enc.setFragmentBytes(&p, length: MemoryLayout<CompParams>.stride, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
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

// MARK: - AVFoundation custom compositor (editor preview + export)

final class CompositionInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let screenTrack: CMPersistentTrackID
    let cameraTrack: CMPersistentTrackID
    let params: CompParams
    let hdrOutput: Bool

    init(timeRange: CMTimeRange, screenTrack: CMPersistentTrackID, cameraTrack: CMPersistentTrackID, params: CompParams, hdrOutput: Bool) {
        self.timeRange = timeRange; self.screenTrack = screenTrack; self.cameraTrack = cameraTrack
        self.params = params; self.hdrOutput = hdrOutput
        requiredSourceTrackIDs = [screenTrack, cameraTrack].filter { $0 != kCMPersistentTrackID_Invalid }.map { NSNumber(value: $0) }
    }
}

/// Base compositor. Sources arrive as 10-bit biplanar YCbCr; the HDR subclass writes 10-bit P010 (BT.2020), the SDR
/// one writes 8-bit BGRA (BT.709).
class LayerCompositor: NSObject, AVVideoCompositing {
    class var hdr: Bool { false }
    var sourcePixelBufferAttributes: [String: any Sendable]? {
        [kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange],
         kCVPixelBufferMetalCompatibilityKey as String: true]
    }
    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [kCVPixelBufferPixelFormatTypeKey as String: [Self.hdr ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_32BGRA],
         kCVPixelBufferMetalCompatibilityKey as String: true]
    }
    var supportsHDRSourceFrames: Bool { true }
    var supportsWideColorSourceFrames: Bool { true }
    let renderQueue = DispatchQueue(label: "compositor")
    var intermediate: MTLTexture?

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}
    func cancelAllPendingVideoCompositionRequests() {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        renderQueue.async { [self] in
            guard let ins = request.videoCompositionInstruction as? CompositionInstruction,
                  let out = request.renderContext.newPixelBuffer() else {
                request.finish(with: NSError(domain: "Compositor", code: 1)); return
            }
            let core = MetalCore.shared
            var keep: [CVMetalTexture] = []
            var params = ins.params
            var screen: (MTLTexture, MTLTexture)?
            if ins.screenTrack != kCMPersistentTrackID_Invalid, let pb = request.sourceFrame(byTrackID: ins.screenTrack), let p = core.planes(pb) {
                screen = (p.0, p.1); keep += p.2; params.fmt.z = p.3; params.adopt(screen: pb)
            } else { params.flags.x = 0 }
            var camera: (MTLTexture, MTLTexture)?
            if ins.cameraTrack != kCMPersistentTrackID_Invalid, let pb = request.sourceFrame(byTrackID: ins.cameraTrack), let p = core.planes(pb) {
                camera = (p.0, p.1); keep += p.2; params.fmt.w = p.3; params.adopt(camera: pb)
            } else { params.flags.y = 0 }
            guard let cb = core.queue.makeCommandBuffer() else { request.finish(with: NSError(domain: "Compositor", code: 2)); return }
            let w = CVPixelBufferGetWidth(out), h = CVPixelBufferGetHeight(out)
            if Self.hdr {
                if intermediate?.width != w || intermediate?.height != h {
                    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
                    d.usage = [.renderTarget, .shaderRead]; d.storageMode = .private
                    intermediate = core.device.makeTexture(descriptor: d)
                }
                guard let mid = intermediate, let (yT, yRef) = core.texture(out, .r16Unorm, plane: 0), let (cT, cRef) = core.texture(out, .rg16Unorm, plane: 1) else {
                    request.finish(with: NSError(domain: "Compositor", code: 3)); return
                }
                keep += [yRef, cRef]
                core.encodeComposite(cb, target: mid, screen: screen, camera: camera, params: params)
                core.encodeConvert(cb, fragment: "lumaFrag", source: mid, target: yT)
                core.encodeConvert(cb, fragment: "chromaFrag", source: mid, target: cT)
                tag(out, hdrTransfer: params.fmt.y)
            } else {
                guard let (t, ref) = core.texture(out, .bgra8Unorm) else { request.finish(with: NSError(domain: "Compositor", code: 3)); return }
                keep.append(ref)
                core.encodeComposite(cb, target: t, screen: screen, camera: camera, params: params)
                tag(out, hdrTransfer: nil)
            }
            cb.addCompletedHandler { _ in
                _ = keep
                request.finish(withComposedVideoFrame: out)
            }
            cb.commit()
        }
    }

    private func tag(_ pb: CVPixelBuffer, hdrTransfer: Int32?) {
        let (prim, tf, mat): (CFString, CFString, CFString) = switch hdrTransfer {
        case 0: (kCVImageBufferColorPrimaries_ITU_R_2020, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, kCVImageBufferYCbCrMatrix_ITU_R_2020)
        case 1: (kCVImageBufferColorPrimaries_ITU_R_2020, kCVImageBufferTransferFunction_ITU_R_2100_HLG, kCVImageBufferYCbCrMatrix_ITU_R_2020)
        default: (kCVImageBufferColorPrimaries_ITU_R_709_2, kCVImageBufferTransferFunction_ITU_R_709_2, kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        }
        CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, prim, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, tf, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, mat, .shouldPropagate)
    }
}

final class HDRLayerCompositor: LayerCompositor { override class var hdr: Bool { true } }
final class SDRLayerCompositor: LayerCompositor { override class var hdr: Bool { false } }
