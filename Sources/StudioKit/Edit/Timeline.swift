import Foundation

struct Segment: Codable, Equatable { var startMs: Double; var endMs: Double }
extension Segment {
    enum CodingKeys: String, CodingKey { case startMs, endMs }
    init(from d: Decoder) throws { let c = try d.container(keyedBy: CodingKeys.self); self.init(startMs: c.v(.startMs, 0), endMs: c.v(.endMs, 0)) }
}
struct SceneTransition: Codable, Equatable {
    var style: Style = .morph
    var durationMs = 380.0
    enum Style: String, Codable { case cut, fade, morph }
}
extension SceneTransition {
    enum CodingKeys: String, CodingKey { case style, durationMs }
    init(from d: Decoder) throws { let c = try d.container(keyedBy: CodingKeys.self); self.init(style: c.v(.style, .morph), durationMs: c.v(.durationMs, 380)) }
}
struct SceneSpan: Codable, Equatable {
    var id = UUID(); var startMs: Double; var sceneID: UUID; var transition = SceneTransition()
}
extension SceneSpan {
    enum CodingKeys: String, CodingKey { case id, startMs, sceneID, transition }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        self.init(id: c.v(.id, UUID()), startMs: c.v(.startMs, 0), sceneID: c.v(.sceneID, UUID()), transition: c.v(.transition, SceneTransition()))
    }
}
struct ZoomBlock: Codable, Equatable {
    var id = UUID(); var startMs, endMs: Double
    var scale = 1.8; var focusX = 0.5, focusY = 0.5; var easeMs = 450.0
    func weight(at s: Double) -> Double {
        guard s > startMs, s < endMs else { return 0 }
        guard easeMs > 0 else { return 1 }
        let x = min(1, min(s - startMs, endMs - s) / easeMs)
        return x < 0.5 ? 4*x*x*x : 1 - pow(-2*x + 2, 3)/2
    }
}
extension ZoomBlock {
    enum CodingKeys: String, CodingKey { case id, startMs, endMs, scale, focusX, focusY, easeMs }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        self.init(id: c.v(.id, UUID()), startMs: c.v(.startMs, 0), endMs: c.v(.endMs, 0), scale: c.v(.scale, 1.8),
                  focusX: c.v(.focusX, 0.5), focusY: c.v(.focusY, 0.5), easeMs: c.v(.easeMs, 450))
    }
}
struct Marker: Codable, Equatable { var id = UUID(); var tMs: Double; var label = "" }
extension Marker {
    enum CodingKeys: String, CodingKey { case id, tMs, label }
    init(from d: Decoder) throws { let c = try d.container(keyedBy: CodingKeys.self); self.init(id: c.v(.id, UUID()), tMs: c.v(.tMs, 0), label: c.v(.label, "")) }
}
struct SessionEvent: Codable, Equatable {
    var tMs: Double; var type: String
    var sceneID: UUID?; var zoom: Double?; var focusX: Double?; var focusY: Double?
}
extension SessionEvent {
    enum CodingKeys: String, CodingKey { case tMs, type, sceneID, zoom, focusX, focusY }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        self.init(tMs: c.v(.tMs, 0), type: c.v(.type, ""), sceneID: c.v(.sceneID, nil), zoom: c.v(.zoom, nil), focusX: c.v(.focusX, nil), focusY: c.v(.focusY, nil))
    }
}
struct Timeline: Codable, Equatable {
    var segments: [Segment] = []; var sceneSpans: [SceneSpan] = []; var zooms: [ZoomBlock] = []; var markers: [Marker] = []
}
extension Timeline {
    enum CodingKeys: String, CodingKey { case segments, sceneSpans, zooms, markers }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        self.init(segments: c.v(.segments, []), sceneSpans: c.v(.sceneSpans, []), zooms: c.v(.zooms, []), markers: c.v(.markers, []))
    }
}

