// The scenes the user switches between live, persisted as scenes.json. This is main-thread state: the renderer never
// sees it, only the `LiveSceneState` built from it.
import CoreGraphics
import Foundation

struct SceneTransition: Codable, Equatable {
    enum Style: String, Codable, CaseIterable, Identifiable {
        case cut, fade, morph
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }
    var style: Style = .morph
    var durationMs = 380.0
    static let durationRange = 150.0...1500.0
}
extension SceneTransition {
    enum CodingKeys: String, CodingKey { case style, durationMs }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self), z = SceneTransition()
        let ms = c.v(.durationMs, z.durationMs)
        self.init(style: c.v(.style, z.style), durationMs: ms.isFinite ? min(max(ms, 0), 10_000) : z.durationMs)
    }
}

struct SceneCollection: Codable, Equatable {
    var scenes: [Scene]
    var activeID: UUID
    var transition = SceneTransition()

    /// Never empty after `normalize()`, which every load and edit path runs.
    var active: Scene { scenes.first { $0.id == activeID } ?? scenes.first ?? Scene(name: "Scene") }
    var activeIndex: Int? { scenes.firstIndex { $0.id == activeID } }
    func index(of id: UUID) -> Int? { scenes.firstIndex { $0.id == id } }
    subscript(id: UUID) -> Scene? { scenes.first { $0.id == id } }

    mutating func normalize() {
        if scenes.isEmpty { self = SceneCollection.defaults() }
        if index(of: activeID) == nil { activeID = scenes[0].id }
    }

    /// A unique name: "Gameplay", then "Gameplay 2", "Gameplay 3"…
    func uniqueName(_ base: String) -> String {
        let names = Set(scenes.map(\.name))
        guard names.contains(base) else { return base }
        var n = 2
        while names.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }
}
extension SceneCollection {
    enum CodingKeys: String, CodingKey { case scenes, activeID, transition }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let scenes: [Scene] = c.v(.scenes, [])
        self.init(scenes: scenes, activeID: c.v(.activeID, scenes.first?.id ?? UUID()), transition: c.v(.transition, SceneTransition()))
        normalize()
    }
}

// MARK: - Defaults and templates

enum SceneTemplate: String, CaseIterable, Identifiable {
    case gameplay, gameOnly, cameraFocus, justCamera, sideBySide, startingSoon, beRightBack, ending
    var id: String { rawValue }
    var name: String {
        switch self {
        case .gameplay: "Gameplay"; case .gameOnly: "Game Only"; case .cameraFocus: "Camera Focus"
        case .justCamera: "Just Camera"; case .sideBySide: "Side by Side"
        case .startingSoon: "Starting Soon"; case .beRightBack: "Be Right Back"; case .ending: "Ending"
        }
    }
    var summary: String {
        switch self {
        case .gameplay: "Game with your camera in a corner"
        case .gameOnly: "Just the game, nothing on top"
        case .cameraFocus: "You, with the game in a window"
        case .justCamera: "Camera only, for intros and breaks"
        case .sideBySide: "Game and camera next to each other"
        case .startingSoon: "Title and the time, before you go live"
        case .beRightBack: "A break screen with the live timer"
        case .ending: "Thanks for watching, with your camera"
        }
    }

    /// `placement`: the user's facecam window, migrated from the single live layout that came before scenes.
    func scene(placement: CameraPlacement = CameraPlacement(), mirror: Bool = false) -> Scene {
        let wide = Canvas.wide.size(.hd), tall = Canvas.vertical.size(.hd)
        func game(_ f: NRect = .full) -> Layer { Layer(name: "Game", source: .game, frame: f) }
        func camera(_ f: NRect = .full) -> Layer { Layer(name: "Camera", source: .camera, frame: f, mirror: mirror) }
        /// A rounded window snapped to an anchor (0…7 in `CameraPlacement.anchors` order) with a soft shadow.
        func window(_ l: Layer, size: Double, aspect: CameraAspect, anchor: Int, canvas: CGSize, roundness: Double = 0.1) -> Layer {
            var p = CameraPlacement(size: size, aspect: aspect)
            let a = CameraPlacement.anchors(for: p.rect(in: canvas).size, canvas: canvas)
            p.move(to: a[anchor], canvas: canvas, snap: false)
            var l = l
            l.frame = NRect(p.rect(in: canvas), in: canvas); l.roundness = roundness; l.shadow = true
            return l
        }
        switch self {
        case .startingSoon, .beRightBack, .ending:
            return screen(mirror: mirror)
        case .gameplay:
            return Scene(name: name, wide: .from(layout: CanvasLayout(kind: .pip, camera: placement), canvas: wide, hasCamera: true, mirror: mirror),
                         vertical: .from(layout: .verticalDefault, canvas: tall, hasCamera: true, mirror: mirror))
        case .gameOnly:
            return Scene(name: name, wide: Composition(layers: [game()]), vertical: Composition(layers: [game()]))
        case .cameraFocus:
            // Vertical: the game spans the width, inset by the snap margin, just above the bottom margin.
            let m = 0.04 * tall.width, w = tall.width - 2 * m, h = (w * 9 / 16).rounded()
            var bottom = game(NRect(CGRect(x: m, y: tall.height - m - h, width: w, height: h), in: tall))
            bottom.roundness = 0.06; bottom.shadow = true
            return Scene(name: name,
                         wide: Composition(layers: [camera(), window(game(), size: 0.34, aspect: .wide, anchor: 7, canvas: wide, roundness: 0.08)]),
                         vertical: Composition(layers: [camera(), bottom]))
        case .justCamera:
            return Scene(name: name, wide: Composition(layers: [camera()]), vertical: Composition(layers: [camera()]))
        case .sideBySide:
            // Wide: a 16:9 game window (as tall as it is wide in normalized units) and a portrait camera beside it,
            // with equal outer margins. Vertical: the game across the top, the camera filling the rest.
            var g = game(NRect(x: 0.035, y: 0.19, w: 0.62, h: 0.62)), c = camera(NRect(x: 0.675, y: 0.19, w: 0.29, h: 0.62))
            g.roundness = 0.04; g.shadow = true; c.roundness = 0.06; c.shadow = true
            let gh = Double(tall.width * 9 / 16 / tall.height)
            return Scene(name: name, wide: Composition(layers: [g, c]),
                         vertical: Composition(layers: [game(NRect(x: 0, y: 0, w: 1, h: gh)), camera(NRect(x: 0, y: gh, w: 1, h: 1 - gh))]))
        }
    }
}

