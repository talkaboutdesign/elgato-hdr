import XCTest
@testable import StudioKit

final class SceneTests: XCTestCase {
    func assertRect(_ a: CGRect, _ b: SIMD4<Float>, _ msg: String, file: StaticString = #filePath, line: UInt = #line) {
        for (x, y) in zip([a.minX, a.minY, a.width, a.height], [b.x, b.y, b.z, b.w]) { XCTAssertEqual(Double(x), Double(y), accuracy: 0.001, msg, file: file, line: line) }
    }

    /// Every template resolves to the rectangles and shape the fixed-layout shader parameters held.
    func testTemplatesMatchLayoutParams() {
        let screen = CGSize(width: 2560, height: 1440), cam = CGSize(width: 1280, height: 720)
        var variants: [CanvasLayout] = []
        for kind in LayoutKind.allCases {
            for fit in [false, true] {
                for (zoom, panX, panY) in [(1.0, 0.5, 0.5), (1.7, 0.2, 0.9)] {
                    var l = CanvasLayout(kind: kind, camera: CameraPlacement(x: 0.3, y: 0.8, size: 0.4, aspect: .classic, roundness: 0.7))
                    l.fit = fit; l.zoom = zoom; l.panX = panX; l.panY = panY; l.camera.border = true; l.camera.shadow = kind == .pip
                    variants.append(l)
                }
            }
            variants.append(kind == .stacked ? .verticalDefault : CanvasLayout(kind: kind))
        }
        for canvasKind in Canvas.allCases {
            let canvas = canvasKind.size(.hd)
            for layout in variants {
                for hasCamera in [true, false] {
                    for mirror in [false, true] {
                        let name = "\(canvasKind) \(layout.kind) fit=\(layout.fit) zoom=\(layout.zoom) camera=\(hasCamera) mirror=\(mirror)"
                        let p = LayoutMath.params(layout: layout, canvas: canvas, screen: screen, camera: hasCamera ? cam : nil, mirror: mirror,
                                                  screenTransfer: 0, outTransfer: 0)
                        var sources: [SourceKey: SourceInfo] = [.game: SourceInfo(size: screen)]
                        if hasCamera { sources[.camera] = SourceInfo(size: cam) }
                        let comp = Composition.from(layout: layout, canvas: canvas, hasCamera: hasCamera, mirror: mirror)
                        XCTAssertEqual(comp.background, [0.06, 0.06, 0.07, 1])
                        let r = SceneResolver.resolve(comp, canvas: canvas, sources: sources)
                        let game = r.first { $0.key == .game }, camera = r.first { $0.key == .camera }
                        XCTAssertEqual(game != nil, p.flags.x != 0, name)
                        XCTAssertEqual(camera != nil, p.flags.y != 0, name)
                        XCTAssertEqual(r.count, (game != nil ? 1 : 0) + (camera != nil ? 1 : 0), name)
                        if let g = game {
                            assertRect(g.dst, p.screenDst, name); assertRect(g.src, p.screenSrc, name)
                            XCTAssertEqual([g.radius, g.border, g.shadow], [0, 0, 0], name)
                            XCTAssertFalse(g.mirror, name); XCTAssertEqual(g.opacity, 1); XCTAssertNil(g.color)
                        }
                        if let c = camera {
                            assertRect(c.dst, p.camDst, name); assertRect(c.src, p.camSrc, name)
                            for (a, b) in zip([c.radius, c.border, c.shadow], [p.shape.x, p.shape.y, p.shape.z]) { XCTAssertEqual(Double(a), Double(b), accuracy: 0.001, name) }
                            XCTAssertEqual(c.mirror, p.flags.z != 0, name); XCTAssertEqual(c.opacity, 1)
                        }
                        if layout.kind == .pip, hasCamera { XCTAssertEqual(r.map(\.key), [.game, .camera], name) }
                    }
                }
            }
        }
    }

