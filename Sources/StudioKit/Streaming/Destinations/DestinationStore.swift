import Foundation

/// `~/Library/Application Support/Elgato HDR/streaming.json`. Tests and agent demo runs point it elsewhere
/// (`EHDR_STREAMING_FILE`) so they never touch the user's destinations.
struct DestinationStore {
    let url: URL

    static var defaultURL: URL {
        if let path = ProcessInfo.processInfo.environment["EHDR_STREAMING_FILE"], !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("\(AppInfo.name)/streaming.json")
    }
    init(url: URL = DestinationStore.defaultURL) { self.url = url }

    /// A missing or unreadable file is an empty configuration; a damaged one is kept aside rather than overwritten.
    func load() -> StreamingConfig {
        guard let data = try? Data(contentsOf: url) else { return StreamingConfig() }
        do { return try JSONDecoder().decode(StreamingConfig.self, from: data) }
        catch {
            let aside = url.deletingPathExtension().appendingPathExtension("damaged.json")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.copyItem(at: url, to: aside)
            log("streaming: \(url.lastPathComponent) is unreadable, kept a copy as \(aside.lastPathComponent)")
            return StreamingConfig()
        }
    }

    func save(_ config: StreamingConfig) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(config).write(to: url, options: .atomic)
    }
}
