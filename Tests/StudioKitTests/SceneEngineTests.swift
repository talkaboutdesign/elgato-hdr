import XCTest
@testable import StudioKit

final class SceneEngineTests: XCTestCase {
    let size = CGSize(width: 1920, height: 1080)
    let sources: [SourceKey: SourceInfo] = [.game: SourceInfo(size: CGSize(width: 2560, height: 1440)), .camera: SourceInfo(size: CGSize(width: 1280, height: 720))]
    lazy var collection = SceneCollection.defaults()
    var gameplay: Scene { collection.scenes[0] }
    var gameOnly: Scene { collection.scenes[1] }
    var focus: Scene { collection.scenes[2] }
    var justCamera: Scene { collection.scenes[3] }
    let ms: UInt64 = 1_000_000
    let t0: UInt64 = 1_000_000_000_000

    func resolve(_ s: Scene, _ canvas: Canvas = .wide) -> [ResolvedLayer] {
        SceneResolver.resolve(s.composition(canvas), canvas: canvas == .wide ? size : CGSize(width: 1080, height: 1920), sources: sources)
    }
    func frame(_ st: LiveSceneState, at t: UInt64, _ canvas: Canvas = .wide) -> [ResolvedLayer] {
        st.layers(canvas: canvas, size: canvas == .wide ? size : CGSize(width: 1080, height: 1920), sources: sources, atNs: t)
    }
    func state(_ a: Scene, _ b: Scene, _ style: SceneTransition.Style, duration: Double = 400) -> LiveSceneState {
        LiveSceneState(scene: a).switching(to: b, atNs: t0, transition: SceneTransition(style: style, durationMs: duration), sources: sources)
    }
    /// Time at which the spring reaches progress `e`.
    func time(for e: Double, duration: Double = 400) -> UInt64 {
        var lo = 0.0, hi = duration
        for _ in 0..<60 { let m = (lo + hi) / 2; if SceneEasing.spring(m, duration: duration) < e { lo = m } else { hi = m } }
        return t0 + UInt64(lo * 1e6)
    }
    func assertRect(_ a: CGRect, _ b: CGRect, _ msg: String = "", accuracy: CGFloat = 0.01, file: StaticString = #filePath, line: UInt = #line) {
        for (x, y) in zip([a.minX, a.minY, a.width, a.height], [b.minX, b.minY, b.width, b.height]) { XCTAssertEqual(x, y, accuracy: accuracy, msg, file: file, line: line) }
    }
    func mid(_ a: CGRect, _ b: CGRect) -> CGRect {
        CGRect(x: (a.minX + b.minX) / 2, y: (a.minY + b.minY) / 2, width: (a.width + b.width) / 2, height: (a.height + b.height) / 2)
    }

    func testEasing() {
        XCTAssertEqual(SceneEasing.spring(0, duration: 380), 0)
        XCTAssertEqual(SceneEasing.spring(380 - 1e-9, duration: 380), 0.99, accuracy: 1e-4)
        XCTAssertEqual(SceneEasing.spring(380, duration: 380), 1)
        var last = 0.0
        for i in 1..<100 { let e = SceneEasing.spring(Double(i) * 3.8, duration: 380); XCTAssertGreaterThan(e, last); XCTAssertLessThan(e, 1); last = e }
        XCTAssertEqual(SceneEasing.hold(0.5), 1); XCTAssertEqual(SceneEasing.hold(1), 0); XCTAssertEqual(SceneEasing.early(0.25), 1)
    }

    func testOutsideATransitionIsTheResolvedScene() {
        let st = LiveSceneState(scene: gameplay)
        XCTAssertEqual(frame(st, at: t0), resolve(gameplay))
        XCTAssertEqual(frame(st, at: t0, .vertical), resolve(gameplay, .vertical))
        XCTAssertFalse(st.isTransitioning(atNs: t0))
    }

