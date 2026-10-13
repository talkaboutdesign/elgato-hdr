// Recordings library and project editor (SwiftUI hosted in AppKit windows).
// Library: a grid of recordings with search and quick actions. Editor: live preview of the layered composite in the
// chosen canvas (16:9 or 9:16), direct manipulation of the facecam and game framing, a layer timeline with trim, and
// multi-format export.
import AppKit
import AVFoundation
import SwiftUI

// MARK: - Windows

extension AppDelegate {
    func makeLibraryWindow() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 680),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.title = "Recordings"
        w.isReleasedWhenClosed = false
        let host = NSHostingController(rootView: LibraryView())
        host.sizingOptions = []   // keep the window size we choose instead of shrinking to the SwiftUI minimum
        w.contentViewController = host
        w.setContentSize(NSSize(width: 1040, height: 680))
        w.minSize = NSSize(width: 560, height: 400)
        w.center()
        w.setFrameAutosaveName("RecordingsLibrary")
        return w
    }
}

/// One editor window per project folder.
final class EditorWindows: NSObject, NSWindowDelegate {
    static let shared = EditorWindows()
    private var windows: [URL: (NSWindow, EditorModel)] = [:]

    func open(_ doc: ProjectDoc) {
        if let (w, _) = windows[doc.dir] { w.makeKeyAndOrderFront(nil); return }
        let model = EditorModel(doc: doc)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.title = doc.project.name
        w.isReleasedWhenClosed = false
        let host = NSHostingController(rootView: EditorView(model: model))
        host.sizingOptions = []
        w.contentViewController = host
        w.setContentSize(NSSize(width: 1280, height: 800))
        w.minSize = NSSize(width: 900, height: 600)
        w.delegate = self
        w.center()
        windows[doc.dir] = (w, model)
        w.makeKeyAndOrderFront(nil)
    }

    /// The editor that owns a project's state while it is open, so library actions go through it.
    func model(for dir: URL) -> EditorModel? { windows[dir]?.1 }

    func windowWillClose(_ n: Notification) {
        guard let w = n.object as? NSWindow, let (key, (_, model)) = windows.first(where: { $0.value.0 === w }) else { return }
        model.close()
        windows[key] = nil
    }
}

// MARK: - Library

struct LibraryView: View {
    @ObservedObject var lib = Library.shared
    @State private var search = ""
    @State private var selection: URL?
    @State private var renaming: ProjectDoc?
    @State private var newName = ""

    var filtered: [ProjectDoc] {
        let q = search.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? lib.docs : lib.docs.filter { $0.project.name.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        Group {
            if lib.docs.isEmpty {
                ContentUnavailableView {
                    Label("No recordings yet", systemImage: "rectangle.stack.badge.play")
                } description: {
                    Text("Press ⌘R in the live window to record. The game, your camera and your microphone are saved as separate layers you can lay out and export here.")
                }
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: search)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 240, maximum: 340), spacing: 20, alignment: .top)], alignment: .leading, spacing: 24) {
                        ForEach(filtered) { doc in
                            ProjectCard(doc: doc, selected: selection == doc.dir)
                                .onTapGesture(count: 2) { EditorWindows.shared.open(doc) }
                                .simultaneousGesture(TapGesture().onEnded { selection = doc.dir })
                                .contextMenu { menu(for: doc) }
                        }
                    }
                    .padding(24)
                }
                .background(Color(nsColor: .windowBackgroundColor))
                .onTapGesture { selection = nil }
            }
        }
        .frame(minWidth: 560, minHeight: 400)
        .searchable(text: $search, placement: .toolbar, prompt: "Search recordings")
        .toolbar {
            ToolbarItemGroup {
                Button { lib.reload() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                Button { NSWorkspace.shared.open(lib.root) } label: { Label("Show in Finder", systemImage: "folder") }
            }
        }
        .alert("Rename Recording", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") { if let d = renaming { lib.rename(d, to: newName) }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .onAppear { lib.reload() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { n in
            if (n.object as? NSWindow)?.title == "Recordings" { lib.reload() }
        }
    }

    @ViewBuilder func menu(for doc: ProjectDoc) -> some View {
        Button("Open") { EditorWindows.shared.open(doc) }
        Divider()
        Button("Rename…") { newName = doc.project.name; renaming = doc }
        Button("Duplicate") { lib.duplicate(doc) }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([doc.dir]) }
        if FileManager.default.fileExists(atPath: doc.exportsDir.path) {
            Button("Show Exports") { NSWorkspace.shared.open(doc.exportsDir) }
        }
        Divider()
        Button("Move to Trash", role: .destructive) { lib.trash(doc) }
    }
}

