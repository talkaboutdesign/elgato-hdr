import AppKit
import AVFoundation
import SwiftUI

// Wiring between AppDelegate (which does the work) and StudioState (which the studio window reads).
extension AppDelegate {
    /// Property initializers do not run didSet, so the first values are copied once at launch.
    func syncStateFromSettings() {
        state.modeIndex = modeIndex; state.colorMode = colorMode; state.presentation = presentation
        state.placement = livePlacement; state.cameraMirror = cameraMirror
    }

    func installActions() {
        var a = StudioActions()
        a.toggleRecording = { [weak self] in self?.toggleRecording() }
        a.goLive = { [weak self] in self?.showGoLive() }
        a.selectMode = { [weak self] in self?.selectMode(index: $0) }
        a.selectColor = { [weak self] in self?.selectColor(mode: $0) }
        a.selectPresentation = { [weak self] in self?.selectPresentation(mode: $0) }
        a.setMuted = { [weak self] m in guard let self = self, self.audio.muted != m else { return }; self.toggleMute() }
        a.selectCamera = { [weak self] id in
            guard let self = self else { return }
            if let id = id { self.selectCamera(id: id) } else if self.camera.cameraOn { self.toggleCamera() }
        }
        a.selectMic = { [weak self] in self?.selectMic(id: $0) }
        a.setPlacement = { [weak self] in self?.setPlacement($0) }
        a.setShape = { [weak self] in self?.applyShape($0) }
        a.setAspect = { [weak self] in self?.applyAspect($0) }
        a.setPosition = { [weak self] in self?.setPosition(cell: $0) }
        a.setMirror = { [weak self] on in guard let self = self, self.cameraMirror != on else { return }; self.toggleMirror() }
        a.setBorder = { [weak self] on in guard let self = self, self.livePlacement.border != on else { return }; self.toggleBorder() }
        a.setShadow = { [weak self] on in guard let self = self, self.livePlacement.shadow != on else { return }; self.toggleShadow() }
        a.refreshDevices = { [weak self] in self?.syncDevices() }
        a.reconnect = { [weak self] in self?.reconnect() }
        a.showLibrary = { [weak self] in self?.showLibrary() }
        a.toggleSidebar = { [weak self] in self?.toggleSidebar() }
        a.toggleFocus = { [weak self] in self?.toggleFocusMode() }
        state.actions = a
        installStreamActions()
    }

    // MARK: Devices

    /// Device lists and the active camera and microphone. Listing devices needs no permission; the demo camera
    /// never touches AVCaptureDevice at all. Discovery is slow-ish, so this runs on device changes and when the
    /// sidebar or the Camera menu opens, not on every placement change.
    func syncDevices() {
        let cams: [DeviceInfo], mics: [DeviceInfo]
        if demoCamera {
            cams = [DeviceInfo(id: "demo-camera", name: "Demo Camera")]; mics = [DeviceInfo(id: "demo-mic", name: "Demo Microphone")]
        } else {
            cams = CameraCapture.cameras().map { DeviceInfo(id: $0.uniqueID, name: $0.localizedName) }
            mics = CameraCapture.microphones().map { DeviceInfo(id: $0.uniqueID, name: $0.localizedName) }
        }
        if state.cameras != cams { state.cameras = cams }
        if state.microphones != mics { state.microphones = mics }
        syncActiveDevices()
    }

    /// Which camera and microphone are on; cheap enough for every overlay change.
    func syncActiveDevices() {
        let cid = camera.cameraOn ? (demoCamera ? "demo-camera" : cameraID) : nil
        let mid = camera.micOn ? (demoCamera ? "demo-mic" : micID) : nil
        if state.cameraID != cid { state.cameraID = cid }
        if state.micID != mid { state.micID = mid }
    }

