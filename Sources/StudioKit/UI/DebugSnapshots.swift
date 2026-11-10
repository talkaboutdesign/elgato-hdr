import AppKit
import AVFoundation
import SwiftUI

#if DEBUG
/// Development aid: EHDR_SNAPSHOT=<dir> writes PNGs of the app's windows every few seconds (layer-backed video
/// content excluded); EHDR_OPEN=<n> opens the n-th library item in the editor.
enum DebugSnapshots {
    static func start() {
        let env = ProcessInfo.processInfo.environment
        EditorHarness.start()
        if let n = env["EHDR_OPEN"].flatMap(Int.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                Library.shared.reload()
                if n < Library.shared.docs.count { EditorWindows.shared.open(Library.shared.docs[n]) }
            }
        }
        guard let dir = env["EHDR_SNAPSHOT"] else { return }
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            for (i, w) in NSApp.windows.enumerated() where w.isVisible {
                guard let v = w.contentView?.superview ?? w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { continue }
                v.cacheDisplay(in: v.bounds, to: rep)
                let name = w.title.isEmpty ? "window\(i)" : w.title.replacingOccurrences(of: "/", with: "-")
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
            }
        }
    }
}
#endif
