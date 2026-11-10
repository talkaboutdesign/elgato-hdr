// Streaming wiring: the StreamController (destinations, keys, sessions), the Stream menu, the add/edit sheet, the
// quit and close confirmations while live, and the debug `--go-live-for` flag.
import AppKit
import SwiftUI

extension AppDelegate {
    func makeStreamController() -> StreamController {
        // Agent demo runs point the Keychain service elsewhere so they never touch the user's stream keys.
        #if DEBUG
        let service = ProcessInfo.processInfo.environment["EHDR_KEYCHAIN_SERVICE"].flatMap { $0.isEmpty ? nil : $0 } ?? KeychainStore.streamKeyService
        #else
        let service = KeychainStore.streamKeyService
        #endif
        let c = StreamController(state: state.streaming, keychain: KeychainStore(service: service))
        c.makeSession = { [weak self] outputs, settings in
            guard let self, let renderer = self.renderer else { return nil }
            self.streamMixer.addInput("mic").delayMs = settings.micDelayMs
            let session = StreamSession(outputs: outputs, audioBitrate: settings.audioKbps * 1000, renderer: renderer, mixer: self.streamMixer)
            session.loadPolicy.preference = settings.overloadPolicy
            session.load = { [weak self] in
                guard let self else { return (false, 0) }
                return (self.recorder != nil, Double(self.session?.w ?? 0) * Double(self.session?.h ?? 0) * self.nominalFps)
            }
            session.onRateChange = { [weak self] canvas, divisor, fps in
                guard let self else { return }
                self.state.streaming.reducedRates[canvas] = divisor == 2 ? fps / 2 : nil
                // The log line's wording is parsed by scripts/stream_checks.py; the toast names the canvas as the UI does.
                let name = canvas == .vertical ? "Vertical" : "Horizontal"
                log(divisor == 2 ? "\(name) stream at \(Int(fps / 2)) fps — the video encoder is at capacity" : "\(name) stream restored to \(Int(fps)) fps")
                if divisor == 2 {
                    self.toast("\(canvas.label) stream at \(Int(fps / 2)) fps", detail: "The video encoder is at capacity, so this canvas streams at a lower frame rate.", style: .warning)
                } else {
                    self.toast("\(canvas.label) stream back to \(Int(fps)) fps", style: .success)
                }
            }
            return session
        }
        c.toast = { [weak self] text, detail, style in self?.toast(text, detail: detail, style: style) }
        c.onMicDelay = { [weak self] ms in self?.streamMixer.addInput("mic").delayMs = ms }
        return c
    }

    /// Called from `installActions`, before the window exists.
    func installStreamActions() {
        let c = streamController
        var a = StreamActions()
        a.goLive = { c.goLive() }
        a.endStream = { c.endStream() }
        a.save = { d, key, keepPath, done in c.save(d, key: key, keepPath: keepPath, done: done) }
        a.delete = { c.delete($0) }
        a.setEnabled = { c.setEnabled($0, $1) }
        a.retry = { c.retry($0) }
        a.updateSettings = { c.updateSettings($0) }
        a.testConnection = { d, key, keepPath, done in c.testConnection(d, key: key, keepPath: keepPath, done: done) }
        a.openHelp = { s in if let url = s.preset.helpURL { NSWorkspace.shared.open(url) } }
        a.addDestination = { [weak self] in self?.showStreamTab(); self?.state.streaming.editor = DestinationEditorRequest() }
        a.showStreamTab = { [weak self] in self?.showStreamTab() }
        state.streaming.actions = a
    }

