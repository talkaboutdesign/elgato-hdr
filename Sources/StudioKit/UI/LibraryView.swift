// Recordings library and the windows around the editor. The library window shows either the grid of recordings or
// one project's editor (opening a project navigates inside the window, "‹ Library" goes back); a project can also
// open in a window of its own from the context menu.
import AppKit
import AVFoundation
import ImageIO
import Observation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Windows

extension AppDelegate {
    func makeLibraryWindow() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.title = "Recordings"
        w.isReleasedWhenClosed = false
        w.toolbarStyle = .unified
        let host = NSHostingController(rootView: LibraryRoot())
        host.sizingOptions = []   // keep the window size we choose instead of shrinking to the SwiftUI minimum
        w.contentViewController = host
        w.setContentSize(NSSize(width: 1180, height: 760))
        w.minSize = NSSize(width: 640, height: 440)
        w.center()
        w.setFrameAutosaveName("RecordingsLibrary")
        LibraryNavigation.shared.attach(w)
        return w
    }
}

/// What the library window shows. Main thread only.
@Observable
final class LibraryNavigation {
    static let shared = LibraryNavigation()
    private(set) var editor: EditorModel?
    @ObservationIgnored private(set) weak var window: NSWindow?
    @ObservationIgnored private let delegate = LibraryWindowDelegate()
    @ObservationIgnored private var frameBeforeEditor: NSRect?

    func attach(_ w: NSWindow) { window = w; w.delegate = delegate }

    func open(_ doc: ProjectDoc) {
        if let (w, _) = EditorWindows.shared.entry(for: doc.dir) { w.makeKeyAndOrderFront(nil); return }
        if editor?.doc.dir == doc.dir { return }
        editor?.close()
        let m = EditorModel(doc: doc)
        growWindowForEditor()
        withAnimation(DS.Motion.gentle) { editor = m }
        window?.title = doc.project.name
    }

    func back() {
        guard let m = editor else { return }
        m.close()
        withAnimation(DS.Motion.gentle) { editor = nil }
        if let w = window {
            w.minSize = NSSize(width: 640, height: 440)
            if let f = frameBeforeEditor { w.setFrame(f, display: true, animate: !DS.Motion.reduceMotion) }
            w.title = "Recordings"
            w.subtitle = ""
        }
        frameBeforeEditor = nil
        Library.shared.reload()
    }

    /// The editor wants room for preview, inspector and timeline; a small library window grows and shrinks back.
    private func growWindowForEditor() {
        guard let w = window, let screen = w.screen?.visibleFrame else { return }
        w.minSize = NSSize(width: 960, height: 640)
        let want = NSSize(width: min(screen.width, max(w.frame.width, 1280)), height: min(screen.height, max(w.frame.height, 820)))
        guard want.width > w.frame.width + 1 || want.height > w.frame.height + 1 else { return }
        frameBeforeEditor = w.frame
        var f = NSRect(x: w.frame.minX, y: w.frame.maxY - want.height, width: want.width, height: want.height)
        f.origin.x = min(max(screen.minX, f.minX), screen.maxX - f.width)
        f.origin.y = min(max(screen.minY, f.minY), screen.maxY - f.height)
        w.setFrame(f, display: true, animate: !DS.Motion.reduceMotion)
    }

    fileprivate func windowWillClose() {
        editor?.close(); editor = nil; frameBeforeEditor = nil
    }
}

private final class LibraryWindowDelegate: NSObject, NSWindowDelegate {
    /// ⌘Z and ⇧⌘Z reach the window, which asks here: the open project's history, none while it exports.
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        LibraryNavigation.shared.editor?.undoManager(for: window) ?? searchUndo
    }
    private let searchUndo = UndoManager()
    func windowWillClose(_ notification: Notification) { LibraryNavigation.shared.windowWillClose() }
}

