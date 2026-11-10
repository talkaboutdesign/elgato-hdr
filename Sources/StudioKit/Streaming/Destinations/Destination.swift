// Where the app streams to. Destinations and output settings live in `streaming.json`; stream keys never do (they are
// in the Keychain, see KeychainStore). Every field decodes leniently so a hand-edited or older file still loads.
import Foundation
import CoreGraphics

struct Destination: Codable, Identifiable, Equatable {
    enum Service: String, Codable, CaseIterable, Identifiable {
        case twitch, youtube, kick, custom
        var id: String { rawValue }
    }
    var id = UUID()
    var service: Service
    var name: String                // "Twitch", "YouTube Shorts", user-editable
    var url: String                 // rtmp(s)://host[:port]/app
    var canvas: Canvas              // .wide or .vertical
    var enabled = true

    init(id: UUID = UUID(), service: Service, name: String? = nil, url: String? = nil, canvas: Canvas = .wide, enabled: Bool = true) {
        self.id = id; self.service = service; self.canvas = canvas; self.enabled = enabled
        self.name = name ?? service.preset.defaultName(canvas)
        self.url = url ?? service.preset.defaultURL
    }

    enum CodingKeys: String, CodingKey { case id, service, name, url, canvas, enabled }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.v(.id, UUID())
        service = c.v(.service, .custom)
        canvas = c.v(.canvas, .wide)
        name = c.v(.name, service.preset.defaultName(canvas))
        url = c.v(.url, "")
        enabled = c.v(.enabled, true)
    }

    var endpoint: StreamEndpoint? { StreamEndpoint(url: Destination.normalizedURL(url, service: service)) }
    /// Host only, for cards and logs: never the path, where a pasted key could hide.
    var host: String { URLComponents(string: url.trimmingCharacters(in: .whitespaces))?.host ?? "" }
}

/// One set for all destinations in this version; per-destination bitrate is out of scope.
struct StreamSettings: Codable, Equatable {
    var resolution = 1080           // 1080 or 720 (short side)
    var fps = 60                    // 60 or 30
    var videoKbps = 6000
    var audioKbps = 160
    var micDelayMs: Double = 0

    static let bitrateRange = 2500...9000

    init() {}
    enum CodingKeys: String, CodingKey { case resolution, fps, videoKbps, audioKbps, micDelayMs }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self), d = StreamSettings()
        resolution = c.v(.resolution, d.resolution); fps = c.v(.fps, d.fps)
        videoKbps = c.v(.videoKbps, d.videoKbps); audioKbps = c.v(.audioKbps, d.audioKbps)
        micDelayMs = c.v(.micDelayMs, d.micDelayMs)
        self = sanitized
    }

    /// Out-of-range values (hand edits, older builds) snap to something the encoder and servers accept.
    var sanitized: StreamSettings {
        var s = self
        s.resolution = resolution == 720 ? 720 : 1080
        s.fps = fps == 30 ? 30 : 60
        s.videoKbps = min(max(videoKbps, 500), 20_000)
        s.audioKbps = min(max(audioKbps, 64), 320)
        s.micDelayMs = micDelayMs.isFinite ? min(max(micDelayMs, 0), 1000) : 0
        return s
    }

    func size(_ canvas: Canvas) -> CGSize {
        let long = resolution == 720 ? 1280.0 : 1920.0, short = Double(resolution == 720 ? 720 : 1080)
        return canvas == .wide ? CGSize(width: long, height: short) : CGSize(width: short, height: long)
    }
    /// Upload for `count` destinations in kbps: every destination carries its own copy of video and audio.
    func uploadKbps(destinations count: Int) -> Int { (videoKbps + audioKbps) * count }
}

/// Everything in `streaming.json`.
struct StreamingConfig: Codable, Equatable {
    var destinations: [Destination] = []
    var settings = StreamSettings()

    init(destinations: [Destination] = [], settings: StreamSettings = StreamSettings()) {
        self.destinations = destinations; self.settings = settings
    }
    enum CodingKeys: String, CodingKey { case destinations, settings }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // One unreadable entry must not drop the rest of the list.
        destinations = ((try? c.decodeIfPresent([Lenient<Destination>].self, forKey: .destinations)) ?? nil)?.compactMap(\.value) ?? []
        settings = c.v(.settings, StreamSettings())
    }
}

private struct Lenient<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

// MARK: - Service presets

