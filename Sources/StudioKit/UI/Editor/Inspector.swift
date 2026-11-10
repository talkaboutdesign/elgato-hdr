import AppKit
import AVFoundation
import SwiftUI

// MARK: - Inspector

struct Inspector: View {
    @Bindable var model: EditorModel

    var body: some View {
        let l = model.layout
        Form {
            Section(model.canvas.title) {
                Picker("Layout", selection: model.binding(\.kind)) {
                    ForEach(LayoutKind.allCases, id: \.self) { k in
                        Text(k.label).tag(k)
                    }
                }
                .disabled(!model.hasCamera)
                if !model.hasCamera { Text("This recording has no camera layer.").font(.caption).foregroundStyle(.secondary) }
            }

            if model.hasCamera && l.kind != .screenOnly {
                Section("Camera") {
                    if l.kind == .pip {
                        Picker("Shape", selection: Binding(
                            get: { l.camera.isCircle ? 0 : l.camera.roundness > 0 ? 1 : 2 },
                            set: { v in
                                var c = l.camera
                                switch v { case 0: c.aspect = .square; c.roundness = 0.5; case 1: c.roundness = 0.16; default: c.roundness = 0 }
                                model.binding(\.camera).wrappedValue = c
                            })) {
                            Image(systemName: "circle").tag(0)
                            Image(systemName: "app").tag(1)
                            Image(systemName: "square").tag(2)
                        }
                        .pickerStyle(.segmented)
                        Picker("Window", selection: model.binding(\.camera.aspect)) {
                            ForEach(CameraAspect.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        LabeledContent("Size") { Slider(value: model.binding(\.camera.size), in: 0.1...0.9, onEditingChanged: model.gesture) }
                        LabeledContent("Corners") { Slider(value: model.binding(\.camera.roundness), in: 0...0.5, onEditingChanged: model.gesture) }
                        LabeledContent("Position") { PositionGrid(model: model) }
                        Toggle("Shadow", isOn: model.binding(\.camera.shadow))
                        Toggle("Border", isOn: model.binding(\.camera.border))
                    }
                    if l.kind == .stacked {
                        LabeledContent("Camera height") { Slider(value: model.binding(\.split), in: 0.2...0.7, onEditingChanged: model.gesture) }
                    }
                    Toggle("Mirror", isOn: model.projectBinding(\.cameraMirror))
                }
            }

            if l.kind != .cameraOnly {
                Section("Game") {
                    Picker("Framing", selection: model.binding(\.fit)) {
                        Text("Fill").tag(false)
                        Text("Fit").tag(true)
                    }
                    .pickerStyle(.segmented)
                    LabeledContent("Zoom") { Slider(value: model.binding(\.zoom), in: 1...3, onEditingChanged: model.gesture) }
                    HStack {
                        Text("Drag the preview to reframe").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Center") { var nl = l; nl.panX = 0.5; nl.panY = 0.5; nl.zoom = 1; model.layout = nl }
                    }
                }
            }

            Section("Audio & Sync") {
                LabeledContent("Game volume") { VolumeSlider(value: model.projectBinding(\.game.volume, "Game Volume"), onEditingChanged: model.gesture) }
                if model.hasMic {
                    LabeledContent("Mic volume") {
                        VolumeSlider(value: Binding(get: { model.project.mic?.volume ?? 1 }, set: { v in model.update("Mic Volume") { $0.mic?.volume = v } }), max: 3, onEditingChanged: model.gesture)
                    }
                    OffsetRow(title: "Mic offset", value: Binding(get: { model.project.mic?.offsetMs ?? 0 }, set: { v in model.update { $0.mic?.offsetMs = v } }))
                }
                if model.hasCamera {
                    OffsetRow(title: "Camera offset", value: Binding(get: { model.project.camera?.offsetMs ?? 0 }, set: { v in model.update { $0.camera?.offsetMs = v } }))
                }
                if model.hasMic || model.hasCamera {
                    Text("The capture card adds a little delay to the game. If your voice or face runs ahead of the gameplay, add a positive offset.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            ExportSection(model: model)
        }
        .formStyle(.grouped)
    }
}

struct VolumeSlider: View {
    @Binding var value: Double
    var max = 2.0
    var onEditingChanged: (Bool) -> Void = { _ in }
    var body: some View {
        HStack {
            Slider(value: $value, in: 0...max, onEditingChanged: onEditingChanged)
            Text("\(Int((value * 100).rounded()))%").font(.caption.monospacedDigit()).frame(width: 40, alignment: .trailing)
        }
    }
}

/// Sync nudge in milliseconds, committed on release so the composition is rebuilt once per change.
struct OffsetRow: View {
    let title: String
    @Binding var value: Double
    @State private var draft: Double?
    var body: some View {
        LabeledContent(title) {
            HStack {
                Slider(value: Binding(get: { draft ?? value }, set: { draft = ($0 / 10).rounded() * 10 }), in: -500...500) { editing in
                    if !editing, let d = draft { value = d; draft = nil }
                }
                Stepper("", value: Binding(get: { value }, set: { value = $0 }), in: -2000...2000, step: 10).labelsHidden()
                Text("\(Int(draft ?? value)) ms").font(.caption.monospacedDigit()).frame(width: 52, alignment: .trailing)
            }
        }
    }
}

struct PositionGrid: View {
    @Bindable var model: EditorModel
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
                            }.buttonStyle(.plain)
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

struct ExportSection: View {
    @Bindable var model: EditorModel
    var body: some View {
        Section("Export") {
            ForEach(Canvas.allCases) { c in
                Toggle(isOn: Binding(get: { model.exportCanvases.contains(c) },
                                     set: { if $0 { model.exportCanvases.insert(c) } else { model.exportCanvases.remove(c) } })) {
                    Label(c.title, systemImage: c == .wide ? "rectangle" : "rectangle.portrait")
                }
            }
            Picker("Resolution", selection: $model.resolution) {
                Text("1080p").tag(ExportResolution.hd)
                Text("4K").tag(ExportResolution.uhd)
            }
            Picker("Frame rate", selection: $model.fps) {
                Text("Source (\(Int(model.project.fps.rounded())))").tag(ExportFPS.source)
                Text("60").tag(ExportFPS.sixty)
                Text("30").tag(ExportFPS.thirty)
            }
            if model.isHDRSource {
                Picker("Color", selection: $model.range) {
                    Text("HDR · HEVC 10-bit").tag(ExportRange.hdr)
                    Text("SDR · H.264").tag(ExportRange.sdr)
                }
                Text(model.range == .hdr ? "Best for YouTube. The preview shows HDR." : "Plays everywhere (TikTok, Reels, Shorts). HDR highlights are tone-mapped; the preview matches.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Canvas.allCases) { c in
                if let s = model.exports[c] {
                    HStack {
                        Text(c.label).font(.caption.bold()).frame(width: 34, alignment: .leading)
                        if s.running { ProgressView(value: s.progress).progressViewStyle(.linear) }
                        else if let e = s.error { Text(e).font(.caption).foregroundStyle(.red).lineLimit(2) }
                        else if let u = s.url {
                            Text(u.lastPathComponent).font(.caption).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button { NSWorkspace.shared.activateFileViewerSelecting([u]) } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.borderless)
                        }
                    }
                }
            }
            HStack {
                if model.anyExporting { Button("Cancel") { model.cancelExports() } }
                Spacer()
                Button {
                    model.export()
                } label: {
                    Label(model.exportCanvases.count > 1 ? "Export Both" : "Export", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("e", modifiers: .command)
                .disabled(model.exportCanvases.isEmpty || model.anyExporting)
            }
        }
    }
}

