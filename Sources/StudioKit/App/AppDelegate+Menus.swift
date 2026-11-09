import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import VideoToolbox
import Metal
import QuartzCore

extension AppDelegate {
    func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Elgato HDR", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        // Standard Edit menu so text fields (rename, search) get copy/paste/undo.
        let editItem = NSMenuItem(); main.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        let modeItem = NSMenuItem(); main.addItem(modeItem)
        let modeMenu = NSMenu(title: "Input")
        for (i, m) in modes.enumerated() {
            let it = NSMenuItem(title: m.name, action: #selector(selectMode(_:)), keyEquivalent: i < 9 ? "\(i+1)" : "")
            it.tag = i; modeMenu.addItem(it); modeItems.append(it)
        }
        modeItem.submenu = modeMenu

        let colorItem = NSMenuItem(); main.addItem(colorItem)
        let colorMenu = NSMenu(title: "Color")
        for (name, mode) in [("HDR10 (PQ, BT.2020)", ColorMode.pq), ("HLG (BT.2020)", .hlg), ("SDR (BT.709)", .sdr)] {
            let it = NSMenuItem(title: name, action: #selector(selectColor(_:)), keyEquivalent: "")
            it.representedObject = mode.rawValue; colorMenu.addItem(it); colorItems.append(it)
        }
        colorItem.submenu = colorMenu

        let audioItem = NSMenuItem(); main.addItem(audioItem)
        let audioMenu = NSMenu(title: "Audio")
        muteItem = NSMenuItem(title: "Mute", action: #selector(toggleMute), keyEquivalent: "m")
        audioMenu.addItem(muteItem)
        audioItem.submenu = audioMenu

        let camItem = NSMenuItem(); main.addItem(camItem)
        cameraMenu.delegate = self   // rebuilt on open so device lists stay current
        camItem.submenu = cameraMenu

        let recItem = NSMenuItem(); main.addItem(recItem)
        let recMenu = NSMenu(title: "Record")
        recordItem = NSMenuItem(title: "Start Recording", action: #selector(toggleRecording), keyEquivalent: "r")
        recMenu.addItem(recordItem)
        recMenu.addItem(.separator())
        recMenu.addItem(withTitle: "Recordings Library", action: #selector(showLibraryAction), keyEquivalent: "o")
        recMenu.addItem(withTitle: "Show Recordings in Finder", action: #selector(showRecordings), keyEquivalent: "")
        recItem.submenu = recMenu

        addStreamMenu(to: main)

        let viewItem = NSMenuItem(); main.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Show Live View", action: #selector(showLiveView), keyEquivalent: "0")
        viewMenu.addItem(withTitle: "Toggle Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        viewMenu.addItem(.separator())
        for (name, p, key) in [("Smooth", Presentation.smooth, "j"), ("Game (low latency, no tearing)", .game, "g"), ("Lowest Latency (may tear)", .immediate, "l")] {
            let it = NSMenuItem(title: name, action: #selector(selectPresentation(_:)), keyEquivalent: key)
            it.representedObject = p.rawValue; viewMenu.addItem(it); presentationItems.append(it)
        }
        viewMenu.addItem(.separator())
        let rc = NSMenuItem(title: "Reconnect", action: #selector(reconnect), keyEquivalent: "r"); rc.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(rc)
        viewItem.submenu = viewMenu
        NSApp.mainMenu = main
        populateCameraMenu(cameraMenu)
        refreshChecks()
    }

    func menuNeedsUpdate(_ menu: NSMenu) { if menu === cameraMenu { populateCameraMenu(menu) } }

    func makeCameraMenu(title: String) -> NSMenu { let m = NSMenu(title: title); populateCameraMenu(m); return m }

    /// Camera menu: devices, then the overlay window's look. Also used as the live view's right-click menu.
    func populateCameraMenu(_ m: NSMenu) {
        m.removeAllItems()
        func item(_ title: String, _ sel: Selector, _ key: String = "", on: Bool = false, obj: Any? = nil, enabled: Bool = true) -> NSMenuItem {
            let it = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            it.target = self; it.state = on ? .on : .off; it.representedObject = obj; it.isEnabled = enabled
            m.addItem(it); return it
        }
        _ = item(camera.cameraOn ? "Hide Camera" : "Show Camera", #selector(toggleCamera), "k")
        m.addItem(.separator())
        let camHeader = NSMenuItem(title: "Camera", action: nil, keyEquivalent: ""); camHeader.isEnabled = false; m.addItem(camHeader)
        let cams = demoCamera ? [] : CameraCapture.cameras()
        if cams.isEmpty { _ = item("No cameras found", #selector(noop), enabled: false) }
        for d in cams { _ = item(d.localizedName, #selector(selectCamera(_:)), on: camera.cameraOn && d.uniqueID == cameraID, obj: d.uniqueID) }
        m.addItem(.separator())
        let micHeader = NSMenuItem(title: "Microphone (recorded as its own layer)", action: nil, keyEquivalent: ""); micHeader.isEnabled = false; m.addItem(micHeader)
        _ = item("None", #selector(selectMic(_:)), on: !camera.micOn, obj: "")
        for d in (demoCamera ? [] : CameraCapture.microphones()) { _ = item(d.localizedName, #selector(selectMic(_:)), on: camera.micOn && d.uniqueID == micID, obj: d.uniqueID) }
        m.addItem(.separator())
        let p = livePlacement
        _ = item("Circle", #selector(setShape(_:)), on: p.isCircle, obj: "circle")
        _ = item("Rounded", #selector(setShape(_:)), on: !p.isCircle && p.roundness > 0, obj: "rounded")
        _ = item("Square Corners", #selector(setShape(_:)), on: p.roundness == 0, obj: "square")
        let aspectItem = NSMenuItem(title: "Window Shape", action: nil, keyEquivalent: ""); m.addItem(aspectItem)
        let am = NSMenu()
        for a in CameraAspect.allCases {
            let it = NSMenuItem(title: a.rawValue, action: #selector(setAspect(_:)), keyEquivalent: ""); it.target = self
            it.representedObject = a.rawValue; it.state = p.aspect == a ? .on : .off; am.addItem(it)
        }
        aspectItem.submenu = am
        let posItem = NSMenuItem(title: "Position", action: nil, keyEquivalent: ""); m.addItem(posItem)
        let pm = NSMenu()
        for (name, x, y) in [("Top Left", 0, 0), ("Top", 1, 0), ("Top Right", 2, 0), ("Left", 0, 1), ("Right", 2, 1), ("Bottom Left", 0, 2), ("Bottom", 1, 2), ("Bottom Right", 2, 2)] {
            let it = NSMenuItem(title: name, action: #selector(setPosition(_:)), keyEquivalent: ""); it.target = self
            it.tag = y * 3 + x; pm.addItem(it)
        }
        posItem.submenu = pm
        _ = item("Bigger", #selector(biggerCamera), "=")
        _ = item("Smaller", #selector(smallerCamera), "-")
        m.addItem(.separator())
        _ = item("Mirror", #selector(toggleMirror), on: cameraMirror)
        _ = item("Border", #selector(toggleBorder), on: p.border)
        _ = item("Shadow", #selector(toggleShadow), on: p.shadow)
        m.addItem(.separator())
        _ = item("Drag the camera to move it, drag a corner or scroll to resize", #selector(noop), enabled: false)
    }

    @objc func noop() {}

    func refreshChecks() {
        for it in modeItems { it.state = it.tag == modeIndex ? .on : .off }
        for it in colorItems { it.state = (it.representedObject as? String) == colorMode.rawValue ? .on : .off }
        muteItem?.state = audio.muted ? .on : .off
        for it in presentationItems { it.state = (it.representedObject as? String) == presentation.rawValue ? .on : .off }
    }

    @objc func selectMode(_ sender: NSMenuItem) { modeIndex = sender.tag; UserDefaults.standard.set(modeIndex, forKey: "mode"); refreshChecks(); start() }
    @objc func selectColor(_ sender: NSMenuItem) {
        colorMode = ColorMode(rawValue: sender.representedObject as! String)!; UserDefaults.standard.set(colorMode.rawValue, forKey: "color")
        refreshChecks(); renderer?.colorMode = colorMode
    }
    @objc func toggleMute() { audio.muted.toggle(); UserDefaults.standard.set(audio.muted, forKey: "muted"); refreshChecks(); setTitle(lastInfo) }
    @objc func selectPresentation(_ sender: NSMenuItem) {
        presentation = Presentation(rawValue: sender.representedObject as! String)!; UserDefaults.standard.set(presentation.rawValue, forKey: "presentation")
        refreshChecks(); renderer?.presentation = presentation
    }
    @objc func reconnect() { start() }

}
