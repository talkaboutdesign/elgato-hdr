// The layer list and the layer inspector of a scene. The live Scene tab shows them for the active live scene; the
// editor shows the very same views for the project's copy of the scene at the playhead. Edits go through
// `LayerEditing.layerActions`, as picture edits do.
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// What a camera layer's inspector adds: mirroring (which follows the camera into every scene) and, live, the device.
struct CameraLayerExtras {
    var mirror: Bool
    var setMirror: (Bool) -> Void
    var help: String
    var device: AnyView? = nil
}

// MARK: - Layers

struct LayerListSection: View {
    let model: any LayerEditing
    @State private var dragging: UUID?

    var body: some View {
        // Topmost first, as in every layers panel; the composition stores them bottom first.
        let layers = Array(model.editedComposition.layers.reversed())
        InspectorSection(title: "Layers", trailing: AnyView(AddLayerMenu(model: model))) {
            VStack(spacing: 2) {
                ForEach(layers) { l in
                    LayerRow(model: model, layer: l, selected: model.selectedLayerID == l.id)
                        .onDrag { dragging = l.id; return NSItemProvider(object: l.id.uuidString as NSString) }
                        .onDrop(of: [UTType.text], delegate: LayerDropDelegate(target: l.id, model: model, dragging: $dragging))
                }
                if layers.isEmpty {
                    Text("No layers. Add the game, the camera, an image or text with +.").font(.system(size: 11)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, DS.Space.xs)
                }
            }
            .padding(-DS.Space.xs)
            Divider().opacity(0.4)
            let other = model.editedCanvas == .wide ? "9:16" : "16:9"
            Button { model.layerActions.copyLayoutToOtherCanvas() } label: {
                Label("Copy Layout to \(other)", systemImage: model.editedCanvas == .wide ? "rectangle.portrait" : "rectangle")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain).foregroundStyle(Color.accentColor)
            .help("Start the \(other) canvas of this scene from this layout")
        }
    }
}

private struct LayerDropDelegate: DropDelegate {
    let target: UUID
    let model: any LayerEditing
    @Binding var dragging: UUID?
    func dropEntered(info: DropInfo) {
        guard let d = dragging, d != target, let to = model.editedComposition.layers.firstIndex(where: { $0.id == target }) else { return }
        withAnimation(DS.Motion.snappy) { model.layerActions.moveLayer(d, to) }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool { dragging = nil; return true }
}

private struct LayerRow: View {
    let model: any LayerEditing
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
            Button { model.layerActions.editLayer(layer.id) { $0.visible.toggle() } } label: {
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
        .simultaneousGesture(TapGesture().onEnded { model.layerActions.selectLayer(layer.id) })
        .contextMenu {
            Button("Rename") { name = layer.displayName; renaming = true; DispatchQueue.main.async { focused = true } }
            Button(layer.visible ? "Hide" : "Show") { model.layerActions.editLayer(layer.id) { $0.visible.toggle() } }
            Divider()
            Button("Bring to Front") { model.layerActions.moveLayer(layer.id, Int.max) }
            Button("Send to Back") { model.layerActions.moveLayer(layer.id, 0) }
            if !layer.isGameOrCamera { Divider(); Button("Delete", role: .destructive) { model.layerActions.deleteLayer(layer.id) } }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func commit() {
        renaming = false
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !n.isEmpty && n != layer.name { model.layerActions.editLayer(layer.id) { $0.name = n } }
    }
}

private struct AddLayerMenu: View {
    let model: any LayerEditing
    var body: some View {
        Button { model.addLayerOpen.toggle() } label: {
            Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).frame(width: 20, height: 16).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(model.addLayerOpen ? Color.accentColor : Color.secondary)
        .help("Add a layer to this scene")
        .accessibilityLabel("Add layer")
        .popover(isPresented: Binding(get: { model.addLayerOpen }, set: { model.addLayerOpen = $0 }), arrowEdge: .bottom) {
            AddLayerPalette(model: model)
        }
    }
}

/// What can be added to the scene being edited, grouped: overlays first (what this menu is mostly for), then the
/// capture sources, then ready-made presets.
struct AddLayerPalette: View {
    let model: any LayerEditing
    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Add to “\(model.editedSceneName)”").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text("\(model.editedCanvas.label) canvas").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            group("Overlays") {
                AddLayerTile(title: "Image…", symbol: "photo", help: "Choose an image file (PNG, JPEG, HEIC, TIFF, GIF)") { later { model.layerActions.addImage(nil, nil) } }
                AddLayerTile(title: "Text", symbol: "textformat", help: "A line of text; {timer} and {time} update live") { model.layerActions.addLayer("text") }
                AddLayerTile(title: "Color", symbol: "paintpalette", help: "A solid colour behind everything") { model.layerActions.addLayer("color") }
            }
            if model.addsSourceLayers {
                group("Sources") {
                    AddLayerTile(title: "Game", symbol: "gamecontroller", help: "The capture card picture") { model.layerActions.addLayer("game") }
                    AddLayerTile(title: "Camera", symbol: "person.crop.rectangle", help: "Your camera in a window") { model.layerActions.addLayer("camera") }
                }
            }
            group("Presets") {
                ForEach(LayerPreset.allCases) { p in AddLayerTile(title: p.name, symbol: p.symbol, help: p.summary) { model.layerActions.addPreset(p) } }
            }
            Divider().opacity(0.5)
            Label("Or drag an image file onto the picture", systemImage: "arrow.down.doc")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(DS.Space.l)
        .frame(width: 304)
        .environment(\.colorScheme, .dark)
    }

