// Recording projects: each recording is a folder of independent layers (game, camera, mic) plus project.json, which
// holds every non-destructive edit (layout per canvas, trim, volumes, sync). Exports render the layers through the
// shared Metal compositor.
import AppKit
import AVFoundation

// MARK: - Model

// project.json is decoded leniently: a missing key falls back to the default, so projects written by older (or newer)
// versions keep opening as fields are added.
extension KeyedDecodingContainer {
    func v<T: Decodable>(_ key: Key, _ fallback: T) -> T { ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback }
}

enum CameraAspect: String, Codable, CaseIterable {
    case wide = "16:9", classic = "4:3", square = "1:1", portrait = "3:4", tall = "9:16"
    var value: Double { switch self { case .wide: 16.0 / 9; case .classic: 4.0 / 3; case .square: 1; case .portrait: 3.0 / 4; case .tall: 9.0 / 16 } }
}
enum LayoutKind: String, Codable, CaseIterable {
    case pip, stacked, screenOnly, cameraOnly
    var label: String { switch self { case .pip: "Camera overlay"; case .stacked: "Split"; case .screenOnly: "Game only"; case .cameraOnly: "Camera only" } }
}
enum Canvas: String, Codable, CaseIterable, Identifiable {
    case wide, vertical
    var id: String { rawValue }
    var label: String { self == .wide ? "16:9" : "9:16" }
    var title: String { self == .wide ? "Widescreen 16:9" : "Vertical 9:16" }
    var aspect: Double { self == .wide ? 16.0 / 9 : 9.0 / 16 }
    func size(_ res: ExportResolution) -> CGSize {
        let (l, s) = res == .uhd ? (3840.0, 2160.0) : (1920.0, 1080.0)
        return self == .wide ? CGSize(width: l, height: s) : CGSize(width: s, height: l)
    }
}
enum ExportResolution: String, Codable, CaseIterable { case hd, uhd }
enum ExportRange: String, Codable, CaseIterable { case hdr, sdr }
enum ExportFPS: Int, Codable, CaseIterable { case source = 0, sixty = 60, thirty = 30 }

/// The facecam window. Position is the window centre normalized to the canvas and size is relative to the canvas's
/// shorter side, so one placement reads the same in 16:9 and 9:16. Roundness is the corner radius as a fraction of
/// the window's shorter side (0.5 on a square window = circle).
struct CameraPlacement: Codable, Equatable {
    var x = 0.85, y = 0.76
    var size = 0.34
    var aspect = CameraAspect.square
    var roundness = 0.16
    var border = false
    var shadow = true

    var isCircle: Bool { aspect == .square && roundness >= 0.5 }

    /// Window rect in canvas pixels, clamped inside the canvas.
    func rect(in canvas: CGSize) -> CGRect {
        let short = min(canvas.width, canvas.height) * size
        let a = aspect.value
        let w = min(canvas.width, a >= 1 ? short * a : short), h = min(canvas.height, a >= 1 ? short : short / a)
        let cx = min(max(x * canvas.width, w / 2), canvas.width - w / 2)
        let cy = min(max(y * canvas.height, h / 2), canvas.height - h / 2)
        return CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
    }
    init(x: Double = 0.85, y: Double = 0.76, size: Double = 0.34, aspect: CameraAspect = .square, roundness: Double = 0.16) {
        self.x = x; self.y = y; self.size = size; self.aspect = aspect; self.roundness = roundness
    }
    enum CodingKeys: String, CodingKey { case x, y, size, aspect, roundness, border, shadow }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self), z = CameraPlacement()
        x = c.v(.x, z.x); y = c.v(.y, z.y); size = c.v(.size, z.size); aspect = c.v(.aspect, z.aspect)
        roundness = c.v(.roundness, z.roundness); border = c.v(.border, z.border); shadow = c.v(.shadow, z.shadow)
    }

    func radius(for r: CGRect) -> CGFloat { min(0.5, max(0, roundness)) * min(r.width, r.height) }

    /// The eight snap anchors (corners and edge midpoints) inset by a margin, like streaming-overlay presets.
    static func anchors(for size: CGSize, canvas: CGSize) -> [CGPoint] {
        let m = min(canvas.width, canvas.height) * 0.04
        let xs = [m + size.width / 2, canvas.width / 2, canvas.width - m - size.width / 2]
        let ys = [m + size.height / 2, canvas.height / 2, canvas.height - m - size.height / 2]
        return ys.flatMap { y in xs.map { CGPoint(x: $0, y: y) } }.filter { !($0.x == canvas.width / 2 && $0.y == canvas.height / 2) }
    }

    /// Moves the window centre to `p` (canvas pixels), pulling it onto a nearby anchor.
    mutating func move(to p: CGPoint, canvas: CGSize, snap: Bool = true) {
        let r = rect(in: canvas)
        var c = p
        if snap, let a = CameraPlacement.anchors(for: r.size, canvas: canvas).min(by: { hypot($0.x - p.x, $0.y - p.y) < hypot($1.x - p.x, $1.y - p.y) }),
           hypot(a.x - p.x, a.y - p.y) < min(canvas.width, canvas.height) * 0.05 { c = a }
        x = Double(c.x / canvas.width); y = Double(c.y / canvas.height)
    }
}

