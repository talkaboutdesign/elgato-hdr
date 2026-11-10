// What the scene UI (strip, Scene tab, canvas switch, picture editing) reads. Main thread only; `AppDelegate`
// owns the logic and fills in `actions`, as `StudioState` does for the rest of the studio.
import AppKit
import Observation

@Observable
final class SceneModel {
    var collection = SceneCollection.defaults()
    /// The canvas the window shows and edits.
    var canvas: Canvas = .wide
    var selectedLayerID: UUID?
    /// Crop mode for this layer: dragging pans the source inside the frame, scrolling zooms.
    var cropLayerID: UUID?
    /// The switch in progress, for the strip's animation.
    var transition: TransitionMark?
    var punchedIn = false
    var punchAmount = 1.6
    var renamingSceneID: UUID?
    var galleryOpen = false
    var addLayerOpen = false
    /// A text layer whose inspector field should take keyboard focus once shown (double-click, a new text layer).
    var focusTextLayerID: UUID?
    /// Template previews for the add-scene gallery, with fixed ids so their thumbnails can be cached.
    @ObservationIgnored let templates: [(template: SceneTemplate, scene: Scene)] = SceneTemplate.allCases.map { ($0, $0.scene()) }
    let thumbnails = SceneThumbnails()
    @ObservationIgnored var actions = SceneActions()

    /// Capture before opening a panel or starting file I/O; completion may arrive after navigation.
    func captureImageImport(_ completion: @escaping (UUID, Canvas, CGSize, String, CGSize) -> Void) -> (String, CGSize) -> Void {
        let id = collection.activeID, target = canvas, size = canvasSize
        return { name, native in completion(id, target, size, name, native) }
    }

    var active: Scene { collection.active }
    /// The active scene's composition on the shown canvas.
    var composition: Composition { collection.active.composition(canvas) }
    var selectedLayer: Layer? { selectedLayerID.flatMap { id in composition.layers.first { $0.id == id } } }
    var canvasSize: CGSize { canvas.size(.hd) }
}

struct TransitionMark: Equatable { let id: UUID; let start: Date; let duration: TimeInterval }

/// Card images, published twice a second; a separate object so only the cards re-render.
@Observable
final class SceneThumbnails {
    var images: [UUID: CGImage] = [:]
    var canvas: Canvas = .wide
}

struct SceneActions {
    var switchTo: (UUID) -> Void = { _ in }
    var add: (SceneTemplate) -> Void = { _ in }
    var duplicate: (UUID) -> Void = { _ in }
    var delete: (UUID) -> Void = { _ in }
    var rename: (UUID, String) -> Void = { _, _ in }
    var move: (UUID, Int) -> Void = { _, _ in }            // scene to index
    var updateFromCurrent: (UUID) -> Void = { _ in }       // copy the active scene's layout into this one
    var setCanvas: (Canvas) -> Void = { _ in }
    var setTransition: (SceneTransition) -> Void = { _ in }
    var setPunchAmount: (Double) -> Void = { _ in }
    var togglePunchIn: () -> Void = {}
    var selectLayer: (UUID?) -> Void = { _ in }
    /// Edits one layer of the active scene on the shown canvas.
    var editLayer: (UUID, (inout Layer) -> Void) -> Void = { _, _ in }
    var moveLayer: (UUID, Int) -> Void = { _, _ in }       // layer to index, bottom first
    var addLayer: (String) -> Void = { _ in }              // "game" | "camera" | "color" | "text"
    var deleteLayer: (UUID) -> Void = { _ in }
    /// An image layer from a file (nil: choose one) centred at a canvas point (nil: the middle).
    var addImage: (URL?, CGPoint?) -> Void = { _, _ in }
    /// Chooses a new file for an image layer, keeping its place and width.
    var replaceImage: (UUID) -> Void = { _ in }
    var addPreset: (LayerPreset) -> Void = { _ in }
    /// Selects a text layer and puts the cursor in the inspector's text field.
    var editText: (UUID) -> Void = { _ in }
    var copyLayoutToOtherCanvas: () -> Void = {}
    var setCrop: (UUID?) -> Void = { _ in }
    /// A drag or slider: the edits in between become one undo step.
    var beginGesture: () -> Void = {}
    var endGesture: (String) -> Void = { _ in }
}