    func testCut() {
        let st = state(gameplay, focus, .cut)
        XCTAssertEqual(frame(st, at: t0), resolve(focus))
        XCTAssertEqual(frame(st, at: t0 + 1), resolve(focus))
        XCTAssertFalse(st.isTransitioning(atNs: t0))
    }

    func testFade() throws {
        let st = state(gameplay, justCamera, .fade)
        // A frame captured before the switch still shows the old scene.
        XCTAssertEqual(frame(st, at: t0 - 5 * ms), resolve(gameplay))
        XCTAssertEqual(frame(st, at: t0), resolve(gameplay))
        let half = frame(st, at: time(for: 0.5))
        // Old layers below, new on top at e. The new camera covers the canvas, so the old ones stay opaque under it
        // (a true cross-fade, no dip to the background).
        XCTAssertEqual(half.map(\.key), [.game, .camera, .camera])
        XCTAssertEqual(half[0].opacity, 1, accuracy: 1e-6); XCTAssertEqual(half[1].opacity, 1, accuracy: 1e-6)
        XCTAssertEqual(half[2].opacity, 0.5, accuracy: 1e-3)
        XCTAssertEqual(half[2].dst, resolve(justCamera)[0].dst)
        XCTAssertEqual(frame(st, at: t0 + 400 * ms), resolve(justCamera))
        // Without a covering new layer the old one fades out linearly.
        let toWindow = state(justCamera, Scene(name: "W", wide: Composition(layers: [Layer(source: .game, frame: NRect(x: 0.1, y: 0.1, w: 0.4, h: 0.4))])), .fade)
        let h2 = frame(toWindow, at: time(for: 0.5))
        XCTAssertEqual(h2.map(\.opacity).map { ($0 * 1000).rounded() / 1000 }, [0.5, 0.5])
    }

    /// The signature move: the camera grows from its corner to full screen while the game shrinks into a window.
    func testMorphGameplayToCameraFocus() throws {
        let st = state(gameplay, focus, .morph)
        let a = resolve(gameplay), b = resolve(focus)
        let aGame = a.first { $0.key == .game }!, aCam = a.first { $0.key == .camera }!
        let bGame = b.first { $0.key == .game }!, bCam = b.first { $0.key == .camera }!
        // Progress 0: the old picture exactly (the rising game's upper copy is invisible and dropped).
        let start = frame(st, at: t0)
        XCTAssertEqual(start.map(\.key), [.game, .camera])
        XCTAssertEqual(start, [aGame, aCam].map { var l = $0; l.opacity = 1; return l })
        // Progress 0.5: geometry half-way for both; the game is drawn at its old depth (below the camera) and its
        // copy at the new depth (above) is fading in, late so the camera's growth reads first.
        let half = frame(st, at: time(for: 0.5))
        XCTAssertEqual(half.map(\.key), [.game, .camera, .game])
        assertRect(half[1].dst, mid(aCam.dst, bCam.dst), "camera dst")
        assertRect(half[1].src, mid(aCam.src, bCam.src), "camera src", accuracy: 1e-4)
        XCTAssertEqual(half[1].radius, (aCam.radius + bCam.radius) / 2, accuracy: 0.05)
        XCTAssertEqual(half[1].shadow, (aCam.shadow + bCam.shadow) / 2, accuracy: 0.05)
        assertRect(half[0].dst, mid(aGame.dst, bGame.dst), "game dst")
        assertRect(half[2].dst, half[0].dst, "both game copies at one place")
        XCTAssertEqual(half[0].opacity, 1, accuracy: 1e-6)
        XCTAssertEqual(half[2].opacity, SceneEasing.rise(0.5), accuracy: 1e-3)
        XCTAssertEqual(SceneEasing.rise(0.3), 0); XCTAssertEqual(SceneEasing.rise(0.9), 1)
        // Progress 1: the target scene.
        XCTAssertEqual(frame(st, at: t0 + 400 * ms), b)
        XCTAssertFalse(st.isTransitioning(atNs: t0 + 400 * ms))
        XCTAssertTrue(st.isTransitioning(atNs: t0 + 399 * ms))
    }