    private func group<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).kerning(0.6).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(84), spacing: DS.Space.s), count: 3), alignment: .leading, spacing: DS.Space.s) { content() }
        }
    }
    /// The open panel is a sheet on the window: let the popover close first.
    private func later(_ f: @escaping () -> Void) { model.addLayerOpen = false; DispatchQueue.main.async(execute: f) }
}

private struct AddLayerTile: View {
    let title: String
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hover = false
    @State private var pressed = false
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 17, weight: .regular)).frame(height: 20)
                Text(title).font(.system(size: 11, weight: .medium)).lineLimit(1).minimumScaleFactor(0.85)
            }
            .foregroundStyle(hover ? Color.primary : Color.primary.opacity(0.85))
            .frame(width: 84, height: 62)
            .background(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).fill(Color.white.opacity(hover ? 0.11 : 0.05)))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).strokeBorder(hover ? Color.accentColor.opacity(0.7) : DS.Color.stroke))
            .contentShape(Rectangle())
            .scaleEffect(DS.Motion.pressScale(pressed))
        }
        .buttonStyle(PressTracking(pressed: $pressed))
        .onHover { hover = $0 }
        .animation(DS.Motion.snappy, value: hover)
        .help(help)
        .accessibilityLabel("Add \(title)")
    }
}

struct NoSelectionHint: View {
    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.s) {
            Image(systemName: "cursorarrow.click.2").foregroundStyle(.secondary)
            Text("Click a layer on the picture or in the list to arrange it. Drag to move, drag a handle to resize, double-click the game or camera to crop, double-click text to edit it. Drop an image file on the picture to add it.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, DS.Space.xs)
    }
}

// MARK: - Inspector

struct LayerInspector: View {
    let model: any LayerEditing
    let layer: Layer
    /// Camera layers only: mirroring and the device belong to the camera, not to one scene.
    var camera: CameraLayerExtras? = nil

