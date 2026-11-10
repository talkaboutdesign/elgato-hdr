#if DEBUG
import AppKit
import AVFoundation
import QuartzCore
import SwiftUI

/// Development harness for the editor, driven by environment variables (agents and CI have no mouse):
/// `EHDR_EDITOR_SCRIPT="seek 1; split; …"` runs commands against the first editor that opens (`EHDR_OPEN=<n>` or
/// `EHDR_LIBRARY_OPEN=<n>`, which opens item n inside the library window). See `run(_:)` for the commands.
enum EditorHarness {
    static let env = ProcessInfo.processInfo.environment
    static var started = false
    static weak var showExportTarget: EditorModel?
    static var showExport: ((Bool) -> Void)?

    static func start() {
        // The library and editor follow the system appearance; this checks the other one without changing it.
        if let a = env["EHDR_APPEARANCE"] { NSApp.appearance = NSAppearance(named: a == "light" ? .aqua : .darkAqua) }
        if let n = env["EHDR_LIBRARY_OPEN"].flatMap(Int.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                (NSApp.delegate as? AppDelegate)?.showLibrary()
                DispatchQueue.main.asyncAfter(deadline: .now() + (env["EHDR_LIBRARY_OPEN_DELAY"].flatMap(Double.init) ?? 0.8)) {
                    if n < Library.shared.docs.count { LibraryNavigation.shared.open(Library.shared.docs[n]) }
                }
            }
        }
    }

    /// Called by the first editor view that appears.
    static func editorAppeared(_ m: EditorModel) {
        guard !started, let script = env["EHDR_EDITOR_SCRIPT"] else { return }
        started = true
        let steps = script.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        log("harness: \(steps.count) steps")
        // Wait for the preview to load before the first step.
        func waitReady(_ tries: Int) {
            if m.duration > 0 && m.player.currentItem != nil || tries > 50 { run(steps[...], m) }
            else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { waitReady(tries + 1) } }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { waitReady(0) }
    }

    private static func run(_ steps: ArraySlice<String>, _ m: EditorModel) {
        guard let step = steps.first else { log("harness: done"); return }
        let rest = steps.dropFirst()
        let parts = step.split(separator: " ").map(String.init)
        let arg = parts.dropFirst().joined(separator: " ")
        let num = Double(parts.count > 1 ? parts[1] : "") ?? 0
        var delay = 0.35
        log("harness: \(step)")
        switch parts[0] {
        case "wait": delay = num
        case "seek": m.seek(num)
        case "split": m.split()
        case "delete": m.deleteSelection()
        case "zoom": m.addZoom()
        case "marker": m.addMarker()
        case "scene": m.addSceneChange(index: Int(num))
        case "in": m.setIn()
        case "out": m.setOut()
        case "undo": m.undo()
        case "redo": m.redo()
        case "undoall": while m.canUndo { m.undo() }
        case "redoall": while m.canRedo { m.redo() }
        case "key": if let c = keyCommand(arg) { m.perform(c) }
        case "type": for k in parts.dropFirst() { postKey(k, to: m.window) }
        case "canvas": m.canvas = arg == "vertical" ? .vertical : .wide
        case "hide": m.hideRemoved = arg == "on"
        case "fit": m.fitTimeline()
        case "tlzoom": var a = m.axis; a.zoom(by: num, anchorX: a.x(m.time)); m.axis = a
        case "select": select(parts, m)
        case "focus": if case .zoom(let id) = m.selection, parts.count > 2 { m.updateZoom(id) { $0.focusX = num; $0.focusY = Double(parts[2]) ?? 0.5 } }
        case "zoomscale": if case .zoom(let id) = m.selection { m.updateZoom(id) { $0.scale = num } }
        case "rename": if case .marker(let id) = m.selection { m.renameMarker(id, arg) }
        case "transition": if case .scene(let id?) = m.selection { m.update { TimelineEdits.setTransition(&$0, spanID: id, SceneTransition(style: .fade, durationMs: num)) } }
        case "short": if case .marker(let id) = m.selection { m.makeShort(from: id) }
        case "save": m.saveNow()
        case "state":
            let sel: String = { switch m.selection { case .none: "none"; case .section(let s): "section \(Int(s.startMs))-\(Int(s.endMs)) \(s.kept ? "kept" : "removed")"; case .scene: "scene"; case .zoom: "zoom"; case .marker(let id): "marker \(Int(m.marker(id)?.tMs ?? -1))" } }()
            log(String(format: "harness: state %@ t=%.3f playing=%d rate=%.0f reverse=%d pps=%.2f fitted=%d hide=%d sections=%d markers=%d zooms=%d undo=%@ sel=%@", arg, m.time, m.playing ? 1 : 0, m.shuttleRate,
                       m.player.currentItem?.canPlayReverse == true ? 1 : 0, m.axis.pps, m.axis.fitted ? 1 : 0, m.hideRemoved ? 1 : 0, TimelineEdits.sections(m.project).count,
                       m.project.timeline.markers.count, m.project.timeline.zooms.count, m.undoTitle, sel))
        case "dump": m.saveNow(); try? FileManager.default.copyItem(at: m.doc.dir.appendingPathComponent("project.json"), to: URL(fileURLWithPath: arg))
        case "hover": hover(parts, m)
        case "exportsheet": showExport?(arg != "off"); delay = 1
        case "export":
            let presets = arg.split(separator: ",").compactMap { ExportPreset(rawValue: String($0)) }
            m.startExport(presets, custom: ExportPreset.Custom())
        case "waitexport":
            func poll() { if m.exportQueue.isRunning { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: poll) } else { run(rest, m) } }
            poll(); return
        case "popover": NotificationCenter.default.post(name: .harnessShowQueue, object: nil); delay = 1
        case "shortcuts": ShortcutsWindow.show(); delay = 1
        case "shot": shot(arg, window: m.window)
        case "shotlib": shot(arg, window: LibraryNavigation.shared.window)
        case "shotwin": if parts.count > 2, let w = NSApp.windows.first(where: { $0.title == parts[1] && $0.isVisible }) { shot(parts[2], window: w) }
        case "closewin": NSApp.windows.first { $0.title == arg }?.close()
        case "scrubtest": scrubTest(m) { run(rest, m) }; return
        case "perftest": MainActor.assumeIsolated { perfTest(m) }; delay = 0.5
        case "axdump": axDump(m.window, verbose: arg != "quiet")
        case "back": LibraryNavigation.shared.back(); delay = 1
        case "quit": NSApp.terminate(nil); return
        default: log("harness: unknown step \(step)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { run(rest, m) }
    }

    private static func keyCommand(_ s: String) -> EditorCommand? {
        let mods: [(String, NSEvent.ModifierFlags)] = [("cmd+", .command), ("shift+", .shift), ("opt+", .option), ("ctrl+", .control)]
        var rest = s, flags: NSEvent.ModifierFlags = []
        for (p, f) in mods where rest.hasPrefix(p) { rest.removeFirst(p.count); flags.insert(f) }
        let codes: [String: UInt16] = ["space": 49, "left": 123, "right": 124, "down": 125, "up": 126, "delete": 51, "esc": 53]
        return EditorShortcut.command(chars: codes[rest] == nil ? rest : "", keyCode: codes[rest] ?? 0xFFFF, flags: flags)
    }

    /// A real key-down through the application's event queue, so the editor's key handler sees what a keyboard sends.
    private static func postKey(_ s: String, to w: NSWindow?) {
        guard let w = w else { return }
        let mods: [(String, NSEvent.ModifierFlags)] = [("cmd+", .command), ("shift+", .shift), ("opt+", .option), ("ctrl+", .control)]
        var rest = s, flags: NSEvent.ModifierFlags = []
        for (p, f) in mods where rest.hasPrefix(p) { rest.removeFirst(p.count); flags.insert(f) }
        let special: [String: (UInt16, String)] = ["space": (49, " "), "left": (123, "\u{F702}"), "right": (124, "\u{F703}"), "down": (125, "\u{F701}"),
                                                    "up": (126, "\u{F700}"), "delete": (51, "\u{7F}"), "esc": (53, "\u{1B}")]
        let letters: [Character: UInt16] = ["a": 0, "s": 1, "d": 2, "h": 4, "z": 6, "x": 7, "b": 11, "e": 14, "1": 18, "2": 19, "3": 20, "=": 24, "-": 27,
                                            "o": 31, "i": 34, "l": 37, "j": 38, "k": 40, "/": 44, "m": 46]
        let (code, chars) = special[rest] ?? (letters[Character(rest.lowercased())] ?? 0, rest)
        let shown = flags.contains(.shift) ? chars.uppercased() : chars
        guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: w.windowNumber, context: nil, characters: shown, charactersIgnoringModifiers: shown,
                                       isARepeat: false, keyCode: code) else { return }
        NSApp.postEvent(e, atStart: false)
    }

    private static func select(_ parts: [String], _ m: EditorModel) {
        let t = (Double(parts.count > 2 ? parts[2] : "") ?? m.time) * 1000
        switch parts.count > 1 ? parts[1] : "" {
        case "section": if let s = TimelineEdits.section(at: t, in: m.project) { m.select(.section(s)) }
        case "scene": if let r = TimelineEdits.sceneRun(at: t, in: m.project) { m.select(.scene(r.span?.id)) }
        case "zoom": if let z = m.project.timeline.zooms.first { m.select(.zoom(z.id)) }
        case "marker": if let k = m.project.timeline.markers.first { m.select(.marker(k.id)) }
        default: m.select(.none)
        }
    }

    /// Hover state for screenshots of handles: `hover cut <s>`, `hover zoomedge`, `hover marker`.
    private static func hover(_ parts: [String], _ m: EditorModel) {
        switch parts.count > 1 ? parts[1] : "" {
        case "cut": let t = (Double(parts.count > 2 ? parts[2] : "") ?? 0) * 1000
            m.hover = TimelineEdits.boundaries(m.project).min { abs($0.ms - t) < abs($1.ms - t) }.map { .cut($0) }
        case "zoomedge": m.hover = m.project.timeline.zooms.first.map { .zoomEdge($0.id, leading: false) }
        case "marker": m.hover = m.project.timeline.markers.first.map { .marker($0.id) }
        default: m.hover = nil
        }
    }

    // MARK: Snapshots

    /// The window with its sheet and popovers composited on top (they are separate windows).
    static func shot(_ name: String, window: NSWindow?) {
        guard let dir = env["EHDR_SNAPSHOT"], let w = window else { return }
        guard let base = image(of: w) else { return }
        let scale = w.backingScaleFactor
        let size = NSSize(width: w.frame.width, height: w.frame.height)
        let out = NSImage(size: size)
        out.lockFocus()
        base.draw(in: NSRect(origin: .zero, size: size))
        var extra = w.childWindows ?? []
        if let s = w.attachedSheet { extra.append(s) }
        for c in extra where c.isVisible {
            guard let img = image(of: c) else { continue }
            let r = NSRect(x: c.frame.minX - w.frame.minX, y: c.frame.minY - w.frame.minY, width: c.frame.width, height: c.frame.height)
            NSGraphicsContext.current?.cgContext.setShadow(offset: CGSize(width: 0, height: -6), blur: 24, color: NSColor.black.withAlphaComponent(0.35).cgColor)
            img.draw(in: r)
        }
        out.unlockFocus()
        guard let tiff = out.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return }
        rep.size = size
        let px = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale), bitsPerSample: 8,
                                  samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        if let px = px {
            px.size = size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: px)
            out.draw(in: NSRect(origin: .zero, size: size))
            NSGraphicsContext.restoreGraphicsState()
            try? px.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
        log("harness: wrote \(name).png")
    }

    private static func image(of w: NSWindow) -> NSImage? {
        guard let v = w.contentView?.superview ?? w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return nil }
        v.cacheDisplay(in: v.bounds, to: rep)
        let img = NSImage(size: v.bounds.size)
        img.addRepresentation(rep)
        return img
    }

    // MARK: Measurements

    /// 120 scrub positions at 60 Hz through the same coalescing path as a ruler drag.
    private static func scrubTest(_ m: EditorModel, done: @escaping () -> Void) {
        m.beginScrub()
        let d = m.duration
        var i = 0
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { timer in
            let x = Double(i) / 119
            m.seek(d * (0.1 + 0.8 * (0.5 - 0.5 * cos(x * .pi * 3))), fast: true)
            i += 1
            if i == 120 {
                timer.invalidate()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    log("harness: scrub test, 120 drag positions at 60 Hz: \(m.scrubStats.summary) while dragging")
                    m.endScrub()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        log("harness: scrub test, exact seek on release: \(m.exactStats.summary)")
                        // Pointer resting mid-drag: an exact seek after each pause.
                        var targets = [0.2, 0.45, 0.7, 0.33, 0.9, 0.12, 0.58, 0.81].map { $0 * d }
                        m.beginScrub()
                        func nextRest() {
                            guard !targets.isEmpty else {
                                m.endScrub()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { log("harness: scrub test, exact seeks after resting: \(m.exactStats.summary)"); done() }
                                return
                            }
                            m.seek(targets.removeFirst(), fast: true)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: nextRest)
                        }
                        nextRest()
                    }
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
    }

    /// Draw cost of the lanes at 120 zoom and scroll positions, rendered offscreen (the screen may be locked, so
    /// this measures the work per frame rather than presented frames).
    @MainActor private static func perfTest(_ m: EditorModel) {
        let layout = TimelineLayout.make(hasMic: m.hasMic)
        let width = max(800, m.axis.width)
        var axis = m.axis; axis.setWidth(width); axis.fit()
        var times: [Double] = []
        let saved = m.axis
        for i in 0..<120 {
            if i < 60 { axis.zoom(by: 1.06, anchorX: width * 0.4) } else { axis.pan(by: 37) }
            m.axis = axis
            let view = LanesSnapshot(model: m, layout: layout).frame(width: width, height: layout.height)
            let r = ImageRenderer(content: view)
            r.scale = 2
            let t0 = CACurrentMediaTime()
            _ = r.cgImage
            times.append(CACurrentMediaTime() - t0)
        }
        m.axis = saved
        let avg = times.reduce(0, +) / Double(times.count) * 1000, worst = (times.max() ?? 0) * 1000
        let sorted = times.sorted(), p95 = sorted[Int(Double(sorted.count) * 0.95)] * 1000
        log(String(format: "harness: lane draw cost over 120 zoom/scroll frames at %.0f pt: average %.2f ms, p95 %.2f ms, worst %.2f ms (60 fps budget 16.7 ms)", width, avg, p95, worst))
    }

    /// Every control the accessibility tree exposes in the window, and the ones without a name.
    private static func axDump(_ w: NSWindow?, verbose: Bool) {
        guard let w = w else { return }
        var named: [String] = [], unnamed: [String] = []
        var seen = Set<ObjectIdentifier>()
        let roles: Set<NSAccessibility.Role> = [.button, .popUpButton, .menuButton, .slider, .checkBox, .radioButton, .textField, .group, .toolbar]
        // What an assistive client sets on the app; SwiftUI builds its accessibility tree once someone asks.
        NSApp.perform(Selector(("accessibilitySetValue:forAttribute:")), with: NSNumber(value: true), with: "AXEnhancedUserInterface")
        func children(_ e: Any) -> [Any] {
            let el = e as? NSAccessibilityProtocol
            var out = el?.accessibilityChildren() ?? []
            if let o = e as? NSObject, o.responds(to: Selector(("accessibilityAttributeValue:"))) {
                for a in [NSAccessibility.Attribute.children, NSAccessibility.Attribute(rawValue: "AXChildrenInNavigationOrder")] {
                    out += (o.perform(Selector(("accessibilityAttributeValue:")), with: a.rawValue)?.takeUnretainedValue() as? NSArray as? [Any]) ?? []
                }
            }
            return out
        }
        func walk(_ e: Any, depth: Int) {
            guard depth < 60, let el = e as? NSAccessibilityProtocol else { return }
            if let role = el.accessibilityRole(), roles.contains(role), role != .group, role != .toolbar {
                let label = el.accessibilityLabel() ?? el.accessibilityTitle() ?? ""
                if label.isEmpty {
                    let f = el.accessibilityFrame()
                    unnamed.append("\(role.rawValue) help=\(el.accessibilityHelp() ?? "-") value=\(String(describing: el.accessibilityValue() ?? "-")) at \(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height)) \(type(of: e))")
                } else { named.append("\(role.rawValue.replacingOccurrences(of: "AX", with: "")): \(label)") }
            }
            for c in children(e) {
                let id = ObjectIdentifier(c as AnyObject)
                if seen.insert(id).inserted { walk(c, depth: depth + 1) }
            }
        }
        walk(w, depth: 0)
        if let host = w.contentView { walk(host, depth: 0) }
        log("harness: accessibility \(named.count) named controls, \(unnamed.count) without a name")
        if verbose { for n in named { log("harness: ax \(n)") } }
        if verbose { for u in unnamed { log("harness: ax UNNAMED \(u)") } }
    }
}