    func testMorphUnmatchedLayers() throws {
        // Gameplay -> Game Only: the camera has no partner; it fades out above the game (nothing covers it).
        let out = state(gameplay, gameOnly, .morph)
        let h = frame(out, at: time(for: 0.5))
        XCTAssertEqual(h.map(\.key), [.game, .camera])
        XCTAssertEqual(h[1].opacity, 0.5, accuracy: 1e-3)
        XCTAssertEqual(h[1].dst, resolve(gameplay)[1].dst, "an unmatched layer keeps its place")
        // Game Only -> Gameplay: the camera fades in on top.
        let into = frame(state(gameOnly, gameplay, .morph), at: time(for: 0.5))
        XCTAssertEqual(into.map(\.key), [.game, .camera]); XCTAssertEqual(into[1].opacity, 0.5, accuracy: 1e-3)
        // Just Camera -> Game Only: nothing matches; the full game fades in over the camera, which stays opaque
        // beneath it until the last quarter.
        let swap = state(justCamera, gameOnly, .morph)
        let s = frame(swap, at: time(for: 0.5))
        XCTAssertEqual(s.map(\.key), [.camera, .game])
        XCTAssertEqual(s.map(\.opacity)[0], 1, accuracy: 1e-6); XCTAssertEqual(s.map(\.opacity)[1], 0.5, accuracy: 1e-3)
        XCTAssertEqual(frame(swap, at: time(for: 0.9))[0].opacity, 0.4, accuracy: 1e-3)
        // Just Camera -> Gameplay: the game appears beneath the full-screen camera, so it may show at once as the
        // camera shrinks away.
        let reveal = frame(state(justCamera, gameplay, .morph), at: time(for: 0.5))
        XCTAssertEqual(reveal.map(\.key), [.game, .camera])
        XCTAssertEqual(reveal[0].opacity, 1, accuracy: 1e-6)
        // Overlays match by layer id, not by type.
        let logo = Layer(name: "Logo", source: LayerSource(type: "color", color: [1, 0, 0, 1]), frame: NRect(x: 0, y: 0, w: 0.1, h: 0.1))
        var other = logo; other.id = UUID(); other.frame = NRect(x: 0.5, y: 0.5, w: 0.1, h: 0.1)
        var sa = gameOnly; sa.wide.layers.append(logo)
        var sb = gameOnly; sb.id = UUID(); sb.wide.layers.append(other)
        var moved = logo; moved.frame = NRect(x: 0.8, y: 0, w: 0.1, h: 0.1)
        var sc = gameOnly; sc.id = UUID(); sc.wide.layers.append(moved)
        XCTAssertEqual(frame(state(sa, sb, .morph), at: time(for: 0.5)).count, 3, "different overlays cross-fade")
        let glide = frame(state(sa, sc, .morph), at: time(for: 0.5))
        XCTAssertEqual(glide.count, 2); XCTAssertEqual(glide[1].dst.minX, 0.4 * 1920, accuracy: 1)
    }