struct ProjectCard: View {
    let doc: ProjectDoc
    let selected: Bool
    @State private var thumb: NSImage?
    @State private var hover = false

    var body: some View {
        let p = doc.project
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                Rectangle().fill(Color.black.opacity(0.85))
                if let t = thumb { Image(nsImage: t).resizable().aspectRatio(contentMode: .fill) }
                else { Image(systemName: "gamecontroller").font(.system(size: 30)).foregroundStyle(.white.opacity(0.3)) }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(alignment: .topLeading) {
                HStack(spacing: 4) {
                    if p.color != .sdr { Badge(text: p.color == .pq ? "HDR" : "HLG") }
                    if p.state == "recording" { Badge(text: "RECOVERING", tint: .orange) }
                    if !p.lastExport.isEmpty { Badge(text: "EXPORTED", tint: .green) }
                }.padding(8)
            }
            .overlay(alignment: .bottomTrailing) { Badge(text: formatTime(p.durationMs / 1000)).padding(8) }
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(hover ? 0.25 : 0.08), lineWidth: selected ? 3 : 1))
            .shadow(color: .black.opacity(hover ? 0.25 : 0.12), radius: hover ? 10 : 4, y: hover ? 4 : 2)

            VStack(alignment: .leading, spacing: 3) {
                Text(p.name).font(.headline).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(p.createdAt.formatted(date: .abbreviated, time: .shortened)).lineLimit(1)
                    if p.height > 0 { Text(verbatim: "· \(p.height)p\(Int(p.fps.rounded()))").lineLimit(1).layoutPriority(-1) }
                    Spacer(minLength: 4)
                    LayerIcons(camera: doc.hasCamera, mic: doc.hasMic)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 2)
        }
        .scaleEffect(hover ? 1.012 : 1)
        .animation(.easeOut(duration: 0.15), value: hover)
        .onHover { hover = $0 }
        .contentShape(Rectangle())
        .task(id: "\(doc.dir.path)/\(p.durationMs)") { thumb = NSImage(contentsOf: doc.thumbnailURL) }
    }
}

struct LayerIcons: View {
    let camera: Bool, mic: Bool
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "gamecontroller.fill").help("Game layer")
            if camera { Image(systemName: "video.fill").help("Camera layer") }
            if mic { Image(systemName: "mic.fill").help("Microphone layer") }
        }
    }
}

struct Badge: View {
    let text: String
    var tint: Color = .black
    var body: some View {
        Text(text).font(.system(size: 10, weight: .semibold).monospacedDigit())
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(tint.opacity(tint == .black ? 0.6 : 0.85), in: Capsule())
            .foregroundStyle(.white)
    }
}

func formatTime(_ s: Double) -> String {
    guard s.isFinite, s >= 0 else { return "0:00" }
    let t = Int(s)
    return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
}
func formatTimePrecise(_ s: Double) -> String {
    guard s.isFinite, s >= 0 else { return "0:00.0" }
    return String(format: "%d:%04.1f", Int(s) / 60, s.truncatingRemainder(dividingBy: 60))
}

// MARK: - Editor model

struct ExportState {
    var progress = 0.0
    var running = false
    var url: URL?
    var error: String?
}

final class EditorModel: ObservableObject {
    let doc: ProjectDoc
    @Published var project: Project
    @Published var canvas: Canvas = .wide { didSet { if canvas != oldValue { rebuild() } } }
    @Published var range: ExportRange { didSet { if range != oldValue { rebuild() } } }
    @Published var time = 0.0
    @Published var duration = 0.0
    @Published var playing = false
    @Published var exportCanvases: Set<Canvas> = [.wide, .vertical]
    @Published var resolution: ExportResolution = .hd
    @Published var fps: ExportFPS = .source
    @Published var exports: [Canvas: ExportState] = [:]
    @Published var loadError: String?
    let player = AVPlayer()
    private var built: BuiltComposition?
    private var timeObserver: Any?
    private var saveWork: DispatchWorkItem?
    private var buildGen = 0
    private var exporters: [Exporter] = []
    private var dirty = false

    var hasCamera: Bool { doc.hasCamera }
    var hasMic: Bool { doc.hasMic }
    var isHDRSource: Bool { project.color != .sdr }

