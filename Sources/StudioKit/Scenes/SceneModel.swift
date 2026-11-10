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