    /// A switch mid-way starts from the picture on screen at that instant, never from either scene.
    func testRetargetingMidTransition() throws {
        let st = state(gameplay, focus, .morph)
        let tSwitch = time(for: 0.5)
        let before = frame(st, at: tSwitch)
        let next = st.switching(to: justCamera, atNs: tSwitch, transition: SceneTransition(style: .morph, durationMs: 400), sources: sources)
        XCTAssertEqual(next.depth, 1)
        XCTAssertEqual(frame(next, at: tSwitch), before, "no jump at the switch")
        // Slightly later it is moving from there: close to `before`, not to Camera Focus or Gameplay.
        let soon = frame(next, at: tSwitch + 5 * ms)
        let cam = soon.last { $0.key == .camera }!.dst, was = before.first { $0.key == .camera }!.dst
        XCTAssertLessThan(abs(cam.minX - was.minX), 40)
        XCTAssertEqual(frame(next, at: tSwitch + 400 * ms), resolve(justCamera))
        // Switching back and forth faster than transitions finish stays bounded.
        var s = next
        for i in 0..<20 { s = s.switching(to: [gameplay, focus, justCamera, gameOnly][i % 4], atNs: tSwitch + UInt64(i + 1) * 30 * ms, transition: SceneTransition(), sources: sources) }
        XCTAssertLessThanOrEqual(s.depth, 1)
        let last = tSwitch + 21 * 30 * ms
        XCTAssertFalse(frame(s, at: last).isEmpty)
        XCTAssertEqual(frame(s, at: last + 400 * ms), resolve(gameOnly))
        // After a finished transition a switch starts clean.
        let done = st.switching(to: justCamera, atNs: t0 + 500 * ms, transition: SceneTransition(), sources: sources)
        XCTAssertEqual(done.depth, 0)
        XCTAssertEqual(frame(done, at: t0 + 500 * ms), resolve(focus))
    }

    /// Switches every 50 ms, faster than any transition ends. At each switch instant the picture is exactly the one
    /// on screen just before it (every layer's rect, crop, opacity and stacking), and the next frame has moved by no
    /// more than one frame of the spring allows. The starting picture is one flat snapshot, so depth never grows.
    func testRapidSwitchingNeverJumps() {
        let order = [focus, justCamera, gameOnly, gameplay, focus, gameOnly, justCamera, gameplay, focus, justCamera, gameplay, gameOnly]
        let tr = SceneTransition()
        // The spring's steepest step over one 60 Hz frame, as a fraction of the distance, with some slack.
        let frameNs = 16_666_667 as UInt64, w = SceneEasing.x99 / tr.durationMs
        let maxStep = 1.2 * w / M_E * 16.67   // e'(t) peaks at t = 1/ω with ω/e
        for canvas in Canvas.allCases {
            for size in [Canvas.wide == canvas ? self.size : CGSize(width: 1080, height: 1920), canvas.size(.uhd)] {
                func pic(_ st: LiveSceneState, _ t: UInt64) -> [ResolvedLayer] { st.layers(canvas: canvas, size: size, sources: sources, atNs: t) }
                let span = max(size.width, size.height)
                var s = LiveSceneState(scene: gameplay)
                for (i, sc) in order.enumerated() {
                    let t = t0 + UInt64(i) * 50 * ms, what = "switch \(i + 1), \(canvas.label) at \(Int(size.width))"
                    let before = pic(s, t)
                    s = s.switching(to: sc, atNs: t, transition: tr, sources: sources)
                    XCTAssertLessThanOrEqual(s.depth, 1)
                    let after = pic(s, t)
                    XCTAssertEqual(after.map(\.key), before.map(\.key), "stacking, \(what)")
                    guard after.count == before.count else { continue }
                    for (x, y) in zip(before, after) {
                        assertRect(y.dst, x.dst, "dst, \(what)", accuracy: 0.5)
                        assertRect(y.src, x.src, "src, \(what)", accuracy: 1e-4)
                        XCTAssertEqual(y.opacity, x.opacity, accuracy: 0.01, "opacity, \(what)")
                        XCTAssertEqual(y.radius, x.radius, accuracy: 0.5, "radius, \(what)")
                    }
                    // One frame later every layer that is still there has moved by at most one frame of motion.
                    let next = pic(s, t + frameNs)
                    for l in next {
                        let d = after.filter { $0.key == l.key }.map { abs($0.dst.minX - l.dst.minX) + abs($0.dst.minY - l.dst.minY) }.min() ?? 0
                        XCTAssertLessThanOrEqual(d, maxStep * 2 * span + 1, "\(l.key) moved \(d) px in one frame, \(what)")
                    }
                }
                XCTAssertEqual(pic(s, t0 + UInt64(order.count - 1) * 50 * ms + 400 * ms),
                               SceneResolver.resolve(order.last!.composition(canvas), canvas: size, sources: sources))
            }
        }
    }

