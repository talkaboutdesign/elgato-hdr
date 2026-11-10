import XCTest
@testable import StudioKit

/// The editor replays a recording's scene switches with the transition that was live: each switch's own style and
/// duration, else the recording's default, and the render plan draws the same picture the live engine drew.
final class EventTransitionTests: XCTestCase {
    static let sources: [SourceKey: SourceInfo] = [.game: SourceInfo(size: CGSize(width: 1920, height: 1080)),
                                                   .camera: SourceInfo(size: CGSize(width: 1280, height: 720))]
    let cut = SceneTransition(style: .cut, durationMs: 380)
    let fade = SceneTransition(style: .fade, durationMs: 520)
    let morph = SceneTransition(style: .morph, durationMs: 900)

    /// Gameplay at 0, then a cut, a fade and a morph of different durations, logged as the live app logs them.
    func recording() -> (Project, [Scene]) {
        var p = Project(name: "Rec", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        let scenes = SceneCollection.defaults().scenes
        p.scenes = scenes; p.durationMs = 10_000; p.state = "recording"
        p.sceneTransition = SceneTransition(style: .fade, durationMs: 250)
        let log = SessionEventLog(startNs: 1_000_000_000)
        let ns = { (ms: Double) in UInt64(1_000_000_000 + ms * 1e6) }
        p.events = [log.event("scene", atNs: ns(0), sceneID: scenes[0].id),
                    log.event("scene", atNs: ns(2000), sceneID: scenes[2].id, transition: cut),
                    log.event("scene", atNs: ns(4000), sceneID: scenes[0].id, transition: fade),
                    log.event("marker", atNs: ns(5000)),
                    log.event("scene", atNs: ns(6000), sceneID: scenes[2].id, transition: morph)]
        p.state = "complete"
        return (p, scenes)
    }

    func testImportUsesEachSwitchsTransition() throws {
        var (p, scenes) = recording()
        p.importEvents()
        XCTAssertTrue(p.eventsImported); XCTAssertTrue(p.eventTransitions)
        XCTAssertEqual(p.timeline.sceneSpans.map(\.startMs), [0, 2000, 4000, 6000])
        XCTAssertEqual(p.timeline.sceneSpans.map(\.sceneID), [scenes[0].id, scenes[2].id, scenes[0].id, scenes[2].id])
        // The first switch has no transition of its own: the recording's default stands in (it draws nothing).
        XCTAssertEqual(p.timeline.sceneSpans.map(\.transition), [p.sceneTransition, cut, fade, morph])
        // An older event without transition fields falls back to the recording default, per field.
        var e = p.events[1]; e.transitionStyle = nil; e.transitionDurationMs = nil
        XCTAssertEqual(p.recordedTransition(e), p.sceneTransition)
        e.transitionStyle = .morph
        XCTAssertEqual(p.recordedTransition(e), SceneTransition(style: .morph, durationMs: 250))
        // Saved and loaded again: nothing changes.
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try dec.decode(Project.self, from: enc.encode(p)), p)
    }

    /// A project the earlier app imported (default transitions, no `eventTransitions` key) upgrades on load while its
    /// spans are untouched, keeping their ids; any edit to the spans leaves them alone.
    func testProjectsImportedWithOldDefaultsUpgradeOnlyWhenUnedited() throws {
        var (p, _) = recording()
        p.eventsImported = true
        p.timeline.sceneSpans = p.spansFromEvents(recordedTransitions: false)
        let ids = p.timeline.sceneSpans.map(\.id)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        func oldFile(_ q: Project) throws -> Data {
            var o = try XCTUnwrap(JSONSerialization.jsonObject(with: enc.encode(q)) as? [String: Any])
            o.removeValue(forKey: "eventTransitions")
            return try JSONSerialization.data(withJSONObject: o)
        }
        let upgraded = try dec.decode(Project.self, from: oldFile(p))
        XCTAssertTrue(upgraded.eventTransitions)
        XCTAssertEqual(upgraded.timeline.sceneSpans.map(\.id), ids)
        XCTAssertEqual(upgraded.timeline.sceneSpans.map(\.transition), [p.sceneTransition, cut, fade, morph])

        // Edited in any way the comparison can see: untouched, and never looked at again.
        let edits: [(String, (inout Project) -> Void)] = [
            ("moved", { $0.timeline.sceneSpans[2].startMs = 4100 }),
            ("restyled", { $0.timeline.sceneSpans[1].transition = SceneTransition(style: .fade, durationMs: 380) }),
            ("removed", { $0.timeline.sceneSpans.remove(at: 3) }),
            ("added", { $0.timeline.sceneSpans.append(SceneSpan(startMs: 8000, sceneID: $0.scenes[1].id)) }),
            ("rescened", { $0.timeline.sceneSpans[3].sceneID = $0.scenes[1].id }),
        ]
        for (name, edit) in edits {
            var q = p; edit(&q)
            let loaded = try dec.decode(Project.self, from: oldFile(q))
            XCTAssertEqual(loaded.timeline.sceneSpans.sorted { $0.startMs < $1.startMs }.map(\.transition),
                           q.timeline.sceneSpans.sorted { $0.startMs < $1.startMs }.map(\.transition), name)
            XCTAssertTrue(loaded.eventTransitions, name)
        }
        // A project imported by this version keeps what the user set, even when it equals the old default.
        var mine = upgraded
        mine.timeline.sceneSpans[2].transition = SceneTransition()
        XCTAssertEqual(try dec.decode(Project.self, from: enc.encode(mine)).timeline.sceneSpans[2].transition, SceneTransition())
    }

