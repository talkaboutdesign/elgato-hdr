import Foundation
import Observation

/// Manual picture controls for one video source. Applied in linear light by `layerFrag` (`grade` in
/// `MetalCore.swift`); the defaults are neutral and leave the shader on its ungraded path.
struct PictureGrade: Equatable, Codable {
    var exposure = 0.0      // stops,   -2...2
    var contrast = 0.0      // percent, -100...100
    var highlights = 0.0    // percent, -100...100
    var shadows = 0.0       // percent, -100...100
    var saturation = 100.0  // percent, 0...200
    var temperature = 0.0   // percent, -100...100 (positive is warmer)
    var tint = 0.0          // percent, -100...100 (positive is magenta)

    static let neutral = PictureGrade()
    static let exposureRange: ClosedRange<Double> = -2...2
    static let percentRange: ClosedRange<Double> = -100...100
    static let saturationRange: ClosedRange<Double> = 0...200

    init() {}
    init(exposure: Double = 0, contrast: Double = 0, highlights: Double = 0, shadows: Double = 0, saturation: Double = 100,
         temperature: Double = 0, tint: Double = 0) {
        self.exposure = exposure; self.contrast = contrast; self.highlights = highlights; self.shadows = shadows
        self.saturation = saturation; self.temperature = temperature; self.tint = tint
    }

    var isNeutral: Bool { self == .neutral }

    /// Every control inside its range; a non-finite value (a hand-edited default) is the control's default.
    func clamped() -> PictureGrade {
        func c(_ v: Double, _ r: ClosedRange<Double>, _ d: Double) -> Double { v.isFinite ? min(max(v, r.lowerBound), r.upperBound) : d }
        let n = PictureGrade.neutral
        return PictureGrade(exposure: c(exposure, Self.exposureRange, n.exposure), contrast: c(contrast, Self.percentRange, n.contrast),
                            highlights: c(highlights, Self.percentRange, n.highlights), shadows: c(shadows, Self.percentRange, n.shadows),
                            saturation: c(saturation, Self.saturationRange, n.saturation), temperature: c(temperature, Self.percentRange, n.temperature),
                            tint: c(tint, Self.percentRange, n.tint))
    }

    /// What `layerFrag` reads, computed here so the shader does no per-pixel `exp2` it can avoid. `gain.rgb`: white
    /// balance (normalised so a neutral grey keeps its BT.2020 luminance) times exposure; `gain.w`: contrast exponent.
    /// `tone`: shadows and highlights in stops, saturation, and 1 when the grade does anything (the shader's switch).
    var uniforms: (gain: SIMD4<Float>, tone: SIMD4<Float>) {
        if isNeutral { return (SIMD4(1, 1, 1, 1), SIMD4(0, 0, 1, 0)) }
        let g = clamped()
        let t: Double = g.temperature / 100, n: Double = g.tint / 100
        let r: Double = exp2(0.30 * t + 0.15 * n), gr: Double = exp2(-0.30 * n), b: Double = exp2(-0.30 * t + 0.15 * n)
        let luma: Double = 0.2627 * r + 0.6780 * gr + 0.0593 * b
        let e: Double = exp2(g.exposure) / luma
        let contrast: Double = pow(1.5, g.contrast / 100)
        let gain = SIMD4<Float>(Float(r * e), Float(gr * e), Float(b * e), Float(contrast))
        let tone = SIMD4<Float>(Float(g.shadows / 100 * 1.5), Float(g.highlights / 100 * 1.5), Float(g.saturation / 100), 1)
        return (gain, tone)
    }

    // Lenient: a missing or unreadable field takes its default; values are clamped by the caller (`PictureAdjust.read`).
    private enum CodingKeys: String, CodingKey { case exposure, contrast, highlights, shadows, saturation, temperature, tint }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let n = PictureGrade.neutral
        exposure = c.v(.exposure, n.exposure); contrast = c.v(.contrast, n.contrast)
        highlights = c.v(.highlights, n.highlights); shadows = c.v(.shadows, n.shadows)
        saturation = c.v(.saturation, n.saturation); temperature = c.v(.temperature, n.temperature); tint = c.v(.tint, n.tint)
    }
}

/// The game's and the camera's grades, as a renderer reads them for one frame.
struct PictureGrades: Equatable {
    var game = PictureGrade(), camera = PictureGrade()
    var isNeutral: Bool { game.isNeutral && camera.isNeutral }
}

/// "Picture" controls in the studio sidebar: one global grade for the game and one for the camera, in `UserDefaults`.
/// Recordings stay raw; the live window, streams, thumbnails, the editor preview and exports apply the current grades.
@Observable
final class PictureAdjust {
    enum Source: String, CaseIterable { case game, camera }
    static func key(_ s: Source) -> String { s == .game ? "pictureGradeGame" : "pictureGradeCamera" }
    static let shared = PictureAdjust(store: .standard, publishes: true)

    /// What renderers read on their own threads, once per frame; written on the main thread when a slider moves.
    /// Behind a lock: the hold is a single load or store, so a render thread never waits on anything slow.
    static var current: PictureGrades {
        get { lock.lock(); defer { lock.unlock() }; return cached }
        set { lock.lock(); cached = newValue; lock.unlock() }
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: PictureGrades = read(.standard)

    @ObservationIgnored private let store: UserDefaults
    @ObservationIgnored private let publishes: Bool
    private(set) var grades: PictureGrades

    /// `publishes`: only the shared instance feeds `current`; tests use their own store and leave renderers alone.
    init(store: UserDefaults, publishes: Bool = false) {
        self.store = store; self.publishes = publishes
        grades = Self.read(store)
    }

    func grade(_ s: Source) -> PictureGrade { s == .game ? grades.game : grades.camera }

    /// Main thread. Clamps, persists and publishes; a neutral grade is stored as such, not removed.
    func set(_ s: Source, _ g: PictureGrade) {
        let v = g.clamped()
        guard v != grade(s) else { return }
        if s == .game { grades.game = v } else { grades.camera = v }
        if let data = try? JSONEncoder().encode(v) { store.set(data, forKey: Self.key(s)) }
        if publishes { Self.current = grades }
    }

    func reset(_ s: Source) { set(s, PictureGrade()) }

    /// Absent or unreadable means neutral; out-of-range values (an older build, `defaults write`) are clamped.
    static func read(_ store: UserDefaults) -> PictureGrades {
        func one(_ s: Source) -> PictureGrade {
            guard let data = store.data(forKey: key(s)), let g = try? JSONDecoder().decode(PictureGrade.self, from: data) else { return PictureGrade() }
            return g.clamped()
        }
        return PictureGrades(game: one(.game), camera: one(.camera))
    }
}