    /// Re-engaging the punch-in before the zoom-out has finished keeps the panned focus: the crop does not move at
    /// that instant. Once a release has settled, the next punch-in centres on the scene's crop again.
    func testPunchInReengageKeepsFocus() {
        var p = PunchIn(); p.amount = 1.6; p.durationMs = 400
        p.set(engaged: true, atNs: t0)
        let g = resolve(gameplay)[0].src
        p.moveFocus(to: CGPoint(x: 0.95, y: 0.5), atNs: t0 + 400 * ms, centre: CGPoint(x: g.midX, y: g.midY))
        var st = LiveSceneState(scene: gameplay)
        p.set(engaged: false, atNs: t0 + 900 * ms)
        let tAgain = t0 + 1000 * ms   // zoom-out under way
        st.punchIn = p
        let before = frame(st, at: tAgain)[0].src
        p.set(engaged: true, atNs: tAgain); st.punchIn = p
        let after = frame(st, at: tAgain)[0].src
        assertRect(after, before, "no jump when re-engaging", accuracy: 1e-9)
        XCTAssertLessThan(abs(frame(st, at: tAgain + 17 * ms)[0].src.midX - after.midX), 0.02)
        XCTAssertGreaterThan(frame(st, at: tAgain + 400 * ms)[0].src.maxX, 0.999, "zooms back in on the panned focus")
        // Fully released, then engaged again: centred on the crop.
        p.set(engaged: false, atNs: tAgain + 500 * ms)
        p.set(engaged: true, atNs: tAgain + 1000 * ms)
        XCTAssertNil(p.focus)
        st.punchIn = p
        XCTAssertEqual(frame(st, at: tAgain + 1400 * ms)[0].src.midX, g.midX, accuracy: 1e-9)
    }

    /// The game is drawn with hard edges only while both ends of a morph are: growing from a rounded window to full
    /// screen it stays anti-aliased until it arrives.
    func testMorphHardEdge() {
        XCTAssertTrue(resolve(gameplay)[0].hardEdge); XCTAssertFalse(resolve(focus).first { $0.key == .game }!.hardEdge)
        for (a, b) in [(focus, gameplay), (gameplay, focus)] {
            let half = frame(state(a, b, .morph), at: time(for: 0.5))
            XCTAssertFalse(half.contains { $0.key == .game && $0.hardEdge }, "rounded at one end: never hard-clipped mid-way")
            XCTAssertEqual(frame(state(a, b, .morph), at: t0 + 400 * ms), resolve(b))
        }
        let both = frame(state(gameplay, gameOnly, .morph), at: time(for: 0.5))
        XCTAssertTrue(both.first { $0.key == .game }!.hardEdge, "full screen at both ends stays hard-edged")
    }