extension Layer {
    var isGameOrCamera: Bool { source.type == "game" || source.type == "camera" }
    var symbol: String {
        switch source.type {
        case "game": "gamecontroller.fill"
        case "camera": "person.crop.rectangle.fill"
        case "image": "photo.fill"
        case "text": "textformat"
        case "color": "paintpalette.fill"
        default: "square.dashed"
        }
    }
    var displayName: String {
        if !name.isEmpty { return name }
        switch source.type {
        case "game": return "Game"; case "camera": return "Camera"; case "color": return "Color"
        case "text": return (source.text?.string).map { $0.isEmpty ? "Text" : String($0.split(separator: "\n").first ?? "Text") } ?? "Text"
        default: return source.type.capitalized
        }
    }
}

// What the add-layer palette makes, the same live and in the editor.
extension Layer {
    /// A new layer of `type` ("game", "camera", "color", "text") for `c` on `canvas`; nil for anything else.
    static func added(_ type: String, canvas: Canvas, to c: Composition, mirror: Bool) -> Layer? {
        let size = canvas.size(.hd)
        switch type {
        case "camera":
            var p = CameraPlacement(); p.shadow = true
            return Layer(name: "Camera", source: .camera, frame: NRect(p.rect(in: size), in: size), roundness: p.roundness, shadow: true, mirror: mirror)
        case "game":
            // A second game layer starts as a window, so it is visible over the first.
            let has = c.layers.contains { $0.source.type == "game" }
            var l = Layer(name: "Game", source: .game, frame: has ? NRect(x: 0.25, y: 0.25, w: 0.5, h: 0.5) : .full)
            if has { l.roundness = 0.06; l.shadow = true }
            return l
        case "color":
            return Layer(name: "Backdrop", source: LayerSource(type: "color", color: [0.11, 0.12, 0.16, 1]))
        case "text":
            // Unnamed, so the layer list shows what it says.
            let v = canvas == .vertical
            return Layer(source: LayerSource(type: "text", text: TextSpec(string: "Your text", weight: "bold")),
                         frame: v ? NRect(x: 0.1, y: 0.45, w: 0.8, h: 0.06) : NRect(x: 0.25, y: 0.43, w: 0.5, h: 0.12))
        default: return nil
        }
    }

    /// An image layer's frame: centred at `point` (canvas pixels) or in the middle, at most 40% of the canvas and never
    /// larger than the image, kept inside the canvas.
    static func imageFrame(native: CGSize, canvas: CGSize, at point: CGPoint?) -> NRect {
        let k = min(1, canvas.width * 0.4 / max(native.width, 1), canvas.height * 0.4 / max(native.height, 1))
        let w = max(LayerResize.minSide, (native.width * k).rounded()), h = max(LayerResize.minSide, (native.height * k).rounded())
        let c = point ?? CGPoint(x: canvas.width / 2, y: canvas.height / 2)
        let r = CGRect(x: min(max(c.x - w / 2, 0), max(0, canvas.width - w)), y: min(max(c.y - h / 2, 0), max(0, canvas.height - h)), width: w, height: h)
        return NRect(r, in: canvas)
    }

    /// The same place and width for a replacement image, its height from the new image's aspect.
    func replacingImage(_ name: String, native: CGSize, canvas: CGSize) -> Layer {
        var l = self, r = frame.rect(in: canvas)
        r.size.height = (r.width * native.height / max(native.width, 1)).rounded()
        l.source.file = name; l.frame = NRect(r, in: canvas)
        return l
    }
}

extension Composition {
    /// Colour backdrops go to the bottom, everything else on top.
    mutating func add(_ l: Layer) { if l.source.type == "color" { layers.insert(l, at: 0) } else { layers.append(l) } }
    /// Game and camera are hidden rather than deleted: scenes keep their place in the stack. Returns the undo name.
    @discardableResult mutating func delete(_ id: UUID) -> String? {
        guard let j = layers.firstIndex(where: { $0.id == id }) else { return nil }
        if layers[j].isGameOrCamera { layers[j].visible = false; return "Hide Layer" }
        layers.remove(at: j); return "Delete Layer"
    }
    mutating func move(_ id: UUID, to index: Int) {
        guard let i = layers.firstIndex(where: { $0.id == id }) else { return }
        let l = layers.remove(at: i)
        layers.insert(l, at: min(max(index, 0), layers.count))
    }
}
