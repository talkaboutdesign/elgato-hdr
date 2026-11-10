import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import VideoToolbox
import Metal
import QuartzCore

extension AppDelegate {
    /// Camera/mic failures: permission problems get a blocking alert with a way to System Settings, anything else a toast.
    func deviceResult(_ error: String?) {
        applyOverlay()
        syncDevices()
        log("camera: \(camera.cameraName ?? "off"), microphone: \(camera.micName ?? "off")\(error.map { " — \($0)" } ?? "")")
        guard let error = error else { return }
        let message = error.prefix(1).uppercased() + error.dropFirst()
        let privacy = error.contains("access denied")
        guard privacy else { toast(String(message), detail: "Try another device, or reconnect it.", style: .warning); return }
        let a = NSAlert()
        a.messageText = String(message)
        a.informativeText = "Allow \(AppInfo.name) under System Settings › Privacy & Security, then select the device again."
        a.addButton(withTitle: "OK")
        if privacy { a.addButton(withTitle: "Open Privacy Settings") }
        if a.runModal() == .alertSecondButtonReturn {
            let pane = error.hasPrefix("camera") ? "Privacy_Camera" : "Privacy_Microphone"
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
        }
    }

    func applyOverlay() {
        let rt = sceneRuntime
        if rt.cameraAvailable != camera.cameraOn {
            var old = switchSources()
            if !rt.cameraAvailable { old.removeValue(forKey: .camera) }
            else if old[.camera] == nil { old[.camera] = SourceInfo(size: CGSize(width: 1280, height: 720)) }
            var transition = scenes.collection.transition
            if DS.Motion.reduceMotion && transition.style != .cut { transition = SceneTransition(style: .fade, durationMs: 150) }
            rt.live = rt.live.changingSources(atNs: nowNs(), transition: transition, previous: old)
            rt.cameraAvailable = camera.cameraOn
        }
        renderer?.overlay = LiveOverlay(camera: camera.cameraOn ? camera : nil)
        pushScene()
        view.refreshOverlay()
        syncActiveDevices()
    }
    /// The facecam window now lives in the active scene: this edits its camera layer (`livePlacement` follows).
    func setPlacement(_ p: CameraPlacement) {
        applyCameraPlacement(p)
        applyOverlay()
    }

    @objc func toggleCamera() {
        if demoCamera { return }
        if camera.cameraOn { camera.setCamera(uniqueID: nil) { [weak self] _ in self?.applyOverlay() }; return }
        let id = cameraID.flatMap { id in CameraCapture.cameras().first { $0.uniqueID == id }?.uniqueID } ?? CameraCapture.cameras().first?.uniqueID
        guard let id = id else { toast("No camera found", detail: "Connect a camera, or use Continuity Camera with an iPhone.", style: .warning); return }
        cameraID = id; UserDefaults.standard.set(id, forKey: "cameraID")
        camera.setCamera(uniqueID: id) { [weak self] e in self?.deviceResult(e) }
    }
    @objc func selectCamera(_ sender: NSMenuItem) { if let id = sender.representedObject as? String { selectCamera(id: id) } }
    func selectCamera(id: String) {
        if demoCamera { return }
        if recorder != nil { toast("Stop recording to switch cameras", style: .warning); return }
        cameraID = id; UserDefaults.standard.set(id, forKey: "cameraID")
        camera.setCamera(uniqueID: id) { [weak self] e in self?.deviceResult(e) }
    }
    @objc func selectMic(_ sender: NSMenuItem) { if let id = sender.representedObject as? String { selectMic(id: id.isEmpty ? nil : id) } }
    func selectMic(id: String?) {
        if demoCamera { return }
        if recorder != nil { toast("Stop recording to switch microphones", style: .warning); return }
        micID = id; UserDefaults.standard.set(micID, forKey: "micID")
        log("microphone: selecting \(micID ?? "none")")
        camera.setMicrophone(uniqueID: micID) { [weak self] e in self?.deviceResult(e) }
    }
    @objc func setShape(_ sender: NSMenuItem) { applyShape(CameraShape(rawValue: sender.representedObject as? String ?? "") ?? .rounded) }
    func applyShape(_ shape: CameraShape) { var p = livePlacement; shape.apply(to: &p); setPlacement(p) }
    @objc func setAspect(_ sender: NSMenuItem) { if let a = CameraAspect(rawValue: sender.representedObject as? String ?? "") { applyAspect(a) } }
    func applyAspect(_ a: CameraAspect) {
        var p = livePlacement; p.aspect = a
        if a != .square && p.roundness > 0.3 { p.roundness = 0.16 }   // a circle only makes sense on a square window
        setPlacement(p)
    }
    @objc func setPosition(_ sender: NSMenuItem) { setPosition(cell: sender.tag) }
    func setPosition(cell: Int) {
        guard cell != 4, (0..<9).contains(cell) else { return }
        var p = livePlacement
        let canvas = view.videoRect.size, r = p.rect(in: canvas)
        let anchors = CameraPlacement.anchors(for: r.size, canvas: canvas)   // 8 anchors in row order, centre omitted
        let idx = cell > 4 ? cell - 1 : cell
        if idx < anchors.count { p.move(to: anchors[idx], canvas: canvas, snap: false) }
        setPlacement(p)
    }
    @objc func biggerCamera() { var p = livePlacement; p.size = min(1, p.size * 1.15); setPlacement(p) }
    @objc func smallerCamera() { var p = livePlacement; p.size = max(0.08, p.size / 1.15); setPlacement(p) }
    @objc func toggleMirror() { cameraMirror.toggle(); UserDefaults.standard.set(cameraMirror, forKey: "cameraMirror"); applyCameraMirror(cameraMirror); applyOverlay() }
    @objc func toggleBorder() { var p = livePlacement; p.border.toggle(); setPlacement(p) }
    @objc func toggleShadow() { var p = livePlacement; p.shadow.toggle(); setPlacement(p) }

}
