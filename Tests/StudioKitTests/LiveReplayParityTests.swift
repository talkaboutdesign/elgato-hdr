import XCTest
@testable import StudioKit

/// The editor replays what live showed in the two cases the plain span replay could not: a switch made while another
/// transition was still running (live starts from the frozen in-between picture), and a live punch-in (live springs in
/// from the press and starts back at the release).
final class LiveReplayParityTests: XCTestCase {
    typealias T = EventTransitionTests
    let scenes = SceneCollection.defaults().scenes          // Gameplay, Game Only, Camera Focus, Just Camera
    static func ns(_ ms: Double) -> UInt64 { UInt64((1000 + ms) * 1e6) }

    /// Scenes with a title that morphs by id and changes its text, so frozen overlays take part too.
    func scenesWithTitle() -> [Scene] {
        var s = scenes
        let title = Layer(name: "Title", source: LayerSource(type: "text", text: TextSpec(string: "One")), frame: NRect(x: 0.1, y: 0.1, w: 0.3, h: 0.1))
        var two = title; two.source.text?.string = "Two"; two.frame = NRect(x: 0.5, y: 0.7, w: 0.4, h: 0.12)
        s[0].wide.layers.append(title); s[0].vertical.layers.append(title)
        s[2].wide.layers.append(two); s[2].vertical.layers.append(two)
        return s
    }

    /// The live engine switched at `switches` (scene, transition, ms), with the sources the app freezes a picture with
    /// (`switchSources`: frames plus the shown overlays' sizes).
    func liveStates(_ first: Scene, _ switches: [(Double, Scene, SceneTransition)], canvasSizes: (Canvas) -> [String: SourceInfo]) -> [(Double, LiveSceneState)] {
        var states = [(0.0, LiveSceneState(scene: first))]
        for (ms, scene, t) in switches {
            let live = states.last!.1
            var sources = T.sources
            for c in Canvas.allCases {
                // As the app merges them: one map, the first canvas's size wins.
                let sizes = canvasSizes(c)
                for l in live.overlayLayers(canvas: c, atNs: Self.ns(ms)) where sources[.layer(l.id)] == nil { sources[.layer(l.id)] = sizes[l.source.text?.string ?? ""] }
            }
            states.append((ms, live.switching(to: scene, atNs: Self.ns(ms), transition: t, sources: sources)))
        }
        return states
    }

    /// Three switches 150 ms apart, each while the one before is still running (morph 900, fade 600, morph 380), then
    /// one more after they settle. At every 10 ms, on both canvases, the plan gives the live engine's layers, overlays
    /// and background.
    func testRapidSwitchesReplayFromTheFrozenPicture() throws {
        let s = scenesWithTitle()
        let switches: [(Double, Scene, SceneTransition)] = [
            (2000, s[2], SceneTransition(style: .morph, durationMs: 900)),
            (2150, s[0], SceneTransition(style: .fade, durationMs: 600)),
            (2300, s[3], SceneTransition(style: .morph, durationMs: 380)),
            (4000, s[2], SceneTransition(style: .morph, durationMs: 900))]
        var timeline = Timeline(sceneSpans: [SceneSpan(startMs: 0, sceneID: s[0].id)])
        for (ms, scene, t) in switches { timeline.sceneSpans.append(SceneSpan(startMs: ms, sceneID: scene.id, transition: t)) }
        let states = liveStates(s[0], switches) { T.overlaySizes(s, canvas: $0) }
        var checked = 0, worstLayer: CGFloat = 0
        for canvas in Canvas.allCases {
            let size = canvas.size(.hd), sizes = T.overlaySizes(s, canvas: canvas)
            let plan = RenderPlan(scenes: s, timeline: timeline, map: TimeMap(segments: [], sourceDurationMs: 10_000),
                                  canvas: canvas, canvasSize: size, sources: T.sources, mirrorCamera: false)
            for ms in stride(from: 1900.0, through: 5200, by: 10) {
                let live = states.last { $0.0 <= ms }!.1
                let liveOverlays = live.overlayLayers(canvas: canvas, atNs: Self.ns(ms))
                var sources = T.sources
                for l in liveOverlays { sources[.layer(l.id)] = sizes[l.source.text?.string ?? ""] }
                let want = live.frame(canvas: canvas, size: size, sources: sources, atNs: Self.ns(ms))
                // As the compositor does: the plan's overlays' sizes are merged into its sources.
                let planOverlays = plan.overlayLayers(atTimelineMs: ms)
                XCTAssertEqual(planOverlays.map(\.id), liveOverlays.map(\.id), "\(canvas) overlays at \(ms)")
                var withOverlays = plan
                for l in planOverlays { withOverlays.sources[.layer(l.id)] = sizes[l.source.text?.string ?? ""] }
                let got = withOverlays.layers(atTimelineMs: ms)
                T.assertSame(got, want.layers, "\(canvas) at \(ms)")
                for (a, b) in zip(got, want.layers) { worstLayer = max(worstLayer, abs(a.dst.minX - b.dst.minX), abs(a.dst.width - b.dst.width), CGFloat(abs(a.opacity - b.opacity))) }
                let bg: SIMD4<Float> = withOverlays.background(atTimelineMs: ms) - want.background
                XCTAssertLessThan(max(max(abs(bg.x), abs(bg.y)), max(abs(bg.z), abs(bg.w))), 1e-5, "\(canvas) background at \(ms)")
                checked += 1
            }
        }
        print("Rapid switches, plan vs live engine: \(checked) frames on both canvases, worst layer difference \(worstLayer)")
        // The second and third switches really started from a frozen picture.
        XCTAssertEqual(states[2].1.depth, 1); XCTAssertEqual(states[3].1.depth, 1); XCTAssertEqual(states[4].1.depth, 0)
    }

