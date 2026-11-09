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