/// Projects opened in windows of their own.
final class EditorWindows: NSObject, NSWindowDelegate {
    static let shared = EditorWindows()
    private var windows: [URL: (NSWindow, EditorModel)] = [:]

    func open(_ doc: ProjectDoc) {
        if let (w, _) = windows[doc.dir] { w.makeKeyAndOrderFront(nil); return }
        // One editor per project: if it is open in the library window, it moves out.
        if LibraryNavigation.shared.editor?.doc.dir == doc.dir { LibraryNavigation.shared.back() }
        let model = EditorModel(doc: doc)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.title = doc.project.name
        w.isReleasedWhenClosed = false
        w.toolbarStyle = .unified
        let host = NSHostingController(rootView: EditorView(model: model))
        host.sizingOptions = []
        w.contentViewController = host
        w.setContentSize(NSSize(width: 1280, height: 820))
        w.minSize = NSSize(width: 960, height: 640)
        w.delegate = self
        w.center()
        windows[doc.dir] = (w, model)
        w.makeKeyAndOrderFront(nil)
    }

    func entry(for dir: URL) -> (NSWindow, EditorModel)? { windows[dir] }
    func window(for model: EditorModel) -> NSWindow? { windows.values.first { $0.1 === model }?.0 }

    /// The editor that owns a project's state while it is open, so library actions go through it.
    func model(for dir: URL) -> EditorModel? {
        if let m = windows[dir]?.1 { return m }
        if let m = LibraryNavigation.shared.editor, m.doc.dir == dir { return m }
        return nil
    }

    /// ⌘Z and ⇧⌘Z in the Edit menu reach the window, which asks its delegate: the project's own history.
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        windows.values.first { $0.0 === window }?.1.undoManager(for: window)
    }

    func windowWillClose(_ n: Notification) {
        guard let w = n.object as? NSWindow, let (key, (_, model)) = windows.first(where: { $0.value.0 === w }) else { return }
        model.close()
        windows[key] = nil
    }
}

// MARK: - Root

struct LibraryRoot: View {
    let nav = LibraryNavigation.shared
    var body: some View {
        ZStack {
            if let m = nav.editor {
                EditorView(model: m, onBack: { nav.back() })
                    .id(m.doc.dir)
                    .transition(DS.Motion.transition(.asymmetric(insertion: .scale(scale: 1.025).combined(with: .opacity), removal: .opacity)))
                    .zIndex(1)
            } else {
                LibraryView { nav.open($0) }
                    .transition(DS.Motion.transition(.asymmetric(insertion: .opacity, removal: .scale(scale: 0.975).combined(with: .opacity))))
            }
        }
        .background(DS.Color.panel)
    }
}

// MARK: - Library

enum LibraryFilter: Hashable { case all, live }

struct LibraryView: View {
    var open: (ProjectDoc) -> Void
    @ObservedObject var lib = Library.shared
    @State private var search = ""
    @State private var filter = LibraryFilter.all
    @State private var selection: URL?
    @State private var renaming: ProjectDoc?
    @State private var newName = ""

    var filtered: [ProjectDoc] {
        let q = search.trimmingCharacters(in: .whitespaces)
        return lib.docs.filter { d in
            (filter == .all || !d.project.events.isEmpty) && (q.isEmpty || d.project.name.localizedCaseInsensitiveContains(q))
        }
    }

