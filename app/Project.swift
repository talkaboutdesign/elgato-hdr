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
    var version = 1
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
    var lastExport: [String: String] = [:]    // canvas raw value -> file name

    init(name: String, createdAt: Date) { self.name = name; self.createdAt = createdAt }
    enum CodingKeys: String, CodingKey {
        case version, name, createdAt, state, durationMs, width, height, fps, colorMode, game, camera, mic, cameraMirror
        case trimStartMs, trimEndMs, wide, vertical, lastExport
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        createdAt = c.v(.createdAt, Date())
        let z = Project(name: name, createdAt: createdAt)
        version = c.v(.version, z.version); state = c.v(.state, z.state); durationMs = c.v(.durationMs, 0)
        width = c.v(.width, 0); height = c.v(.height, 0); fps = c.v(.fps, z.fps); colorMode = c.v(.colorMode, z.colorMode)
        game = c.v(.game, z.game); camera = c.v(.camera, nil); mic = c.v(.mic, nil); cameraMirror = c.v(.cameraMirror, false)
        trimStartMs = c.v(.trimStartMs, 0); trimEndMs = c.v(.trimEndMs, 0)
        wide = c.v(.wide, z.wide); vertical = c.v(.vertical, z.vertical); lastExport = c.v(.lastExport, [:])
    }

    var color: ColorMode { ColorMode(rawValue: colorMode) ?? .pq }
    func layout(_ c: Canvas) -> CanvasLayout { c == .wide ? wide : vertical }
    mutating func setLayout(_ c: Canvas, _ l: CanvasLayout) { if c == .wide { wide = l } else { vertical = l } }
    var trimmedRange: (Double, Double) { (trimStartMs, trimEndMs > trimStartMs ? trimEndMs : durationMs) }
}

/// A project folder on disk.
final class ProjectDoc: Identifiable, Hashable {
    var dir: URL
    var project: Project
    var id: URL { dir }
    init(dir: URL, project: Project) { self.dir = dir; self.project = project }
    static func == (a: ProjectDoc, b: ProjectDoc) -> Bool { a.dir == b.dir }
    func hash(into h: inout Hasher) { h.combine(dir) }

    func url(_ file: String) -> URL { dir.appendingPathComponent(file) }
    var thumbnailURL: URL { dir.appendingPathComponent("thumbnail.jpg") }
    var exportsDir: URL { dir.appendingPathComponent("Exports") }
    var hasCamera: Bool { project.camera.map { FileManager.default.fileExists(atPath: url($0.file).path) } ?? false }
    var hasMic: Bool { project.mic.map { FileManager.default.fileExists(atPath: url($0.file).path) } ?? false }

    static func load(_ dir: URL) -> ProjectDoc? {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent("project.json")) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        guard let p = try? dec.decode(Project.self, from: d) else { return nil }
        return ProjectDoc(dir: dir, project: p)
    }

    func save() {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(project) { try? d.write(to: dir.appendingPathComponent("project.json"), options: .atomic) }
    }

    /// Fills in duration and size from the game file and writes a thumbnail; used after recording and for recovery.
    func finalize(completion: @escaping () -> Void) {
        Task {
            let asset = AVURLAsset(url: url(project.game.file))
            if let d = try? await asset.load(.duration), d.seconds.isFinite { project.durationMs = d.seconds * 1000 }
            if let t = try? await asset.loadTracks(withMediaType: .video).first {
                if let s = try? await t.load(.naturalSize) { project.width = Int(s.width); project.height = Int(s.height) }
                if let f = try? await t.load(.nominalFrameRate), f > 0 { project.fps = Double(f) }
            }
            project.state = "complete"
            save()
            await writeThumbnail()
            await MainActor.run { completion() }
        }
    }

    /// Card image for the library: a frame of the 16:9 composite, so it shows the facecam as laid out.
    func writeThumbnail() async {
        let at = CMTime(seconds: min(3, max(0, project.durationMs / 2000)), preferredTimescale: 600)
        var image: CGImage?
        if let built = try? await CompositionBuilder.build(self, canvas: .wide, resolution: .hd, range: .sdr, trimmed: false) {
            let gen = AVAssetImageGenerator(asset: built.asset)
            gen.videoComposition = built.video
            gen.maximumSize = CGSize(width: 640, height: 360)
            image = try? await gen.image(at: at).image
        }
        if image == nil {
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url(project.game.file)))
            gen.maximumSize = CGSize(width: 640, height: 360)
            image = try? await gen.image(at: at).image
        }
        guard let img = image else { return }
        let rep = NSBitmapImageRep(cgImage: img)
        try? rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])?.write(to: thumbnailURL)
    }
}