/// Half-open ranges; a boundary belongs to the next kept segment. The final endpoint maps to the final source end.
struct TimeMap {
    private(set) var segments: [Segment]
    let sourceDurationMs: Double
    let frameMs: Double
    init(segments: [Segment], sourceDurationMs: Double, frameMs: Double = 1000/60) {
        self.sourceDurationMs = sourceDurationMs.isFinite ? max(0, sourceDurationMs) : 0
        self.frameMs = frameMs > 0 && frameMs.isFinite ? frameMs : 1000/60
        self.segments = segments.isEmpty ? [Segment(startMs: 0, endMs: self.sourceDurationMs)] : segments
        sanitize(mergeTouching: false, dropShort: false)
    }
    var durationMs: Double { segments.reduce(0) { $0 + $1.endMs - $1.startMs } }
    // [] means all in project JSON, so an explicit empty range preserves an all-deleted edit.
    var storedSegments: [Segment] { segments.isEmpty ? [Segment(startMs: 0, endMs: 0)] : segments }
    func source(fromTimeline t: Double) -> Double {
        var left = t.isFinite ? max(0, t) : 0
        for s in segments { let length = s.endMs - s.startMs; if left < length { return s.startMs + left }; left -= length }
        return segments.last?.endMs ?? 0
    }
    func timeline(fromSource s: Double) -> Double? {
        var t = 0.0
        for r in segments { if s >= r.startMs && s < r.endMs { return t + s - r.startMs }; t += r.endMs - r.startMs }
        return s == segments.last?.endMs ? t : nil
    }
    func cutPoints() -> [Double] {
        var t = 0.0, result: [Double] = []
        for (i, s) in segments.enumerated() {
            if i > 0 && s.startMs > segments[i-1].endMs { result.append(t) }
            t += s.endMs - s.startMs
        }
        return result
    }
    func crossedCut(from start: Double, through end: Double) -> Bool {
        segments.enumerated().contains { i, s in
            s.startMs >= start && s.startMs <= end && (i == 0 ? s.startMs > 0 : s.startMs > segments[i-1].endMs)
        }
    }
    mutating func split(atSourceMs s: Double) {
        guard let i = segments.firstIndex(where: { s - $0.startMs >= frameMs && $0.endMs - s >= frameMs }) else { return }
        let r = segments[i]; segments.replaceSubrange(i...i, with: [Segment(startMs: r.startMs, endMs: s), Segment(startMs: s, endMs: r.endMs)])
    }
    mutating func remove(sourceRange r: Segment) {
        guard r.startMs.isFinite, r.endMs.isFinite, r.endMs > r.startMs else { return }
        segments = segments.flatMap { s -> [Segment] in
            if r.endMs <= s.startMs || r.startMs >= s.endMs { return [s] }
            return [Segment(startMs: s.startMs, endMs: min(s.endMs, r.startMs)), Segment(startMs: max(s.startMs, r.endMs), endMs: s.endMs)]
        }
        normalize()
    }
    mutating func restore(sourceRange r: Segment) { segments.append(r); normalize() }
    mutating func normalize() { sanitize(mergeTouching: true, dropShort: true) }
    private mutating func sanitize(mergeTouching: Bool, dropShort: Bool) {
        var result: [Segment] = []
        let valid = segments.filter { $0.startMs.isFinite && $0.endMs.isFinite }.map {
            Segment(startMs: max(0, $0.startMs), endMs: min(sourceDurationMs, $0.endMs))
        }.filter { $0.endMs > $0.startMs }.sorted { $0.startMs < $1.startMs }
        for s in valid {
            if let last = result.last, s.startMs < last.endMs || (mergeTouching && s.startMs == last.endMs) {
                result[result.count-1].endMs = max(last.endMs, s.endMs)
            } else { result.append(s) }
        }
        segments = dropShort ? result.filter { $0.endMs - $0.startMs >= frameMs - 0.000001 } : result
    }
}