    var body: some View {
        Group {
            if lib.docs.isEmpty {
                EmptyState(systemImage: "rectangle.stack.badge.play", title: "No recordings yet",
                           message: "Press ⌘R in the live window to record. The game, your camera and your microphone are saved as separate layers you can cut, zoom and export here.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filtered.isEmpty {
                if !search.isEmpty { ContentUnavailableView.search(text: search) }
                else {
                    EmptyState(systemImage: "dot.radiowaves.left.and.right", title: "No live sessions yet",
                               message: "Recordings made while streaming keep their scene switches, zooms and markers, and show up here.")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300, maximum: 420), spacing: DS.Space.xl, alignment: .top)], alignment: .leading, spacing: 28) {
                        ForEach(filtered) { doc in
                            ProjectCard(doc: doc, project: doc.project, selected: selection == doc.dir)
                                .onTapGesture(count: 2) { open(doc) }
                                .simultaneousGesture(TapGesture().onEnded { selection = doc.dir })
                                .contextMenu { menu(for: doc) }
                                .accessibilityAddTraits(.isButton)
                                .accessibilityAction { open(doc) }
                        }
                    }
                    .padding(DS.Space.xl)
                }
                .onTapGesture { selection = nil }
            }
        }
        .frame(minWidth: 560, minHeight: 400)
        .background(DS.Color.panel)
        .background(WindowTitle(title: "Recordings", subtitle: lib.docs.isEmpty ? "" : "\(lib.docs.count) recording\(lib.docs.count == 1 ? "" : "s")",
                                active: { LibraryNavigation.shared.editor == nil }))
        .searchable(text: $search, placement: .toolbar, prompt: "Search recordings")
        .toolbar {
            ToolbarItem(placement: .principal) {
                SegmentedSwitch(selection: $filter, options: [
                    .init(value: .all, label: "All", help: "Every recording"),
                    .init(value: .live, label: "Live Sessions", help: "Recordings with scene switches, zooms or markers from a live session"),
                ], height: 26)
                .frame(width: 240)
                .accessibilityLabel("Filter")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                IconButton(systemImage: "arrow.clockwise", help: "Refresh") { lib.reload() }
                IconButton(systemImage: "folder", help: "Show recordings in Finder") { NSWorkspace.shared.open(lib.root) }
            }
        }
        .alert("Rename Recording", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") { if let d = renaming { lib.rename(d, to: newName) }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .onAppear {
            lib.reload()
            #if DEBUG
            if ProcessInfo.processInfo.environment["EHDR_LIBRARY_FILTER"] == "live" { filter = .live }
            #endif
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { n in
            if (n.object as? NSWindow) === LibraryNavigation.shared.window, LibraryNavigation.shared.editor == nil { lib.reload() }
        }
    }

    @ViewBuilder func menu(for doc: ProjectDoc) -> some View {
        Button("Open") { open(doc) }
        Button("Open in New Window") { EditorWindows.shared.open(doc) }
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
    let project: Project   // by value: ProjectDoc compares by folder only, so SwiftUI would skip state changes (recovery)
    let selected: Bool
    @State private var thumb: NSImage?
    @State private var hover = false
    @State private var scrub: Int?
    @State private var frames: [CGImage] = []
    @State private var framesKey = ""
    @State private var loadingFrames = false

    var body: some View {
        let p = project
        let edited = !p.timeline.segments.isEmpty
        let kept = TimelineEdits.kept(p).reduce(0.0) { $0 + $1.endMs - $1.startMs } / 1000
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { geo in
                ZStack {
                    Rectangle().fill(Color.black.opacity(0.88))
                    if let i = scrub, i < frames.count {
                        Image(decorative: frames[i], scale: 1).resizable().aspectRatio(contentMode: .fill)
                    } else if let t = thumb {
                        Image(nsImage: t).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: "gamecontroller").font(.system(size: 30)).foregroundStyle(.white.opacity(0.3))
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let pt):
                        let i = min(4, max(0, Int(pt.x / max(1, geo.size.width) * 5)))
                        if scrub != i { scrub = i }
                        loadFrames()
                    case .ended: scrub = nil
                    }
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(alignment: .topLeading) {
                HStack(spacing: 4) {
                    if !p.events.isEmpty { Badge(text: "LIVE", tint: DS.Color.live) }
                    if p.color != .sdr { Badge(text: p.color == .pq ? "HDR" : "HLG") }
                    if p.state == "recording" { Badge(text: "RECOVERING", tint: .orange) }
                    if p.state == "damaged" { Badge(text: "DAMAGED", tint: .red) }
                    if !p.lastExport.isEmpty { Badge(text: "EXPORTED", tint: DS.Color.ok) }
                }.padding(10)
            }
            .overlay(alignment: .bottomLeading) {
                LayerIcons(camera: doc.hasCamera, mic: doc.hasMic)
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .background(Capsule().fill(Color.black.opacity(0.6)))
                    .foregroundStyle(.white)
                    .padding(10)
            }
            .overlay(alignment: .bottomTrailing) {
                Badge(text: edited ? "\(formatTime(kept)) of \(formatTime(p.durationMs / 1000))" : formatTime(p.durationMs / 1000)).padding(10)
            }
            .overlay(alignment: .bottom) {
                if scrub != nil {
                    HStack(spacing: 3) {
                        ForEach(0..<5, id: \.self) { i in
                            Capsule().fill(Color.white.opacity(i == scrub ? 0.95 : 0.35)).frame(height: 3)
                        }
                    }
                    .padding(.horizontal, 12).padding(.bottom, 4)
                    .transition(.opacity)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(hover ? 0.22 : 0.08), lineWidth: selected ? 3 : 1))
            .shadow(color: .black.opacity(hover ? 0.28 : 0.12), radius: hover ? 12 : 4, y: hover ? 5 : 2)

            VStack(alignment: .leading, spacing: 3) {
                Text(p.name).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(p.createdAt.formatted(date: .abbreviated, time: .shortened)).lineLimit(1)
                    if p.height > 0 { Text(verbatim: "· \(p.height)p\(Int(p.fps.rounded()))").lineLimit(1).layoutPriority(-1) }
                    if edited { Text("· edited").lineLimit(1).layoutPriority(-2) }
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 2)
        }
        .scaleEffect(hover && !DS.Motion.reduceMotion ? 1.01 : 1)
        .animation(DS.Motion.snappy, value: hover)
        .animation(.easeOut(duration: 0.12), value: scrub)
        .onHover { hover = $0 }
        .contentShape(Rectangle())
        .task(id: "\(doc.dir.path)/\(p.durationMs)/\(p.state)") { thumb = NSImage(contentsOf: doc.thumbnailURL) }
        #if DEBUG
        .onAppear {
            // EHDR_LIBRARY_SCRUB="<name prefix>:<frame>" shows a card mid-scrub for screenshots (no pointer in CI).
            let v = (ProcessInfo.processInfo.environment["EHDR_LIBRARY_SCRUB"] ?? "").split(separator: ":")
            if v.count == 2, p.name.hasPrefix(v[0]), let i = Int(v[1]) { hover = true; scrub = i; loadFrames() }
        }
        #endif
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(p.name), \(formatTime(p.durationMs / 1000))")
        .accessibilityHint("Double-click to open")
    }

    private func loadFrames() {
        // An edit made since the frames were loaded (the editor saved) makes them stale.
        let key = ScrubFrames.fingerprint(project)
        if framesKey != key { frames = []; framesKey = key }
        guard frames.isEmpty, !loadingFrames, project.state == "complete" else { return }
        loadingFrames = true
        let doc = self.doc, p = project
        Task {
            let f = await ScrubFrames.load(doc, project: p)
            await MainActor.run { if framesKey == key { frames = f }; loadingFrames = false }
        }
    }
}

