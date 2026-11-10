import AppKit
import AVFoundation
import SwiftUI

// MARK: - Editor view

struct EditorView: View {
    @Bindable var model: EditorModel

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                PreviewStage(model: model)
                Divider()
                TimelinePanel(model: model)
            }
            Divider()
            Inspector(model: model).frame(width: 320)
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Canvas", selection: $model.canvas) {
                    ForEach(Canvas.allCases) { c in Text(c.label).tag(c) }
                }
                .pickerStyle(.segmented)
                .frame(width: 140)
                .help("Each canvas has its own layout; both can be exported at once")
            }
            ToolbarItemGroup {
                Button { model.undo() } label: { Label(model.undoTitle, systemImage: "arrow.uturn.backward") }
                    .disabled(!model.canUndo).help(model.undoTitle + " (⌘Z)")
                Button { model.redo() } label: { Label(model.redoTitle, systemImage: "arrow.uturn.forward") }
                    .disabled(!model.canRedo).help(model.redoTitle + " (⇧⌘Z)")
            }
            ToolbarItem {
                Button { NSWorkspace.shared.activateFileViewerSelecting([model.doc.dir]) } label: { Label("Show in Finder", systemImage: "folder") }
            }
        }
    }
}
