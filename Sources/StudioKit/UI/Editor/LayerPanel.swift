import AppKit
import QuartzCore
import SwiftUI

// The editor's side of layer editing: the scene at the playhead with its layer list (as in the live Scene tab), and
// the shared layer inspector when a layer is picked in the preview or the list.

/// The scene at the playhead: its name and canvas, what can be done with it, and its layers.
struct EditorSceneLayers: View {
    let model: EditorModel
    var showsNote = true
    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.editedSceneName).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Text("Scene at the playhead · \(model.canvas == .wide ? "widescreen" : "vertical") canvas").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Button("Save as Live Scene") { model.saveSceneToLive() }
                    Button(model.canvas == .wide ? "Copy Layout to 9:16" : "Copy Layout to 16:9") { model.copyLayoutToOtherCanvas() }
                } label: { Image(systemName: "ellipsis.circle").font(.system(size: 14)) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Scene actions")
                .accessibilityLabel("Scene actions")
            }
            .padding(.horizontal, DS.Space.xs)
            LayerListSection(model: model)
            if showsNote {
                Text("Edits change this recording's copy of the scene; your live scenes stay as they are until you save one.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, DS.Space.xs)
            }
        }
    }
}

/// A layer picked in the preview or the list: the list stays on top so another layer is one click away.
struct LayerSelectionInspector: View {
    let model: EditorModel
    var body: some View {
        EditorSceneLayers(model: model, showsNote: false)
        if let l = model.selectedEditedLayer {
            LayerInspector(model: model, layer: l, camera: l.source.type == "camera" ? cameraExtras : nil)
        } else {
            Label("That layer is not in the scene at the playhead.", systemImage: "info.circle")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            NoSelectionHint()
        }
    }

    /// Mirroring belongs to the camera: it applies in every scene of the recording.
    private var cameraExtras: CameraLayerExtras {
        let m = model
        return CameraLayerExtras(mirror: m.project.cameraMirror, setMirror: { on in m.update("Mirror") { $0.cameraMirror = on } },
                                 help: "Flip the camera horizontally, in every scene of this recording")
    }
}

/// "Add from Live Scenes": a live scene this recording does not have yet, copied in with its images.
struct AddLiveSceneMenu: View {
    let model: EditorModel
    var run: SceneRun? = nil
    var body: some View {
        let scenes = model.liveScenesToAdd
        Menu {
            if scenes.isEmpty { Text("Every live scene is already in this recording") }
            ForEach(scenes) { s in Button(s.name) { model.addLiveScene(s, for: run) } }
        } label: {
            Label("Add from Live Scenes", systemImage: "square.and.arrow.down.on.square").font(.system(size: 12))
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help(run == nil ? "Copy one of your live scenes into this recording and change to it at the playhead"
                         : "Copy one of your live scenes into this recording and use it for this part")
    }
}

/// The preview's layer editing: `LayerCanvasView` over the player, on the scene at the playhead.
struct EditorLayerStage: View {
    let model: EditorModel
    var body: some View {
        // Read here so SwiftUI updates the view when any of it changes (never the 60 Hz playhead itself).
        let state = EditorStageView.State(composition: model.editedComposition, selection: model.selection, crop: model.cropLayerID,
                                          canvas: model.canvas, enabled: !model.editsLocked, revision: model.previewRevision)
        EditorStageRepresentable(model: model, state: state)
            .accessibilityElement()
            .accessibilityLabel("Picture")
            .accessibilityHint("Click a layer to select it, drag to move it, drag a handle to resize it")
    }
}

private struct EditorStageRepresentable: NSViewRepresentable {
    let model: EditorModel
    let state: EditorStageView.State
    func makeNSView(context: Context) -> EditorStageView { EditorStageView(model: model) }
    func updateNSView(_ v: EditorStageView, context: Context) { v.apply(state) }
}

final class EditorStageView: LayerCanvasView {
    struct State: Equatable {
        var composition: Composition
        var selection: TimelineSelection
        var crop: UUID?
        var canvas: Canvas
        var enabled: Bool
        var revision: Int
    }
    private weak var model: EditorModel?

    init(model: EditorModel) {
        self.model = model
        super.init(frame: .zero, host: CALayer())
        editing = model
        sources = { [weak model] in model?.stageSources() ?? [:] }
        contextMenu = { [weak model] id in model?.layerMenu(id) }
        model.layerKeys = { [weak self] e in self?.handleLayerKey(e) ?? false }
    }
    required init?(coder: NSCoder) { fatalError() }

    func apply(_ s: State) {
        canvasAspect = s.canvas == .wide ? CGSize(width: 16, height: 9) : CGSize(width: 9, height: 16)
        editingEnabled = s.enabled
        refreshOverlay()
    }
}