    func testResolverRules() {
        let canvas = CGSize(width: 200, height: 100)
        let red = Layer(name: "Red", source: LayerSource(type: "color", color: [1, 0, 0, 0.5]), frame: NRect(x: 0.5, y: 0, w: 0.5, h: 0.5),
                        roundness: 0.9, border: true, shadow: true, opacity: 0.25)
        let image = Layer(source: LayerSource(type: "image", file: "logo.png"), frame: NRect(x: 0, y: 0, w: 0.5, h: 1), fit: true)
        let comp = Composition(layers: [
            Layer(source: .camera), red, Layer(source: .game, visible: false), image,
            Layer(source: LayerSource(type: "hologram")), Layer(source: LayerSource(type: "color", color: [1])),
            Layer(source: .game, opacity: 0),
        ])
        let r = SceneResolver.resolve(comp, canvas: canvas, sources: [.layer(image.id): SourceInfo(size: CGSize(width: 50, height: 25))])
        // No camera source, hidden, unknown type, malformed color and invisible layers are skipped.
        XCTAssertEqual(r.map(\.key), [.layer(red.id), .layer(image.id)])
        XCTAssertEqual(r[0], ResolvedLayer(key: .layer(red.id), dst: CGRect(x: 100, y: 0, width: 100, height: 50), src: CGRect(x: 0, y: 0, width: 1, height: 1),
                                           radius: 25, border: 2, shadow: 8, opacity: 0.25, mirror: false, color: SIMD4(1, 0, 0, 0.5)))
        XCTAssertEqual(r[1].dst, CGRect(x: 0, y: 25, width: 100, height: 50))
        XCTAssertEqual(r[1].src, CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertEqual([r[1].radius, r[1].border, r[1].shadow], [0, 0, 0])
        // A bigger layer gets proportional border and shadow.
        let big = SceneResolver.resolve(Composition(layers: [Layer(source: .game, border: true, shadow: true)]), canvas: CGSize(width: 1920, height: 1080),
                                        sources: [.game: SourceInfo(size: CGSize(width: 1920, height: 1080))])
        XCTAssertEqual(big[0].border, 1920 * 0.018, accuracy: 1e-9); XCTAssertEqual(big[0].shadow, 1920 * 0.08, accuracy: 1e-9)
    }

    func testLenientCoding() throws {
        let s = try JSONDecoder().decode(Scene.self, from: Data(#"{"name":"Just chatting","wide":{"layers":[{"source":{"type":"camera"},"opacity":0.5,"future":1},{}]}}"#.utf8))
        XCTAssertEqual(s.name, "Just chatting")
        XCTAssertEqual(s.vertical, Composition())
        XCTAssertEqual(s.wide.background, [0.06, 0.06, 0.07, 1])
        XCTAssertEqual(s.wide.layers.count, 2)
        let cam = s.wide.layers[0]
        XCTAssertEqual(cam.source, .camera); XCTAssertEqual(cam.opacity, 0.5); XCTAssertEqual(cam.frame, .full)
        XCTAssertTrue(cam.visible); XCTAssertEqual(cam.zoom, 1); XCTAssertEqual(cam.panX, 0.5)
        XCTAssertEqual(s.wide.layers[1].source.type, "")
        let n = try JSONDecoder().decode(NRect.self, from: Data(#"{"x":0.25}"#.utf8))
        XCTAssertEqual(n, NRect(x: 0.25, y: 0, w: 1, h: 1))

        var scene = Scene(name: "Gameplay")
        scene.wide = .from(layout: .wideDefault, canvas: Canvas.wide.size(.hd), hasCamera: true, mirror: true)
        scene.vertical = .from(layout: .verticalDefault, canvas: Canvas.vertical.size(.hd), hasCamera: true, mirror: false)
        scene.wide.layers.append(Layer(name: "Tint", source: LayerSource(type: "color", color: [0, 0, 1, 0.2])))
        XCTAssertEqual(try JSONDecoder().decode(Scene.self, from: JSONEncoder().encode(scene)), scene)
        XCTAssertEqual(scene.composition(.vertical), scene.vertical)
    }
}