extension Notification.Name { static let harnessShowQueue = Notification.Name("EHDRHarnessShowQueue") }

extension EditorModel {
    /// The window showing this editor (its own or the library's).
    var window: NSWindow? {
        if let w = EditorWindows.shared.window(for: self) { return w }
        if LibraryNavigation.shared.editor === self { return LibraryNavigation.shared.window }
        return nil
    }
}

/// The lanes alone, for offscreen draw timing.
private struct LanesSnapshot: View {
    let model: EditorModel
    let layout: TimelineLayout
    var body: some View {
        ZStack(alignment: .topLeading) {
            RulerLane(model: model).frame(height: layout.lane(.ruler)!.height).offset(y: layout.lane(.ruler)!.y)
            SceneLane(model: model).frame(height: layout.lane(.scenes)!.height).offset(y: layout.lane(.scenes)!.y)
            ZoomLane(model: model).frame(height: layout.lane(.zoom)!.height).offset(y: layout.lane(.zoom)!.y)
            VideoLane(model: model).frame(height: layout.lane(.video)!.height).offset(y: layout.lane(.video)!.y)
            AudioLane(model: model, mic: false).frame(height: layout.lane(.gameAudio)!.height).offset(y: layout.lane(.gameAudio)!.y)
            if let mic = layout.lane(.micAudio) { AudioLane(model: model, mic: true).frame(height: mic.height).offset(y: mic.y) }
            GuidesOverlay(model: model, layout: layout)
        }
        .environment(\.colorScheme, .dark)
    }
}

