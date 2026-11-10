import AppKit
import AVFoundation
import SwiftUI

// MARK: - Editor view

/// Preview and inspector on top, the timeline across the bottom. `onBack` is set when the editor lives inside the
/// library window, which adds "‹ Library".
struct EditorView: View {
    let model: EditorModel
    var onBack: (() -> Void)? = nil
    @State private var showExport = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                PreviewStage(model: model)
                Rectangle().fill(DS.Color.stroke).frame(width: 1)
                EditorInspector(model: model).frame(width: 300)
            }
            Rectangle().fill(DS.Color.stroke).frame(height: 1)
            TimelinePanel(model: model)
        }
        .background(EditorKeyHandler(model: model) { c in
            switch c {
            case .export: if !model.editsLocked { showExport = true } else { NSSound.beep() }
            case .shortcuts: ShortcutsWindow.show()
            default: model.perform(c)
            }
        })
        .background(WindowTitle(title: model.project.name, subtitle: recordingSummary(model.project, duration: model.duration)))
        .toolbar { toolbar }
        .sheet(isPresented: $showExport) { ExportSheet(model: model) { showExport = false } }
        #if DEBUG
        .background(EditorHarnessHook(model: model, showExport: $showExport))
        #endif
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if let back = onBack {
            ToolbarItem(placement: .navigation) {
                Button(action: back) { Label("Library", systemImage: "chevron.left") }
                    .labelStyle(.titleAndIcon)
                    .help("Back to the recordings library")
                    .accessibilityLabel("Back to Library")
            }
        }
        ToolbarItem(placement: .principal) {
            SegmentedSwitch(selection: Binding(get: { model.canvas }, set: { model.canvas = $0 }), options: [
                .init(value: .wide, label: "16:9", help: "Widescreen canvas"),
                .init(value: .vertical, label: "9:16", help: "Vertical canvas"),
            ], height: 26)
            .frame(width: 120)
            .help("Each canvas has its own layout; both share the timeline")
            .accessibilityLabel("Canvas")
        }
        ToolbarItemGroup(placement: .automatic) {
            ExportProgressCapsule(model: model)
            IconButton(systemImage: "arrow.uturn.backward", help: model.undoTitle + " (⌘Z)") { model.undo() }
                .disabled(!model.canUndo)
            IconButton(systemImage: "arrow.uturn.forward", help: model.redoTitle + " (⇧⌘Z)") { model.redo() }
                .disabled(!model.canRedo)
            IconButton(systemImage: "keyboard", help: "Keyboard Shortcuts (⌘/)") { ShortcutsWindow.show() }
            PillButton("Export", systemImage: "square.and.arrow.up", prominent: true, help: "Export… (⌘E)") { showExport = true }
                .disabled(model.editsLocked)
        }
    }
}

/// Sets the hosting window's title and subtitle (the editor shares a window with the library).
struct WindowTitle: NSViewRepresentable {
    let title: String
    let subtitle: String
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ v: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let w = v.window else { return }
            if w.title != title { w.title = title }
            if w.subtitle != subtitle { w.subtitle = subtitle }
        }
    }
}
