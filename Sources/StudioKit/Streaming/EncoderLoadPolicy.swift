import Foundation

/// Reduction is sticky within a load epoch. Only an actual load change permits restoration,
/// so a retry that saturates within 30 seconds cannot start a periodic restore/reduce loop.
enum EncoderOverloadPolicy: String, Codable, CaseIterable {
    case verticalFirst, horizontalFirst, never
    var title: String {
        switch self {
        case .verticalFirst: "Reduce vertical stream first (recommended)"
        case .horizontalFirst: "Reduce horizontal stream first"
        case .never: "Don't reduce (may stutter)"
        }
    }
}

struct EncoderLoadPolicy {
    var preference: EncoderOverloadPolicy = .verticalFirst
    private(set) var reduced: Set<Canvas> = []
    private var streaks: [Canvas: Int] = [:]
    init(preference: EncoderOverloadPolicy = .verticalFirst) { self.preference = preference }
    mutating func loadChanged(initial: Canvas? = nil) {
        streaks = [:]; reduced = []
        if preference != .never, let initial { reduced.insert(initial) }
    }
    mutating func sample(rejections: [Canvas: Int]) -> Canvas? {
        guard preference != .never else { return nil }
        for (canvas, count) in rejections { streaks[canvas] = count >= 2 ? (streaks[canvas] ?? 0) + 1 : 0 }
        guard rejections.keys.contains(where: { (streaks[$0] ?? 0) >= 3 }) else { return nil }
        let order: [Canvas] = preference == .horizontalFirst ? [.wide, .vertical] : [.vertical, .wide]
        guard let next = order.first(where: { rejections[$0] != nil && !reduced.contains($0) }) else { return nil }
        reduced.insert(next); streaks = [:]
        return next
    }
    static func initialLane(recording: Bool, sourcePixelsPerSecond: Double, lanes: Int, resolution: Int, fps: Int,
                            preference: EncoderOverloadPolicy) -> Canvas? {
        guard recording, lanes == 2, resolution == 1080, fps == 60,
              sourcePixelsPerSecond > 1920 * 1080 * 60, preference != .never else { return nil }
        return preference == .horizontalFirst ? .wide : .vertical
    }
}