    func addStreamMenu(to main: NSMenu) {
        let item = NSMenuItem(), menu = NSMenu(title: "Stream")
        let toggle = NSMenuItem(title: "Go Live…", action: #selector(showGoLive), keyEquivalent: "l")
        toggle.target = self; toggle.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(toggle)
        let end = NSMenuItem(title: "End Stream", action: #selector(endStreamFromMenu), keyEquivalent: "")
        end.target = self; menu.addItem(end)
        menu.addItem(.separator())
        let add = NSMenuItem(title: "Add Destination…", action: #selector(addDestinationFromMenu), keyEquivalent: "")
        add.target = self; menu.addItem(add)
        let tab = NSMenuItem(title: "Destinations and Settings", action: #selector(showStreamTabFromMenu), keyEquivalent: "")
        tab.target = self; menu.addItem(tab)
        menu.autoenablesItems = false
        item.submenu = menu; main.addItem(item); streamItem = toggle
        let streaming = state.streaming
        trackChanges({ streaming.isActive }) { live in
            toggle.title = live ? "Stream Health…" : "Go Live…"
            end.isEnabled = live
        }
        observeDestinationEditor()
    }

    @objc func showGoLive() {
        window.makeKeyAndOrderFront(nil)
        state.streaming.showGoLivePopover = true
    }
    @objc func endStreamFromMenu() { streamController.endStream() }
    @objc func addDestinationFromMenu() { state.streaming.actions.addDestination() }
    @objc func showStreamTabFromMenu() { showStreamTab() }

    /// Shows the sidebar on its Stream tab (the tab is the sidebar's @AppStorage value).
    func showStreamTab() {
        window.makeKeyAndOrderFront(nil)
        UserDefaults.standard.set(SidebarTab.stream.rawValue, forKey: "sidebarTab")
        if !state.focusMode { studio.setSidebar(visible: true, animated: true) }
    }

    /// Stops a stream without asking (window closes, quit after confirmation).
    func endStream() { if streamController.isActive { streamController.endStream() } }

    // MARK: Add/edit sheet

    /// The sheet is an AppKit sheet on the studio window, so it opens from anywhere (popover, menu, sidebar).
    private func observeDestinationEditor() {
        let streaming = state.streaming
        trackChanges({ streaming.editor }) { [weak self] request in
            guard let self, let request else { return }
            if let open = self.window.attachedSheet {
                guard open.identifier?.rawValue == "destination-sheet" else { return }
                self.window.endSheet(open)
            }
            let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
            sheet.identifier = NSUserInterfaceItemIdentifier("destination-sheet")
            sheet.title = request.destination == nil ? "Add Destination" : "Edit Destination"
            sheet.appearance = NSAppearance(named: .darkAqua)
            let close: () -> Void = { [weak self, weak sheet] in
                guard let self, let sheet else { return }
                self.window.endSheet(sheet)
                if self.state.streaming.editor?.id == request.id { self.state.streaming.editor = nil }
            }
            let host = NSHostingController(rootView: DestinationSheet(streaming: streaming, request: request, close: close)
                .environment(\.colorScheme, .dark))
            host.sizingOptions = [.preferredContentSize]
            sheet.contentViewController = host
            self.window.beginSheet(sheet)
        }
    }

    // MARK: Confirmations

    /// Asks before quitting or closing the live window. Returns true when it is fine to go ahead.
    func confirmEndingStream(_ action: String) -> Bool {
        guard streamController.isActive else { return true }
        let alert = NSAlert()
        alert.messageText = "You are live"
        alert.informativeText = "\(action) ends the stream on every destination."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "End Stream and \(action)")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        streamController.endStream()
        return true
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender === window ? confirmEndingStream("Close") : true
    }

    // MARK: Debug

    #if DEBUG
    /// `EHDR_STREAM_UI="tab@1,sheet:twitch@4,close@8,popover@10"` opens stream UI at the given seconds for
    /// EHDR_SNAPSHOT screenshots, since nobody can click in an agent session. Actions: tab, popover, close,
    /// sheet (service chooser), sheet:<twitch|youtube|kick|custom>, edit:<index>, savekey:<index> (key from
    /// EHDR_DEBUG_SAVE_KEY, stored like the sheet does), delete:<index> (destination and its key).
    func scheduleStreamUIChecks() {
        guard let spec = ProcessInfo.processInfo.environment["EHDR_STREAM_UI"] else { return }
        for step in spec.split(separator: ",") {
            let parts = step.split(separator: "@")
            guard parts.count == 2, let at = Double(parts[1]) else { continue }
            let action = String(parts[0])
            DispatchQueue.main.asyncAfter(deadline: .now() + at) { [weak self] in
                guard let self else { return }
                let s = self.state.streaming
                log("stream UI check: \(action)")
                switch action {
                case "tab": self.showStreamTab()
                case "popover": self.showGoLive()
                case "close":
                    s.showGoLivePopover = false
                    if let sheet = self.window.attachedSheet { self.window.endSheet(sheet) }
                    s.editor = nil
                case "sheet": s.editor = DestinationEditorRequest()
                default:
                    if action.hasPrefix("sheet:"), let service = Destination.Service(rawValue: String(action.dropFirst(6))) {
                        s.editor = DestinationEditorRequest(destination: nil, service: service)
                    } else if action.hasPrefix("edit:"), let i = Int(action.dropFirst(5)), s.destinations.indices.contains(i) {
                        s.editor = DestinationEditorRequest(destination: s.destinations[i])
                    } else if action.hasPrefix("savekey:"), let i = Int(action.dropFirst(8)), s.destinations.indices.contains(i),
                              let key = ProcessInfo.processInfo.environment["EHDR_DEBUG_SAVE_KEY"] {
                        // Through the real save path, so the item belongs to this binary and reads back without a prompt.
                        self.streamController.save(s.destinations[i], key: key) { log("stream UI check: savekey \($0 ?? "ok")") }
                    } else if action.hasPrefix("delete:"), let i = Int(action.dropFirst(7)), s.destinations.indices.contains(i) {
                        self.streamController.delete(s.destinations[i].id)
                    }
                }
            }
        }
    }
    #endif

    /// `--go-live-for <seconds>`: goes live to the stored, enabled destinations after 3 s, ends after the given time
    /// and quits in demo mode. `EHDR_STREAM_KEY` replaces every key on this path only (scripts/stream-selftest.sh),
    /// so the self-test needs no Keychain item; the key is never logged.
    func scheduleStreaming() {
        #if DEBUG
        scheduleStreamUIChecks()
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--go-live-for"), i + 1 < args.count,
              let seconds = Double(args[i + 1]), seconds.isFinite, seconds > 0 else { return }
        if let key = ProcessInfo.processInfo.environment["EHDR_STREAM_KEY"], !key.isEmpty {
            streamController.keyOverride = key
            log("stream: --go-live-for uses EHDR_STREAM_KEY for every destination")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.streamController.goLive()
            if let i = args.firstIndex(of: "--stream-restart-after"), i + 1 < args.count,
               let delay = Double(args[i + 1]), delay > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in log("stream: restarting capture while live (--stream-restart-after)"); self?.start() }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                self?.endStream()
                // terminateLater enters a nested AppKit loop inside this dispatch callback. Finish first
                // so the recording's main-queue completion can run before requesting termination.
                if args.contains("--demo-source") {
                    if self?.recorder != nil { self?.finishRecording { _ in NSApp.terminate(nil) } }
                    else { NSApp.terminate(nil) }
                }
            }
        }
        #endif
    }
}