    func testPunchIn() throws {
        var st = LiveSceneState(scene: gameplay)
        var p = PunchIn(); p.amount = 1.6; p.durationMs = 400
        p.set(engaged: true, atNs: t0)
        st.punchIn = p
        let base = resolve(gameplay)
        XCTAssertEqual(frame(st, at: t0), base)
        let zoomed = frame(st, at: t0 + 400 * ms)
        let g = base[0].src, z = zoomed[0].src
        XCTAssertEqual(z.width, g.width / 1.6, accuracy: 1e-9); XCTAssertEqual(z.height, g.height / 1.6, accuracy: 1e-9)
        XCTAssertEqual(z.midX, g.midX, accuracy: 1e-9); XCTAssertEqual(z.midY, g.midY, accuracy: 1e-9)
        XCTAssertEqual(zoomed[1], base[1], "only the game layer zooms")
        XCTAssertEqual(zoomed[0].dst, base[0].dst)
        // Moving the focus pans towards it, clamped inside the source.
        p.moveFocus(to: CGPoint(x: 0.95, y: 0.5), atNs: t0 + 400 * ms, centre: CGPoint(x: g.midX, y: g.midY))
        st.punchIn = p
        let panned = frame(st, at: t0 + 800 * ms)[0].src
        XCTAssertEqual(panned.maxX, 1, accuracy: 1e-9)
        // Releasing mid-way springs back from the current scale, without a jump.
        let tRel = t0 + 900 * ms
        let sBefore = p.scale(atNs: tRel)
        p.set(engaged: false, atNs: tRel)
        XCTAssertEqual(p.scale(atNs: tRel), sBefore, accuracy: 1e-12)
        st.punchIn = p
        XCTAssertEqual(frame(st, at: tRel + 400 * ms), base)
        XCTAssertTrue(p.isIdle(atNs: tRel + 400 * ms))
        // It applies in every scene, during transitions too.
        var tr = state(gameplay, focus, .morph); tr.punchIn = PunchIn(amount: 2, engaged: true, startNs: 0, fromScale: 2)
        let mid = frame(tr, at: time(for: 0.5))
        let plain = frame(state(gameplay, focus, .morph), at: time(for: 0.5))
        for (m, q) in zip(mid, plain) where m.key == .game { XCTAssertEqual(m.src.width, q.src.width / 2, accuracy: 1e-9) }
    }

    /// What `drawNow` adds per frame on the reader thread: copying the state and evaluating it, next to what it did
    /// before (building and resolving the fixed layout). Printed for the pull request; the bound only catches an
    /// accidental blow-up.
    func testPerFrameCost() {
        let n = 20_000
        func measure(_ f: () -> Void) -> Double {
            let t = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<n { f() }
            return Double(DispatchTime.now().uptimeNanoseconds - t) / Double(n) / 1000
        }
        let size = CGSize(width: 2560, height: 1440)
        let before = measure { _ = SceneResolver.resolve(Composition.from(layout: CanvasLayout(kind: .pip), canvas: size, hasCamera: true, mirror: false), canvas: size, sources: sources) }
        let steady = LiveSceneState(scene: gameplay)
        let still = measure { _ = steady.frame(canvas: .wide, size: size, sources: sources, atNs: t0) }
        let st = state(gameplay, focus, .morph), mid = time(for: 0.5)
        let morph = measure { _ = st.frame(canvas: .wide, size: size, sources: sources, atNs: mid) }
        var nested = st
        for i in 0..<5 { nested = nested.switching(to: [justCamera, gameOnly, focus][i % 3], atNs: t0 + UInt64(i + 1) * 20 * ms, transition: SceneTransition(), sources: sources) }
        let deep = measure { _ = nested.frame(canvas: .wide, size: size, sources: sources, atNs: t0 + 110 * ms) }
        print(String(format: "per-frame scene cost (µs): before (fixed layout) %.2f, scene %.2f, mid-morph %.2f, after 5 rapid switches %.2f", before, still, morph, deep))
        XCTAssertLessThan(deep, 200)
    }

    /// The 9:16 canvas transitions with the same rules. Gameplay's camera and game sit side by side (stacked), so
    /// the game, which has no partner in Just Camera, goes beneath the camera: the camera grows over it.
    func testVerticalMorph() {
        let st = state(gameplay, justCamera, .morph)
        let a = resolve(gameplay, .vertical), b = resolve(justCamera, .vertical)
        let half = frame(st, at: time(for: 0.5), .vertical)
        XCTAssertEqual(half.map(\.key), [.game, .camera])
        XCTAssertEqual(half[0].opacity, 1, accuracy: 1e-6, "held until the camera covers it")
        assertRect(half[1].dst, mid(a.first { $0.key == .camera }!.dst, b[0].dst))
        // And back: the game appears beneath the shrinking camera at once.
        let back = frame(state(justCamera, gameplay, .morph), at: time(for: 0.5), .vertical)
        XCTAssertEqual(back.map(\.key), [.game, .camera]); XCTAssertEqual(back[0].opacity, 1, accuracy: 1e-6)
    }
}
