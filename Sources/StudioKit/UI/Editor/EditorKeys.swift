import AppKit
import SwiftUI

/// Every editor keyboard action. The same table drives the key handler and the Keyboard Shortcuts window.
enum EditorCommand: Hashable {
    case playPause, shuttleBack, shuttleStop, shuttleForward
    case stepBack, stepForward, jumpBack, jumpForward, previousEdit, nextEdit
    case split, delete, setIn, setOut, clearInOut
    case addZoom, addMarker, nextMarker, previousMarker, sceneChange(Int)
    case fit, zoomIn, zoomOut, toggleRemoved
    case deselect, undo, redo, export, shortcuts
}

struct EditorShortcut: Identifiable {
    let keys: String
    let title: String
    let group: String
    let command: EditorCommand
    var id: String { group + keys + title }

    static let groups = ["Playback", "Navigate", "Edit", "Zoom, Scenes and Markers", "Timeline", "Project"]

    static let all: [EditorShortcut] = [
        .init(keys: "Space", title: "Play or pause", group: "Playback", command: .playPause),
        .init(keys: "L", title: "Play forward; again for 2× and 4×", group: "Playback", command: .shuttleForward),
        .init(keys: "J", title: "Play backward; again for 2× and 4×", group: "Playback", command: .shuttleBack),
        .init(keys: "K", title: "Stop", group: "Playback", command: .shuttleStop),
        .init(keys: "←  →", title: "Step one frame", group: "Navigate", command: .stepForward),
        .init(keys: "⇧←  ⇧→", title: "Step one second", group: "Navigate", command: .jumpForward),
        .init(keys: "↑  ↓", title: "Previous or next edit point (cut, scene, zoom, marker)", group: "Navigate", command: .nextEdit),
        .init(keys: "⇧M  ⌥M", title: "Next or previous marker", group: "Navigate", command: .nextMarker),
        .init(keys: "S  or  ⌘B", title: "Split at the playhead", group: "Edit", command: .split),
        .init(keys: "⌫", title: "Remove the selection, or restore a removed section", group: "Edit", command: .delete),
        .init(keys: "I", title: "Set the in point (nothing before it is exported)", group: "Edit", command: .setIn),
        .init(keys: "O", title: "Set the out point", group: "Edit", command: .setOut),
        .init(keys: "⌥X", title: "Clear in and out", group: "Edit", command: .clearInOut),
        .init(keys: "⌘Z  ⇧⌘Z", title: "Undo and redo", group: "Edit", command: .undo),
        .init(keys: "Esc", title: "Select nothing (project settings)", group: "Edit", command: .deselect),
        .init(keys: "Z", title: "Add a zoom at the playhead", group: "Zoom, Scenes and Markers", command: .addZoom),
        .init(keys: "⌃1 … ⌃9", title: "Change to scene 1…9 at the playhead", group: "Zoom, Scenes and Markers", command: .sceneChange(1)),
        .init(keys: "M", title: "Add a marker", group: "Zoom, Scenes and Markers", command: .addMarker),
        .init(keys: "=  -", title: "Zoom the timeline in or out (or ⌘-scroll, pinch)", group: "Timeline", command: .zoomIn),
        .init(keys: "⇧Z", title: "Show the whole recording", group: "Timeline", command: .fit),
        .init(keys: "H", title: "Hide or show removed sections", group: "Timeline", command: .toggleRemoved),
        .init(keys: "⌘E", title: "Export…", group: "Project", command: .export),
        .init(keys: "⌘/", title: "This list", group: "Project", command: .shortcuts),
    ]

    /// Maps a key event to a command. Pure, so the table is testable.
    static func command(chars: String, keyCode: UInt16, flags: NSEvent.ModifierFlags) -> EditorCommand? {
        let f = flags.intersection([.command, .shift, .option, .control])
        let c = chars.lowercased()
        switch (keyCode, f) {
        case (49, []): return .playPause
        case (123, []): return .stepBack
        case (124, []): return .stepForward
        case (123, [.shift]): return .jumpBack
        case (124, [.shift]): return .jumpForward
        case (126, []): return .previousEdit
        case (125, []): return .nextEdit
        case (51, []), (117, []): return .delete
        case (53, []): return .deselect
        default: break
        }
        switch (c, f) {
        case ("j", []): return .shuttleBack
        case ("k", []): return .shuttleStop
        case ("l", []): return .shuttleForward
        case ("s", []), ("b", [.command]): return .split
        case ("i", []): return .setIn
        case ("o", []): return .setOut
        case ("x", [.option]), ("≈", [.option]): return .clearInOut
        case ("z", []): return .addZoom
        case ("z", [.shift]): return .fit
        case ("z", [.command]): return .undo
        case ("z", [.command, .shift]): return .redo
        case ("m", []): return .addMarker
        case ("m", [.shift]): return .nextMarker
        case ("m", [.option]), ("µ", [.option]): return .previousMarker
        case ("=", []), ("+", []), ("+", [.shift]): return .zoomIn
        case ("-", []): return .zoomOut
        case ("h", []): return .toggleRemoved
        case ("e", [.command]): return .export
        case ("/", [.command]), ("?", [.command, .shift]): return .shortcuts
        default: break
        }
        if f == [.control], let n = Int(c), (1...9).contains(n) { return .sceneChange(n) }
        return nil
    }
}

