import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import VideoToolbox
import Metal
import QuartzCore

// MARK: - App

/// Does the work: capture, camera, recording, menus. The studio window reads `state` and asks for things through
/// `state.actions`, which call the same methods as the menus. Every property the UI shows is mirrored into `state`
/// on the main thread (the didSets below).
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    let state = StudioState()
    var studio: StudioWindowController!
    var window: NSWindow!
    var view: MetalView!
    var renderer: Renderer!
    var shm: UnsafeMutableRawPointer?
    var demoSource: DemoSource?
    var demoRequested = false          // "Try the Demo Source" on the first-launch sheet
    let demoCamera = CommandLine.arguments.contains("--demo-camera")
    let streamMixer = AudioMixer()
    lazy var streamController = makeStreamController()
    var streamItem: NSMenuItem?
    var session: Session?
    var modeIndex = min(max(UserDefaults.standard.integer(forKey: "mode"), 0), modes.count - 1) { didSet { state.modeIndex = modeIndex } }   // also accepts `-mode N` on the command line
    var colorMode = ColorMode(rawValue: UserDefaults.standard.string(forKey: "color") ?? "pq") ?? .pq { didSet { state.colorMode = colorMode } }
    var presentation = Presentation(rawValue: UserDefaults.standard.string(forKey: "presentation") ?? "")
        ?? (UserDefaults.standard.bool(forKey: "lowLatency") ? .immediate : .smooth) { didSet { state.presentation = presentation } }
    var modeItems: [NSMenuItem] = [], colorItems: [NSMenuItem] = []
    let audio = AudioPlayer()
    var muteItem: NSMenuItem!, recordItem: NSMenuItem!, sidebarItem: NSMenuItem!
    var presentationItems: [NSMenuItem] = []
    var recorder: Recorder?
    var recStart = Date()
    var recTimer: Timer?
    var meterTimer: Timer?
    var deviceObservers: [NSObjectProtocol] = []
    var measuredFps: Double = 30
    var lastInfo = ""
    var panels = PanelLayout()         // sidebar across focus mode
    var galleryWindow: NSWindow?

    // Facecam + microphone layers
    let camera = CameraCapture()
    var cameraMenu = NSMenu(title: "Camera")
    var cameraID = UserDefaults.standard.string(forKey: "cameraID")
    var micID = UserDefaults.standard.string(forKey: "micID")
    var cameraMirror = UserDefaults.standard.bool(forKey: "cameraMirror") { didSet { state.cameraMirror = cameraMirror } }
    var livePlacement: CameraPlacement = {
        if let d = UserDefaults.standard.data(forKey: "livePlacement"), let p = try? JSONDecoder().decode(CameraPlacement.self, from: d) { return p }
        return CameraPlacement()
    }() { didSet { state.placement = livePlacement } }
    var recDoc: ProjectDoc?
    var camWriter: LayerWriter?, micWriter: LayerWriter?
    /// Folder of the recording in progress. Setting it registers the folder in `recordingDirs`, where it stays until
    /// `recordingFinalized`: a new recording can start while the previous one's writers are still finishing.
    static var activeRecordingDir: URL? { didSet { if let d = activeRecordingDir { recordingDirs.insert(recordingKey(d)) } } }
    /// Folders recording or still finalizing, which library recovery must leave alone. Keyed by path: folder URLs
    /// listed from disk carry a trailing slash, the one `newProjectDir` returns does not. Main thread only.
    static var recordingDirs = Set<String>()
    static func recordingKey(_ dir: URL) -> String { dir.standardizedFileURL.path }
    static func isRecording(_ dir: URL) -> Bool { recordingDirs.contains(recordingKey(dir)) }
    static func recordingFinalized(_ dir: URL) {
        recordingDirs.remove(recordingKey(dir))
        if let d = activeRecordingDir, recordingKey(d) == recordingKey(dir) { activeRecordingDir = nil }
    }
    var libraryWindow: NSWindow?

    func applicationDidFinishLaunching(_ n: Notification) {
        view = MetalView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720))
        syncStateFromSettings()
        installActions()
        studio = StudioWindowController(state: state, metalView: view)
        window = studio.window
        window.delegate = self
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        audio.muted = UserDefaults.standard.bool(forKey: "muted"); state.muted = audio.muted
        // Development: `--export <project folder> [hdr|sdr] [hd|uhd]` renders both canvases and quits (no capture).
        if let i = CommandLine.arguments.firstIndex(of: "--export"), i + 1 < CommandLine.arguments.count {
            let args = CommandLine.arguments
            runHeadlessExport(dir: URL(fileURLWithPath: args[i + 1]), range: args.contains("sdr") ? .sdr : .hdr, res: args.contains("uhd") ? .uhd : .hd)
            return
        }
        #if DEBUG
        if let i = CommandLine.arguments.firstIndex(of: "--make-fixture"), i+1 < CommandLine.arguments.count {
            let arg = CommandLine.arguments[i+1]
            let dir = arg.hasPrefix("/") ? URL(fileURLWithPath: arg) : Self.recordingsDir.appendingPathComponent(arg)
            headless = true
            Task {
                do { let doc = try await FixtureProject.make(at: dir); log("fixture: \(doc.dir.path)"); exit(0) }
                catch { log("fixture failed: \(error)"); exit(1) }
            }
            return
        }
        #endif
        view.placement = { [weak self] in
            guard let self = self, self.camera.cameraOn else { return nil }
            return self.livePlacement
        }
        view.onPlacement = { [weak self] p in self?.setPlacement(p) }
        view.contextMenu = { [weak self] in self?.makeCameraMenu(title: "Camera") }
        camera.onState = { [weak self] in self?.syncDevices() }
        buildMenu()
        startMeterTimer()
        observeDeviceChanges()
        if CommandLine.arguments.contains("--no-capture") { setConnection(.noSignal("Capture is off (--no-capture)")) } else { start() }
        let micInput = streamMixer.addInput("mic")
        camera.onMicAudio = { buffer, ns in micInput.push(buffer, endHostNs: ns) }
        if demoCamera { camera.injectDemo(); applyOverlay() }
        if !demoCamera && cameraID != nil { camera.setCamera(uniqueID: cameraID) { [weak self] e in self?.deviceResult(e) } }
        if !demoCamera && micID != nil { camera.setMicrophone(uniqueID: micID) { [weak self] e in self?.deviceResult(e) } }
        syncDevices()
        if CommandLine.arguments.contains("--fullscreen") { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.window.toggleFullScreen(nil) } }
        if CommandLine.arguments.contains("--library") { showLibrary() }
        scheduleStreaming()
        #if DEBUG
        if CommandLine.arguments.contains("--design-gallery") { galleryWindow = DesignGallery.open() }
        if CommandLine.arguments.contains("--first-launch-sheet") {
            // Shows the sheet for screenshots only: neither button can reach the administrator prompt from here.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.presentFirstLaunchSheet(preview: true) }
        }
        DebugSnapshots.start()
        startDebugChecks()
        #endif
        if let i = CommandLine.arguments.firstIndex(of: "--record"), i + 1 < CommandLine.arguments.count, let secs = Double(CommandLine.arguments[i + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                self?.startRecording()
                DispatchQueue.main.asyncAfter(deadline: .now() + secs) { self?.stopRecording() }
            }
        }
    }

    var headless = false

    /// Statistics and connection state from the capture session; the window title stays the app name.
    func setStatus(_ info: String) {
        lastInfo = info
        if info == "stream ended" { setConnection(.noSignal("The stream ended")); return }
        if info.hasPrefix("helper too old") { setConnection(.noSignal("The capture helper is out of date: quit and reopen the app")); return }
        guard let s = session, s.w > 0, let stats = StudioFormat.parseStats(info) else { return }
        state.applyStats(width: s.w, height: s.h, fps: StudioFormat.nominalFps(measured: stats.fps, nominal: nominalFps), latencyMs: stats.latencyMs, demo: demoSource != nil)
    }

    var nominalFps: Double { demoSource?.fps ?? modes[modeIndex].fps }

    func setConnection(_ c: Connection) {
        if state.connection != c { state.connection = c }
        if case .connecting = c { state.signal = ""; state.shortSignal = ""; state.latencyMs = 0 }
    }

    func start() {
        if recorder != nil { stopRecording() }
        session?.stop(); session = nil
        let mode = modes[modeIndex]
        setConnection(.connecting)
        let wantDemo = demoRequested
        DispatchQueue.global().async { [weak self] in
            let demo: DemoSource?
            if let (w,h,f) = DemoSource.configuration(CommandLine.arguments) { demo = DemoSource(width: w, height: h, fps: f) }
            else if wantDemo { demo = DemoSource(width: 2560, height: 1440, fps: 60) }
            else { demo = nil }
            var fd = demo.map { dup($0.readFD) } ?? connectHelper()
            if fd < 0 {
                // Only the real card path gets here: a demo source always yields a descriptor.
                precondition(demo == nil)
                var proceed = false
                DispatchQueue.main.sync { proceed = self?.confirmAdminPromptIfFirstLaunch() ?? false }
                guard proceed else { return }   // the first-launch sheet restarts capture when answered
                var spawned = false
                DispatchQueue.main.sync { spawned = spawnHelperWithAdminPrompt() }
                if !spawned { DispatchQueue.main.async { self?.setConnection(.noSignal("The helper was not started (password prompt cancelled)")) }; return }
                for _ in 0..<50 { usleep(200_000); fd = connectHelper(); if fd >= 0 { break } }
            }
            guard fd >= 0 else { DispatchQueue.main.async { self?.setConnection(.noSignal("The capture helper is not reachable")) }; return }
            guard let self = self else { return }
            if let demo = demo {
                self.demoSource?.stop()
                self.demoSource = demo; self.shm = demo.memory
                DispatchQueue.main.sync { self.renderer?.displayLink?.invalidate(); self.renderer = nil }
            }
            if self.shm == nil { self.shm = mapSharedFrames() }
            guard let shm = self.shm else { DispatchQueue.main.async { self.setConnection(.noSignal("Shared memory unavailable (old helper?)")) }; close(fd); return }
            DispatchQueue.main.sync {
                if self.renderer == nil {
                    self.renderer = Renderer(layer: self.view.metalLayer, shm: shm, demoSource: demo)
                    self.renderer?.colorMode = self.colorMode; self.renderer?.presentation = self.presentation
                    self.view.updateDrawableSize()
                    self.renderer?.attachDisplayLink(view: self.view)
                    self.applyOverlay()
                    if let renderer = self.renderer { self.streamController.replaceRenderer(renderer) }
                }
            }
            guard let renderer = self.renderer else { DispatchQueue.main.async { self.setConnection(.noSignal("Metal is unavailable")) }; close(fd); return }
            let cmd = "START 7 \(mode.frame) \(mode.fps) SHM\n"
            if let demo = demo { demo.start() } else { _ = cmd.withCString { write(fd, $0, strlen($0)) } }
            renderer.resetPacing()
            let s = Session(fd: fd, renderer: renderer, shm: shm)
            s.audio = self.audio
            let gameInput = self.streamMixer.addInput("game")
            s.onGameAudio = { bytes, count, ns in gameInput.pushInt16Stereo(bytes, byteCount: count, endHostNs: ns) }
            s.onInfo = { [weak self] info in DispatchQueue.main.async {
                if let r = info.range(of: #"([0-9.]+) fps"#, options: .regularExpression), let v = Double(info[r].dropLast(4)) { self?.measuredFps = v }
                if let self = self, s.w > 0, self.view.videoSize != CGSize(width: s.w, height: s.h) {
                    self.view.videoSize = CGSize(width: s.w, height: s.h)
                }
                self?.setStatus(info) } }
            DispatchQueue.main.async { self.session = s }
            s.run()
        }
    }
    /// Closing the live view stops capture (and any recording) but keeps the library and editors open.
    func windowWillClose(_ n: Notification) {
        guard (n.object as? NSWindow) === window else { return }
        if recorder != nil { stopRecording() }
        endStream()
        session?.stop(); session = nil
        audio.stop()
        setConnection(.noSignal("Capture stopped"))
    }
    @objc func showLiveView() {
        window.makeKeyAndOrderFront(nil)
        if session == nil { start() }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { !headless }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showLiveView() }
        return true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard confirmEndingStream("Quit") else { return .terminateCancel }
        endStream()
        guard recorder != nil else { return .terminateNow }
        finishRecording { _ in NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
    func applicationWillTerminate(_ n: Notification) { stopStudioObservers(); endStream(); session?.stop(); demoSource?.stop() }
}