    init(doc: ProjectDoc) {
        self.doc = doc
        project = doc.project
        range = doc.project.color == .sdr ? .sdr : .hdr
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
            guard let self = self else { return }
            self.time = t.seconds
            self.playing = self.player.rate != 0
        }
        rebuild()
    }

    func close() {
        player.pause()
        if let o = timeObserver { player.removeTimeObserver(o); timeObserver = nil }
        saveNow()
        if dirty { Task { await doc.writeThumbnail(); await MainActor.run { Library.shared.objectWillChange.send() } } }
    }

    // Edits

    func update(_ f: (inout Project) -> Void) {
        let old = project
        var p = project; f(&p)
        guard p != old else { return }
        project = p
        doc.project = p
        dirty = true
        scheduleSave()
        if p.game != old.game || p.camera != old.camera || p.mic != old.mic { rebuild() }
        else if p.wide != old.wide || p.vertical != old.vertical || p.cameraMirror != old.cameraMirror { restyle() }
        if p.trimStartMs != old.trimStartMs || p.trimEndMs != old.trimEndMs { applyTrim() }
    }

    var layout: CanvasLayout {
        get { project.layout(canvas) }
        set { let c = canvas; update { $0.setLayout(c, newValue) } }
    }
    func binding<T>(_ kp: WritableKeyPath<CanvasLayout, T>) -> Binding<T> {
        Binding(get: { self.layout[keyPath: kp] }, set: { v in var l = self.layout; l[keyPath: kp] = v; self.layout = l })
    }
    func projectBinding<T>(_ kp: WritableKeyPath<Project, T>) -> Binding<T> {
        Binding(get: { self.project[keyPath: kp] }, set: { v in self.update { $0[keyPath: kp] = v } })
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
    }
    func saveNow() { saveWork?.cancel(); saveWork = nil; doc.project = project; doc.save() }

    // Preview

    /// Rebuilds the composition (layers, offsets, volumes) for the current canvas. The preview is untrimmed so trim
    /// handles can be dragged over the whole recording; playback is limited to the trim range.
    func rebuild() {
        buildGen += 1
        let gen = buildGen, canvas = canvas, range = range
        let keep = player.currentTime()
        Task {
            do {
                let b = try await CompositionBuilder.build(doc, canvas: canvas, resolution: .hd, range: range, trimmed: false)
                await MainActor.run {
                    guard gen == self.buildGen else { return }
                    self.built = b
                    let item = AVPlayerItem(asset: b.asset)
                    item.videoComposition = b.video
                    item.audioMix = b.audioMix
                    self.player.replaceCurrentItem(with: item)
                    self.duration = b.duration.seconds
                    self.applyTrim()
                    self.player.seek(to: keep.isValid ? keep : CMTime(seconds: self.trimStart, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                    self.loadError = nil
                }
            } catch {
                await MainActor.run { self.loadError = error.localizedDescription }
            }
        }
    }

    /// Layout-only change: swap the render instruction; the layers stay loaded.
    private func restyle() {
        guard let b = built, let item = player.currentItem else { return }
        item.videoComposition = CompositionBuilder.videoComposition(project, canvas: canvas, size: canvas.size(.hd), built: b)
        if player.rate == 0 { player.seek(to: player.currentTime(), toleranceBefore: .zero, toleranceAfter: .zero) }
    }

    var trimStart: Double { project.trimStartMs / 1000 }
    var trimEnd: Double { project.trimEndMs > project.trimStartMs ? project.trimEndMs / 1000 : duration }

    private func applyTrim() {
        player.currentItem?.forwardPlaybackEndTime = project.trimEndMs > 0 ? CMTime(seconds: trimEnd, preferredTimescale: 600) : .invalid
    }

    func togglePlay() {
        if player.rate != 0 { player.pause(); playing = false; return }
        if time < trimStart - 0.01 || time >= trimEnd - 0.05 { seek(trimStart) }
        player.play(); playing = true
    }
    func seek(_ s: Double) {
        let t = min(max(0, s), duration)
        time = t
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }
    func setIn() { let t = time; update { $0.trimStartMs = t * 1000; if $0.trimEndMs > 0 && $0.trimEndMs <= $0.trimStartMs { $0.trimEndMs = 0 } } }
    func setOut() { let t = time; update { $0.trimEndMs = t * 1000; if $0.trimStartMs >= $0.trimEndMs { $0.trimStartMs = 0 } } }

    // Export

    var anyExporting: Bool { exports.values.contains { $0.running } }

    func export() {
        saveNow()
        let jobs = Canvas.allCases.filter { exportCanvases.contains($0) }
            .map { ExportJob(canvas: $0, resolution: resolution, range: isHDRSource ? range : .sdr, fps: fps) }
        guard !jobs.isEmpty else { return }
        player.pause()
        for j in jobs { exports[j.canvas] = ExportState(running: true) }
        Task {
            // One at a time: the media engines are shared, and sequential keeps each export at full speed.
            for j in jobs {
                let ex = Exporter(doc: doc, job: j)
                await MainActor.run { self.exporters.append(ex) }
                do {
                    let url = try await ex.run { p in DispatchQueue.main.async { self.exports[j.canvas]?.progress = p } }
                    await MainActor.run {
                        self.exports[j.canvas] = ExportState(progress: 1, running: false, url: url)
                        self.update { $0.lastExport[j.canvas.rawValue] = url.lastPathComponent }
                        self.saveNow()
                    }
                } catch {
                    await MainActor.run { self.exports[j.canvas] = ExportState(running: false, error: ex.cancelled ? "Cancelled" : error.localizedDescription) }
                }
            }
            await MainActor.run { self.exporters.removeAll(); Library.shared.objectWillChange.send() }
        }
    }
    func cancelExports() { exporters.forEach { $0.cancel() } }
}

// MARK: - Editor view

struct EditorView: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                PreviewStage(model: model)
                Divider()
                TimelineView(model: model)
            }
            Divider()
            Inspector(model: model).frame(width: 320)
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Canvas", selection: $model.canvas) {
                    ForEach(Canvas.allCases) { c in Text(c.label).tag(c) }
                }
                .pickerStyle(.segmented)
                .frame(width: 140)
                .help("Each canvas has its own layout; both can be exported at once")
            }
            ToolbarItem {
                Button { NSWorkspace.shared.activateFileViewerSelecting([model.doc.dir]) } label: { Label("Show in Finder", systemImage: "folder") }
            }
        }
    }
}

