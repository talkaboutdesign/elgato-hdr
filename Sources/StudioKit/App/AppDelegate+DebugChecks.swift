#if DEBUG
import AppKit

/// Development checks that need no clicks (agents and CI cannot use the GUI):
/// `EHDR_MENU_TEST=1` performs every item of the app's menus through NSMenu, as a click would, and logs the state
/// before and after; `EHDR_RESIZE_TEST=<seconds>` resizes the studio window continuously.
extension AppDelegate {
    func startDebugChecks() {
        let env = ProcessInfo.processInfo.environment
        if env["EHDR_MENU_TEST"] != nil { DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.runMenuTest() } }
        // The focus-mode layout without the full-screen transition, which a locked or headless session refuses.
        if env["EHDR_FOCUS_LAYOUT"] != nil { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.enterFocus() } }
        if let s = env["EHDR_RESIZE_TEST"].flatMap(Double.init) { DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.runResizeTest(seconds: s) } }
    }

    var debugSummary: String {
        let p = state.placement
        return String(format: "mode=%d color=%@ pres=%@ muted=%d rec=%d cam=%d shape=%@ aspect=%@ size=%.3f pos=(%.2f,%.2f) mirror=%d border=%d shadow=%d sidebar=%d focus=%d library=%d live=%d",
                      state.modeIndex, state.colorMode.rawValue, state.presentation.rawValue, state.muted ? 1 : 0, state.recording ? 1 : 0,
                      state.cameraOn ? 1 : 0, CameraShape(p).rawValue, p.aspect.rawValue, p.size, p.x, p.y, state.cameraMirror ? 1 : 0,
                      p.border ? 1 : 0, p.shadow ? 1 : 0, state.sidebarVisible ? 1 : 0, state.focusMode ? 1 : 0,
                      libraryWindow?.isVisible == true ? 1 : 0, window.isVisible ? 1 : 0)
    }

    /// Items not performed: Quit (ends the test), Show Recordings in Finder (opens Finder), Edit items (need a
    /// text field), Hide/Show Camera with the demo camera (a no-op there by design). Their wiring is still checked.
    func runMenuTest() {
        populateCameraMenu(cameraMenu)
        var items: [(NSMenuItem, String)] = []
        func walk(_ m: NSMenu, _ path: String) {
            for it in m.items where !it.isSeparatorItem {
                if let sub = it.submenu { walk(sub, "\(path) › \(it.title)"); continue }
                items.append((it, path))
            }
        }
        for top in NSApp.mainMenu?.items ?? [] { if let sub = top.submenu { walk(sub, sub.title.isEmpty ? "App" : sub.title) } }
        let skip: Set<String> = ["Quit \(AppInfo.name)", "Show Recordings in Finder", "Undo", "Redo", "Cut", "Copy", "Paste", "Select All", "Hide Camera", "Show Camera"]
        var queue = items
        // Record toggles: perform Start once more at the end to stop the recording it started.
        if let rec = items.first(where: { $0.0 === recordItem }) { queue.append(rec) }
        log("menu-test: \(items.count) items, start \(debugSummary)")
        func next() {
            guard !queue.isEmpty else { log("menu-test: done \(debugSummary)"); return }
            let (it, path) = queue.removeFirst()
            let name = "\(path) › \(it.title)"
            guard let action = it.action, it.isEnabled else { log("menu-test: \(name): no action (label)"); next(); return }
            let target = NSApp.target(forAction: action, to: it.target, from: it)
            if skip.contains(it.title) {
                log("menu-test: \(name): skipped, wired to \(target.map { String(describing: type(of: $0)) } ?? "nothing") (\(action))")
                next(); return
            }
            let before = debugSummary
            guard let menu = it.menu else { next(); return }
            menu.performActionForItem(at: menu.index(of: it))
            let wait = it === recordItem ? 3.0 : it.title.contains("Full Screen") ? 2.5 : 0.5
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                guard let self = self else { return }
                let after = self.debugSummary
                log("menu-test: \(name) [\(action)]: \(before == after ? "no state change" : diff(before, after))")
                next()
            }
        }
        func diff(_ a: String, _ b: String) -> String {
            zip(a.split(separator: " "), b.split(separator: " ")).filter { $0 != $1 }.map { "\($0) -> \($1.split(separator: "=").last ?? "")" }.joined(separator: ", ")
        }
        next()
    }

    func runResizeTest(seconds: Double) {
        guard let screen = window.screen?.visibleFrame else { return }
        let start = Date(), origin = window.frame.origin
        var steps = 0
        log("resize-test: start \(window.frame)")
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            let e = Date().timeIntervalSince(start)
            if e > seconds {
                timer.invalidate()
                log(String(format: "resize-test: done, %d steps, frame %@, video %@, stage %@", steps,
                           NSStringFromRect(self.window.frame), NSStringFromRect(self.view.frame), NSStringFromRect(self.studio.stage.view.frame)))
                return
            }
            let w = max(960, min(screen.width, 1200 + 500 * sin(e * 2.1)))
            let h = max(600, min(screen.height, 780 + 260 * sin(e * 1.3 + 1)))
            self.window.setFrame(NSRect(x: origin.x, y: max(screen.minY, origin.y), width: w, height: h), display: true)
            steps += 1
        }
        RunLoop.main.add(t, forMode: .common)
    }
}
#endif