    var body: some View {
        let size = model.editedCanvasSize
        let r = layer.frame.rect(in: size)
        let id = layer.id
        let isCamera = layer.source.type == "camera"
        InspectorSection(title: layer.displayName, trailing: layer.isGameOrCamera ? AnyView(CropButton(model: model, id: id)) : nil) {
            Grid(horizontalSpacing: DS.Space.s, verticalSpacing: DS.Space.s) {
                GridRow {
                    NumberField(label: "X", field: .x, canvas: size, value: r.minX) { v in set { $0.origin.x = v } }
                    NumberField(label: "Y", field: .y, canvas: size, value: r.minY) { v in set { $0.origin.y = v } }
                }
                GridRow {
                    NumberField(label: "W", field: .width, canvas: size, value: r.width) { v in set { $0.size.width = v } }
                    NumberField(label: "H", field: .height, canvas: size, value: r.height) { v in set { $0.size.height = v } }
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
                    SegmentedSwitch(selection: Binding(get: { layer.fit }, set: { f in model.layerActions.editLayer(id) { $0.fit = f } }), options: [
                        .init(value: false, label: "Fill", help: "Crop the picture to fill the frame"),
                        .init(value: true, label: "Fit", help: "Show the whole picture inside the frame"),
                    ])
                    .frame(width: 132)
                }
                slider("Zoom", \.zoom, 1...4, 1, format: { String(format: "%.2f×", $0) })
                Text(LayerHandle.cropHint)
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if layer.source.type == "color" { ColorRow(model: model, layer: layer) }
            if layer.source.type == "text" { TextControls(model: model, layer: layer) }
            if layer.source.type == "image" { ImageControls(model: model, layer: layer) }
            if layer.source.type != "text" { slider("Corners", \.roundness, 0...0.5, 0) }
            if isCamera {
                ToggleRow(label: "Frame", isOn: layer.frameWidth > 0, help: "Outer camera frame") { on in
                    model.layerActions.editLayer(id) { $0.frameWidth = on ? 0.009 : 0 }
                }
                if layer.frameWidth > 0 {
                    ColorWellRow(label: "Frame color", value: layer.frameColor) { value in model.layerActions.editLayer(id) { $0.frameColor = value } }
                    slider("Frame width", \.frameWidth, 0.001...0.05, 0.009)
                }
            }
            slider("Opacity", \.opacity, 0...1, 1)
            if layer.source.type != "text" {
                // Text has its own shadow (around the letters) and plate; a frame border or box shadow would not fit it.
                Divider().opacity(0.4)
                ToggleRow(label: "Border", isOn: layer.border, help: "Thin white border") { on in model.layerActions.editLayer(id) { $0.border = on } }
                ToggleRow(label: "Shadow", isOn: layer.shadow, help: "Soft shadow under the layer") { on in model.layerActions.editLayer(id) { $0.shadow = on } }
            }
            if let c = camera {
                ToggleRow(label: "Mirror", isOn: c.mirror, help: c.help) { on in c.setMirror(on) }
            } else if layer.isGameOrCamera {
                ToggleRow(label: "Mirror", isOn: layer.mirror, help: "Flip horizontally") { on in model.layerActions.editLayer(id) { $0.mirror = on } }
            }
            if let device = camera?.device {
                Divider().opacity(0.4)
                device
            }
        }
    }

    private var placement: CameraPlacement {
        CameraPlacement(frame: layer.frame, canvas: model.editedCanvasSize, roundness: layer.roundness, border: layer.border, shadow: layer.shadow)
    }
    private func set(_ f: @escaping (inout CGRect) -> Void) {
        let size = model.editedCanvasSize
        model.layerActions.editLayer(layer.id) { l in var r = l.frame.rect(in: size); f(&r); l.frame = NRect(r, in: size) }
    }
    private func setAspect(_ a: CameraAspect) {
        var p = placement; p.aspect = a
        let size = model.editedCanvasSize, frame = NRect(p.rect(in: size), in: size)
        model.layerActions.editLayer(layer.id) { l in
            l.frame = frame
            if a != .square && l.roundness > 0.3 { l.roundness = 0.16 }   // a circle only makes sense on a square frame
        }
    }
    private func apply(_ s: LayerShape) {
        let size = model.editedCanvasSize
        var p = placement
        if s == .circle { p.aspect = .square }
        let frame = NRect(p.rect(in: size), in: size)
        model.layerActions.editLayer(layer.id) { l in
            l.roundness = s.roundness
            if s == .circle { l.frame = frame }
        }
    }
    private func slider(_ label: String, _ key: WritableKeyPath<Layer, Double>, _ range: ClosedRange<Double>, _ reset: Double,
                        format: @escaping (Double) -> String = { String(format: "%.0f%%", $0 * 100) }) -> some View {
        let id = layer.id, m = model
        return LabeledSlider(label: label, value: Binding(get: { layer[keyPath: key] }, set: { v in m.layerActions.editLayer(id) { $0[keyPath: key] = v } }),
                             range: range, defaultValue: reset, format: format,
                             onEditingChanged: { editing in if editing { m.layerActions.beginGesture() } else { m.layerActions.endGesture("Change \(label)") } })
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
    let model: any LayerEditing
    let id: UUID
    var body: some View {
        let on = model.cropLayerID == id
        Button(on ? "Done" : "Crop") { model.layerActions.setCrop(on ? nil : id) }
            .buttonStyle(.plain).font(.system(size: 11, weight: .medium))
            .foregroundStyle(on ? Color.accentColor : Color.secondary)
            .help(on ? "Finish cropping (Esc)" : "Move and zoom the picture inside its frame (or double-click it)")
    }
}

/// Snaps the layer to one of the eight anchors the camera presets have always used (corners and edge centres,
/// inset by the 4% margin), or the centre.
private struct LayerPositionGrid: View {
    let model: any LayerEditing
    let layer: Layer
    static let names = ["Top Left", "Top", "Top Right", "Left", "Centre", "Right", "Bottom Left", "Bottom", "Bottom Right"]

    var body: some View {
        let size = model.editedCanvasSize, r = layer.frame.rect(in: size)
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
        model.layerActions.editLayer(layer.id) { $0.frame = n }
    }
}

private struct ColorRow: View {
    let model: any LayerEditing
    let layer: Layer
    var body: some View {
        ColorWellRow(label: "Color", value: layer.source.color ?? [0, 0, 0, 1]) { v in model.layerActions.editLayer(layer.id) { $0.source.color = v } }
    }
}

/// A colour as SDR sRGB code values r, g, b, a, edited with the system colour panel.
private struct ColorWellRow: View {
    let label: String
    let value: [Double]
    let set: ([Double]) -> Void
    var body: some View {
        let c = { (i: Int, d: Double) -> Double in i < value.count ? value[i] : d }
        InspectorRow(label: label) {
            ColorPicker(label, selection: Binding(get: { Color(.sRGB, red: c(0, 0), green: c(1, 0), blue: c(2, 0), opacity: c(3, 1)) }, set: { new in
                guard let s = NSColor(new).usingColorSpace(.sRGB) else { return }
                set([Double(s.redComponent), Double(s.greenComponent), Double(s.blueComponent), Double(s.alphaComponent)])
            }))
            .labelsHidden()
        }
    }
}

/// Text layer: the words (live as you type; one undo step per edit), tokens, font, weight, alignment, colour, plate
/// and shadow.
private struct TextControls: View {
    let model: any LayerEditing
    let layer: Layer
    @State private var draft = ""
    @FocusState private var focused: Bool
    static let weights: [(String, String)] = [("regular", "Regular"), ("medium", "Medium"), ("semibold", "Semibold"), ("bold", "Bold"), ("heavy", "Heavy")]

    private var spec: TextSpec { layer.source.text ?? TextSpec() }
    private func set(_ name: String = "Change Text", _ f: @escaping (inout TextSpec) -> Void) {
        model.layerActions.editLayer(layer.id) { l in var t = l.source.text ?? TextSpec(); f(&t); l.source.text = t }
    }

    var body: some View {
        let t = spec
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Text").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Button("Stream or Recording Time  {timer}") { insert("{timer}") }
                    Button("Clock  {time}") { insert("{time}") }
                } label: { Text("Insert").font(.system(size: 11, weight: .medium)) }
                .menuStyle(.borderlessButton).menuIndicator(.visible).fixedSize()
                .help("Live values that update while you stream or record")
            }
            TextField("Text", text: $draft, axis: .vertical)
                .lineLimit(1...4).textFieldStyle(.plain).font(.system(size: 13))
                .focused($focused)
                .padding(.horizontal, DS.Space.s).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).fill(Color.white.opacity(focused ? 0.1 : 0.06)))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).strokeBorder(focused ? Color.accentColor.opacity(0.8) : .clear))
                .onChange(of: draft) { _, v in if v != spec.string { set { $0.string = v } } }
                .onChange(of: focused) { _, f in if f { model.layerActions.beginGesture() } else { model.layerActions.endGesture("Edit Text") } }
                .accessibilityLabel("Text")
            Text("{timer} counts the stream while live, else the recording. {time} is the clock. ⌥↩ adds a line.")
                .font(.system(size: 10)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { draft = t.string; takeFocusIfAsked() }
        .onChange(of: layer.id) { _, _ in draft = spec.string }
        // Undo, or an edit from elsewhere; typing round-trips to the same string.
        .onChange(of: t.string) { _, v in if v != draft { draft = v } }
        .onChange(of: model.focusTextLayerID) { _, _ in takeFocusIfAsked() }
        InspectorRow(label: "Font") {
            Picker("Font", selection: Binding(get: { t.fontName }, set: { n in set { $0.fontName = n } })) {
                Text("System").tag("")
                Divider()
                ForEach(TextRasterizer.families, id: \.self) { Text($0).tag($0) }
                if !t.fontName.isEmpty && !TextRasterizer.families.contains(t.fontName) { Text(t.fontName).tag(t.fontName) }
            }
            .labelsHidden().pickerStyle(.menu).fixedSize()
        }
        InspectorRow(label: "Weight") {
            Picker("Weight", selection: Binding(get: { t.weight }, set: { w in set { $0.weight = w } })) {
                ForEach(Self.weights, id: \.0) { Text($0.1).tag($0.0) }
            }
            .labelsHidden().pickerStyle(.menu).fixedSize()
        }
        InspectorRow(label: "Alignment") {
            SegmentedSwitch(selection: Binding(get: { t.alignment }, set: { a in set { $0.alignment = a } }), options: [
                .init(value: "left", label: "Left", systemImage: "text.alignleft"),
                .init(value: "center", label: "Centre", systemImage: "text.aligncenter"),
                .init(value: "right", label: "Right", systemImage: "text.alignright"),
            ], iconOnly: true)
            .frame(width: 132)
        }
        ColorWellRow(label: "Color", value: t.color) { v in set { $0.color = v } }
        Divider().opacity(0.4)
        ToggleRow(label: "Plate", isOn: t.plate != nil, help: "A rounded background behind the text") { on in set { $0.plate = on ? ScreenStyle.plate : nil } }
        if let plate = t.plate {
            ColorWellRow(label: "Plate color", value: plate) { v in set { $0.plate = v } }
            LabeledSlider(label: "Plate corners", value: Binding(get: { t.plateRadius }, set: { v in set { $0.plateRadius = v } }),
                          range: 0...0.5, defaultValue: TextSpec().plateRadius,
                          onEditingChanged: { e in if e { model.layerActions.beginGesture() } else { model.layerActions.endGesture("Change Plate") } })
        }
        ToggleRow(label: "Shadow", isOn: t.shadow, help: "A soft shadow behind the letters, for text over the game") { on in set { $0.shadow = on } }
    }

    private func insert(_ token: String) {
        let s = draft.isEmpty ? token : draft + (draft.hasSuffix(" ") ? "" : " ") + token
        draft = s
        set { $0.string = s }
    }
    private func takeFocusIfAsked() {
        guard model.focusTextLayerID == layer.id else { return }
        model.focusTextLayerID = nil
        DispatchQueue.main.async { focused = true }
    }
}