/// The aspect-fitted canvas preview with direct manipulation on top.
struct PreviewStage: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        ZStack {
            Color(white: 0.09)
            ZStack {
                PlayerLayerView(player: model.player)
                StageInteraction(model: model)
            }
            .aspectRatio(model.canvas.aspect, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .shadow(color: .black.opacity(0.5), radius: 12)
            .padding(24)
            if let e = model.loadError {
                Text(e).foregroundStyle(.white).padding(10).background(.red.opacity(0.8), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .frame(minHeight: 300)
    }
}

struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer
    final class View: NSView {
        let playerLayer = AVPlayerLayer()
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer = playerLayer
            playerLayer.videoGravity = .resizeAspect
            playerLayer.backgroundColor = NSColor.black.cgColor
        }
        required init?(coder: NSCoder) { fatalError() }
    }
    func makeNSView(context: Context) -> View { let v = View(); v.playerLayer.player = player; return v }
    func updateNSView(_ v: View, context: Context) { if v.playerLayer.player !== player { v.playerLayer.player = player } }
}

/// Drag the camera window (snaps to corners/edges), drag its corner to resize, drag the game to reframe it, and drag
/// the divider of a split layout.
struct StageInteraction: View {
    @ObservedObject var model: EditorModel
    @State private var hover = false
    @State private var moveStart: (CGPoint, CameraPlacement)?
    @State private var panStart: (Double, Double)?
    @State private var resizing = false

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let l = model.layout
            let showCam = model.hasCamera && (l.kind == .pip)
            let camRect = l.camera.rect(in: size)
            let screenRegion = l.kind == .stacked && model.hasCamera
                ? CGRect(x: 0, y: size.height * l.split, width: size.width, height: size.height * (1 - l.split))
                : CGRect(origin: .zero, size: size)
            ZStack(alignment: .topLeading) {
                // Game framing (pan) on the whole stage.
                Color.clear.contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 2)
                        .onChanged { g in pan(g, region: screenRegion) }
                        .onEnded { _ in panStart = nil })
                    .help(l.kind == .cameraOnly ? "" : "Drag to reframe the game")

                if l.kind == .stacked && model.hasCamera {
                    Rectangle().fill(Color.white.opacity(0.001)).frame(width: size.width, height: 16)
                        .overlay(Capsule().fill(.white.opacity(0.85)).frame(width: 44, height: 5).shadow(radius: 2))
                        .position(x: size.width / 2, y: size.height * l.split)
                        .gesture(DragGesture().onChanged { g in model.binding(\.split).wrappedValue = min(0.7, max(0.2, g.location.y / size.height)) })
                        .onHover { $0 ? NSCursor.resizeUpDown.push() : NSCursor.pop() }
                }

                if showCam {
                    let r = l.camera.radius(for: camRect)
                    RoundedRectangle(cornerRadius: r + 3, style: .circular)
                        .strokeBorder(.white.opacity(hover || moveStart != nil || resizing ? 0.9 : 0), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                        .frame(width: camRect.width + 6, height: camRect.height + 6)
                        .contentShape(RoundedRectangle(cornerRadius: r))
                        .position(x: camRect.midX, y: camRect.midY)
                        .onHover { hover = $0; $0 ? NSCursor.openHand.push() : NSCursor.pop() }
                        .gesture(DragGesture(minimumDistance: 1)
                            .onChanged { g in
                                if moveStart == nil { moveStart = (CGPoint(x: g.startLocation.x - camRect.midX, y: g.startLocation.y - camRect.midY), l.camera) }
                                guard let (grab, start) = moveStart else { return }
                                var p = start
                                p.move(to: CGPoint(x: g.location.x - grab.x, y: g.location.y - grab.y), canvas: size, snap: !NSEvent.modifierFlags.contains(.option))
                                model.binding(\.camera).wrappedValue = p
                            }
                            .onEnded { _ in moveStart = nil })
                    ForEach(0..<4, id: \.self) { i in
                        let c = CGPoint(x: i % 2 == 0 ? camRect.minX : camRect.maxX, y: i < 2 ? camRect.minY : camRect.maxY)
                        Circle().fill(.white).frame(width: 10, height: 10).shadow(radius: 1.5)
                            .opacity(hover || resizing ? 1 : 0)
                            .frame(width: 22, height: 22).contentShape(Rectangle())
                            .position(c)
                            .onHover { h in hover = h || hover; h ? NSCursor.crosshair.push() : NSCursor.pop() }
                            .gesture(DragGesture()
                                .onChanged { g in
                                    resizing = true
                                    var p = l.camera
                                    let a = p.aspect.value
                                    let halfShort = max(abs(g.location.x - camRect.midX) / (a >= 1 ? a : 1), abs(g.location.y - camRect.midY) * (a >= 1 ? 1 : a))
                                    p.size = min(1, max(0.08, Double(2 * halfShort / min(size.width, size.height))))
                                    model.binding(\.camera).wrappedValue = p
                                }
                                .onEnded { _ in resizing = false })
                    }
                }
            }
        }
    }

    private func pan(_ g: DragGesture.Value, region: CGRect) {
        let l = model.layout
        guard l.kind != .cameraOnly else { return }
        if panStart == nil { panStart = (l.panX, l.panY) }
        guard let (x0, y0) = panStart, let b = modelScreenSize() else { return }
        let crop = l.fit ? LayoutMath.fillCrop(sourceSize: b, dst: b, zoom: l.zoom, panX: l.panX, panY: l.panY)
                         : LayoutMath.fillCrop(sourceSize: b, dst: region.size, zoom: l.zoom, panX: l.panX, panY: l.panY)
        var nl = l
        nl.panX = min(1, max(0, x0 - Double(g.translation.width / region.width) * crop.width))
        nl.panY = min(1, max(0, y0 - Double(g.translation.height / region.height) * crop.height))
        model.layout = nl
    }
    private func modelScreenSize() -> CGSize? {
        let p = model.project
        return p.width > 0 ? CGSize(width: p.width, height: p.height) : CGSize(width: 16, height: 9)
    }
}

