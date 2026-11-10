import AppKit
import AVFoundation

// MARK: - Library

/// Lists recordings under ~/Movies/Elgato HDR, newest first.
final class Library: ObservableObject {
    static let shared = Library()
    @Published var docs: [ProjectDoc] = []
    var root: URL { AppDelegate.recordingsDir }
    private var recoveryAttempted = Set<URL>()   // reload runs often; recover each folder at most once per launch

    func reload() {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        let found = dirs.compactMap { ProjectDoc.load($0) }.sorted { $0.project.createdAt > $1.project.createdAt }
        for d in found where d.project.state == "recording" && !AppDelegate.isRecording(d.dir) && !recoveryAttempted.contains(d.dir) {
            recoveryAttempted.insert(d.dir)
            log("recovering interrupted recording \(d.dir.lastPathComponent)")
            // Reload from disk afterwards: another reload may have replaced `d` in `docs` while finalize ran.
            d.finalize { [weak self] in self?.reload() }
        }
        docs = found
    }

    func newProjectDir(date: Date) -> (URL, String) {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let name = "Capture \(f.string(from: date))"
        let dir = root.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (dir, name)
    }

    func rename(_ doc: ProjectDoc, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-")
        guard !clean.isEmpty, clean != doc.project.name else { return }
        if let editor = EditorWindows.shared.model(for: doc.dir) {
            // An open editor autosaves its copy of the project: rename through it and leave the folder alone for now.
            editor.update { $0.name = clean }; editor.saveNow()
            doc.project.name = clean; objectWillChange.send()
            return
        }
        doc.project.name = clean; doc.save()
        // The folder carries the name too, so it reads the same in Finder.
        let dest = doc.dir.deletingLastPathComponent().appendingPathComponent(clean)
        if !FileManager.default.fileExists(atPath: dest.path), (try? FileManager.default.moveItem(at: doc.dir, to: dest)) != nil { doc.dir = dest }
        objectWillChange.send()
    }

    func duplicate(_ doc: ProjectDoc) {
        let fm = FileManager.default
        var dest = root.appendingPathComponent(doc.dir.lastPathComponent + " copy")
        var n = 2
        while fm.fileExists(atPath: dest.path) { dest = root.appendingPathComponent(doc.dir.lastPathComponent + " copy \(n)"); n += 1 }
        do {
            try fm.createDirectory(at: dest, withIntermediateDirectories: true)
            for f in try fm.contentsOfDirectory(atPath: doc.dir.path) where f != "Exports" && f != ".cache" {   // .cache: disposable editor thumbnails and waveforms
                // Layers are immutable once recorded: clone (APFS copy-on-write) so duplicates are free.
                try fm.copyItem(at: doc.url(f), to: dest.appendingPathComponent(f))
            }
            if let copy = ProjectDoc.load(dest) {
                copy.project.name = doc.project.name + " copy"; copy.project.createdAt = Date(); copy.project.lastExport = [:]; copy.save()
            }
        } catch { log("duplicate failed: \(error)") }
        reload()
    }

    func trash(_ doc: ProjectDoc) {
        NSWorkspace.shared.recycle([doc.dir]) { [weak self] _, _ in DispatchQueue.main.async { self?.reload() } }
    }
}
