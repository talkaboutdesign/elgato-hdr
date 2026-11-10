import AppKit
import ObjectiveC

/// Development runs on a machine someone is using: with `EHDR_BACKGROUND=1` (debug builds) the app never activates
/// and every window it shows is transparent, ignores the pointer and sits off-screen, so a scripted run can neither
/// cover nor take input from anyone's windows. Window snapshots (`EHDR_SNAPSHOT`, the editor harness) still work: they
/// draw the views, not the screen.
enum BackgroundWindows {
    private(set) static var active = false

    #if DEBUG
    static func installIfRequested() {
        guard !active, ProcessInfo.processInfo.environment["EHDR_BACKGROUND"] == "1" else { return }
        active = true
        // Every way of showing a window ends in `orderWindow(_:relativeTo:)`; hide the window before it goes on screen.
        let cls: AnyClass = NSWindow.self
        guard let original = class_getInstanceMethod(cls, #selector(NSWindow.order(_:relativeTo:))),
              let replacement = class_getInstanceMethod(cls, #selector(NSWindow.ehdr_backgroundOrder(_:relativeTo:))) else { return }
        method_exchangeImplementations(original, replacement)
        for w in NSApp.windows { w.ehdr_hide() }
        log("background: windows stay transparent and off-screen; the app does not activate")
    }
    #endif
}

#if DEBUG
extension NSWindow {
    func ehdr_hide() {
        alphaValue = 0; ignoresMouseEvents = true; hasShadow = false
        setFrameOrigin(NSPoint(x: -40_000, y: -40_000))
    }
    @objc func ehdr_backgroundOrder(_ place: NSWindow.OrderingMode, relativeTo other: Int) {
        if place != .out { ehdr_hide() }
        ehdr_backgroundOrder(place, relativeTo: other)    // the original, after the exchange
    }
}
#endif