struct ServicePreset {
    let title: String
    let defaultURL: String
    /// Where the stream key is, in the platform's own words.
    let keyHint: String
    let note: String?
    /// Opens the platform's stream settings page.
    let helpURL: URL?
    let monogram: String
    /// Tile colour as 0xRRGGBB, and whether the monogram is dark on it.
    let tint: UInt32
    let darkMonogram: Bool

    func defaultName(_ canvas: Canvas) -> String {
        guard canvas == .vertical else { return title }
        return title == "YouTube" ? "YouTube Shorts" : title == "Custom server" ? "Custom (vertical)" : "\(title) Vertical"
    }
}

extension Destination.Service {
    // Verified in November 2026 against each platform's own pages; the sources are listed in the pull request of plan 21.
    var preset: ServicePreset {
        switch self {
        case .twitch:
            // Twitch's ingest list (ingest.twitch.tv/ingests) names this host its "Default" (global, auto-routed) ingest.
            return ServicePreset(title: "Twitch", defaultURL: "rtmps://ingest.global-contribute.live-video.net:443/app",
                keyHint: "Creator Dashboard → Settings → Stream → Primary Stream key.",
                note: "Twitch recommends 6,000 kbps for 1080p60; higher bitrates may be rejected.",
                helpURL: URL(string: "https://dashboard.twitch.tv/settings/stream"), monogram: "T", tint: 0x9146FF, darkMonogram: false)
        case .youtube:
            return ServicePreset(title: "YouTube", defaultURL: "rtmps://a.rtmps.youtube.com:443/live2",
                keyHint: "YouTube Studio → Create → Go live → Stream → Stream settings → Stream key.",
                note: "A vertical 9:16 stream is published as a vertical live.",
                helpURL: URL(string: "https://www.youtube.com/livestreaming"), monogram: "Y", tint: 0xE62117, darkMonogram: false)
        case .kick:
            return ServicePreset(title: "Kick", defaultURL: "",
                keyHint: "Creator Dashboard → Channel → Stream URL and Key. Copy both: Kick gives every creator a personal server URL.",
                note: nil,
                helpURL: URL(string: "https://dashboard.kick.com/stream"), monogram: "K", tint: 0x53FC18, darkMonogram: true)
        case .custom:
            return ServicePreset(title: "Custom server", defaultURL: "",
                keyHint: "The stream key or stream name your server expects.",
                note: "Any RTMP or RTMPS server, for example rtmp://192.168.1.10/live.",
                helpURL: nil, monogram: "", tint: 0x5E5E66, darkMonogram: false)
        }
    }
}

// MARK: - URL helpers

extension Destination {
    /// Trims whitespace, and gives Twitch and Kick (both Amazon IVS ingest) their `/app` when it was left off.
    static func normalizedURL(_ raw: String, service: Service) -> String {
        let url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard service == .twitch || service == .kick, var c = URLComponents(string: url), c.host != nil,
              c.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty else { return url }
        c.path = "/app"
        return c.string ?? url
    }

    /// People often copy "URL + key" as one string. For a known service the app is a single path component
    /// (`/app`, `/live2`), so anything after it is the key: returns the split, or nil if there is nothing to split.
    static func splitKey(from raw: String, service: Service) -> (url: String, key: String)? {
        guard service != .custom else { return nil }
        let url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var c = URLComponents(string: url), c.host != nil, c.query == nil else { return nil }
        let parts = c.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count > 1 else { return nil }
        c.percentEncodedPath = "/" + parts[0]
        let key = parts.dropFirst().joined(separator: "/")
        guard let base = c.string, !key.isEmpty else { return nil }
        return (base, key.removingPercentEncoding ?? key)
    }

    /// Nil when the URL is usable, else a short reason for the sheet.
    static func urlProblem(_ raw: String, service: Service) -> String? {
        let url = normalizedURL(raw, service: service)
        if url.isEmpty { return service == .kick ? "Paste the Stream URL from your Kick dashboard." : "Enter the server URL." }
        guard let c = URLComponents(string: url), let scheme = c.scheme?.lowercased() else { return "This is not a valid URL." }
        guard scheme == "rtmp" || scheme == "rtmps" else { return "The URL must start with rtmp:// or rtmps://." }
        guard StreamEndpoint(url: url) != nil else { return "The URL needs a server and an application path, like rtmp://host/live." }
        return nil
    }
}
