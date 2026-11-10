import AppKit
import AVFoundation
import SwiftUI

// MARK: - Inspector

/// Selection-dependent: nothing selected shows the project (default scene layout, audio and sync); a section, scene
/// span, zoom block or marker shows its own controls.
struct EditorInspector: View {
    let model: EditorModel

    var body: some View {
        VStack(spacing: 0) {
            InspectorHeader(model: model)
            Rectangle().fill(DS.Color.stroke).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.l) {
                    if model.editsLocked {
                        Label("Editing resumes when the export queue finishes.", systemImage: "lock")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    content.disabled(model.editsLocked)
                }
                .padding(DS.Space.l)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(DS.Color.panel)
    }

    @ViewBuilder private var content: some View {
        switch model.selection {
        case .none: ProjectInspector(model: model)
        case .section(let s): SectionInspector(model: model, section: s)
        case .scene: SceneInspector(model: model)
        case .zoom(let id): ZoomInspector(model: model, id: id)
        case .marker(let id): MarkerInspector(model: model, id: id)
        }
    }
}

struct InspectorHeader: View {
    let model: EditorModel
    var body: some View {
        let (title, symbol): (String, String) = {
            switch model.selection {
            case .none: return ("Project", "doc.richtext")
            case .section(let s): return (s.kept ? "Section" : "Removed Section", "film")
            case .scene: return ("Scene", "rectangle.3.group")
            case .zoom: return ("Zoom", "plus.magnifyingglass")
            case .marker: return ("Marker", "flag")
            }
        }()
        HStack(spacing: DS.Space.s) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            Text(title).font(.system(size: 13, weight: .semibold))
            Spacer()
            if model.selection != .none {
                Button { withAnimation(DS.Motion.snappy) { model.selection = .none } } label: {
                    Text("Done").font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.borderless)
                .help("Back to the project settings (Esc)")
            }
        }
        .padding(.horizontal, DS.Space.l)
        .frame(height: 40)
    }
}

// MARK: - Project