// MARK: - Layout resolution

enum LayoutMath {
    /// Crops `src` (normalized) so it fills `dst` with the given aspect, zoom and pan.
    static func fillCrop(sourceSize: CGSize, dst: CGSize, zoom: Double, panX: Double, panY: Double) -> CGRect {
        guard sourceSize.width > 0, sourceSize.height > 0, dst.width > 0, dst.height > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let sa = sourceSize.width / sourceSize.height, da = dst.width / dst.height
        var w = 1.0, h = 1.0
        if sa > da { w = da / sa } else { h = sa / da }
        let z = max(1, zoom); w /= z; h /= z
        let cx = min(max(panX, w / 2), 1 - w / 2), cy = min(max(panY, h / 2), 1 - h / 2)
        return CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
    }

    static func fitRect(_ src: CGSize, in r: CGRect) -> CGRect {
        guard src.width > 0, src.height > 0 else { return r }
        let s = min(r.width / src.width, r.height / src.height)
        let w = (src.width * s).rounded(), h = (src.height * s).rounded()
        return CGRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h)
    }

    /// Resolves a layout into shader parameters for a canvas of `canvas` pixels.
    static func params(layout: CanvasLayout, canvas: CGSize, screen: CGSize, camera: CGSize?, mirror: Bool,
                       screenTransfer: Int32, outTransfer: Int32) -> CompParams {
        var p = CompParams()
        p.canvas = SIMD4(Float(canvas.width), Float(canvas.height), 0, 0)
        p.bg = SIMD4(0.06, 0.06, 0.07, 1)
        p.fmt = SIMD4(screenTransfer, outTransfer, 10, 8)
        p.fmt2 = SIMD4(2, screenTransfer == 2 ? 1 : 0, 1, 0)
        let full = CGRect(origin: .zero, size: canvas)
        var screenDst = full, camDst = CGRect.zero, radius: CGFloat = 0, border: CGFloat = 0, shadow: CGFloat = 0
        var showScreen = true, showCam = camera != nil
        switch layout.kind {
        case .pip:
            camDst = layout.camera.rect(in: canvas)
            radius = layout.camera.radius(for: camDst)
            if layout.fit { screenDst = fitRect(screen, in: full) }
            border = layout.camera.border ? max(2, camDst.width * 0.018) : 0
            shadow = layout.camera.shadow ? max(6, camDst.width * 0.08) : 0
        case .stacked:
            if showCam {
                let ch = (canvas.height * layout.split).rounded()
                camDst = CGRect(x: 0, y: 0, width: canvas.width, height: ch)
                screenDst = CGRect(x: 0, y: ch, width: canvas.width, height: canvas.height - ch)
            }
            if layout.fit { screenDst = fitRect(screen, in: screenDst) }
        case .screenOnly: showCam = false; if layout.fit { screenDst = fitRect(screen, in: full) }
        case .cameraOnly: showScreen = false; camDst = full
        }
        p.screenDst = SIMD4(screenDst)
        p.screenSrc = SIMD4(layout.fit ? fillCrop(sourceSize: screen, dst: screen, zoom: layout.zoom, panX: layout.panX, panY: layout.panY)
                                       : fillCrop(sourceSize: screen, dst: screenDst.size, zoom: layout.zoom, panX: layout.panX, panY: layout.panY))
        if let cs = camera, showCam {
            p.camDst = SIMD4(camDst)
            p.camSrc = SIMD4(fillCrop(sourceSize: cs, dst: camDst.size, zoom: 1, panX: 0.5, panY: 0.5))
        }
        p.shape = SIMD4(Float(radius), Float(border), Float(shadow), 0)
        p.flags = SIMD4(showScreen ? 1 : 0, showCam ? 1 : 0, mirror ? 1 : 0, 0)
        return p
    }
}