/// Installs the editor's key handling for the window it is in. A local monitor sees keys before the menus and
/// the focused control; it steps aside while a text field is being edited or a sheet is up.
struct EditorKeyHandler: NSViewRepresentable {
    let model: EditorModel
    let perform: (EditorCommand) -> Void

    func makeNSView(context: Context) -> KeyView { let v = KeyView(); v.perform = perform; return v }
    func updateNSView(_ v: KeyView, context: Context) { v.perform = perform }

    final class KeyView: NSView {
        var perform: ((EditorCommand) -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                guard let self = self, let w = self.window, e.window === w, w.attachedSheet == nil else { return e }
                if w.firstResponder is NSText { return e }   // typing in a field
                guard let cmd = EditorShortcut.command(chars: e.charactersIgnoringModifiers ?? "", keyCode: e.keyCode, flags: e.modifierFlags) else { return e }
                self.perform?(cmd)
                return nil
            }
        }
        deinit { if let m = monitor { NSEvent.removeMonitor(m) } }
    }
}

extension EditorModel {
    /// The keyboard's entry point; `showExport` and `showShortcuts` are view state handled by the caller.
    func perform(_ c: EditorCommand) {
        switch c {
        case .playPause: togglePlay()
        case .shuttleBack: shuttle(forward: false)
        case .shuttleStop: if playing || reverseTimer != nil { pause() }
        case .shuttleForward: shuttle(forward: true)
        case .stepBack: step(frames: -1)
        case .stepForward: step(frames: 1)
        case .jumpBack: jump(seconds: -1)
        case .jumpForward: jump(seconds: 1)
        case .previousEdit: jumpToEdit(forward: false)
        case .nextEdit: jumpToEdit(forward: true)
        case .split: split()
        case .delete: deleteSelection()
        case .setIn: setIn()
        case .setOut: setOut()
        case .clearInOut: clearInOut()
        case .addZoom: addZoom()
        case .addMarker: addMarker()
        case .nextMarker: nextMarker()
        case .previousMarker: previousMarker()
        case .sceneChange(let n): addSceneChange(index: n)
        case .fit: fitTimeline()
        case .zoomIn: zoomTimeline(in: true)
        case .zoomOut: zoomTimeline(in: false)
        case .toggleRemoved: hideRemoved.toggle()
        case .deselect: selection = .none
        case .undo: undo()
        case .redo: redo()
        case .export, .shortcuts: break
        }
    }
}

// MARK: - Keyboard Shortcuts window

enum ShortcutsWindow {
    private static var window: NSWindow?
    static func show() {
        if let w = window { w.makeKeyAndOrderFront(nil); return }
        let w = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 640), styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .utilityWindow],
                        backing: .buffered, defer: false)
        w.title = "Keyboard Shortcuts"
        w.isReleasedWhenClosed = false
        w.titlebarAppearsTransparent = true
        let host = NSHostingController(rootView: ShortcutsView())
        host.sizingOptions = []
        w.contentViewController = host
        w.setContentSize(NSSize(width: 520, height: 640))
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
    }
}

struct ShortcutsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.l) {
                Text("Editor Keyboard Shortcuts").font(.system(size: 17, weight: .semibold)).padding(.top, DS.Space.xl)
                ForEach(EditorShortcut.groups, id: \.self) { g in
                    InspectorSection(title: g) {
                        ForEach(EditorShortcut.all.filter { $0.group == g }) { s in
                            HStack(alignment: .firstTextBaseline) {
                                Text(s.title).font(.system(size: 12))
                                Spacer(minLength: DS.Space.m)
                                Text(s.keys).font(.system(size: 12, weight: .medium).monospaced())
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)))
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
                Text("Drag in the ruler to scrub. In the timeline, ⌘-scroll or pinch to zoom and scroll to pan; hold ⌥ while dragging to turn snapping off.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).padding(.bottom, DS.Space.xl)
            }
            .padding(.horizontal, DS.Space.xl)
        }
        .background(DS.Color.panel)
        .frame(minWidth: 420, minHeight: 360)
    }
}
