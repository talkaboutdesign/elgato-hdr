import AppKit
import AVFoundation
import Observation

/// User-visible app name; every UI string goes through it so a rename is one line.
enum AppInfo { static let name = "Elgato HDR" }

struct DeviceInfo: Identifiable, Equatable, Hashable { let id: String; let name: String }

enum Connection: Equatable {
    case connecting, live, noSignal(String), demo
}

/// Phase of the stream as a whole; per-destination health is in `StreamingState`.
enum StreamUIState: Equatable {
    case unavailable
    case idle
    case connecting
    case live(since: Date)
}

struct Toast: Identifiable, Equatable {
    enum Style: Equatable { case info, success, warning, error }
    let id = UUID()
    var text: String
    var detail: String? = nil
    var style: Style = .info

    var symbol: String {
        switch style {
        case .info: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }
}

/// What a stopped recording reports to its caller (toast, log, quit), decided after `finalize` has run.
enum RecordingOutcome: Equatable {
    case saved(name: String, layers: [String])
    case failed(reason: String)

    /// `gameError` is the game writer's message when it did not complete. Fragments written before the failure can
    /// still make the project readable, but the recording stopped short, so that is reported as a failure too.
    init(project: Project, gameError: String?) {
        if project.state == "damaged" {
            self = .failed(reason: "\(project.name) could not be read and was marked damaged" + (gameError.map { " (\($0))" } ?? ""))
        } else if let e = gameError {
            self = .failed(reason: "The game video did not finish (\(e)); \(project.name) keeps what was written")
        } else {
            self = .saved(name: project.name, layers: ["game"] + (project.camera != nil ? ["camera"] : []) + (project.mic != nil ? ["mic"] : []))
        }
    }

    /// Nil when the writer completed. `Recorder.finish` reports "saved …" even when `finishWriting` failed, so the
    /// writer's own error comes first.
    static func writerError(_ w: AVAssetWriter, message: String) -> String? {
        w.status == .completed ? nil : (w.error?.localizedDescription ?? message)
    }

    var logLine: String {
        switch self {
        case .saved(let name, let layers): return "saved \(name) [\(layers.joined(separator: " + "))]"
        case .failed(let reason): return "recording failed: \(reason)"
        }
    }

    var toast: Toast {
        switch self {
        case .saved(let name, let layers): return Toast(text: "Recording saved", detail: "\(name) · \(layers.joined(separator: ", "))", style: .success)
        case .failed(let reason): return Toast(text: "Recording failed", detail: reason, style: .error)
        }
    }
}

/// Everything the UI can ask for. `AppDelegate` fills these in; menu items call the same methods, so menus and
/// controls can never disagree.
struct StudioActions {
    var toggleRecording: () -> Void = {}
    var goLive: () -> Void = {}
    var selectMode: (Int) -> Void = { _ in }
    var selectColor: (ColorMode) -> Void = { _ in }
    var selectPresentation: (Presentation) -> Void = { _ in }
    var setMuted: (Bool) -> Void = { _ in }
    var selectCamera: (String?) -> Void = { _ in }
    var selectMic: (String?) -> Void = { _ in }
    var setPlacement: (CameraPlacement) -> Void = { _ in }
    var setShape: (CameraShape) -> Void = { _ in }
    var setAspect: (CameraAspect) -> Void = { _ in }
    var setPosition: (Int) -> Void = { _ in }     // 0...8 in row order, 4 (centre) unused
    var setMirror: (Bool) -> Void = { _ in }
    var setBorder: (Bool) -> Void = { _ in }
    var setShadow: (Bool) -> Void = { _ in }
    var refreshDevices: () -> Void = {}
    var reconnect: () -> Void = {}
    var showLibrary: () -> Void = {}
    var toggleSidebar: () -> Void = {}
    var toggleFocus: () -> Void = {}
}

enum CameraShape: String, CaseIterable, Identifiable {
    case circle, rounded, square
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var symbol: String { switch self { case .circle: "circle"; case .rounded: "app"; case .square: "square" } }
    init(_ p: CameraPlacement) { self = p.isCircle ? .circle : p.roundness == 0 ? .square : .rounded }
    func apply(to p: inout CameraPlacement) {
        switch self {
        case .circle: p.aspect = .square; p.roundness = 0.5
        case .square: p.roundness = 0
        case .rounded: p.roundness = 0.16
        }
    }
}

/// The single observable object the studio UI reads. `@Observable` tracks reads per property, so a view only
/// re-renders for the values it shows: the 20 Hz mic level only invalidates the meter, not the whole sidebar.
/// Written on the main thread only.
@Observable
final class StudioState {
    // connection and signal
    var connection: Connection = .connecting
    var signal = ""                 // "2560×1440 · 60 fps · HDR10"
    var shortSignal = ""            // "1440p60 HDR"
    var latencyMs: Double = 0
    var modeIndex = 0
    var colorMode: ColorMode = .pq
    var presentation: Presentation = .smooth
    var muted = false
    // devices
    var cameras: [DeviceInfo] = []
    var cameraID: String?           // the shown camera, nil = off
    var microphones: [DeviceInfo] = []
    var micID: String?              // nil = none
    var micLevel: Float = 0         // linear peak 0...1, published at most 20 times a second
    var placement = CameraPlacement()
    var cameraMirror = false
    // recording
    var recording = false
    var recordingElapsed: TimeInterval = 0
    var recordingLayers: [String] = []
    // streaming: destinations, settings and live health (plan 21)
    let streaming = StreamingState()
    // transient messages
    var toast: Toast?
    // window chrome
    var sidebarVisible = true
    var focusMode = false

