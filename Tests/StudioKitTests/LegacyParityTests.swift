import XCTest
import Metal
@testable import StudioKit

/// The former fixed game-plus-camera fragment shader (removed from the app with `CompParams`), frozen here as the
/// pixel reference for the layer templates. It reuses the app shader's colour helpers, which did not change.
let legacyCompositorShader = """
struct Comp {
    float4 canvas;      // w, h, -, -
    float4 screenDst, screenSrc, camDst, camSrc;
    float4 shape;       // corner radius px, border px, shadow px, -
    float4 bg;          // background, SDR BT.709 code values
    int4 fmt;           // screen transfer (0 PQ, 1 HLG, 2 SDR), output transfer, screen bits, camera bits
    int4 flags;         // screen visible, camera visible, mirror camera, -
    int4 fmt2;          // camera transfer, screen uses BT.709 matrix, camera uses BT.709 matrix, -
};

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

// Largest channel difference of two same-sized images as float bits (out[0]), how many pixels exceed the tolerance
// (out[1]) and the first of them in row order as y << 16 | x (out[2]).
kernel void maxDiff(texture2d<float, access::read> a [[texture(0)]], texture2d<float, access::read> b [[texture(1)]],
                    device atomic_uint *out [[buffer(0)]], constant float &tol [[buffer(1)]], uint2 g [[thread_position_in_grid]]) {
    if (g.x >= a.get_width() || g.y >= a.get_height()) return;
    float4 d = abs(a.read(g) - b.read(g));
    float m = max(max(d.r, d.g), max(d.b, d.a));
    atomic_fetch_max_explicit(&out[0], as_type<uint>(m), memory_order_relaxed);
    if (m > tol) {
        atomic_fetch_add_explicit(&out[1], 1u, memory_order_relaxed);
        atomic_fetch_min_explicit(&out[2], (g.y << 16) | g.x, memory_order_relaxed);
    }
}
"""

/// Uniforms of the frozen `compositeFrag`; layout matches its `Comp` struct.
struct LegacyComp {
    var canvas = SIMD4<Float>(1, 1, 0, 0)
    var screenDst = SIMD4<Float>(0, 0, 1, 1), screenSrc = SIMD4<Float>(0, 0, 1, 1)
    var camDst = SIMD4<Float>(0, 0, 0, 0), camSrc = SIMD4<Float>(0, 0, 1, 1)
    var shape = SIMD4<Float>(0, 0, 0, 0)
    var bg = SIMD4<Float>(0.06, 0.06, 0.07, 1)
    var fmt = SIMD4<Int32>(0, 0, 10, 8)
    var flags = SIMD4<Int32>(1, 0, 0, 0)
    var fmt2 = SIMD4<Int32>(2, 0, 1, 0)
}

extension CompositorGoldenTests {
    /// Every pixel of every legacy layout through the layer compositor against the frozen fixed shader, at canvas
    /// sizes where letterboxed (`fit`) edges land on half pixels. The 16x9 golden grid cannot see edge rows.
    func testLegacyLayoutsFullFrame() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let core = MetalCore.shared
        let library = try device.makeLibrary(source: compositorShader + legacyCompositorShader, options: nil)
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = library.makeFunction(name: "vtx"); d.fragmentFunction = library.makeFunction(name: "compositeFrag")
        d.colorAttachments[0].pixelFormat = .rgba16Float
        let legacy = try device.makeRenderPipelineState(descriptor: d)
        let diff = try device.makeComputePipelineState(function: XCTUnwrap(library.makeFunction(name: "maxDiff")))
        let (screen, camera) = sources()
        let camSize = CGSize(width: 1280, height: 720)
        var tol: Float = 0.002

