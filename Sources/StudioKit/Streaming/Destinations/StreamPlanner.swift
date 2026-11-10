import Foundation
import CoreGraphics

/// Enabled destinations grouped by canvas: each group is one output (one render, one encode) feeding one publisher
/// per destination. Pure, so the grouping is testable without Metal or a network.
enum StreamPlanner {
    struct Group: Equatable {
        var canvas: Canvas
        var size: CGSize
        var fps: Double
        var videoBitrate: Int           // bits per second
        var destinations: [Destination]
    }

    static func groups(destinations: [Destination], settings: StreamSettings) -> [Group] {
        let s = settings.sanitized
        return Canvas.allCases.compactMap { canvas in
            let members = destinations.filter { $0.enabled && $0.canvas == canvas }
            guard !members.isEmpty else { return nil }
            return Group(canvas: canvas, size: s.size(canvas), fps: Double(s.fps), videoBitrate: s.videoKbps * 1000, destinations: members)
        }
    }

    static func output(for group: Group, publishers: [RTMPPublisher]) -> StreamSession.Output {
        .init(canvas: group.canvas, size: group.size, fps: group.fps, videoBitrate: group.videoBitrate, publishers: publishers)
    }

    /// `publisher` returns nil for a destination that cannot start (no key, bad URL); it is left out of its output.
    static func plan(destinations: [Destination], settings: StreamSettings,
                     publisher: (Destination) -> RTMPPublisher?) -> [StreamSession.Output] {
        groups(destinations: destinations, settings: settings).compactMap { g in
            let ps = g.destinations.compactMap(publisher)
            return ps.isEmpty ? nil : output(for: g, publishers: ps)
        }
    }

    static func metadata(_ canvas: Canvas, settings: StreamSettings) -> StreamMetadata {
        let s = settings.sanitized, size = s.size(canvas)
        return StreamMetadata(width: Int(size.width), height: Int(size.height), fps: Double(s.fps), videoKbps: s.videoKbps, audioKbps: s.audioKbps)
    }

    /// Total upload for the UI: "3 destinations · about 18.5 Mbps upload".
    static func uploadSummary(enabled count: Int, settings: StreamSettings) -> String {
        guard count > 0 else { return "No destinations on" }
        let mbps = Double(settings.uploadKbps(destinations: count)) / 1000
        let noun = count == 1 ? "destination" : "destinations"
        return "\(count) \(noun) · about \(String(format: "%.1f", mbps)) Mbps upload"
    }
}