extension SceneCollection {
    /// First launch: the four default scenes, with the user's facecam placement carried over into Gameplay.
    static func defaults(placement: CameraPlacement = CameraPlacement(), mirror: Bool = false) -> SceneCollection {
        let scenes: [SceneTemplate] = [.gameplay, .gameOnly, .cameraFocus, .justCamera]
        let list = scenes.map { $0.scene(placement: placement, mirror: mirror) }
        return SceneCollection(scenes: list, activeID: list[0].id)
    }
}

// MARK: - Storage

/// scenes.json, written 0.5 s after the last change so a drag does not write on every mouse move.
final class SceneStore {
    let url: URL
    private var pending: DispatchWorkItem?
    private var lastWritten: SceneCollection?

    /// The data folder keeps its name if the app's display name changes, so scenes survive a rename.
    static var defaultURL: URL {
        if let f = ProcessInfo.processInfo.environment["EHDR_SCENES_FILE"], !f.isEmpty { return URL(fileURLWithPath: f) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Elgato HDR").appendingPathComponent("scenes.json")
    }

    init(url: URL = SceneStore.defaultURL) { self.url = url }

    func load() -> SceneCollection? {
        guard let d = try? Data(contentsOf: url), let c = try? JSONDecoder().decode(SceneCollection.self, from: d) else { return nil }
        lastWritten = c
        return c
    }

    func scheduleSave(_ c: SceneCollection, delay: TimeInterval = 0.5) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.write(c) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Writes any pending change now (quit, tests).
    func flush(_ c: SceneCollection) { pending?.cancel(); pending = nil; write(c) }

    private func write(_ c: SceneCollection) {
        guard c != lastWritten else { return }
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try enc.encode(c).write(to: url, options: .atomic)
            lastWritten = c
        } catch { log("scenes: saving \(url.path) failed: \(error)") }
    }
}

// MARK: - Bridges to the fixed layouts

extension CameraPlacement {
    /// The placement that reproduces `frame` on `canvas` (centre, short side and the nearest aspect preset).
    init(frame: NRect, canvas: CGSize, roundness: Double, border: Bool, shadow: Bool) {
        let r = frame.rect(in: canvas), short = min(canvas.width, canvas.height)
        let a = r.height > 0 ? r.width / r.height : 1
        let aspect = CameraAspect.allCases.min { abs(log($0.value / a)) < abs(log($1.value / a)) } ?? .square
        self.init(x: Double(r.midX / canvas.width), y: Double(r.midY / canvas.height),
                  size: Double((aspect.value >= 1 ? r.height : r.width) / max(short, 1)), aspect: aspect, roundness: roundness)
        self.border = border; self.shadow = shadow
    }
}

extension CanvasLayout {
    /// The fixed layout closest to a composition. The current editor only reads `wide` and `vertical`, so recordings
    /// write these from the scene active at the start until the editor plays scenes back (plan 30).
    init(approximating c: Composition, canvas: CGSize, fallback: CanvasLayout) {
        let shown = c.layers.filter { $0.visible && $0.opacity > 0 }
        let gi = shown.firstIndex { $0.source.type == "game" }, ci = shown.firstIndex { $0.source.type == "camera" }
        self = fallback
        func takeGame(_ g: Layer) { zoom = g.zoom; panX = g.panX; panY = g.panY; fit = g.fit }
        switch (gi.map { shown[$0] }, ci.map { shown[$0] }) {
        case let (g?, k?):
            takeGame(g)
            let stackedCamera = k.frame.y < 0.001 && k.frame.w > 0.999 && k.frame.h < 1
            if stackedCamera && abs(g.frame.y - k.frame.h) < 0.01 && g.frame.w > 0.999 {
                kind = .stacked; split = k.frame.h
            } else if g.frame == .full || ci! > gi! {
                kind = .pip
                camera = CameraPlacement(frame: k.frame, canvas: canvas, roundness: k.roundness, border: k.border, shadow: k.shadow)
            } else {
                kind = .cameraOnly   // the camera fills the picture and the game is a window on it
            }
        case let (g?, nil): takeGame(g); kind = .screenOnly
        case (nil, _?): kind = .cameraOnly
        case (nil, nil): kind = .screenOnly
        }
    }
}