        func target(_ s: CGSize) -> MTLTexture {
            let t = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: Int(s.width), height: Int(s.height), mipmapped: false)
            t.storageMode = .private; t.usage = [.shaderRead, .renderTarget]
            return device.makeTexture(descriptor: t)!
        }
        /// (max difference, pixels over tolerance, first such pixel) between the two paths.
        func compare(_ layout: CanvasLayout, canvas: CGSize, game: CGSize, mirror: Bool, transfer: Int32, a: MTLTexture, b: MTLTexture,
                     edit: (inout [ResolvedLayer]) -> Void = { _ in }) -> (Float, UInt32, (Int, Int)) {
            let comp = Composition.from(layout: layout, canvas: canvas, hasCamera: true, mirror: mirror)
            var resolved = SceneResolver.resolve(comp, canvas: canvas, sources: [.game: SourceInfo(size: game), .camera: SourceInfo(size: camSize)])
            edit(&resolved)
            let layers = DrawLayer.pair(resolved, [.game: .biplanar(y: screen.0, c: screen.1, bits: 10, transfer: 0, bt709: false),
                                                   .camera: .biplanar(y: camera.0, c: camera.1, bits: 8, transfer: 2, bt709: true)])
            let p = LegacyLayout(layout: layout, canvas: canvas, screen: game, camera: camSize)
            var u = LegacyComp()
            u.canvas = SIMD4(Float(canvas.width), Float(canvas.height), 0, 0)
            u.screenDst = SIMD4(p.screenDst); u.screenSrc = SIMD4(p.screenSrc); u.camDst = SIMD4(p.camDst); u.camSrc = SIMD4(p.camSrc)
            u.shape = SIMD4(Float(p.radius), Float(p.border), Float(p.shadow), 0)
            u.fmt.y = transfer
            u.flags = SIMD4(p.showScreen ? 1 : 0, p.showCam ? 1 : 0, mirror ? 1 : 0, 0)

            let cb = core.queue.makeCommandBuffer()!
            core.encodeLayers(cb, target: a, canvas: canvas, background: comp.backgroundColor, outTransfer: transfer, layers: layers)
            let rp = MTLRenderPassDescriptor()
            rp.colorAttachments[0].texture = b; rp.colorAttachments[0].loadAction = .clear; rp.colorAttachments[0].storeAction = .store
            let enc = cb.makeRenderCommandEncoder(descriptor: rp)!
            enc.setRenderPipelineState(legacy)
            for (i, t) in [screen.0, screen.1, camera.0, camera.1].enumerated() { enc.setFragmentTexture(t, index: i) }
            enc.setFragmentBytes(&u, length: MemoryLayout<LegacyComp>.stride, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            enc.endEncoding()
            let out = device.makeBuffer(bytes: [UInt32(0), 0, UInt32.max], length: 12, options: .storageModeShared)!
            let ce = cb.makeComputeCommandEncoder()!
            ce.setComputePipelineState(diff)
            ce.setTexture(a, index: 0); ce.setTexture(b, index: 1)
            ce.setBuffer(out, offset: 0, index: 0); ce.setBytes(&tol, length: 4, index: 1)
            ce.dispatchThreads(MTLSize(width: a.width, height: a.height, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            ce.endEncoding()
            cb.commit(); cb.waitUntilCompleted()
            XCTAssertEqual(cb.status, .completed)
            let r = out.contents().bindMemory(to: UInt32.self, capacity: 3)
            return (Float(bitPattern: r[0]), r[1], (Int(r[2] & 0xFFFF), Int(r[2] >> 16)))
        }

        // Camera styles: the goldens' (rounded, border, shadow) and a plain square window, which the old shader still
        // anti-aliased. Game sources: 16:9 and 4:3, so `fit` letterboxes on both canvases.
        var styled = CameraPlacement(); styled.border = true; styled.shadow = true
        var plain = CameraPlacement(x: 0.37, y: 0.41, size: 0.33, roundness: 0); plain.shadow = false
        var worst: Float = 0, cases = 0, halfPixelEdges = 0
        for canvas in [CGSize(width: 1080, height: 1920), CGSize(width: 1920, height: 1080), CGSize(width: 405, height: 721), CGSize(width: 721, height: 405)] {
            let a = target(canvas), b = target(canvas)
            for kind in LayoutKind.allCases {
                let styles: [(String, CameraPlacement)] = kind == .pip ? [("styled", styled), ("plain", plain)] : [("styled", styled)]
                for (style, placement) in styles {
                    for fit in [false, true] {
                        for game in [CGSize(width: 1920, height: 1080), CGSize(width: 1440, height: 1080)] {
                            var layout = CanvasLayout(kind: kind, camera: placement); layout.fit = fit
                            let mirror = style == "plain"
                            if fit, kind != .cameraOnly {
                                let g = SceneResolver.resolve(.from(layout: layout, canvas: canvas, hasCamera: true, mirror: mirror), canvas: canvas,
                                                              sources: [.game: SourceInfo(size: game), .camera: SourceInfo(size: camSize)]).first { $0.key == .game }!
                                if g.dst.minX != g.dst.minX.rounded() || g.dst.minY != g.dst.minY.rounded() { halfPixelEdges += 1 }
                            }
                            for transfer: Int32 in 0...2 {
                                let (m, n, at) = compare(layout, canvas: canvas, game: game, mirror: mirror, transfer: transfer, a: a, b: b)
                                worst = max(worst, m); cases += 1
                                XCTAssertEqual(n, 0, "\(Int(canvas.width))x\(Int(canvas.height)) \(kind) camera=\(style) fit=\(fit) game=\(Int(game.width))x\(Int(game.height)) transfer \(transfer): max \(m), first at \(at)")
                            }
                        }
                    }
                }
            }
        }
        print("legacy full-frame parity: \(cases) cases, \(halfPixelEdges * 3) with a letterbox edge on a half pixel, max difference \(worst)")
        XCTAssertEqual(cases, 4 * 5 * 2 * 2 * 3)
        XCTAssertGreaterThan(halfPixelEdges, 0, "no case puts a fitted edge on a half pixel")

        // The check sees the edge rows: anti-aliasing the game, as before the hard-edge flag, fails it.
        let canvas = CGSize(width: 1080, height: 1920)
        var layout = CanvasLayout(kind: .stacked); layout.fit = true
        let (m, n, _) = compare(layout, canvas: canvas, game: CGSize(width: 1920, height: 1080), mirror: false, transfer: 0,
                                a: target(canvas), b: target(canvas)) { r in
            for i in r.indices { r[i].hardEdge = false }
        }
        print("legacy full-frame parity, game anti-aliased instead: max difference \(m), \(n) pixels over tolerance")
        XCTAssertGreaterThan(m, 0.1); XCTAssertGreaterThan(n, 0)
    }
}