// MARK: - Composition (editor preview and export share it)

struct BuiltComposition {
    let asset: AVMutableComposition
    var video: AVMutableVideoComposition
    let audioMix: AVAudioMix?
    let duration: CMTime
    let screenSize: CGSize
    let cameraSize: CGSize?
    let frameDuration: CMTime
    let outTransfer: Int32
    let screenTrack: CMPersistentTrackID
    let cameraTrack: CMPersistentTrackID   // kCMPersistentTrackID_Invalid without a camera layer
}

enum CompositionBuilder {

    static func build(_ doc: ProjectDoc, canvas: Canvas, resolution: ExportResolution, range: ExportRange, fps: ExportFPS = .source, trimmed: Bool = true) async throws -> BuiltComposition {
        let p = doc.project
        let comp = AVMutableComposition()
        let game = AVURLAsset(url: doc.url(p.game.file))
        guard let gv = try await game.loadTracks(withMediaType: .video).first else { throw err("game layer has no video") }
        let gameDur = try await game.load(.duration)
        let screenSize = try await gv.load(.naturalSize)
        let frameRate = try await gv.load(.nominalFrameRate)
        // Video tracks first so audio can't take their IDs; the IDs actually assigned are what the compositor uses.
        let sv = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
        let camTrack = p.camera != nil && doc.hasCamera ? comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) : nil
        try sv.insertTimeRange(CMTimeRange(start: .zero, duration: gameDur), of: gv, at: .zero)
        var mixParams: [AVMutableAudioMixInputParameters] = []
        if let ga = try await game.loadTracks(withMediaType: .audio).first, let t = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try t.insertTimeRange(CMTimeRange(start: .zero, duration: gameDur), of: ga, at: .zero)
            let m = AVMutableAudioMixInputParameters(track: t); m.setVolume(Float(p.game.volume), at: .zero); mixParams.append(m)
        }
        var cameraSize: CGSize?
        if let cam = p.camera, doc.hasCamera {
            let a = AVURLAsset(url: doc.url(cam.file))
            if let cv = try await a.loadTracks(withMediaType: .video).first, let t = camTrack {
                try insert(cv, duration: try await a.load(.duration), into: t, offsetMs: cam.offsetMs, limit: gameDur)
                if !t.segments.isEmpty { cameraSize = try await cv.load(.naturalSize) }
            }
        }
        if let mic = p.mic, doc.hasMic {
            let a = AVURLAsset(url: doc.url(mic.file))
            if let mt = try await a.loadTracks(withMediaType: .audio).first, let t = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                try insert(mt, duration: try await a.load(.duration), into: t, offsetMs: mic.offsetMs, limit: gameDur)
                let m = AVMutableAudioMixInputParameters(track: t); m.setVolume(Float(mic.volume), at: .zero); mixParams.append(m)
            }
        }
        // Trim: drop everything outside [start, end) on every layer at once.
        var cameraTrackID = kCMPersistentTrackID_Invalid
        if let t = camTrack { if cameraSize == nil || t.segments.isEmpty { comp.removeTrack(t); cameraSize = nil } else { cameraTrackID = t.trackID } }
        var duration = gameDur
        if trimmed {
            let (s, e) = p.trimmedRange
            let end = CMTime(seconds: e / 1000, preferredTimescale: 600)
            if e > 0, end < gameDur { comp.removeTimeRange(CMTimeRange(start: end, end: gameDur)) }
            if s > 0 { comp.removeTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: s / 1000, preferredTimescale: 600))) }
            duration = comp.duration
        }

        let sourceFps = max(1, (frameRate > 0 ? Double(frameRate) : p.fps).rounded())
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps == .source ? sourceFps : min(sourceFps, Double(fps.rawValue))))
        let gameTransfer = p.color.transfer
        let outTransfer: Int32 = range == .sdr || gameTransfer == 2 ? 2 : gameTransfer
        let mix = AVMutableAudioMix(); mix.inputParameters = mixParams
        var built = BuiltComposition(asset: comp, video: AVMutableVideoComposition(), audioMix: mixParams.isEmpty ? nil : mix, duration: duration,
                                     screenSize: screenSize, cameraSize: cameraSize,
                                     frameDuration: frameDuration, outTransfer: outTransfer, screenTrack: sv.trackID, cameraTrack: cameraTrackID)
        built.video = videoComposition(p, canvas: canvas, size: canvas.size(resolution), built: built)
        return built
    }

    /// The render description alone: cheap to rebuild whenever the layout changes.
    static func videoComposition(_ p: Project, canvas: Canvas, size: CGSize, built: BuiltComposition) -> AVMutableVideoComposition {
        let out = built.outTransfer
        let params = LayoutMath.params(layout: p.layout(canvas), canvas: size, screen: built.screenSize, camera: built.cameraSize,
                                       mirror: p.cameraMirror, screenTransfer: p.color.transfer, outTransfer: out)
        let vc = AVMutableVideoComposition()
        vc.customVideoCompositorClass = out == 2 ? SDRLayerCompositor.self : HDRLayerCompositor.self
        vc.renderSize = size
        vc.frameDuration = built.frameDuration
        // No colour properties on purpose: setting them makes AVFoundation convert every source into that space before
        // the compositor sees it. The compositor converts each layer itself and tags its output buffers.
        vc.instructions = [CompositionInstruction(timeRange: CMTimeRange(start: .zero, duration: built.duration), screenTrack: built.screenTrack,
                                                  cameraTrack: built.cameraTrack, params: params, hdrOutput: out != 2)]
        return vc
    }

    /// Inserts a layer shifted by its sync offset, clipped to the game's length.
    private static func insert(_ src: AVAssetTrack, duration dur: CMTime, into t: AVMutableCompositionTrack, offsetMs: Double, limit: CMTime) throws {
        let off = CMTime(seconds: offsetMs / 1000, preferredTimescale: 48000)
        var srcStart = CMTime.zero, at = off
        if off < .zero { srcStart = CMTimeAbsoluteValue(off); at = .zero }
        let len = CMTimeMinimum(dur - srcStart, limit - at)
        guard len > .zero else { return }
        try t.insertTimeRange(CMTimeRange(start: srcStart, duration: len), of: src, at: at)
    }

    static func err(_ s: String) -> NSError { NSError(domain: "Project", code: 1, userInfo: [NSLocalizedDescriptionKey: s]) }
}