struct ProjectInspector: View {
    let model: EditorModel
    var body: some View {
        let p = model.project
        InspectorSection(title: "Recording") {
            CommitTextField(title: "Name", text: p.name) { v in
                let clean = v.trimmingCharacters(in: .whitespacesAndNewlines)
                if !clean.isEmpty { model.update("Rename") { $0.name = clean } }
            }
            Text(recordingSummary(p, duration: model.duration)).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        LayoutInspector(model: model)
        AudioInspector(model: model)
        if model.isHDRSource {
            InspectorSection(title: "Preview") {
                SegmentedSwitch(selection: Binding(get: { model.range }, set: { model.range = $0 }), options: [
                    .init(value: .hdr, label: "HDR", help: "Preview in HDR, as the YouTube export"),
                    .init(value: .sdr, label: "SDR", help: "Preview the tone-mapped SDR look of the Shorts and 1080p exports"),
                ])
                Text(model.range == .hdr ? "Shows the HDR picture, as the YouTube export." : "Shows the tone-mapped SDR look of the Shorts and 1080p exports.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
}

func recordingSummary(_ p: Project, duration: Double) -> String {
    var parts = [formatTime(duration > 0 ? duration : p.durationMs / 1000)]
    if p.width > 0 { parts.append("\(p.width)×\(p.height)") }
    parts.append("\(Int(p.fps.rounded())) fps")
    parts.append(StudioFormat.colorLabel(p.color))
    return parts.joined(separator: " · ")
}

/// The template controls of the default scene (the layout the recording started with) for the current canvas.
struct LayoutInspector: View {
    @Bindable var model: EditorModel
    var body: some View {
        let l = model.layout
        InspectorSection(title: "Default Scene · \(model.canvas.label)") {
            InspectorRow(label: "Layout") {
                Picker("Layout", selection: model.binding(\.kind)) {
                    ForEach(LayoutKind.allCases, id: \.self) { k in Text(k.label).tag(k) }
                }
                .labelsHidden().fixedSize()
                .disabled(!model.hasCamera)
            }
            if !model.hasCamera { Text("This recording has no camera layer.").font(.system(size: 11)).foregroundStyle(.secondary) }
            if model.hasCamera && l.kind == .pip {
                InspectorRow(label: "Shape") {
                    SegmentedSwitch(selection: Binding(
                        get: { CameraShape(l.camera) },
                        set: { v in var c = model.layout.camera; v.apply(to: &c); model.binding(\.camera).wrappedValue = c }),
                        options: CameraShape.allCases.map { .init(value: $0, label: $0.label, systemImage: $0.symbol) }, iconOnly: true)
                    .frame(width: 120)
                }
                InspectorRow(label: "Window") {
                    Picker("Window", selection: model.binding(\.camera.aspect)) {
                        ForEach(CameraAspect.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                LabeledSlider(label: "Size", value: model.binding(\.camera.size), range: 0.1...0.9, defaultValue: 0.34, onEditingChanged: model.gesture)
                LabeledSlider(label: "Corners", value: model.binding(\.camera.roundness), range: 0...0.5, defaultValue: 0.16, onEditingChanged: model.gesture)
                InspectorRow(label: "Position") { PositionGrid(model: model) }
                HStack {
                    Toggle("Shadow", isOn: model.binding(\.camera.shadow))
                    Toggle("Border", isOn: model.binding(\.camera.border))
                }
                .toggleStyle(.checkbox).font(.system(size: 12))
            }
            if model.hasCamera && l.kind == .stacked {
                LabeledSlider(label: "Camera height", value: model.binding(\.split), range: 0.2...0.7, defaultValue: 0.36, onEditingChanged: model.gesture)
            }
            if model.hasCamera && l.kind != .screenOnly {
                Toggle("Mirror camera", isOn: model.projectBinding(\.cameraMirror, "Mirror")).toggleStyle(.checkbox).font(.system(size: 12))
            }
            if l.kind != .cameraOnly {
                InspectorRow(label: "Game") {
                    SegmentedSwitch(selection: model.binding(\.fit), options: [.init(value: false, label: "Fill"), .init(value: true, label: "Fit")]).frame(width: 120)
                }
                LabeledSlider(label: "Game zoom", value: model.binding(\.zoom), range: 1...3, defaultValue: 1,
                              format: { String(format: "%.2f×", $0) }, onEditingChanged: model.gesture)
                HStack {
                    Text("Drag the preview to reframe").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Center") { var nl = model.layout; nl.panX = 0.5; nl.panY = 0.5; nl.zoom = 1; model.layout = nl }.controlSize(.small)
                }
            }
        }
    }
}

struct AudioInspector: View {
    let model: EditorModel
    var body: some View {
        InspectorSection(title: "Audio & Sync") {
            LabeledSlider(label: "Game volume", value: model.projectBinding(\.game.volume, "Game Volume"), range: 0...2, defaultValue: 1, onEditingChanged: model.gesture)
            if model.hasMic {
                LabeledSlider(label: "Mic volume", value: Binding(get: { model.project.mic?.volume ?? 1 }, set: { v in model.update("Mic Volume") { $0.mic?.volume = v } }),
                              range: 0...3, defaultValue: 1, onEditingChanged: model.gesture)
                OffsetRow(title: "Mic offset", value: Binding(get: { model.project.mic?.offsetMs ?? 0 }, set: { v in model.update("Mic Offset") { $0.mic?.offsetMs = v } }))
            }
            if model.hasCamera {
                OffsetRow(title: "Camera offset", value: Binding(get: { model.project.camera?.offsetMs ?? 0 }, set: { v in model.update("Camera Offset") { $0.camera?.offsetMs = v } }))
            }
            if model.hasMic || model.hasCamera {
                Text("The capture card adds a little delay to the game. If your voice or face runs ahead of the gameplay, add a positive offset.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Section

struct SectionInspector: View {
    let model: EditorModel
    let section: CutSection
    var body: some View {
        InspectorSection(title: section.kept ? "Kept" : "Removed") {
            InspectorRow(label: "Start") { Text(formatTimecode(section.startMs / 1000, fps: model.project.fps)).monospacedDigit() }
            InspectorRow(label: "End") { Text(formatTimecode(section.endMs / 1000, fps: model.project.fps)).monospacedDigit() }
            InspectorRow(label: "Length") { Text(formatDuration((section.endMs - section.startMs) / 1000)).monospacedDigit() }
            if section.kept {
                PillButton("Remove Section", systemImage: "scissors", help: "Remove this section from the export (⌫)") { model.deleteSelection() }
                Text("Removed sections stay on the timeline, hatched, so they can be brought back. Drag a section's edge to trim it.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                PillButton("Restore Section", systemImage: "arrow.uturn.backward", prominent: true, help: "Bring this section back (⌫)") { model.restoreSection(section) }
                Text("Playback skips removed sections, and exports leave them out.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.system(size: 12))
    }
}

func formatDuration(_ s: Double) -> String {
    s < 60 ? String(format: "%.2f s", s) : formatTime(s)
}

// MARK: - Scene

struct SceneInspector: View {
    let model: EditorModel
    var body: some View {
        if let run = model.selectedSceneRun() {
            let p = model.project
            InspectorSection(title: "Scene") {
                Text("\(formatTimecode(run.startMs / 1000, fps: p.fps)) – \(formatTimecode(run.endMs / 1000, fps: p.fps))")
                    .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                let columns = [GridItem(.flexible(), spacing: DS.Space.s), GridItem(.flexible(), spacing: DS.Space.s)]
                LazyVGrid(columns: columns, spacing: DS.Space.s) {
                    ForEach(Array(model.sceneChoices.enumerated()), id: \.element.id) { i, c in
                        SceneChoiceTile(model: model, choice: c, index: i, frameMs: (run.startMs + run.endMs) / 2, selected: c.sceneID != nil ? c.sceneID == run.sceneID : (run.sceneID == nil && i == 0)) {
                            model.setScene(c, for: run)
                        }
                    }
                }
                Text("Scenes here belong to this project; changing them never touches your live scenes.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let span = run.span, run.startMs > 0 {
                InspectorSection(title: "Transition") {
                    SegmentedSwitch(selection: Binding(get: { span.transition.style }, set: { v in
                        var t = span.transition; t.style = v
                        model.update("Transition") { TimelineEdits.setTransition(&$0, spanID: span.id, t) }
                    }), options: [.init(value: .cut, label: "Cut"), .init(value: .fade, label: "Fade"), .init(value: .morph, label: "Morph")])
                    LabeledSlider(label: "Duration", value: Binding(get: { span.transition.durationMs / 1000 }, set: { v in
                        var t = span.transition; t.durationMs = (v * 1000).rounded()
                        model.update("Transition Duration") { TimelineEdits.setTransition(&$0, spanID: span.id, t) }
                    }), range: 0.1...1.5, defaultValue: 0.38, format: { String(format: "%.2f s", $0) }, onEditingChanged: model.gesture)
                    .disabled(span.transition.style == .cut)
                    if span.transition.style == .morph {
                        Text("Morph moves shared layers into place; until live scenes arrive it renders as a fade.")
                            .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                PillButton("Delete Scene Change", systemImage: "trash", help: "The previous scene continues (⌫)") { model.deleteSelection() }
            }
        }
    }
}

/// A scene as a small schematic of its layers on the current canvas, the game drawn with a filmstrip frame.
struct SceneChoiceTile: View {
    let model: EditorModel
    let choice: SceneChoice
    let index: Int
    let frameMs: Double
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                SceneSchematic(model: model, composition: composition, frameMs: frameMs)
                    .aspectRatio(model.canvas == .wide ? 16 / 9 : 9 / 16, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 92)
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(selected ? Color.accentColor : DS.Color.stroke, lineWidth: selected ? 2 : 1))
                HStack(spacing: 4) {
                    Circle().fill(TimelineStyle.sceneColor(choice.sceneID, in: model.project)).frame(width: 7, height: 7)
                        .opacity(choice.sceneID == nil && choice.template != nil ? 0.3 : 1)
                    Text(choice.name).font(.system(size: 11, weight: selected ? .semibold : .regular)).lineLimit(1)
                    Spacer(minLength: 0)
                    if index < 9 { Text("⌃\(index + 1)").font(.system(size: 9).monospacedDigit()).foregroundStyle(.tertiary) }
                }
            }
            .padding(5)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(hover ? 0.07 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(choice.sceneID == nil && choice.template != nil ? "Add \(choice.name) to this project and use it here" : "Use \(choice.name) here")
        .accessibilityLabel(choice.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var composition: Composition {
        let p = model.project
        if let id = choice.sceneID, let s = p.scenes.first(where: { $0.id == id }) { return s.composition(model.canvas) }
        if choice.sceneID == nil && choice.template == nil { return p.defaultScene.composition(model.canvas) }
        var l = p.layout(model.canvas); l.kind = choice.template ?? l.kind
        return .from(layout: l, canvas: model.canvas.size(.hd), hasCamera: model.hasCamera, mirror: p.cameraMirror)
    }
}

struct SceneSchematic: View {
    let model: EditorModel
    let composition: Composition
    let frameMs: Double
    var body: some View {
        let film = model.filmstrip
        let _ = film.revision
        let frame = film.image(for: Int(frameMs) / 1000 * 1000, interval: 1000)
        let gameSize = model.gameSize
        SwiftUI.Canvas { ctx, size in
            let rect = CGRect(origin: .zero, size: size)
            ctx.clip(to: Path(roundedRect: rect, cornerRadius: 5))
            let bg = composition.background
            ctx.fill(Path(rect), with: .color(Color(red: bg.count > 0 ? bg[0] : 0, green: bg.count > 1 ? bg[1] : 0, blue: bg.count > 2 ? bg[2] : 0)))
            let layers = SceneResolver.resolve(composition, canvas: size, sources: [.game: SourceInfo(size: gameSize), .camera: SourceInfo(size: CGSize(width: 16, height: 9))])
            for l in layers {
                let path = Path(roundedRect: l.dst, cornerRadius: l.radius)
                switch l.key {
                case .game:
                    var c = ctx; c.clip(to: path)
                    if let img = frame {
                        // Draw the whole frame so the layer's crop lands inside its rectangle.
                        let full = CGRect(x: l.dst.minX - l.src.minX / l.src.width * l.dst.width, y: l.dst.minY - l.src.minY / l.src.height * l.dst.height,
                                          width: l.dst.width / l.src.width, height: l.dst.height / l.src.height)
                        c.draw(Image(decorative: img, scale: 1), in: full)
                    } else {
                        c.fill(path, with: .linearGradient(Gradient(colors: [Color(white: 0.32), Color(white: 0.18)]), startPoint: l.dst.origin, endPoint: CGPoint(x: l.dst.maxX, y: l.dst.maxY)))
                    }
                case .camera:
                    ctx.fill(path, with: .linearGradient(Gradient(colors: [Color(red: 0.45, green: 0.5, blue: 0.62), Color(red: 0.25, green: 0.28, blue: 0.38)]),
                                                         startPoint: l.dst.origin, endPoint: CGPoint(x: l.dst.maxX, y: l.dst.maxY)))
                    let s = min(l.dst.width, l.dst.height) * 0.55
                    let person = ctx.resolve(Image(systemName: "person.fill"))
                    ctx.draw(person, in: CGRect(x: l.dst.midX - s / 2, y: l.dst.midY - s / 2 + s * 0.08, width: s, height: s))
                    if l.border > 0 { ctx.stroke(path, with: .color(.white), lineWidth: 1) }
                default:
                    ctx.fill(path, with: .color(.white.opacity(0.25)))
                }
            }
        }
    }
}

// MARK: - Zoom

struct ZoomInspector: View {
    let model: EditorModel
    let id: UUID
    var body: some View {
        if let z = model.zoomBlock(id) {
            InspectorSection(title: "Zoom") {
                LabeledSlider(label: "Scale", value: Binding(get: { z.scale }, set: { v in model.updateZoom(id, "Zoom Scale") { $0.scale = (v * 20).rounded() / 20 } }),
                              range: 1.1...4, defaultValue: 1.8, format: { String(format: "%.2f×", $0) }, onEditingChanged: editing)
                LabeledSlider(label: "Ease in and out", value: Binding(get: { z.easeMs / 1000 }, set: { v in model.updateZoom(id, "Zoom Ease") { $0.easeMs = (v * 1000 / 10).rounded() * 10 } }),
                              range: 0...1.5, defaultValue: 0.45, format: { String(format: "%.2f s", $0) }, onEditingChanged: editing)
                InspectorRow(label: "Focus") {
                    Text(String(format: "%.0f%%, %.0f%%", z.focusX * 100, z.focusY * 100)).monospacedDigit().foregroundStyle(.secondary)
                    Button("Center") { model.updateZoom(id, "Zoom Focus") { $0.focusX = 0.5; $0.focusY = 0.5 } }.controlSize(.small)
                }
                Text("Drag the target in the preview to choose the point the zoom closes in on.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 12))
            InspectorSection(title: "Timing") {
                InspectorRow(label: "Start") { Text(formatTimecode(z.startMs / 1000, fps: model.project.fps)).monospacedDigit() }
                InspectorRow(label: "Length") { Text(formatDuration((z.endMs - z.startMs) / 1000)).monospacedDigit() }
                Text("Drag the block to move it, its edges to resize it.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .font(.system(size: 12))
            PillButton("Delete Zoom", systemImage: "trash", help: "Delete this zoom (⌫)") { model.deleteSelection() }
        }
    }
    private func editing(_ on: Bool) { model.gesture(on); if on { model.parkOnZoom(id) } }
}

// MARK: - Marker

struct MarkerInspector: View {
    let model: EditorModel
    let id: UUID
    var body: some View {
        if let m = model.marker(id) {
            InspectorSection(title: "Marker") {
                CommitTextField(title: "Name", text: m.label, placeholder: TimelineEdits.markerTitle(m, in: model.project)) { model.renameMarker(id, $0) }
                InspectorRow(label: "Time") {
                    Text(formatTimecode(m.tMs / 1000, fps: model.project.fps)).monospacedDigit()
                    Button("Go") { model.seek(m.tMs / 1000) }.controlSize(.small)
                }
                .font(.system(size: 12))
                Text("⇧M and ⌥M jump to the next and previous marker.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            InspectorSection(title: "Short") {
                Text("Keep 30 seconds around this marker and switch to the vertical canvas, ready for a Shorts export.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                PillButton("Make Short from Marker", systemImage: "iphone", prominent: true, help: "Sets in and out 15 seconds either side and switches to 9:16") {
                    model.makeShort(from: id)
                }
            }
            PillButton("Delete Marker", systemImage: "trash", help: "Delete this marker (⌫)") { model.deleteSelection() }
        }
    }
}

// MARK: - Controls

/// A text field that commits on Return or when it loses focus, so typing is one undo step.
struct CommitTextField: View {
    let title: String
    let text: String
    var placeholder = ""
    let commit: (String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
            TextField(placeholder.isEmpty ? title : placeholder, text: $draft)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { if draft != text { commit(draft) } }
                .onChange(of: focused) { _, f in if !f && draft != text { commit(draft) } }
        }
        .onAppear { draft = text }
        .onChange(of: text) { _, t in if !focused { draft = t } }
    }
}

/// Sync nudge in milliseconds, committed on release so the composition is rebuilt once per change.
struct OffsetRow: View {
    let title: String
    @Binding var value: Double
    @State private var draft: Double?
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(draft ?? value)) ms").font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                Stepper("", value: Binding(get: { value }, set: { value = $0 }), in: -2000...2000, step: 10).labelsHidden().controlSize(.mini)
            }
            Slider(value: Binding(get: { draft ?? value }, set: { draft = ($0 / 10).rounded() * 10 }), in: -500...500) { editing in
                if !editing, let d = draft { value = d; draft = nil }
            }
            .controlSize(.small)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

struct PositionGrid: View {
    let model: EditorModel
    var body: some View {
        Grid(horizontalSpacing: 4, verticalSpacing: 4) {
            ForEach(0..<3, id: \.self) { row in
                GridRow {
                    ForEach(0..<3, id: \.self) { col in
                        if row == 1 && col == 1 { Color.clear.frame(width: 22, height: 14) }
                        else {
                            Button { place(row: row, col: col) } label: {
                                RoundedRectangle(cornerRadius: 2).fill(isAt(row: row, col: col) ? Color.accentColor : Color.secondary.opacity(0.35))
                                    .frame(width: 22, height: 14)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(["Top left", "Top", "Top right", "Left", "", "Right", "Bottom left", "Bottom", "Bottom right"][row * 3 + col])
                        }
                    }
                }
            }
        }
    }
    private var canvas: CGSize { model.canvas.size(.hd) }
    private func anchor(row: Int, col: Int) -> CGPoint? {
        let r = model.layout.camera.rect(in: canvas)
        let idx = row * 3 + col
        let anchors = CameraPlacement.anchors(for: r.size, canvas: canvas)
        let i = idx > 4 ? idx - 1 : idx
        return i < anchors.count ? anchors[i] : nil
    }
    private func place(row: Int, col: Int) {
        guard let a = anchor(row: row, col: col) else { return }
        var c = model.layout.camera; c.move(to: a, canvas: canvas, snap: false)
        model.binding(\.camera).wrappedValue = c
    }
    private func isAt(row: Int, col: Int) -> Bool {
        guard let a = anchor(row: row, col: col) else { return false }
        let r = model.layout.camera.rect(in: canvas)
        return abs(r.midX - a.x) < 2 && abs(r.midY - a.y) < 2
    }
}
