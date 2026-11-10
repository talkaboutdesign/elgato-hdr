// Image assets for overlay layers. An import is copied under a content-hash name, so the same picture imported twice is
// one file and a layer's `LayerSource.file` never goes stale when the original is moved. A recording copies what its
// scenes use into the project's own `Assets/`, so a project folder stays self-contained; rendering a project looks
// there first, then in the application support folder.
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum AssetStore {
    enum ImportError: Error { case unsupported, unreadable }

    /// Read once: render threads look overlays up every frame. `EHDR_ASSETS_DIR` redirects it for test runs.
    static let appSupportAssets: URL = {
        #if DEBUG
        if let d = ProcessInfo.processInfo.environment["EHDR_ASSETS_DIR"], !d.isEmpty { return URL(fileURLWithPath: d, isDirectory: true) }
        #endif
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Elgato HDR/Assets", isDirectory: true)
    }()
    /// Where to look for a project's assets, in lookup order.
    static func searchPaths(project: URL?) -> [URL] {
        (project.map { [$0.appendingPathComponent("Assets", isDirectory: true)] } ?? []) + [appSupportAssets]
    }

    /// PNG, JPEG, HEIC, TIFF and GIF (first frame only).
    static let supportedTypes: [UTType] = [.png, .jpeg, .heic, .tiff, .gif]

    /// Copies an image into `directory` as `<first 16 hex digits of its SHA-256>.<ext>` and returns that file name.
    /// Importing the same bytes again returns the existing name without writing.
    static func importImage(_ url: URL, into directory: URL = appSupportAssets) throws -> String {
        guard let data = try? Data(contentsOf: url) else { throw ImportError.unreadable }
        guard let src = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(src) > 0,
              let id = CGImageSourceGetType(src).flatMap({ UTType($0 as String) }),
              let type = supportedTypes.first(where: { id.conforms(to: $0) }) else { throw ImportError.unsupported }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let name = String(hash.prefix(16)) + "." + (type.preferredFilenameExtension ?? "img")
        let dst = directory.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: dst.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: dst, options: .atomic)
        }
        return name
    }

    /// The first existing file called `name` in `searchPaths`. Names come from project.json, so anything that is not a
    /// plain file name (a path, `..`, a hidden file) is refused.
    static func locate(_ name: String, in searchPaths: [URL]) -> URL? {
        guard isPlainName(name) else { return nil }
        return searchPaths.map { $0.appendingPathComponent(name) }.first { FileManager.default.fileExists(atPath: $0.path) }
    }
    static func isPlainName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix(".") && !name.contains("/") && !name.contains(":") && (name as NSString).lastPathComponent == name
    }

    /// Image files referenced by any canvas of any scene.
    static func referencedFiles(_ scenes: [Scene]) -> Set<String> {
        Set(scenes.flatMap { $0.wide.layers + $0.vertical.layers }.compactMap { $0.source.type == "image" ? $0.source.file : nil })
    }

    /// Hard-links (or copies, across volumes) each named asset into `projectAssets`. Returns the names it could not
    /// find; those layers stay blank in that project until the asset reappears in the application support folder.
    @discardableResult
    static func bundle(_ names: Set<String>, into projectAssets: URL, from searchPaths: [URL] = [appSupportAssets]) -> [String] {
        let fm = FileManager.default
        try? fm.createDirectory(at: projectAssets, withIntermediateDirectories: true)
        var missing: [String] = []
        for name in names.sorted() {
            let dst = projectAssets.appendingPathComponent(name)
            if fm.fileExists(atPath: dst.path) { continue }
            guard let src = locate(name, in: searchPaths) else { missing.append(name); continue }
            if (try? fm.linkItem(at: src, to: dst)) == nil, (try? fm.copyItem(at: src, to: dst)) == nil { missing.append(name) }
        }
        return missing
    }
}