// MARK: - Export

struct ExportJob: Hashable {
    var canvas: Canvas
    var resolution: ExportResolution
    var range: ExportRange
    var fps: ExportFPS
}

/// Renders a project to a single MP4 through AVAssetReader (composited) -> AVAssetWriter.
final class Exporter {
    let doc: ProjectDoc
    let job: ExportJob
    let output: URL
    private var reader: AVAssetReader?
    private var writer: AVAssetWriter?
    private(set) var cancelled = false

    init(doc: ProjectDoc, job: ExportJob) {
        self.doc = doc; self.job = job
        let name = doc.project.name.replacingOccurrences(of: "/", with: "-")
        let res = job.resolution == .uhd ? "4K" : "1080p"
        output = doc.exportsDir.appendingPathComponent("\(name) — \(job.canvas == .wide ? "16x9" : "9x16") \(res) \(job.range == .hdr ? "HDR" : "SDR").mp4")
        // Exports are file names only: the project folder can be renamed or moved freely.
    }

    func cancel() { cancelled = true; reader?.cancelReading(); writer?.cancelWriting() }

    func run(progress: @escaping (Double) -> Void) async throws -> URL {
        let built = try await CompositionBuilder.build(doc, canvas: job.canvas, resolution: job.resolution, range: job.range, fps: job.fps)
        #if DEBUG
        if ProcessInfo.processInfo.environment["EHDR_VALIDATE"] != nil {
            final class V: NSObject, AVVideoCompositionValidationHandling {
                func videoComposition(_ vc: AVVideoComposition, shouldContinueValidatingAfterFindingInvalidValueForKey key: String) -> Bool { log("invalid key \(key)"); return true }
                func videoComposition(_ vc: AVVideoComposition, shouldContinueValidatingAfterFindingEmptyTimeRange r: CMTimeRange) -> Bool { log("empty range \(r.start.seconds)+\(r.duration.seconds)"); return true }
                func videoComposition(_ vc: AVVideoComposition, shouldContinueValidatingAfterFindingInvalidTimeRangeIn i: any AVVideoCompositionInstructionProtocol) -> Bool { log("invalid instr range \(i.timeRange.start.seconds)+\(i.timeRange.duration.seconds)"); return true }
                func videoComposition(_ vc: AVVideoComposition, shouldContinueValidatingAfterFindingInvalidTrackIDIn i: any AVVideoCompositionInstructionProtocol, layerInstruction: AVVideoCompositionLayerInstruction, asset: AVAsset) -> Bool { log("invalid track id"); return true }
            }
            let ok = try await built.video.isValid(for: built.asset, timeRange: CMTimeRange(start: .zero, duration: built.asset.duration), validationDelegate: V())
            log("composition valid: \(ok) comp=\(built.asset.duration.seconds) instr=\(built.duration.seconds) tracks=\(built.asset.tracks.map { "\($0.trackID):\($0.mediaType.rawValue):\($0.timeRange.duration.seconds)" })")
        }
        #endif
        try FileManager.default.createDirectory(at: doc.exportsDir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: output)
        let hdr = built.outTransfer != 2
        let reader = try AVAssetReader(asset: built.asset)
        let videoTracks = built.asset.tracks(withMediaType: .video)
        let vOut = AVAssetReaderVideoCompositionOutput(videoTracks: videoTracks, videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: hdr ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_32BGRA])
        vOut.videoComposition = built.video
        vOut.alwaysCopiesSampleData = false
        reader.add(vOut)
        let audioTracks = built.asset.tracks(withMediaType: .audio)
        var aOut: AVAssetReaderAudioMixOutput?
        if !audioTracks.isEmpty {
            let o = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
            o.audioMix = built.audioMix
            if reader.canAdd(o) { reader.add(o); aOut = o }
        }

