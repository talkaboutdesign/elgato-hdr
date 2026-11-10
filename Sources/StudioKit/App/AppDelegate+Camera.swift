import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import VideoToolbox
import Metal
import QuartzCore

extension AppDelegate {
    /// Camera/mic changes report failures in an alert: the title is rewritten every second by the stream stats.
    func deviceResult(_ error: String?) {
        applyOverlay()
        log("camera: \(camera.cameraName ?? "off"), microphone: \(camera.micName ?? "off")\(error.map { " — \($0)" } ?? "")")
        guard let error = error else { return }
        let a = NSAlert()
        a.messageText = error.prefix(1).uppercased() + error.dropFirst()
        let privacy = error.contains("access denied")
        a.informativeText = privacy ? "Allow Elgato HDR under System Settings › Privacy & Security, then select the device again." : "Try another device, or reconnect it."
        a.addButton(withTitle: "OK")
        if privacy { a.addButton(withTitle: "Open Privacy Settings") }
        if a.runModal() == .alertSecondButtonReturn {
            let pane = error.hasPrefix("camera") ? "Privacy_Camera" : "Privacy_Microphone"
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
        }
    }

    func applyOverlay() {
        renderer?.overlay = LiveOverlay(camera: camera.cameraOn ? camera : nil, placement: livePlacement, mirror: cameraMirror)
        view.updateOutline()
        setTitle(lastInfo)
    }
    func setPlacement(_ p: CameraPlacement) {
        livePlacement = p
        if let d = try? JSONEncoder().encode(p) { UserDefaults.standard.set(d, forKey: "livePlacement") }
        applyOverlay()
    }

    @objc func toggleCamera() {
        if demoCamera { return }
        if camera.cameraOn { camera.setCamera(uniqueID: nil) { [weak self] _ in self?.applyOverlay() }; return }
        let id = cameraID.flatMap { id in CameraCapture.cameras().first { $0.uniqueID == id }?.uniqueID } ?? CameraCapture.cameras().first?.uniqueID
        guard let id = id else { setTitle("no camera found"); return }
        cameraID = id; UserDefaults.standard.set(id, forKey: "cameraID")
        camera.setCamera(uniqueID: id) { [weak self] e in self?.deviceResult(e) }
    }
    @objc func selectCamera(_ sender: NSMenuItem) {
        if demoCamera { return }
        guard let id = sender.representedObject as? String else { return }
        if recorder != nil { setTitle("stop recording to switch cameras"); return }
        cameraID = id; UserDefaults.standard.set(id, forKey: "cameraID")
        camera.setCamera(uniqueID: id) { [weak self] e in self?.deviceResult(e) }
    }
    @objc func selectMic(_ sender: NSMenuItem) {
        if demoCamera { return }
        guard let id = sender.representedObject as? String else { return }
        if recorder != nil { setTitle("stop recording to switch microphones"); return }
        micID = id.isEmpty ? nil : id; UserDefaults.standard.set(micID, forKey: "micID")
        log("microphone: selecting \(micID ?? "none")")
        camera.setMicrophone(uniqueID: micID) { [weak self] e in self?.deviceResult(e) }
    }
    @objc func setShape(_ sender: NSMenuItem) {
        var p = livePlacement
        switch sender.representedObject as? String {
        case "circle": p.aspect = .square; p.roundness = 0.5
        case "square": p.roundness = 0
        default: p.roundness = 0.16
        }
        setPlacement(p)
    }
    @objc func setAspect(_ sender: NSMenuItem) {
        guard let a = CameraAspect(rawValue: sender.representedObject as? String ?? "") else { return }
        var p = livePlacement; p.aspect = a
        if a != .square && p.roundness > 0.3 { p.roundness = 0.16 }   // a circle only makes sense on a square window
        setPlacement(p)
    }
    @objc func setPosition(_ sender: NSMenuItem) {
        var p = livePlacement
        let canvas = view.videoRect.size, r = p.rect(in: canvas)
        let anchors = CameraPlacement.anchors(for: r.size, canvas: canvas)   // 8 anchors in row order, centre omitted
        let idx = sender.tag > 4 ? sender.tag - 1 : sender.tag
        if idx < anchors.count { p.move(to: anchors[idx], canvas: canvas, snap: false) }
        setPlacement(p)
    }
    @objc func biggerCamera() { var p = livePlacement; p.size = min(1, p.size * 1.15); setPlacement(p) }
    @objc func smallerCamera() { var p = livePlacement; p.size = max(0.08, p.size / 1.15); setPlacement(p) }
    @objc func toggleMirror() { cameraMirror.toggle(); UserDefaults.standard.set(cameraMirror, forKey: "cameraMirror"); applyOverlay() }
    @objc func toggleBorder() { var p = livePlacement; p.border.toggle(); setPlacement(p) }
    @objc func toggleShadow() { var p = livePlacement; p.shadow.toggle(); setPlacement(p) }

}
