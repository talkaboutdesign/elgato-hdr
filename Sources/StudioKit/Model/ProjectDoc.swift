import AppKit
import AVFoundation

/// A project folder on disk.
final class ProjectDoc: Identifiable, Hashable {
    var dir: URL
    var project: Project
    var id: URL { dir }
    init(dir: URL, project: Project) { self.dir = dir; self.project = project }
    static func == (a: ProjectDoc, b: ProjectDoc) -> Bool { a.dir == b.dir }
    func hash(into h: inout Hasher) { h.combine(dir) }

    func url(_ file: String) -> URL { dir.appendingPathComponent(file) }
    var thumbnailURL: URL { dir.appendingPathComponent("thumbnail.jpg") }
    /// The render version `thumbnail.jpg` was made with (`renderVersion`); absent for thumbnails made before it.
    var thumbnailVersionURL: URL { dir.appendingPathComponent("thumbnail.version") }

    /// Bumped whenever the editor's composite draws a project differently, so pictures cached from an older one (the
    /// library's thumbnail and hover frames) are made again. 2: image and text overlays are drawn.
    static let renderVersion = 2
    /// The thumbnail exists and was made by the current composite.
    var thumbnailIsCurrent: Bool {
        guard FileManager.default.fileExists(atPath: thumbnailURL.path),
              let s = try? String(contentsOf: thumbnailVersionURL, encoding: .utf8) else { return false }
        return Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) == Self.renderVersion
    }
    var exportsDir: URL { dir.appendingPathComponent("Exports") }
    var hasCamera: Bool { project.camera.map { FileManager.default.fileExists(atPath: url($0.file).path) } ?? false }
    var hasMic: Bool { project.mic.map { FileManager.default.fileExists(atPath: url($0.file).path) } ?? false }

    static func load(_ dir: URL) -> ProjectDoc? {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent("project.json")) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        guard let p = try? dec.decode(Project.self, from: d) else { return nil }
        let doc = ProjectDoc(dir: dir, project: p)
        Exporter.removeStalePartials(in: doc.exportsDir)
        let raw = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
        if (raw?["scenes"] as? [Any])?.isEmpty != false || (raw?["version"] as? Int ?? 1) < 2 ||
            (p.eventsImported && raw?["eventsImported"] as? Bool != true) || (p.eventTransitions && raw?["eventTransitions"] as? Bool != true) ||
            (p.liveZooms && raw?["liveZooms"] as? Bool != true) { doc.save() }
        return doc
    }

    func save() {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(project) { try? d.write(to: dir.appendingPathComponent("project.json"), options: .atomic) }
    }

    /// Fills in duration and size from the game file and writes a thumbnail; used after recording and for recovery.
    /// Layers that did not survive (missing file, no samples) are dropped; an unreadable game file marks the project
    /// "damaged" so the library stops retrying it.
    func finalize(completion: @escaping () -> Void) {
        Task {
            let asset = AVURLAsset(url: url(project.game.file))
            let duration = try? await asset.load(.duration)
            let track = try? await asset.loadTracks(withMediaType: .video).first
            guard let d = duration, d.seconds.isFinite, d.seconds > 0, let t = track else {
                log("finalize: \(project.game.file) in \(dir.lastPathComponent) is unreadable, marking damaged")
                project.state = "damaged"
                save()
                await MainActor.run { completion() }
                return
            }
            project.durationMs = d.seconds * 1000
            if let s = try? await t.load(.naturalSize) { project.width = Int(s.width); project.height = Int(s.height) }
            if let f = try? await t.load(.nominalFrameRate), f > 0 { project.fps = Double(f) }
            if let c = project.camera, await !layerReadable(c) { log("finalize: dropping unreadable camera layer \(c.file)"); project.camera = nil }
            if let m = project.mic, await !layerReadable(m) { log("finalize: dropping unreadable mic layer \(m.file)"); project.mic = nil }
            project.state = "complete"
            project.importEvents()
            // Import before choosing the thumbnail time; notify the library only after it exists.
            await writeThumbnail()
            save()
            await MainActor.run { completion() }
        }
    }

    private func layerReadable(_ layer: LayerInfo) async -> Bool {
        let u = url(layer.file)
        guard FileManager.default.fileExists(atPath: u.path), let d = try? await AVURLAsset(url: u).load(.duration) else { return false }
        return d.seconds.isFinite && d.seconds > 0
    }

    /// Card image for the library: a frame of the 16:9 composite, so it shows the facecam as laid out.
    @discardableResult
    func writeThumbnail() async -> Bool {
        let at = CMTime(seconds: project.timeline.markers.first.map { max(0, min(project.durationMs - 1000 / max(1, project.fps), $0.tMs)) / 1000 } ?? min(3, max(0, project.durationMs / 2000)), preferredTimescale: 600)
        var image: CGImage?, composite = false
        if let built = try? await CompositionBuilder.build(self, canvas: .wide, resolution: .hd, range: .sdr, ignoreCuts: true) {
            let gen = AVAssetImageGenerator(asset: built.asset)
            gen.videoComposition = built.video
            gen.maximumSize = CGSize(width: 640, height: 360)
            image = try? await gen.image(at: at).image
            composite = image != nil
        }
        if image == nil {
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url(project.game.file)))
            gen.maximumSize = CGSize(width: 640, height: 360)
            image = try? await gen.image(at: at).image
        }
        guard let img = image else { return false }
        let rep = NSBitmapImageRep(cgImage: img)
        guard (try? rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])?.write(to: thumbnailURL)) != nil else { return false }
        // Only the composite counts as current: a game-only fallback is retried the next time the library shows it.
        if composite { try? "\(Self.renderVersion)\n".write(to: thumbnailVersionURL, atomically: true, encoding: .utf8) }
        else { try? FileManager.default.removeItem(at: thumbnailVersionURL) }
        return composite
    }

    private static let staleLock = NSLock()
    private static var staleRefreshes: Set<String> = []
    private static func claimStaleRefresh(_ key: String) -> Bool {
        staleLock.lock(); defer { staleLock.unlock() }
        return staleRefreshes.insert(key).inserted
    }
    /// Remakes the thumbnail of a finished project whose `thumbnail.jpg` predates the current `renderVersion`, off the
    /// main thread. At most once per project folder per launch, so a project whose composite cannot be built is not
    /// retried on every redraw. True when a new thumbnail was written.
    func refreshStaleThumbnail() async -> Bool {
        guard project.state == "complete", !thumbnailIsCurrent else { return false }
        guard Self.claimStaleRefresh(dir.standardizedFileURL.path) else { return false }
        let snapshot = ProjectDoc(dir: dir, project: project)
        let made = await Task.detached(priority: .utility) { await snapshot.writeThumbnail() }.value
        if made { log("library: remade the thumbnail of \(dir.lastPathComponent) for render version \(Self.renderVersion)") }
        return made
    }
}