        let size = built.video.renderSize
        let fps = 1 / built.video.frameDuration.seconds
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        var compression: [String: Any] = [AVVideoExpectedSourceFrameRateKey: fps, AVVideoMaxKeyFrameIntervalKey: Int(fps * 2)]
        let videoSettings: [String: Any]
        if hdr {
            compression[AVVideoAverageBitRateKey] = Int(Double(size.width * size.height) * fps * 0.12)
            compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel as String
            let pq = built.outTransfer == 0
            if pq {
                let (m, c) = Recorder.hdr10Metadata()
                compression[kVTCompressionPropertyKey_MasteringDisplayColorVolume as String] = m
                compression[kVTCompressionPropertyKey_ContentLightLevelInfo as String] = c
            }
            videoSettings = [AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: size.width, AVVideoHeightKey: size.height,
                             AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                                                         AVVideoTransferFunctionKey: pq ? AVVideoTransferFunction_SMPTE_ST_2084_PQ : AVVideoTransferFunction_ITU_R_2100_HLG,
                                                         AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020],
                             AVVideoCompressionPropertiesKey: compression]
        } else {
            compression[AVVideoAverageBitRateKey] = Int(Double(size.width * size.height) * fps * 0.14)
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
            videoSettings = [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: size.width, AVVideoHeightKey: size.height,
                             AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                                         AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                                         AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
                             AVVideoCompressionPropertiesKey: compression]
        }
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        writer.add(vIn)
        var aIn: AVAssetWriterInput?
        if aOut != nil {
            let i = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000,
                                                                           AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 256_000])
            writer.add(i); aIn = i
        }
        self.reader = reader; self.writer = writer
        guard reader.startReading() else { throw reader.error ?? CompositionBuilder.err("cannot read layers") }
        guard writer.startWriting() else { throw writer.error ?? CompositionBuilder.err("cannot write export") }
        writer.startSession(atSourceTime: .zero)

        let total = max(0.001, built.duration.seconds)
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await Self.pump(vOut, into: vIn, label: "export-video") { t in progress(min(1, t / total)) } }
            if let aOut = aOut, let aIn = aIn { group.addTask { await Self.pump(aOut, into: aIn, label: "export-audio") { _ in } } }
        }
        if cancelled || reader.status == .failed {
            writer.cancelWriting(); try? FileManager.default.removeItem(at: output)
            throw reader.error ?? CompositionBuilder.err("export cancelled")
        }
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CompositionBuilder.err("export failed") }
        return output
    }

    private static func pump(_ out: AVAssetReaderOutput, into input: AVAssetWriterInput, label: String, progress: @escaping (Double) -> Void) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let q = DispatchQueue(label: label)
            var done = false
            input.requestMediaDataWhenReady(on: q) {
                while input.isReadyForMoreMediaData && !done {
                    if let sb = out.copyNextSampleBuffer() {
                        progress(CMSampleBufferGetPresentationTimeStamp(sb).seconds)
                        if !input.append(sb) { done = true }
                    } else { done = true }
                    if done { input.markAsFinished(); cont.resume() }
                }
            }
        }
    }
}