    /// A transition never runs across a cut: a switch that follows a cut inside the previous transition starts from
    /// the settled previous scene, not from a frozen picture.
    func testNoFrozenPictureAcrossACut() throws {
        let timeline = Timeline(segments: [Segment(startMs: 0, endMs: 2100), Segment(startMs: 2200, endMs: 10_000)],
                                sceneSpans: [SceneSpan(startMs: 0, sceneID: scenes[0].id),
                                             SceneSpan(startMs: 2000, sceneID: scenes[2].id, transition: SceneTransition(style: .morph, durationMs: 900)),
                                             SceneSpan(startMs: 2300, sceneID: scenes[3].id, transition: SceneTransition(style: .fade, durationMs: 600))])
        let plan = RenderPlan(scenes: scenes, timeline: timeline, map: TimeMap(segments: timeline.segments, sourceDurationMs: 10_000),
                              canvas: .wide, canvasSize: Canvas.wide.size(.hd), sources: T.sources, mirrorCamera: false)
        let (state, _) = try XCTUnwrap(plan.liveState(atSourceMs: 2400))
        XCTAssertEqual(state.depth, 0)
        XCTAssertEqual(state.from?.id, scenes[2].id)
    }

    // MARK: Punch-in

    /// A recording with one punch-in from 3.0 s to 4.5 s, half-way through a morph that started at 2.8 s.
    func punchRecording() -> Project {
        var p = Project(name: "Punch", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        p.scenes = scenes; p.durationMs = 10_000; p.state = "recording"
        let log = SessionEventLog(startNs: 1_000_000_000)
        p.events = [log.event("scene", atNs: Self.ns(0), sceneID: scenes[0].id),
                    log.event("scene", atNs: Self.ns(2800), sceneID: scenes[2].id, transition: SceneTransition(style: .morph, durationMs: 900)),
                    log.event("zoomIn", atNs: Self.ns(3000), zoom: 1.6, focus: CGPoint(x: 0.5, y: 0.5)),
                    log.event("zoomOut", atNs: Self.ns(4500))]
        p.state = "complete"
        return p
    }

    /// The imported block is live-style and replays the live spring: in from the press, back from the release (not
    /// before the block ends), on both canvases, through a morph.
    func testPunchInReplaysWithTheLiveSpring() throws {
        var p = punchRecording()
        p.importEvents()
        XCTAssertTrue(p.liveZooms)
        XCTAssertEqual(p.timeline.zooms.count, 1)
        let z = p.timeline.zooms[0]
        XCTAssertTrue(z.live); XCTAssertEqual(z.startMs, 3000); XCTAssertEqual(z.endMs, 4500); XCTAssertEqual(z.scale, 1.6)

        var live = LiveSceneState(scene: scenes[0]).switching(to: scenes[2], atNs: Self.ns(2800), transition: SceneTransition(style: .morph, durationMs: 900), sources: T.sources)
        var punch = PunchIn(); punch.amount = 1.6; punch.durationMs = 380
        var worst = 0.0, checked = 0
        for canvas in Canvas.allCases {
            let size = canvas.size(.hd)
            let plan = RenderPlan(scenes: p.scenes, timeline: p.timeline, map: TimeMap(segments: [], sourceDurationMs: p.durationMs),
                                  canvas: canvas, canvasSize: size, sources: T.sources, mirrorCamera: false)
            for ms in stride(from: 2900.0, through: 5200, by: 10) {
                var state = live, pi = punch
                if ms >= 3000 { pi.set(engaged: true, atNs: Self.ns(3000)) }
                if ms >= 4500 { pi.set(engaged: false, atNs: Self.ns(4500)) }
                state.punchIn = pi
                let want = state.layers(canvas: canvas, size: size, sources: T.sources, atNs: Self.ns(ms))
                let got = plan.layers(atTimelineMs: ms)
                T.assertSame(got, want, "\(canvas) at \(ms)")
                if let g = got.first(where: { $0.key == .game }), let w = want.first(where: { $0.key == .game }) { worst = max(worst, Double(abs(g.src.width - w.src.width))) }
                checked += 1
            }
            // Still fully zoomed just before the release, part-way back 100 ms after it, back after one spring.
            var unzoomed = plan; unzoomed.timeline.zooms = []
            let game = { (p: RenderPlan, ms: Double) in p.layers(atTimelineMs: ms).first { $0.key == .game }!.src.width }
            XCTAssertEqual(game(plan, 4490) * 1.6, game(unzoomed, 4490), accuracy: game(unzoomed, 4490) * 0.002, "\(canvas): the zoom holds until the release")
            XCTAssertGreaterThan(game(plan, 4600), game(plan, 4490) * 1.05)
            XCTAssertLessThan(game(plan, 4600), game(unzoomed, 4600) * 0.95)
            XCTAssertEqual(game(plan, 4500 + 380), game(unzoomed, 4500 + 380), accuracy: 1e-9, "\(canvas): back after one spring")
        }
        live.punchIn = nil
        print("Punch-in, plan vs live engine: \(checked) frames on both canvases, worst game crop difference \(worst)")
    }

    /// The inspector's "Use Editor Timing" turns the block into an editor block, undoably.
    func testConvertToEditorTiming() throws {
        let m = makeEditorModel()
        let id = UUID()
        m.update("Setup") { $0.timeline.zooms = [ZoomBlock(id: id, startMs: 1000, endMs: 3000, scale: 1.6, live: true)] }
        m.useEditorTiming(id)
        XCTAssertEqual(m.zoomBlock(id)?.live, false)
        XCTAssertEqual(m.zoomBlock(id)?.easeMs, ZoomBlock.liveSpringMs)
        XCTAssertEqual(m.undoTitle, "Undo Use Editor Timing")
        m.undo()
        XCTAssertEqual(m.zoomBlock(id)?.live, true)
    }

    /// Projects imported before blocks had a style: unedited blocks become live-style once; an edited block, or a
    /// block converted to editor timing afterwards, stays as it is.
    func testOlderImportsUpgradeOnlyWhenUnedited() throws {
        var p = punchRecording()
        p.importEvents()
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        func asOlderApp(_ p: Project) throws -> Data {
            var o = p
            for i in o.timeline.zooms.indices { o.timeline.zooms[i].live = false }
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: enc.encode(o)) as? [String: Any])
            json.removeValue(forKey: "liveZooms")
            var t = json["timeline"] as! [String: Any]
            t["zooms"] = (t["zooms"] as! [[String: Any]]).map { var z = $0; z.removeValue(forKey: "live"); return z }
            json["timeline"] = t
            return try JSONSerialization.data(withJSONObject: json)
        }
        let upgraded = try dec.decode(Project.self, from: asOlderApp(p))
        XCTAssertTrue(upgraded.liveZooms); XCTAssertEqual(upgraded.timeline.zooms.map(\.live), [true])
        XCTAssertEqual(upgraded.timeline.zooms[0].id, p.timeline.zooms[0].id)
        var edited = p; edited.timeline.zooms[0].scale = 2
        XCTAssertEqual(try dec.decode(Project.self, from: asOlderApp(edited)).timeline.zooms.map(\.live), [false])
        var converted = upgraded; converted.timeline.zooms[0].live = false
        XCTAssertEqual(try dec.decode(Project.self, from: enc.encode(converted)).timeline.zooms.map(\.live), [false], "runs once")
    }
}