    @ObservationIgnored var actions = StudioActions()

    var cameraOn: Bool { cameraID != nil }
    var micOn: Bool { micID != nil }

    /// Applies one statistics report from the capture session (at most once a second). Only these reports may mark
    /// the connection live: a frame arrived.
    func applyStats(width: Int, height: Int, fps: Double, latencyMs: Double, demo: Bool) {
        formatSignal(width: width, height: height, fps: fps)
        let ms = latencyMs.rounded()
        if self.latencyMs != ms { self.latencyMs = ms }
        let c: Connection = demo ? .demo : .live
        if connection != c { connection = c }
    }

    /// Re-labels the signal (for example after a colour mode change) without touching the connection state.
    func formatSignal(width: Int, height: Int, fps: Double) {
        let s = StudioFormat.signal(width: width, height: height, fps: fps, color: colorMode)
        let short = StudioFormat.shortSignal(width: width, height: height, fps: fps, color: colorMode)
        if signal != s { signal = s }
        if shortSignal != short { shortSignal = short }
    }

    /// Text for the status pill over the picture.
    var pillText: String {
        switch connection {
        case .connecting: return "Connecting…"
        case .noSignal(let why): return why.isEmpty ? "No signal" : "No signal · \(why)"
        case .live, .demo:
            let prefix = connection == .demo ? "Demo source · " : ""
            guard !shortSignal.isEmpty else { return connection == .demo ? "Demo source" : "Starting…" }
            return prefix + shortSignal + (latencyMs > 0 ? " · \(Int(latencyMs)) ms" : "")
        }
    }
}

/// Sidebar visibility across focus mode, kept free of AppKit so it can be tested. `sidebar` is what the window
/// should show; `restoreSidebar` is the sidebar as it was before focus mode.
struct PanelLayout: Equatable {
    var focus = false, sidebar = true, restoreSidebar = true

    mutating func enterFocus() { guard !focus else { return }; restoreSidebar = sidebar; focus = true; sidebar = false }
    mutating func leaveFocus() { guard focus else { return }; focus = false; sidebar = restoreSidebar }

    /// ⌥⌘S and the toolbar's inspector button. In focus mode a sidebar would shrink the full-screen picture, so the
    /// toggle leaves focus mode instead (panels restored as before), then applies to what was on screen: the hidden
    /// sidebar is shown, as the menu item ("Show Sidebar") promises. Returns true when focus mode must end; the
    /// caller then leaves full screen, which calls `leaveFocus`.
    mutating func toggleSidebar() -> Bool {
        if focus { restoreSidebar = true; return true }
        sidebar.toggle(); return false
    }
}

/// Pure formatting, shared by the studio window and tests.
enum StudioFormat {
    /// Recording timer: "04:07", or "1:02:05" past an hour.
    static func elapsed(_ t: TimeInterval) -> String {
        let s = max(0, Int(t.isFinite ? t : 0))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }

    /// Nominal rate: 59.94 shows as 60, a measured 59.6 as 60, 29.97 as 30.
    static func roundedFps(_ fps: Double) -> Int { fps.isFinite && fps > 0 ? Int(fps.rounded()) : 0 }

    /// The mode's rate while the measured rate is close to it (USB arrival jitter reads 59.4 or 60.6), else the measurement.
    static func nominalFps(measured: Double, nominal: Double) -> Double {
        abs(measured - nominal) < 2 ? nominal : measured
    }

    static func colorLabel(_ c: ColorMode) -> String { switch c { case .pq: "HDR10"; case .hlg: "HLG"; case .sdr: "SDR" } }

    static func signal(width: Int, height: Int, fps: Double, color: ColorMode) -> String {
        guard width > 0, height > 0 else { return "" }
        return "\(width)×\(height) · \(roundedFps(fps)) fps · \(colorLabel(color))"
    }

    /// Compact form for the pill: "1440p60 HDR", "2560×1080p60 SDR" for non-16:9 sizes.
    static func shortSignal(width: Int, height: Int, fps: Double, color: ColorMode) -> String {
        guard width > 0, height > 0 else { return "" }
        let res = width * 9 == height * 16 ? (height == 2160 ? "4K" : "\(height)p") : "\(width)×\(height)p"
        let range = color == .sdr ? "SDR" : color == .hlg ? "HLG" : "HDR"
        return "\(res)\(roundedFps(fps)) \(range)"
    }

    /// Parses the capture session's once-a-second line ("2560x1440 10-bit  59.9 fps  •  22 ms to screen").
    static func parseStats(_ info: String) -> (fps: Double, latencyMs: Double)? {
        guard let f = info.range(of: #"([0-9.]+) fps"#, options: .regularExpression),
              let fps = Double(info[f].dropLast(4)) else { return nil }
        var ms = 0.0
        if let l = info.range(of: #"([0-9.]+) ms to screen"#, options: .regularExpression) {
            ms = Double(info[l].split(separator: " ").first ?? "") ?? 0
        }
        return (fps, ms)
    }

    /// Mic level in dBFS for metering, clamped to -60...0.
    static func dbfs(_ linear: Float) -> Float { linear > 0.001 ? max(-60, min(0, 20 * log10(linear))) : -60 }
    /// Meter position 0...1 for a linear peak.
    static func meterFraction(_ linear: Float) -> Double { Double((dbfs(linear) + 60) / 60) }
}