// MARK: - Timeline

struct TimelineView: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Button { model.togglePlay() } label: {
                    Image(systemName: model.playing ? "pause.fill" : "play.fill").frame(width: 18)
                }
                .keyboardShortcut(.space, modifiers: [])
                .buttonStyle(.borderless).font(.title3)
                Text("\(formatTimePrecise(model.time)) / \(formatTime(model.duration))").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                Text("Trimmed: \(formatTime(max(0, model.trimEnd - model.trimStart)))").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                Button("Set In") { model.setIn() }.keyboardShortcut("i", modifiers: [])
                Button("Set Out") { model.setOut() }.keyboardShortcut("o", modifiers: [])
                Button("Reset") { model.update { $0.trimStartMs = 0; $0.trimEndMs = 0 } }
                    .disabled(model.project.trimStartMs == 0 && model.project.trimEndMs == 0)
            }
            LayerLanes(model: model).frame(height: 24 + 22 * CGFloat(1 + (model.hasCamera ? 1 : 0) + (model.hasMic ? 1 : 0)))
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(.bar)
    }
}

/// Ruler, one lane per layer (shifted by its sync offset), trim handles and the playhead.
struct LayerLanes: View {
    @ObservedObject var model: EditorModel
    @State private var draggingTrim: Int?   // 0 in, 1 out

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, d = max(model.duration, 0.001)
            let x = { (t: Double) -> CGFloat in CGFloat(t / d) * w }
            let lanes: [(String, String, Color, Double)] = [("Game", "gamecontroller.fill", .blue, 0)]
                + (model.hasCamera ? [("Camera", "video.fill", .green, (model.project.camera?.offsetMs ?? 0) / 1000)] : [])
                + (model.hasMic ? [("Mic", "mic.fill", .orange, (model.project.mic?.offsetMs ?? 0) / 1000)] : [])
            ZStack(alignment: .topLeading) {
                // Ruler / scrub area
                Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 18)
                    .overlay(alignment: .leading) {
                        ForEach(Array(stride(from: 0.0, through: d, by: tick(d))), id: \.self) { t in
                            Text(formatTime(t)).font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary)
                                .position(x: x(t) + 14, y: 9)
                        }
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { g in model.seek(Double(g.location.x / w) * d) })
                ForEach(Array(lanes.enumerated()), id: \.offset) { i, lane in
                    let y = 24 + CGFloat(i) * 22
                    let start = max(0, lane.3)
                    RoundedRectangle(cornerRadius: 4).fill(lane.2.opacity(0.75))
                        .frame(width: max(0, x(d) - x(start)), height: 18)
                        .overlay(alignment: .leading) {
                            Label(lane.0, systemImage: lane.1).font(.system(size: 10, weight: .medium)).foregroundStyle(.white).padding(.leading, 6)
                        }
                        .offset(x: x(start), y: y)
                }
                // Dim what's trimmed away
                Rectangle().fill(Color.black.opacity(0.45)).frame(width: x(model.trimStart), height: geo.size.height).allowsHitTesting(false)
                Rectangle().fill(Color.black.opacity(0.45)).frame(width: max(0, w - x(model.trimEnd)), height: geo.size.height)
                    .offset(x: x(model.trimEnd)).allowsHitTesting(false)
                trimHandle(at: x(model.trimStart), height: geo.size.height, leading: true)
                    .gesture(DragGesture().onChanged { g in
                        let t = min(max(0, Double(g.location.x / w) * d), model.trimEnd - 0.5)
                        model.update { $0.trimStartMs = t * 1000 }; model.seek(t)
                    })
                trimHandle(at: x(model.trimEnd), height: geo.size.height, leading: false)
                    .gesture(DragGesture().onChanged { g in
                        let t = max(min(d, Double(g.location.x / w) * d), model.trimStart + 0.5)
                        model.update { $0.trimEndMs = t >= d - 0.01 ? 0 : t * 1000 }; model.seek(t)
                    })
                // Playhead
                Rectangle().fill(Color.red).frame(width: 2, height: geo.size.height).offset(x: x(model.time) - 1).allowsHitTesting(false)
            }
        }
    }

    func trimHandle(at px: CGFloat, height: CGFloat, leading: Bool) -> some View {
        RoundedRectangle(cornerRadius: 2).fill(Color.yellow)
            .frame(width: 6, height: height)
            .frame(width: 16).contentShape(Rectangle())
            .offset(x: px - 8)
            .onHover { $0 ? NSCursor.resizeLeftRight.push() : NSCursor.pop() }
            .help(leading ? "Trim start (I)" : "Trim end (O)")
    }

    func tick(_ d: Double) -> Double { [1, 5, 10, 15, 30, 60, 120, 300, 600].first { d / $0 <= 10 } ?? 1200 }
}

