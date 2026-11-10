// What the Stream tab, the Go Live button and its popovers read. Written on the main thread by StreamController.
// Stream keys are never stored here: the add/edit sheet keeps the typed key in its own view state only.
import Foundation
import Observation

enum DestinationStatus: Equatable {
    case off                        // not part of the stream
    case connecting
    case live
    case reconnecting(attempt: Int)
    case failed(String)             // permanent until retried: "Stream key rejected"

    var isActive: Bool { switch self { case .off, .failed: false; default: true } }
}

struct DestinationHealth: Equatable {
    var status: DestinationStatus = .off
    var kbps: Double = 0
    var dropped = 0
    var reconnects = 0
    var liveSince: Date?
    /// Last problem in plain words, for the card and the popover.
    var detail: String?
    /// Frames keep dropping: "Upload too slow for this bitrate".
    var slowUpload = false
}

struct CanvasHealth: Equatable {
    var canvas: Canvas
    var fps: Double
    var renderMs: Double
    var encodeMs: Double
    var dropped: Int
}

/// Opens the add/edit sheet: `destination` nil adds a new one (starting at `service` when given).
struct DestinationEditorRequest: Identifiable, Equatable {
    let id = UUID()
    var destination: Destination?
    var service: Destination.Service?
}

enum ConnectionTestResult: Equatable {
    case connected
    case failed(stage: String, message: String)
}

struct StreamActions {
    var goLive: () -> Void = {}
    var endStream: () -> Void = {}
    /// Saves a destination and, when `key` is non-nil, its stream key. Calls back on main with an error message or nil.
    var save: (Destination, String?, @escaping (String?) -> Void) -> Void = { _, _, done in done(nil) }
    var delete: (UUID) -> Void = { _ in }
    var setEnabled: (UUID, Bool) -> Void = { _, _ in }
    var retry: (UUID) -> Void = { _ in }
    var updateSettings: (StreamSettings) -> Void = { _ in }
    /// Tests `destination` with `key`, or with its saved key when `key` is nil.
    var testConnection: (Destination, String?, @escaping (ConnectionTestResult) -> Void) -> Void = { _, _, _ in }
    var openHelp: (Destination.Service) -> Void = { _ in }
    /// Shows the Stream tab and opens the add sheet.
    var addDestination: () -> Void = {}
}

@Observable
final class StreamingState {
    var phase: StreamUIState = .idle
    var destinations: [Destination] = []
    var settings = StreamSettings()
    var health: [UUID: DestinationHealth] = [:]
    var canvases: [CanvasHealth] = []
    /// Destinations with a key in the Keychain (attributes only; the secret is not read for this).
    var keyStored: Set<UUID> = []
    var showGoLivePopover = false
    var editor: DestinationEditorRequest?
    /// Settings the running stream uses; edits apply the next time you go live.
    var liveSettings: StreamSettings?

    @ObservationIgnored var actions = StreamActions()

    var enabledCount: Int { destinations.filter(\.enabled).count }
    var isActive: Bool { phase != .idle && phase != .unavailable }
    var liveSince: Date? { if case .live(let since) = phase { return since }; return nil }
    func health(_ id: UUID) -> DestinationHealth { health[id] ?? DestinationHealth() }
    var uploadSummary: String { StreamPlanner.uploadSummary(enabled: enabledCount, settings: settings) }
}

/// Plain-language text for publisher errors, shared by the health display and "Test connection".
enum StreamErrorText {
    /// Splits a publisher error ("TCP/TLS: POSIXErrorCode(rawValue: 61): Connection refused", "handshake timed out")
    /// into the stage that failed and what to tell the user.
    static func describe(_ raw: String?) -> (stage: String, message: String) {
        let s = raw ?? ""
        let lower = s.lowercased()
        if lower.hasPrefix("tcp/tls") {
            if lower.contains("timed out") { return ("Connect", "The server did not answer. Check the URL and your network.") }
            if lower.contains("refused") { return ("Connect", "Connection refused. Is the server running on that port?") }
            if lower.contains("nodename") || lower.contains("dns") || lower.contains("-65554") || lower.contains("not known") {
                return ("Connect", "Server not found. Check the host name in the URL.")
            }
            if lower.range(of: "-98[0-9][0-9]", options: .regularExpression) != nil || lower.contains("certificate") || lower.contains("ssl") {
                return ("Secure connection", "The secure (TLS) connection failed. Check rtmp:// versus rtmps:// and the port.")
            }
            return ("Connect", "Could not reach the server.")
        }
        if lower.hasPrefix("handshake") { return ("Handshake", "The server did not complete the RTMP handshake. Is this an RTMP server?") }
        if lower.hasPrefix("connect timed out") { return ("RTMP connect", "The server did not accept the connection. Check the application path in the URL.") }
        if lower.hasPrefix("createstream") || lower.hasPrefix("publish") { return ("Publish", "The server did not start the stream. Check the stream key.") }
        if lower.hasPrefix("connection closed") { return ("Publish", "The server closed the connection. Check the stream key.") }
        if lower.hasPrefix("upload stalled") { return ("Upload", "Upload too slow for this bitrate.") }
        if lower.hasPrefix("malformed") { return ("Publish", "The server sent an unexpected response.") }
        if lower.hasPrefix("receive") || lower.hasPrefix("send") { return ("Upload", "The connection dropped.") }
        return ("Publish", s.isEmpty ? "Unknown error." : s)
    }
}

/// Decides when a destination "keeps dropping frames": new drops in at least 3 of the last 5 one-second reports,
/// or a send backlog over 1.5 s. Clears after 5 clean reports.
struct DropTracker {
    private var last: Int?
    private var recent: [Bool] = []
    private(set) var slow = false

    mutating func update(dropped: Int, pendingMs: Double) -> Bool {
        let fresh = last.map { dropped > $0 } ?? (dropped > 0)
        last = dropped
        recent.append(fresh || pendingMs > 1500)
        if recent.count > 5 { recent.removeFirst() }
        if recent.filter({ $0 }).count >= 3 { slow = true }
        else if recent.count == 5 && !recent.contains(true) { slow = false }
        return slow
    }
}