    /// The render plan built from the imported spans draws what the live engine drew at every moment of each
    /// transition: same layers, geometry, opacity and background.
    func testRenderPlanMatchesLiveEngineAtEverySwitch() throws {
        var (p, scenes) = recording()
        // An overlay that morphs by id and a text layer whose content changes, so overlays take part too.
        let text = Layer(name: "Title", source: LayerSource(type: "text", text: TextSpec(string: "One")), frame: NRect(x: 0.1, y: 0.1, w: 0.3, h: 0.1))
        var changed = text; changed.source.text?.string = "Two"; changed.frame = NRect(x: 0.5, y: 0.7, w: 0.4, h: 0.12)
        var s = scenes
        s[0].wide.layers.append(text); s[2].wide.layers.append(changed)
        s[0].vertical.layers.append(text); s[2].vertical.layers.append(changed)
        p.scenes = s
        p.importEvents()
        let switches: [(ms: Double, scene: Scene, t: SceneTransition)] = [(2000, s[2], cut), (4000, s[0], fade), (6000, s[2], morph)]

        for canvas in Canvas.allCases {
            let size = canvas.size(.hd)
            let plan = RenderPlan(scenes: p.scenes, timeline: p.timeline, map: TimeMap(segments: [], sourceDurationMs: p.durationMs),
                                  canvas: canvas, canvasSize: size, sources: Self.sources, mirrorCamera: false)
            // The live engine, switched at the same host times (source time 0 = 1 s of host time).
            var states = [(0.0, LiveSceneState(scene: s[0]))]
            for sw in switches {
                states.append((sw.ms, states.last!.1.switching(to: sw.scene, atNs: Self.ns(sw.ms), transition: sw.t, sources: Self.sources)))
            }
            let overlaySizes = Self.overlaySizes(p.scenes, canvas: canvas)
            for sw in switches {
                for f in [0.0, 0.1, 0.25, 0.5, 0.75, 0.99, 1.0, 1.2] {
                    let ms = sw.ms + f * sw.t.durationMs
                    let live = states.last { $0.0 <= ms }!.1
                    let liveOverlays = live.overlayLayers(canvas: canvas, atNs: Self.ns(ms))
                    var sources = Self.sources
                    for l in liveOverlays { sources[.layer(l.id)] = overlaySizes[l.source.text?.string ?? ""] }
                    let want = live.frame(canvas: canvas, size: size, sources: sources, atNs: Self.ns(ms))
                    var withOverlays = plan
                    let planOverlays = plan.overlayLayers(atTimelineMs: ms)
                    XCTAssertEqual(Set(planOverlays.map(\.id)), Set(liveOverlays.map(\.id)), "\(canvas) \(sw.t.style) at \(f)")
                    for l in planOverlays { withOverlays.sources[.layer(l.id)] = overlaySizes[l.source.text?.string ?? ""] }
                    let got = withOverlays.layers(atTimelineMs: ms)
                    Self.assertSame(got, want.layers, "\(canvas) \(sw.t.style) at \(f)")
                    let bg: SIMD4<Float> = plan.background(atTimelineMs: ms) - want.background
                    let worst: Float = max(max(abs(bg.x), abs(bg.y)), max(abs(bg.z), abs(bg.w)))
                    XCTAssertLessThan(worst, 1e-5, "\(canvas) \(sw.t.style) background at \(f)")
                }
            }
        }
    }

    static func ns(_ ms: Double) -> UInt64 { UInt64((1000 + ms) * 1e6) }
    static func overlaySizes(_ scenes: [Scene], canvas: Canvas) -> [String: SourceInfo] {
        var out: [String: SourceInfo] = [:]
        for l in scenes.flatMap({ $0.composition(canvas).layers }) where l.source.type == "text" {
            out[l.source.text?.string ?? ""] = SourceInfo(size: l.frame.rect(in: canvas.size(.hd)).size)
        }
        return out
    }
    static func assertSame(_ a: [ResolvedLayer], _ b: [ResolvedLayer], _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.map(\.key), b.map(\.key), what, file: file, line: line)
        for (x, y) in zip(a, b) {
            for (u, v) in [(x.dst, y.dst), (x.src, y.src)] {
                XCTAssertEqual(u.minX, v.minX, accuracy: 1e-6, what, file: file, line: line); XCTAssertEqual(u.minY, v.minY, accuracy: 1e-6, what, file: file, line: line)
                XCTAssertEqual(u.width, v.width, accuracy: 1e-6, what, file: file, line: line); XCTAssertEqual(u.height, v.height, accuracy: 1e-6, what, file: file, line: line)
            }
            XCTAssertEqual(x.opacity, y.opacity, accuracy: 1e-6, what, file: file, line: line)
            XCTAssertEqual(x.radius, y.radius, accuracy: 1e-6, what, file: file, line: line)
            XCTAssertEqual(x.mirror, y.mirror, what, file: file, line: line)
        }
    }
}
