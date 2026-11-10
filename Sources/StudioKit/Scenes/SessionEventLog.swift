import CoreGraphics
import Foundation

/// Timing of the live event log during one recording: event times in source milliseconds and the throttle for
/// rewriting project.json (at most every `saveInterval`, the rest at stop).
struct SessionEventLog {
    let startNs: UInt64
    var saveInterval: UInt64 = 5_000_000_000
    private(set) var lastSaveNs: UInt64

    init(startNs: UInt64) { self.startNs = startNs; lastSaveNs = startNs }

    /// Source time of host time `ns`; the recording's first frame is 0.
    func tMs(atNs ns: UInt64) -> Double { ns > startNs ? Double(ns - startNs) / 1e6 : 0 }

    func event(_ type: String, atNs ns: UInt64, sceneID: UUID? = nil, zoom: Double? = nil, focus: CGPoint? = nil) -> SessionEvent {
        SessionEvent(tMs: (tMs(atNs: ns) * 10).rounded() / 10, type: type, sceneID: sceneID, zoom: zoom,
                     focusX: focus.map { Double($0.x) }, focusY: focus.map { Double($0.y) })
    }

    /// Nanoseconds until the next save is allowed (0: save now).
    func saveDelay(atNs ns: UInt64) -> UInt64 { ns >= lastSaveNs + saveInterval ? 0 : lastSaveNs + saveInterval - ns }
    mutating func didSave(atNs ns: UInt64) { lastSaveNs = ns }
}