/// Five frames evenly spaced over what the project exports (its kept ranges), from the 16:9 composite, generated on
/// first hover and kept in memory and in the project's `.cache/scrub/<fingerprint>` folder. The fingerprint covers
/// everything that changes the picture, so a visual edit never shows the frames from before it.
enum ScrubFrames {
    private static let memory = NSCache<NSString, NSArray>()
    private static let lock = NSLock()
    private static var currentKey: [String: NSString] = [:]   // project folder -> its live memory key

    /// What the composite depends on: scenes and layouts, the timeline, mirroring and the layers' sync offsets.
    private struct RenderState: Encodable {
        var scenes: [Scene]; var timeline: Timeline; var wide: CanvasLayout; var vertical: CanvasLayout
        var mirror: Bool; var cameraOffsetMs: Double?; var micOffsetMs: Double?
        var game: String; var camera: String?; var color: String; var durationMs: Double
    }
    /// FNV-1a over the sorted-key JSON: stable across launches (Swift's `Hasher` is seeded per process).
    static func fingerprint(_ p: Project) -> String {
        let state = RenderState(scenes: p.scenes, timeline: p.timeline, wide: p.wide, vertical: p.vertical, mirror: p.cameraMirror,
                                cameraOffsetMs: p.camera?.offsetMs, micOffsetMs: p.mic?.offsetMs, game: p.game.file, camera: p.camera?.file,
                                color: p.colorMode, durationMs: p.durationMs)
        let e = JSONEncoder(); e.outputFormatting = .sortedKeys
        var h: UInt64 = 0xcbf29ce484222325
        for b in (try? e.encode(state)) ?? Data() { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(format: "%016llx", h)
    }

    static func times(_ p: Project) -> [Double] {
        let kept = TimelineEdits.kept(p)
        let total = kept.reduce(0.0) { $0 + $1.endMs - $1.startMs }
        guard total > 0 else { return [] }
        let map = TimeMap(segments: kept, sourceDurationMs: p.durationMs)
        return (0..<5).map { i in (map.source(fromTimeline: total * (Double(i) + 0.5) / 5) / 100).rounded() * 100 }
    }

    private static func replaceKey(_ folder: String, with key: NSString) -> NSString? {
        lock.lock(); defer { lock.unlock() }
        let old = currentKey[folder]
        currentKey[folder] = key
        return old
    }

    static func load(_ doc: ProjectDoc, project p: Project) async -> [CGImage] {
        let ts = times(p), fp = fingerprint(p)
        let key = "\(doc.dir.path)|\(fp)|\(ts.map { Int($0) })" as NSString
        if let old = replaceKey(doc.dir.path, with: key), old != key { memory.removeObject(forKey: old) }
        if let hit = memory.object(forKey: key) as? [CGImage] { return hit }
        let root = doc.dir.appendingPathComponent(".cache/scrub", isDirectory: true)
        let dir = root.appendingPathComponent(fp, isDirectory: true)
        // Frames of earlier edits (and of builds before fingerprinting, loose in the root) are never shown again.
        for f in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] where f.lastPathComponent != fp {
            try? FileManager.default.removeItem(at: f)
        }
        var images: [CGImage] = []
        var generator: AVAssetImageGenerator?
        for t in ts {
            let file = dir.appendingPathComponent("\(Int(t)).jpg")
            if let src = CGImageSourceCreateWithURL(file as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) { images.append(img); continue }
            if generator == nil {
                let snapshot = ProjectDoc(dir: doc.dir, project: p)
                guard let built = try? await CompositionBuilder.build(snapshot, canvas: .wide, resolution: .hd, range: .sdr, ignoreCuts: true) else { break }
                let g = AVAssetImageGenerator(asset: built.asset)
                g.videoComposition = built.video
                g.maximumSize = CGSize(width: 640, height: 360)
                g.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 4); g.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 4)
                generator = g
            }
            guard let g = generator, let img = try? await g.image(at: CMTime(seconds: t / 1000, preferredTimescale: 600)).image else { continue }
            images.append(img)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if let dst = CGImageDestinationCreateWithURL(file as CFURL, UTType.jpeg.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(dst, img, [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary)
                CGImageDestinationFinalize(dst)
            }
        }
        if images.count == ts.count { memory.setObject(images as NSArray, forKey: key) }
        return images
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(["Game", camera ? "camera" : nil, mic ? "microphone" : nil].compactMap { $0 }.joined(separator: ", ") + " layers")
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