/// Image layer: which file (and replacing it) and how it fills its frame.
private struct ImageControls: View {
    let model: any LayerEditing
    let layer: Layer
    var body: some View {
        let file = layer.source.file ?? ""
        let missing = AssetStore.locate(file, in: model.assetSearchPaths) == nil
        InspectorRow(label: "File") {
            HStack(spacing: DS.Space.s) {
                if missing { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(DS.Color.warn).help("The image file is missing") }
                Text(layer.name.isEmpty ? file : layer.name).font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).frame(maxWidth: 110, alignment: .trailing)
                Button("Replace…") { model.layerActions.replaceImage(layer.id) }.controlSize(.small)
            }
        }
        InspectorRow(label: "Picture") {
            SegmentedSwitch(selection: Binding(get: { layer.fit }, set: { f in model.layerActions.editLayer(layer.id) { $0.fit = f } }), options: [
                .init(value: false, label: "Fill", help: "Crop the image to fill the frame"),
                .init(value: true, label: "Fit", help: "Show the whole image inside the frame"),
            ])
            .frame(width: 132)
        }
    }
}

/// Compact numeric field in canvas pixels; commits on Return or when focus leaves.
private struct NumberField: View {
    let label: String
    let field: PixelField
    let canvas: CGSize
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

    static func format(_ v: CGFloat) -> String { PixelField.format(v) }
    /// Rejected text reverts to the current value; out-of-range numbers are clamped before they are committed.
    private func apply() {
        guard let v = field.parse(text, canvas: canvas) else { text = Self.format(value); return }
        if !value.isFinite || abs(v - value) >= 0.5 { commit(v) }
        text = Self.format(v)
    }
}

