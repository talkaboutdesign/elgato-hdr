import Foundation
import Observation

/// "SDR brightness": the HDR luminance (nits) that becomes SDR white when PQ or HLG video is converted for streams,
/// SDR exports and SDR displays. Lower is brighter. One global setting in `UserDefaults`; the stream settings and the
/// export sheet edit the same value on the main thread.
@Observable
final class SdrBrightness {
    static let key = "sdrWhiteNits"
    static let defaultNits: Float = 150
    static let range: ClosedRange<Float> = 80...300
    static let shared = SdrBrightness(store: .standard, publishes: true)

    /// What renderers read on their own threads; written on the main thread when the slider moves. Behind a lock:
    /// the hold is a single load or store, so a render thread never waits on anything slow. A change shows on the
    /// next frame each renderer draws.
    static var current: Float {
        get { lock.lock(); defer { lock.unlock() }; return cached }
        set { lock.lock(); cached = newValue; lock.unlock() }
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: Float = read(.standard)

    @ObservationIgnored private let store: UserDefaults
    @ObservationIgnored private let publishes: Bool
    private var stored: Float

    /// `publishes`: only the shared instance feeds `current`; tests use their own store and leave renderers alone.
    init(store: UserDefaults, publishes: Bool = false) {
        self.store = store; self.publishes = publishes
        stored = Self.read(store)
    }

    var nits: Float {
        get { stored }
        set {
            let v = Self.clamp(newValue)
            guard v != stored else { return }
            stored = v
            store.set(v, forKey: Self.key)
            if publishes { Self.current = v }
        }
    }

    /// Absent or unreadable means the default; out-of-range values (an older build, `defaults write`) are clamped.
    static func read(_ store: UserDefaults) -> Float {
        guard let n = store.object(forKey: key) as? NSNumber else { return defaultNits }
        return clamp(n.floatValue)
    }

    static func clamp(_ v: Float) -> Float { v.isFinite ? min(max(v, range.lowerBound), range.upperBound) : defaultNits }

    /// The UI shows brightness, not nits: 100% is the default, higher is brighter (about 50%...188%).
    static func percent(nits: Float) -> Double { Double(defaultNits / clamp(nits) * 100) }
    static func nits(percent: Double) -> Float { clamp(defaultNits * 100 / Float(max(percent, 1))) }
    static var percentRange: ClosedRange<Double> { percent(nits: range.upperBound)...percent(nits: range.lowerBound) }

    /// Slider position in percent; whole percents, so the read-out does not flicker between neighbours.
    var percent: Double {
        get { Self.percent(nits: nits) }
        set { nits = Self.nits(percent: newValue.rounded()) }
    }
}
