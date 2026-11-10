// The sidebar's Scene tab: the active scene's layers on the shown canvas, an inspector for the selected layer, the
// transition and live zoom, and the capture settings. Edits go through `SceneModel.actions`, as picture edits do.
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SceneTab: View {
    let state: StudioState

    /// The camera layer's mirror follows the camera (every scene); its device is the studio's.
    private func cameraExtras(_ l: Layer) -> CameraLayerExtras? {
        guard l.source.type == "camera" else { return nil }
        let st = state
        return CameraLayerExtras(mirror: l.mirror, setMirror: { st.actions.setMirror($0) }, help: "Flip the camera horizontally, in every scene",
                                 device: AnyView(DevicePicker(label: "Device", devices: st.cameras, selection: st.cameraID, noneLabel: "Off",
                                                              help: "Camera shown in this layer (⌘K shows or hides it)") { st.actions.selectCamera($0) }))
    }

    var body: some View {
        let m = state.scenes
        VStack(alignment: .leading, spacing: DS.Space.xl) {
            SceneHeader(model: m)
            LayerListSection(model: m)
            if let l = m.selectedLayer { LayerInspector(model: m, layer: l, camera: cameraExtras(l)) } else { NoSelectionHint() }
            TransitionSection(model: m)
            PictureSection(state: state)
        }
    }
}

private struct SceneHeader: View {
    let model: SceneModel
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.active.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Text(model.canvas == .wide ? "Widescreen canvas" : "Vertical canvas").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button(model.canvas == .wide ? "Copy Layout to 9:16" : "Copy Layout to 16:9") { model.actions.copyLayoutToOtherCanvas() }
                Button("Duplicate Scene") { model.actions.duplicate(model.active.id) }
                Button("Rename Scene…") { model.renamingSceneID = model.active.id }
            } label: { Image(systemName: "ellipsis.circle").font(.system(size: 14)) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Scene actions")
        }
        .padding(.horizontal, DS.Space.xs)
    }
}

// MARK: - Transition

private struct TransitionSection: View {
    let model: SceneModel
    var body: some View {
        let t = model.collection.transition
        InspectorSection(title: "Switching") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Transition").font(.system(size: 12)).foregroundStyle(.secondary)
                SegmentedSwitch(selection: Binding(get: { t.style }, set: { s in var n = t; n.style = s; model.actions.setTransition(n) }),
                                options: SceneTransition.Style.allCases.map { s in
                                    .init(value: s, label: s.label, help: s == .cut ? "Switch instantly" : s == .fade ? "Cross-fade between scenes" : "Glide each layer to its new place")
                                })
            }
            LabeledSlider(label: "Duration", value: Binding(get: { t.durationMs }, set: { v in var n = t; n.durationMs = v.rounded(); model.actions.setTransition(n) }),
                          range: SceneTransition.durationRange, defaultValue: SceneTransition().durationMs, format: { String(format: "%.0f ms", $0) })
                .disabled(t.style == .cut).opacity(t.style == .cut ? 0.5 : 1)
            Divider().opacity(0.4)
            InspectorRow(label: "Live zoom") {
                Button(model.punchedIn ? "Zoom Out" : "Zoom In") { model.actions.togglePunchIn() }
                    .controlSize(.small)
                    .help("Zoom in on the game (⌃Z, or hold \(SceneKeys.holdLabel))")
            }
            LabeledSlider(label: "Zoom amount", value: Binding(get: { model.punchAmount }, set: { model.actions.setPunchAmount($0) }),
                          range: PunchIn.range, defaultValue: 1.6, format: { String(format: "%.1f×", $0) })
            Text("⌃1…⌃9 switch scenes, \(SceneKeys.previousLabel) / \(SceneKeys.nextLabel) step through them, ⌃Z zooms in on the game (or hold \(SceneKeys.holdLabel)), arrow keys move the zoom while zoomed, ⌃M marks a moment in a recording.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