/// How one canvas (16:9 or 9:16) is laid out.
struct CanvasLayout: Codable, Equatable {
    var kind: LayoutKind
    var camera = CameraPlacement()
    var zoom = 1.0          // >1 crops further into the game
    var panX = 0.5, panY = 0.5   // centre of the game crop, normalized to the source
    var split = 0.36        // stacked: share of the canvas given to the camera (top), the game fills the rest
    var fit = false         // letterbox the game instead of cropping it to fill

    init(kind: LayoutKind, camera: CameraPlacement = CameraPlacement()) { self.kind = kind; self.camera = camera }
    enum CodingKeys: String, CodingKey { case kind, camera, zoom, panX, panY, split, fit }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self), z = CanvasLayout(kind: .pip)
        kind = c.v(.kind, .pip); camera = c.v(.camera, z.camera); zoom = c.v(.zoom, z.zoom)
        panX = c.v(.panX, z.panX); panY = c.v(.panY, z.panY); split = c.v(.split, z.split); fit = c.v(.fit, z.fit)
    }

    static let wideDefault = CanvasLayout(kind: .pip)
    static let verticalDefault = CanvasLayout(kind: .stacked, camera: CameraPlacement(x: 0.5, y: 0.17, size: 0.5, aspect: .square, roundness: 0.5))
}

struct LayerInfo: Codable, Equatable {
    var file: String
    var offsetMs = 0.0      // sync nudge: positive delays the layer
    var volume = 1.0
    init(file: String) { self.file = file }
    enum CodingKeys: String, CodingKey { case file, offsetMs, volume }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        file = try c.decode(String.self, forKey: .file); offsetMs = c.v(.offsetMs, 0); volume = c.v(.volume, 1)
    }
}

struct Project: Codable, Equatable {
    var version = 2
    var name: String
    var createdAt: Date
    var state = "complete"          // "recording" while capture is in progress (crash recovery)
    var durationMs = 0.0
    var width = 0, height = 0, fps = 60.0
    var colorMode: String = ColorMode.pq.rawValue
    var game = LayerInfo(file: "game.mov")
    var camera: LayerInfo?
    var mic: LayerInfo?
    var cameraMirror = false
    var trimStartMs = 0.0, trimEndMs = 0.0   // 0 end = full length
    var wide = CanvasLayout.wideDefault
    var vertical = CanvasLayout.verticalDefault
    var scenes: [Scene] = []
    var events: [SessionEvent] = []
    var timeline = Timeline()
    var lastExport: [String: String] = [:]    // canvas raw value -> file name

    init(name: String, createdAt: Date) { self.name = name; self.createdAt = createdAt }
    enum CodingKeys: String, CodingKey {
        case version, name, createdAt, state, durationMs, width, height, fps, colorMode, game, camera, mic, cameraMirror
        case trimStartMs, trimEndMs, wide, vertical, lastExport, scenes, events, timeline
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        createdAt = c.v(.createdAt, Date())
        let z = Project(name: name, createdAt: createdAt)
        version = c.v(.version, 1); state = c.v(.state, z.state); durationMs = c.v(.durationMs, 0)
        width = c.v(.width, 0); height = c.v(.height, 0); fps = c.v(.fps, z.fps); colorMode = c.v(.colorMode, z.colorMode)
        game = c.v(.game, z.game); camera = c.v(.camera, nil); mic = c.v(.mic, nil); cameraMirror = c.v(.cameraMirror, false)
        trimStartMs = c.v(.trimStartMs, 0); trimEndMs = c.v(.trimEndMs, 0)
        wide = c.v(.wide, z.wide); vertical = c.v(.vertical, z.vertical); lastExport = c.v(.lastExport, [:])
        scenes = c.v(.scenes, []); events = c.v(.events, []); timeline = c.v(.timeline, Timeline())
        if version < 2 { migrateTimeline() }; version = 2
    }