// MARK: - Inspector

struct Inspector: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        let l = model.layout
        Form {
            Section(model.canvas.title) {
                Picker("Layout", selection: model.binding(\.kind)) {
                    ForEach(LayoutKind.allCases, id: \.self) { k in
                        Text(k.label).tag(k)
                    }
                }
                .disabled(!model.hasCamera)
                if !model.hasCamera { Text("This recording has no camera layer.").font(.caption).foregroundStyle(.secondary) }
            }

            if model.hasCamera && l.kind != .screenOnly {
                Section("Camera") {
                    if l.kind == .pip {
                        Picker("Shape", selection: Binding(
                            get: { l.camera.isCircle ? 0 : l.camera.roundness > 0 ? 1 : 2 },
                            set: { v in
                                var c = l.camera
                                switch v { case 0: c.aspect = .square; c.roundness = 0.5; case 1: c.roundness = 0.16; default: c.roundness = 0 }
                                model.binding(\.camera).wrappedValue = c
                            })) {
                            Image(systemName: "circle").tag(0)
                            Image(systemName: "app").tag(1)
                            Image(systemName: "square").tag(2)
                        }
                        .pickerStyle(.segmented)
                        Picker("Window", selection: model.binding(\.camera.aspect)) {
                            ForEach(CameraAspect.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        LabeledContent("Size") { Slider(value: model.binding(\.camera.size), in: 0.1...0.9) }
                        LabeledContent("Corners") { Slider(value: model.binding(\.camera.roundness), in: 0...0.5) }
                        LabeledContent("Position") { PositionGrid(model: model) }
                        Toggle("Shadow", isOn: model.binding(\.camera.shadow))
                        Toggle("Border", isOn: model.binding(\.camera.border))
                    }
                    if l.kind == .stacked {
                        LabeledContent("Camera height") { Slider(value: model.binding(\.split), in: 0.2...0.7) }
                    }
                    Toggle("Mirror", isOn: model.projectBinding(\.cameraMirror))
                }
            }

            if l.kind != .cameraOnly {
                Section("Game") {
                    Picker("Framing", selection: model.binding(\.fit)) {
                        Text("Fill").tag(false)
                        Text("Fit").tag(true)
                    }
                    .pickerStyle(.segmented)
                    LabeledContent("Zoom") { Slider(value: model.binding(\.zoom), in: 1...3) }
                    HStack {
                        Text("Drag the preview to reframe").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Center") { var nl = l; nl.panX = 0.5; nl.panY = 0.5; nl.zoom = 1; model.layout = nl }
                    }
                }
            }

            Section("Audio & Sync") {
                LabeledContent("Game volume") { VolumeSlider(value: model.projectBinding(\.game.volume)) }
                if model.hasMic {
                    LabeledContent("Mic volume") {
                        VolumeSlider(value: Binding(get: { model.project.mic?.volume ?? 1 }, set: { v in model.update { $0.mic?.volume = v } }), max: 3)
                    }
                    OffsetRow(title: "Mic offset", value: Binding(get: { model.project.mic?.offsetMs ?? 0 }, set: { v in model.update { $0.mic?.offsetMs = v } }))
                }
                if model.hasCamera {
                    OffsetRow(title: "Camera offset", value: Binding(get: { model.project.camera?.offsetMs ?? 0 }, set: { v in model.update { $0.camera?.offsetMs = v } }))
                }
                if model.hasMic || model.hasCamera {
                    Text("The capture card adds a little delay to the game. If your voice or face runs ahead of the gameplay, add a positive offset.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            ExportSection(model: model)
        }
        .formStyle(.grouped)
    }
}

struct VolumeSlider: View {
    @Binding var value: Double
    var max = 2.0
    var body: some View {
        HStack {
            Slider(value: $value, in: 0...max)
            Text("\(Int((value * 100).rounded()))%").font(.caption.monospacedDigit()).frame(width: 40, alignment: .trailing)
        }
    }
}

/// Sync nudge in milliseconds, committed on release so the composition is rebuilt once per change.
struct OffsetRow: View {
    let title: String
    @Binding var value: Double
    @State private var draft: Double?
    var body: some View {
        LabeledContent(title) {
            HStack {
                Slider(value: Binding(get: { draft ?? value }, set: { draft = ($0 / 10).rounded() * 10 }), in: -500...500) { editing in
                    if !editing, let d = draft { value = d; draft = nil }
                }
                Stepper("", value: Binding(get: { value }, set: { value = $0 }), in: -2000...2000, step: 10).labelsHidden()
                Text("\(Int(draft ?? value)) ms").font(.caption.monospacedDigit()).frame(width: 52, alignment: .trailing)
            }
        }
    }
}

struct PositionGrid: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        Grid(horizontalSpacing: 4, verticalSpacing: 4) {
            ForEach(0..<3, id: \.self) { row in
                GridRow {
                    ForEach(0..<3, id: \.self) { col in
                        if row == 1 && col == 1 { Color.clear.frame(width: 22, height: 14) }
                        else {
                            Button { place(row: row, col: col) } label: {
                                RoundedRectangle(cornerRadius: 2).fill(isAt(row: row, col: col) ? Color.accentColor : Color.secondary.opacity(0.35))
                                    .frame(width: 22, height: 14)
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }
    private var canvas: CGSize { model.canvas.size(.hd) }
    private func anchor(row: Int, col: Int) -> CGPoint? {
        let r = model.layout.camera.rect(in: canvas)
        let idx = row * 3 + col
        let anchors = CameraPlacement.anchors(for: r.size, canvas: canvas)
        let i = idx > 4 ? idx - 1 : idx
        return i < anchors.count ? anchors[i] : nil
    }
    private func place(row: Int, col: Int) {
        guard let a = anchor(row: row, col: col) else { return }
        var c = model.layout.camera; c.move(to: a, canvas: canvas, snap: false)
        model.binding(\.camera).wrappedValue = c
    }
    private func isAt(row: Int, col: Int) -> Bool {
        guard let a = anchor(row: row, col: col) else { return false }
        let r = model.layout.camera.rect(in: canvas)
        return abs(r.midX - a.x) < 2 && abs(r.midY - a.y) < 2
    }
}

struct ExportSection: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        Section("Export") {
            ForEach(Canvas.allCases) { c in
                Toggle(isOn: Binding(get: { model.exportCanvases.contains(c) },
                                     set: { if $0 { model.exportCanvases.insert(c) } else { model.exportCanvases.remove(c) } })) {
                    Label(c.title, systemImage: c == .wide ? "rectangle" : "rectangle.portrait")
                }
            }
            Picker("Resolution", selection: $model.resolution) {
                Text("1080p").tag(ExportResolution.hd)
                Text("4K").tag(ExportResolution.uhd)
            }
            Picker("Frame rate", selection: $model.fps) {
                Text("Source (\(Int(model.project.fps.rounded())))").tag(ExportFPS.source)
                Text("60").tag(ExportFPS.sixty)
                Text("30").tag(ExportFPS.thirty)
            }
            if model.isHDRSource {
                Picker("Color", selection: $model.range) {
                    Text("HDR · HEVC 10-bit").tag(ExportRange.hdr)
                    Text("SDR · H.264").tag(ExportRange.sdr)
                }
                Text(model.range == .hdr ? "Best for YouTube. The preview shows HDR." : "Plays everywhere (TikTok, Reels, Shorts). HDR highlights are tone-mapped; the preview matches.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Canvas.allCases) { c in
                if let s = model.exports[c] {
                    HStack {
                        Text(c.label).font(.caption.bold()).frame(width: 34, alignment: .leading)
                        if s.running { ProgressView(value: s.progress).progressViewStyle(.linear) }
                        else if let e = s.error { Text(e).font(.caption).foregroundStyle(.red).lineLimit(2) }
                        else if let u = s.url {
                            Text(u.lastPathComponent).font(.caption).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button { NSWorkspace.shared.activateFileViewerSelecting([u]) } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.borderless)
                        }
                    }
                }
            }
            HStack {
                if model.anyExporting { Button("Cancel") { model.cancelExports() } }
                Spacer()
                Button {
                    model.export()
                } label: {
                    Label(model.exportCanvases.count > 1 ? "Export Both" : "Export", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("e", modifiers: .command)
                .disabled(model.exportCanvases.isEmpty || model.anyExporting)
            }
        }
    }
}

#if DEBUG
/// Development aid: EHDR_SNAPSHOT=<dir> writes PNGs of the app's windows every few seconds (layer-backed video
/// content excluded); EHDR_OPEN=<n> opens the n-th library item in the editor.
enum DebugSnapshots {
    static func start() {
        let env = ProcessInfo.processInfo.environment
        if let n = env["EHDR_OPEN"].flatMap(Int.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                Library.shared.reload()
                if n < Library.shared.docs.count { EditorWindows.shared.open(Library.shared.docs[n]) }
            }
        }
        guard let dir = env["EHDR_SNAPSHOT"] else { return }
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            for (i, w) in NSApp.windows.enumerated() where w.isVisible {
                guard let v = w.contentView?.superview ?? w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { continue }
                v.cacheDisplay(in: v.bounds, to: rep)
                let name = w.title.isEmpty ? "window\(i)" : w.title.replacingOccurrences(of: "/", with: "-")
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
            }
        }
    }
}
#endif