/// Hooks the harness into the editor view (the export sheet is view state).
struct EditorHarnessHook: View {
    let model: EditorModel
    @Binding var showExport: Bool
    var body: some View {
        Color.clear.onAppear {
            EditorHarness.showExport = { showExport = $0 }
            EditorHarness.editorAppeared(model)
        }
    }
}

/// `AVPlayerLayer` content is not captured by window snapshots. With `EHDR_SNAPSHOT` set, the preview also shows
/// the frame at the playhead rendered by `AVAssetImageGenerator` through the same video composition.
struct SnapshotFrameOverlay: View {
    let model: EditorModel
    @State private var image: CGImage?
    static let enabled = ProcessInfo.processInfo.environment["EHDR_SNAPSHOT"] != nil

    var body: some View {
        if Self.enabled {
            let key = "\(Int(model.time * 1000))|\(model.canvas.rawValue)|\(model.previewRevision)"
            ZStack { if let i = image { Image(decorative: i, scale: 1).resizable() } }
                .allowsHitTesting(false)
                .task(id: key) {
                    try? await Task.sleep(nanoseconds: 120_000_000)
                    guard let item = model.player.currentItem else { return }
                    let g = AVAssetImageGenerator(asset: item.asset)
                    g.videoComposition = item.videoComposition
                    let half = CMTime(value: 1, timescale: 120)
                    g.requestedTimeToleranceBefore = half; g.requestedTimeToleranceAfter = half
                    g.maximumSize = model.canvas.size(.hd)
                    if let img = try? await g.image(at: CMTime(seconds: model.time, preferredTimescale: 60000)).image { image = img }
                }
        }
    }
}
#endif
