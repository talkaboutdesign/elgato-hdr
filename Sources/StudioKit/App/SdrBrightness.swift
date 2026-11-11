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

    /// What renderers read on their own threads, without a lock. Written only on the main thread; an aligned 32-bit
    /// Float load or store is one instruction on arm64 (and x86-64), so a reader sees the old or the new value,
    /// never a torn mix. A change therefore shows on the next frame each renderer draws.
    nonisolated(unsafe) static var current: Float = shared.nits

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