// MARK: - Library

/// Lists recordings under ~/Movies/Elgato HDR, newest first.
final class Library: ObservableObject {
    static let shared = Library()
    @Published var docs: [ProjectDoc] = []
    var root: URL { AppDelegate.recordingsDir }

    func reload() {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        let found = dirs.compactMap { ProjectDoc.load($0) }.sorted { $0.project.createdAt > $1.project.createdAt }
        for d in found where d.project.state == "recording" && !AppDelegate.isRecording(d.dir) {
            d.finalize { [weak self] in self?.objectWillChange.send() }   // recover a recording interrupted by a crash
        }
        docs = found
    }

    func newProjectDir(date: Date) -> (URL, String) {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let name = "Capture \(f.string(from: date))"
        let dir = root.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (dir, name)
    }

    func rename(_ doc: ProjectDoc, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-")
        guard !clean.isEmpty, clean != doc.project.name else { return }
        if let editor = EditorWindows.shared.model(for: doc.dir) {
            // An open editor autosaves its copy of the project: rename through it and leave the folder alone for now.
            editor.update { $0.name = clean }; editor.saveNow()
            doc.project.name = clean; objectWillChange.send()
            return
        }
        doc.project.name = clean; doc.save()
        // The folder carries the name too, so it reads the same in Finder.
        let dest = doc.dir.deletingLastPathComponent().appendingPathComponent(clean)
        if !FileManager.default.fileExists(atPath: dest.path), (try? FileManager.default.moveItem(at: doc.dir, to: dest)) != nil { doc.dir = dest }
        objectWillChange.send()
    }

    func duplicate(_ doc: ProjectDoc) {
        let fm = FileManager.default
        var dest = root.appendingPathComponent(doc.dir.lastPathComponent + " copy")
        var n = 2
        while fm.fileExists(atPath: dest.path) { dest = root.appendingPathComponent(doc.dir.lastPathComponent + " copy \(n)"); n += 1 }
        do {
            try fm.createDirectory(at: dest, withIntermediateDirectories: true)
            for f in try fm.contentsOfDirectory(atPath: doc.dir.path) where f != "Exports" {
                // Layers are immutable once recorded: clone (APFS copy-on-write) so duplicates are free.
                try fm.copyItem(at: doc.url(f), to: dest.appendingPathComponent(f))
            }
            if let copy = ProjectDoc.load(dest) {
                copy.project.name = doc.project.name + " copy"; copy.project.createdAt = Date(); copy.project.lastExport = [:]; copy.save()
            }
        } catch { log("duplicate failed: \(error)") }
        reload()
    }

    func trash(_ doc: ProjectDoc) {
        NSWorkspace.shared.recycle([doc.dir]) { [weak self] _, _ in DispatchQueue.main.async { self?.reload() } }
    }
}