    mutating func migrateTimeline() {
        if scenes.isEmpty { scenes = [defaultScene] }
        if timeline.segments.isEmpty && (trimStartMs > 0 || trimEndMs > 0) {
            timeline.segments = [Segment(startMs: trimmedRange.0, endMs: trimmedRange.1)]
        }
        let sorted = events.sorted { $0.tMs < $1.tMs }
        if timeline.sceneSpans.isEmpty {
            timeline.sceneSpans = sorted.compactMap { e in
                guard e.type == "scene", let id = e.sceneID else { return nil }
                return SceneSpan(startMs: e.tMs, sceneID: id)
            }
            if timeline.sceneSpans.first?.startMs != 0, let scene = scenes.first {
                timeline.sceneSpans.insert(SceneSpan(startMs: 0, sceneID: scene.id), at: 0)
            }
        }
        if timeline.zooms.isEmpty {
            var start: SessionEvent?
            for e in sorted {
                if e.type == "zoomIn" { if start == nil { start = e } }
                if e.type == "zoomOut", let a = start {
                    if e.tMs > a.tMs { timeline.zooms.append(ZoomBlock(startMs: a.tMs, endMs: e.tMs, scale: a.zoom ?? 1.8, focusX: a.focusX ?? 0.5, focusY: a.focusY ?? 0.5)) }
                    start = nil
                }
            }
            if let a = start, durationMs > a.tMs { timeline.zooms.append(ZoomBlock(startMs: a.tMs, endMs: durationMs, scale: a.zoom ?? 1.8, focusX: a.focusX ?? 0.5, focusY: a.focusY ?? 0.5)) }
        }
        if timeline.markers.isEmpty { timeline.markers = sorted.filter { $0.type == "marker" }.map { Marker(tMs: $0.tMs) } }
    }

    var defaultScene: Scene {
        var w = Composition.from(layout: wide, canvas: Canvas.wide.size(.hd), hasCamera: true, mirror: cameraMirror)
        var v = Composition.from(layout: vertical, canvas: Canvas.vertical.size(.hd), hasCamera: true, mirror: cameraMirror)
        w.legacyLayout = wide; v.legacyLayout = vertical
        return Scene(name: "Default", wide: w, vertical: v)
    }
    var editSegments: [Segment] {
        if !timeline.segments.isEmpty { return timeline.segments }
        return trimStartMs > 0 || trimEndMs > 0 ? [Segment(startMs: trimmedRange.0, endMs: trimmedRange.1)] : []
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(2, forKey: .version)
        try c.encode(name, forKey: .name)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(state, forKey: .state)
        try c.encode(durationMs, forKey: .durationMs)
        try c.encode(width, forKey: .width)
        try c.encode(height, forKey: .height)
        try c.encode(fps, forKey: .fps)
        try c.encode(colorMode, forKey: .colorMode)
        try c.encode(game, forKey: .game)
        try c.encode(camera, forKey: .camera)
        try c.encode(mic, forKey: .mic)
        try c.encode(cameraMirror, forKey: .cameraMirror)
        try c.encode(wide, forKey: .wide)
        try c.encode(vertical, forKey: .vertical)
        try c.encode(lastExport, forKey: .lastExport)
        try c.encode(scenes, forKey: .scenes)
        try c.encode(events, forKey: .events)
        try c.encode(timeline, forKey: .timeline)
        let bounds = timeline.segments.sorted { $0.startMs < $1.startMs }
        try c.encode(bounds.first?.startMs ?? trimStartMs, forKey: .trimStartMs)
        try c.encode(bounds.last?.endMs ?? trimEndMs, forKey: .trimEndMs)
    }

    var color: ColorMode { ColorMode(rawValue: colorMode) ?? .pq }
    func layout(_ c: Canvas) -> CanvasLayout { c == .wide ? wide : vertical }
    mutating func setLayout(_ c: Canvas, _ l: CanvasLayout) { if c == .wide { wide = l } else { vertical = l } }
    var trimmedRange: (Double, Double) { (trimStartMs, trimEndMs > trimStartMs ? trimEndMs : durationMs) }
}

