// The sidebar's Scene tab: the active scene's layers on the shown canvas, an inspector for the selected layer, the
// transition and live zoom, and the capture settings. Edits go through `SceneModel.actions`, as picture edits do.
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SceneTab: View {
    let state: StudioState
    var body: some View {
        let m = state.scenes
        VStack(alignment: .leading, spacing: DS.Space.xl) {
            SceneHeader(model: m)
            LayerListSection(model: m)
            if let l = m.selectedLayer { LayerInspector(state: state, layer: l) } else { NoSelectionHint() }
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

// MARK: - Layers

private struct LayerListSection: View {
    let model: SceneModel
    @State private var dragging: UUID?

    var body: some View {
        // Topmost first, as in every layers panel; the composition stores them bottom first.
        let layers = Array(model.composition.layers.reversed())
        InspectorSection(title: "Layers", trailing: AnyView(AddLayerMenu(model: model))) {
            VStack(spacing: 2) {
                ForEach(layers) { l in
                    LayerRow(model: model, layer: l, selected: model.selectedLayerID == l.id)
                        .onDrag { dragging = l.id; return NSItemProvider(object: l.id.uuidString as NSString) }
                        .onDrop(of: [UTType.text], delegate: LayerDropDelegate(target: l.id, model: model, dragging: $dragging))
                }
                if layers.isEmpty {
                    Text("No layers. Add the game or the camera with +.").font(.system(size: 11)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, DS.Space.xs)
                }
            }
            .padding(-DS.Space.xs)
        }
    }
}

private struct LayerDropDelegate: DropDelegate {
    let target: UUID
    let model: SceneModel
    @Binding var dragging: UUID?
    func dropEntered(info: DropInfo) {
        guard let d = dragging, d != target, let to = model.composition.layers.firstIndex(where: { $0.id == target }) else { return }
        withAnimation(DS.Motion.snappy) { model.actions.moveLayer(d, to) }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool { dragging = nil; return true }
}

private struct LayerRow: View {
    let model: SceneModel
    let layer: Layer
    let selected: Bool
    @State private var hover = false
    @State private var renaming = false
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: layer.symbol).font(.system(size: 11)).frame(width: 18)
                .foregroundStyle(selected ? Color.white : Color.secondary)
            if renaming {
                TextField("Name", text: $name).textFieldStyle(.plain).font(.system(size: 12)).focused($focused)
                    .onSubmit { commit() }.onExitCommand { renaming = false }
                    .onChange(of: focused) { _, f in if !f && renaming { commit() } }
            } else {
                Text(layer.displayName).font(.system(size: 12, weight: selected ? .medium : .regular)).lineLimit(1)
                    .foregroundStyle(layer.visible ? Color.primary : Color.secondary)
            }
            Spacer(minLength: 0)
            Button { model.actions.editLayer(layer.id) { $0.visible.toggle() } } label: {
                Image(systemName: layer.visible ? "eye" : "eye.slash").font(.system(size: 11))
                    .foregroundStyle(selected ? Color.white.opacity(0.9) : layer.visible ? Color.secondary : Color.secondary.opacity(0.6))
                    .frame(width: 22, height: 20).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(hover || !layer.visible || selected ? 1 : 0.0001)
            .help(layer.visible ? "Hide \(layer.displayName) in this scene" : "Show \(layer.displayName)")
            .accessibilityLabel(layer.visible ? "Hide" : "Show")
        }
        .padding(.horizontal, DS.Space.s).frame(height: 28)
        .background(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
            .fill(selected ? Color.accentColor.opacity(0.85) : hover ? Color.white.opacity(0.06) : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { name = layer.displayName; renaming = true; DispatchQueue.main.async { focused = true } }
        .simultaneousGesture(TapGesture().onEnded { model.actions.selectLayer(layer.id) })
        .contextMenu {
            Button("Rename") { name = layer.displayName; renaming = true; DispatchQueue.main.async { focused = true } }
            Button(layer.visible ? "Hide" : "Show") { model.actions.editLayer(layer.id) { $0.visible.toggle() } }
            Divider()
            Button("Bring to Front") { model.actions.moveLayer(layer.id, Int.max) }
            Button("Send to Back") { model.actions.moveLayer(layer.id, 0) }
            if !layer.isGameOrCamera { Divider(); Button("Delete", role: .destructive) { model.actions.deleteLayer(layer.id) } }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func commit() {
        renaming = false
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !n.isEmpty && n != layer.name { model.actions.editLayer(layer.id) { $0.name = n } }
    }
}

private struct AddLayerMenu: View {
    let model: SceneModel
    var body: some View {
        Menu {
            Button("Game") { model.actions.addLayer("game") }
            Button("Camera") { model.actions.addLayer("camera") }
            Button("Color Backdrop") { model.actions.addLayer("color") }
            Divider()
            Button("Image and Text (coming soon)") {}.disabled(true)
        } label: { Image(systemName: "plus").font(.system(size: 11, weight: .semibold)) }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("Add a layer to this scene")
    }
}

private struct NoSelectionHint: View {
    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.s) {
            Image(systemName: "cursorarrow.click.2").foregroundStyle(.secondary)
            Text("Click a layer on the picture or in the list to arrange it. Drag to move, drag a handle to resize, double-click the game or camera to crop.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, DS.Space.xs)
    }
}

// MARK: - Inspector

private struct LayerInspector: View {
    let state: StudioState
    let layer: Layer
    var model: SceneModel { state.scenes }

    var body: some View {
        let size = model.canvasSize
        let r = layer.frame.rect(in: size)
        let id = layer.id
        let isCamera = layer.source.type == "camera"
        InspectorSection(title: layer.displayName, trailing: layer.isGameOrCamera ? AnyView(CropButton(model: model, id: id)) : nil) {
            Grid(horizontalSpacing: DS.Space.s, verticalSpacing: DS.Space.s) {
                GridRow {
                    NumberField(label: "X", value: r.minX) { v in set { $0.origin.x = v } }
                    NumberField(label: "Y", value: r.minY) { v in set { $0.origin.y = v } }
                }
                GridRow {
                    NumberField(label: "W", value: r.width) { v in set { $0.size.width = max(LayerResize.minSide, v) } }
                    NumberField(label: "H", value: r.height) { v in set { $0.size.height = max(LayerResize.minSide, v) } }
                }
            }
            InspectorRow(label: "Position") { LayerPositionGrid(model: model, layer: layer) }
            if layer.isGameOrCamera {
                InspectorRow(label: "Shape") {
                    SegmentedSwitch(selection: Binding(get: { LayerShape(layer) }, set: { s in apply(s) }),
                                    options: LayerShape.allCases.map { .init(value: $0, label: $0.label, systemImage: $0.symbol, help: $0.label) }, iconOnly: true)
                        .frame(width: 132)
                }
                InspectorRow(label: "Aspect") {
                    Picker("Aspect", selection: Binding(get: { placement.aspect }, set: { a in setAspect(a) })) {
                        ForEach(CameraAspect.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.menu).fixedSize()
                    .help("Shape of the frame; the picture is cropped to fill it")
                }
                InspectorRow(label: "Picture") {
                    SegmentedSwitch(selection: Binding(get: { layer.fit }, set: { f in model.actions.editLayer(id) { $0.fit = f } }), options: [
                        .init(value: false, label: "Fill", help: "Crop the picture to fill the frame"),
                        .init(value: true, label: "Fit", help: "Show the whole picture inside the frame"),
                    ])
                    .frame(width: 132)
                }
                slider("Zoom", \.zoom, 1...4, 1, format: { String(format: "%.2f×", $0) })
            }
            if layer.source.type == "color" { ColorRow(model: model, layer: layer) }
            slider("Corners", \.roundness, 0...0.5, 0)
            slider("Opacity", \.opacity, 0...1, 1)
            Divider().opacity(0.4)
            ToggleRow(label: "Border", isOn: layer.border, help: "Thin white border") { on in model.actions.editLayer(id) { $0.border = on } }
            ToggleRow(label: "Shadow", isOn: layer.shadow, help: "Soft shadow under the layer") { on in model.actions.editLayer(id) { $0.shadow = on } }
            if layer.isGameOrCamera {
                ToggleRow(label: "Mirror", isOn: layer.mirror, help: isCamera ? "Flip the camera horizontally, in every scene" : "Flip horizontally") { on in
                    if isCamera { state.actions.setMirror(on) } else { model.actions.editLayer(id) { $0.mirror = on } }
                }
            }
            if isCamera {
                Divider().opacity(0.4)
                DevicePicker(label: "Device", devices: state.cameras, selection: state.cameraID, noneLabel: "Off",
                             help: "Camera shown in this layer (⌘K shows or hides it)") { state.actions.selectCamera($0) }
            }
        }
    }

    private var placement: CameraPlacement {
        CameraPlacement(frame: layer.frame, canvas: model.canvasSize, roundness: layer.roundness, border: layer.border, shadow: layer.shadow)
    }
    private func set(_ f: @escaping (inout CGRect) -> Void) {
        let size = model.canvasSize
        model.actions.editLayer(layer.id) { l in var r = l.frame.rect(in: size); f(&r); l.frame = NRect(r, in: size) }
    }
    private func setAspect(_ a: CameraAspect) {
        var p = placement; p.aspect = a
        let size = model.canvasSize, frame = NRect(p.rect(in: size), in: size)
        model.actions.editLayer(layer.id) { l in
            l.frame = frame
            if a != .square && l.roundness > 0.3 { l.roundness = 0.16 }   // a circle only makes sense on a square frame
        }
    }
    private func apply(_ s: LayerShape) {
        let size = model.canvasSize
        var p = placement
        if s == .circle { p.aspect = .square }
        let frame = NRect(p.rect(in: size), in: size)
        model.actions.editLayer(layer.id) { l in
            l.roundness = s.roundness
            if s == .circle { l.frame = frame }
        }
    }
    private func slider(_ label: String, _ key: WritableKeyPath<Layer, Double>, _ range: ClosedRange<Double>, _ reset: Double,
                        format: @escaping (Double) -> String = { String(format: "%.0f%%", $0 * 100) }) -> some View {
        let id = layer.id, m = model
        return LabeledSlider(label: label, value: Binding(get: { layer[keyPath: key] }, set: { v in m.actions.editLayer(id) { $0[keyPath: key] = v } }),
                             range: range, defaultValue: reset, format: format,
                             onEditingChanged: { editing in if editing { m.actions.beginGesture() } else { m.actions.endGesture("Change \(label)") } })
    }
}

enum LayerShape: String, CaseIterable, Identifiable {
    case circle, rounded, square
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var symbol: String { switch self { case .circle: "circle"; case .rounded: "app"; case .square: "square" } }
    var roundness: Double { switch self { case .circle: 0.5; case .rounded: 0.16; case .square: 0 } }
    init(_ l: Layer) { self = l.roundness >= 0.5 ? .circle : l.roundness == 0 ? .square : .rounded }
}

private struct CropButton: View {
    let model: SceneModel
    let id: UUID
    var body: some View {
        let on = model.cropLayerID == id
        Button(on ? "Done" : "Crop") { model.actions.setCrop(on ? nil : id) }
            .buttonStyle(.plain).font(.system(size: 11, weight: .medium))
            .foregroundStyle(on ? Color.accentColor : Color.secondary)
            .help(on ? "Finish cropping (Esc)" : "Move and zoom the picture inside its frame (or double-click it)")
    }
}

/// Snaps the layer to one of the eight anchors the camera presets have always used (corners and edge centres,
/// inset by the 4% margin), or the centre.
private struct LayerPositionGrid: View {
    let model: SceneModel
    let layer: Layer
    static let names = ["Top Left", "Top", "Top Right", "Left", "Centre", "Right", "Bottom Left", "Bottom", "Bottom Right"]

    var body: some View {
        let size = model.canvasSize, r = layer.frame.rect(in: size)
        let points = anchors(r.size, size)
        let current = points.firstIndex { abs($0.x - r.midX) < 1 && abs($0.y - r.midY) < 1 }
        Grid(horizontalSpacing: 3, verticalSpacing: 3) {
            ForEach(0..<3, id: \.self) { row in
                GridRow {
                    ForEach(0..<3, id: \.self) { col in
                        let i = row * 3 + col
                        Button { move(to: points[i], r, size) } label: {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(i == current ? Color.accentColor : Color.white.opacity(0.13))
                                .frame(width: 26, height: 16).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).help("Move to \(Self.names[i])").accessibilityLabel(Self.names[i])
                    }
                }
            }
        }
    }

    /// The anchors in row order, centre included.
    private func anchors(_ s: CGSize, _ canvas: CGSize) -> [CGPoint] {
        var a = CameraPlacement.anchors(for: s, canvas: canvas)
        a.insert(CGPoint(x: canvas.width / 2, y: canvas.height / 2), at: 4)
        return a
    }
    private func move(to p: CGPoint, _ r: CGRect, _ size: CGSize) {
        let n = NRect(CGRect(x: p.x - r.width / 2, y: p.y - r.height / 2, width: r.width, height: r.height), in: size)
        model.actions.editLayer(layer.id) { $0.frame = n }
    }
}

private struct ColorRow: View {
    let model: SceneModel
    let layer: Layer
    var body: some View {
        let c = layer.source.color ?? [0, 0, 0, 1]
        InspectorRow(label: "Color") {
            ColorPicker("Color", selection: Binding(get: {
                Color(.sRGB, red: c[0], green: c.count > 1 ? c[1] : 0, blue: c.count > 2 ? c[2] : 0, opacity: c.count > 3 ? c[3] : 1)
            }, set: { new in
                guard let s = NSColor(new).usingColorSpace(.sRGB) else { return }
                let v: [Double] = [Double(s.redComponent), Double(s.greenComponent), Double(s.blueComponent), Double(s.alphaComponent)]
                model.actions.editLayer(layer.id) { $0.source.color = v }
            }))
            .labelsHidden()
        }
    }
}

/// Compact numeric field in canvas pixels; commits on Return or when focus leaves.
private struct NumberField: View {
    let label: String
    let value: CGFloat
    let commit: (CGFloat) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).frame(width: 12)
            TextField(label, text: $text)
                .textFieldStyle(.plain).font(.system(size: 12).monospacedDigit())
                .multilineTextAlignment(.trailing)
                .focused($focused)
                .onSubmit { apply() }
                .onChange(of: focused) { _, f in if !f { apply() } }
            Text("px").font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, DS.Space.s).frame(height: 24)
        .background(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).fill(Color.white.opacity(focused ? 0.1 : 0.06)))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).strokeBorder(focused ? Color.accentColor.opacity(0.8) : .clear))
        .onAppear { text = Self.format(value) }
        .onChange(of: value) { _, v in if !focused { text = Self.format(v) } }
        .accessibilityLabel(label)
    }

    static func format(_ v: CGFloat) -> String { String(Int(v.rounded())) }
    private func apply() {
        guard let v = Double(text.trimmingCharacters(in: .whitespaces)) else { text = Self.format(value); return }
        if abs(CGFloat(v) - value) >= 0.5 { commit(CGFloat(v)) }
        text = Self.format(CGFloat(v))
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
                    .help("Zoom in on the game (⌃Z, or hold ⌃Space)")
            }
            LabeledSlider(label: "Zoom amount", value: Binding(get: { model.punchAmount }, set: { model.actions.setPunchAmount($0) }),
                          range: PunchIn.range, defaultValue: 1.6, format: { String(format: "%.1f×", $0) })
            Text("⌃1…⌃9 switch scenes, ⌃Z zooms in on the game, arrow keys move the zoom while zoomed, ⌃M marks a moment in a recording.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
