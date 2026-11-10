// Scenes: each canvas (16:9, 9:16) of a scene is an ordered list of layers drawn bottom first by the one compositor.
// The fixed layouts of a project (`CanvasLayout`) are templates that generate such a list. Every struct decodes
// leniently with `c.v(key, fallback)` so later versions can add fields; the decoders live in extensions to keep the
// memberwise initializers.
import CoreGraphics
import Foundation

/// A rectangle normalized to the canvas, origin top-left.
struct NRect: Codable, Equatable {
    var x, y, w, h: Double
    static let full = NRect(x: 0, y: 0, w: 1, h: 1)
}
extension NRect {
    init(_ r: CGRect, in canvas: CGSize) {
        self.init(x: r.minX / canvas.width, y: r.minY / canvas.height, w: r.width / canvas.width, h: r.height / canvas.height)
    }
    func rect(in canvas: CGSize) -> CGRect { CGRect(x: x * canvas.width, y: y * canvas.height, width: w * canvas.width, height: h * canvas.height) }
    enum CodingKeys: String, CodingKey { case x, y, w, h }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        self.init(x: c.v(.x, 0), y: c.v(.y, 0), w: c.v(.w, 1), h: c.v(.h, 1))
    }
}

/// Text layer contents; filled in by the overlays plan.
struct TextSpec: Codable, Equatable {}

struct LayerSource: Codable, Equatable {
    var type: String            // "game" | "camera" | "image" | "text" | "color"
    var file: String? = nil     // image: asset file name
    var text: TextSpec? = nil
    var color: [Double]? = nil  // color: r, g, b, a in SDR BT.709 code values 0…1
    static let game = LayerSource(type: "game"), camera = LayerSource(type: "camera")
}
extension LayerSource {
    enum CodingKeys: String, CodingKey { case type, file, text, color }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        self.init(type: c.v(.type, ""), file: c.v(.file, nil), text: c.v(.text, nil), color: c.v(.color, nil))
    }
}

struct Layer: Codable, Equatable, Identifiable {
    var id = UUID()
    var name = ""
    var source: LayerSource
    var frame = NRect.full      // where it sits on the canvas
    var fit = false             // false: crop the source to fill the frame; true: letterbox inside the frame
    var zoom = 1.0              // ≥ 1, crops further in
    var panX = 0.5, panY = 0.5  // centre of the crop, normalized to the source
    var roundness = 0.0         // corner radius as a fraction of the frame's shorter side, 0…0.5
    var border = false, shadow = false, mirror = false
    var opacity = 1.0
    var visible = true
}
extension Layer {
    enum CodingKeys: String, CodingKey { case id, name, source, frame, fit, zoom, panX, panY, roundness, border, shadow, mirror, opacity, visible }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self), z = Layer(source: LayerSource(type: ""))
        self.init(id: c.v(.id, UUID()), name: c.v(.name, z.name), source: c.v(.source, z.source), frame: c.v(.frame, z.frame),
                  fit: c.v(.fit, z.fit), zoom: c.v(.zoom, z.zoom), panX: c.v(.panX, z.panX), panY: c.v(.panY, z.panY),
                  roundness: c.v(.roundness, z.roundness), border: c.v(.border, z.border), shadow: c.v(.shadow, z.shadow),
                  mirror: c.v(.mirror, z.mirror), opacity: c.v(.opacity, z.opacity), visible: c.v(.visible, z.visible))
    }
}

/// One canvas of one scene.
struct Composition: Codable, Equatable {
    var background: [Double] = [0.06, 0.06, 0.07, 1]   // SDR BT.709 code values
    var layers: [Layer] = []                           // bottom first
}
extension Composition {
    enum CodingKeys: String, CodingKey { case background, layers }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self), z = Composition()
        self.init(background: c.v(.background, z.background), layers: c.v(.layers, z.layers))
    }

    /// Today's fixed layouts as layers. The split row is rounded exactly as the old shader parameters were, so the
    /// layer path renders the same pixels.
    static func from(layout: CanvasLayout, canvas: CGSize, hasCamera: Bool, mirror: Bool) -> Composition {
        var game = Layer(name: "Game", source: .game, fit: layout.fit, zoom: layout.zoom, panX: layout.panX, panY: layout.panY)
        var camera = Layer(name: "Camera", source: .camera, mirror: mirror)
        var layers: [Layer]
        switch layout.kind {
        case .pip:
            let p = layout.camera
            camera.frame = NRect(p.rect(in: canvas), in: canvas)
            camera.roundness = p.roundness; camera.border = p.border; camera.shadow = p.shadow
            layers = hasCamera ? [game, camera] : [game]
        case .stacked:
            if hasCamera {
                let split = (canvas.height * layout.split).rounded() / canvas.height
                camera.frame = NRect(x: 0, y: 0, w: 1, h: split)
                game.frame = NRect(x: 0, y: split, w: 1, h: 1 - split)
                layers = [camera, game]
            } else { layers = [game] }
        case .screenOnly: layers = [game]
        case .cameraOnly: layers = hasCamera ? [camera] : []
        }
        return Composition(layers: layers)
    }
}

struct Scene: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var wide = Composition(), vertical = Composition()
    func composition(_ c: Canvas) -> Composition { c == .wide ? wide : vertical }
}
extension Scene {
    enum CodingKeys: String, CodingKey { case id, name, wide, vertical }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        self.init(id: c.v(.id, UUID()), name: c.v(.name, ""), wide: c.v(.wide, Composition()), vertical: c.v(.vertical, Composition()))
    }
}
