import AppKit
import Foundation

extension EditorModel {
    /// Queues the ticked presets in the sheet's order. Edits pause until the queue is done, so every queued job
    /// exports the project as it is now.
    func startExport(_ presets: [ExportPreset], custom: ExportPreset.Custom) {
        endGesture()
        saveNow()
        if playing { pause() }
        let p = project
        let jobs = ExportPreset.allCases.filter { presets.contains($0) }.flatMap { preset in
            preset.jobs(for: p, custom: custom).map { j -> (title: String, job: ExportJob) in
                let title = preset == .custom ? "Custom \(j.canvas.label)" : preset.title
                return (title, j)
            }
        }
        guard !jobs.isEmpty else { NSSound.beep(); return }
        let added = exportQueue.enqueue(jobs)
        exportQueue.onDrained = { [weak self] in
            self?.refreshUndoState()
            Library.shared.objectWillChange.send()
        }
        refreshUndoState()
        log("export: queued \(added) of \(jobs.count) (\(jobs.map { ExportPreset.describe($0.job) }.joined(separator: ", ")))")
    }

    /// Image layers of the scenes this edit shows whose file is in neither the project's `Assets/` nor the
    /// application support folder: exports leave them out.
    var missingAssets: [MissingAsset] {
        let used = Set(project.timeline.sceneSpans.map(\.sceneID))
        let shown = project.scenes.filter { used.contains($0.id) || $0.id == project.scenes.first?.id }
        return AssetStore.missing(in: shown, searchPaths: assetSearchPaths)
    }

    func exportFinished(_ item: ExportQueue.Item) {
        switch item.state {
        case .done(let url):
            setSilently { $0.lastExport[item.job.canvas.rawValue] = url.lastPathComponent }
            log("export: \(item.title) done: \(url.lastPathComponent)")
            let missing = missingAssets.count
            showToast(EditorToast(text: "Exported \(item.title)", detail: missing == 0 ? url.lastPathComponent : "\(url.lastPathComponent) · \(missing) missing image\(missing == 1 ? "" : "s") left out",
                                  style: missing == 0 ? .success : .warning, file: url), seconds: 12)
        case .failed(let why):
            log("export: \(item.title) failed: \(why)")
            showToast(EditorToast(text: "\(item.title) export failed", detail: why, style: .error), seconds: 8)
        case .cancelled:
            log("export: \(item.title) cancelled")
        default: break
        }
    }
}
