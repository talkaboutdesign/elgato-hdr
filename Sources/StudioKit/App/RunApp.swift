import AppKit

private var appDelegate: AppDelegate?
public func runApp() {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let d = AppDelegate(); appDelegate = d; app.delegate = d
    app.run()
}