    func observeDeviceChanges() {
        guard !demoCamera else { return }
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.syncDevices() }
        }
    }

    /// The mic level is sampled here at 20 Hz rather than published from the audio queue on every buffer.
    func startMeterTimer() {
        let t = Timer(timeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let v = self.camera.micOn ? self.camera.micLevel : 0
            if abs(v - self.state.micLevel) > 0.002 { self.state.micLevel = v }
        }
        RunLoop.main.add(t, forMode: .common)   // keeps moving during window resizes and menu tracking
        meterTimer = t
    }

    // MARK: Messages

    /// Transient message over the picture, replacing the old window-title status text.
    func toast(_ text: String, detail: String? = nil, style: Toast.Style = .info) {
        log("toast: \(text)\(detail.map { " — \($0)" } ?? "")")
        let t = Toast(text: text, detail: detail, style: style)
        withAnimation(DS.Motion.gentle) { state.toast = t }
        DispatchQueue.main.asyncAfter(deadline: .now() + (style == .error ? 6 : 3.5)) { [weak self] in
            guard let self = self, self.state.toast?.id == t.id else { return }
            withAnimation(DS.Motion.gentle) { self.state.toast = nil }
        }
    }

    // MARK: Window chrome

    @objc func toggleSidebar() { studio.toggleSidebar() }
    /// Always the studio window, whichever window is key: focus mode is about the live picture.
    @objc func toggleFocusMode() { window.makeKeyAndOrderFront(nil); window.toggleFullScreen(nil) }

    func window(_ window: NSWindow, willUseFullScreenPresentationOptions proposed: NSApplication.PresentationOptions = []) -> NSApplication.PresentationOptions {
        proposed.union([.autoHideToolbar, .autoHideMenuBar, .fullScreen])
    }

    /// Focus mode is full screen: sidebar and bottom bar step aside so the game fills the display; the toolbar
    /// reveals itself at the top edge. Leaving restores the panels as they were.
    func windowWillEnterFullScreen(_ n: Notification) {
        guard (n.object as? NSWindow) === window else { return }
        log("focus mode: entering full screen")
        enterFocus()
    }

    func enterFocus() {
        focusRestoreSidebar = state.sidebarVisible
        state.focusMode = true
        studio.setSidebar(visible: false, animated: false)
        studio.stage.setFocus(true)
    }
    func windowWillExitFullScreen(_ n: Notification) {
        guard (n.object as? NSWindow) === window else { return }
        log("focus mode: leaving full screen")
        leaveFocus()
    }
    /// A refused transition (another app in front, a locked screen) must not leave the panels hidden.
    func windowDidFailToEnterFullScreen(_ w: NSWindow) { if w === window { log("focus mode: full screen refused"); leaveFocus() } }
    func windowDidEnterFullScreen(_ n: Notification) { if (n.object as? NSWindow) === window { log("focus mode: in full screen") } }
    func windowDidExitFullScreen(_ n: Notification) { if (n.object as? NSWindow) === window { log("focus mode: left full screen") } }

    private func leaveFocus() {
        guard state.focusMode else { return }
        state.focusMode = false
        studio.stage.setFocus(false)
        studio.setSidebar(visible: focusRestoreSidebar, animated: false)
    }

    // MARK: First launch

    /// Called on the main thread right before the administrator prompt. Returns false while the explanation
    /// sheet is up; its buttons restart capture (or switch to the demo source).
    func confirmAdminPromptIfFirstLaunch() -> Bool {
        if UserDefaults.standard.bool(forKey: "helperIntroShown") { return true }
        presentFirstLaunchSheet(preview: false)
        setConnection(.noSignal("Waiting for you to continue"))
        return false
    }

    func presentFirstLaunchSheet(preview: Bool) {
        guard window.attachedSheet == nil else { return }
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 220), styleMask: [.titled], backing: .buffered, defer: false)
        let finish: (Bool) -> Void = { [weak self, weak sheet] demo in
            guard let self = self, let sheet = sheet else { return }
            self.window.endSheet(sheet)
            guard !preview else { return }
            UserDefaults.standard.set(true, forKey: "helperIntroShown")
            if demo { self.demoRequested = true }
            self.start()
        }
        let host = NSHostingController(rootView: FirstLaunchSheet(onContinue: { finish(false) }, onDemo: { finish(true) }))
        host.sizingOptions = [.preferredContentSize]
        sheet.contentViewController = host
        window.beginSheet(sheet)
    }
}
