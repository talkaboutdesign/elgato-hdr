import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import VideoToolbox
import Metal
import QuartzCore

let socketPath = "/tmp/elgato-uvc.sock"
let shmName = "/elgato-uvc-frames"
let shmSlots = 3
let shmSlotBytes = 24883200

// MARK: - Helper process management

func connectHelper() -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
    _ = withUnsafeMutablePointer(to: &addr.sun_path) { p in
        p.withMemoryRebound(to: CChar.self, capacity: 104) { strncpy($0, socketPath, 103) }
    }
    let r = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    if r != 0 { close(fd); return -1 }
    var sz: Int32 = 1 << 20
    setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &sz, socklen_t(MemoryLayout<Int32>.size))
    return fd
}

func spawnHelperWithAdminPrompt() -> Bool {
    guard let helper = Bundle.main.url(forResource: "uvc_capture", withExtension: nil, subdirectory: nil)?.path
        ?? Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("uvc_capture").path else { return false }
    let quoted = "'" + helper.replacingOccurrences(of: "'", with: "'\\''") + "'"
    let shell = "\(quoted) --serve \(socketPath) --idle 20 >/dev/null 2>>/tmp/elgato-uvc.log &"
    let script = "do shell script \"\(shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
    var err: NSDictionary?
    NSAppleScript(source: script)?.executeAndReturnError(&err)
    if let err = err { log("admin launch failed: \(err)"); return false }
    return true
}

func mapSharedFrames() -> UnsafeMutableRawPointer? {
    // shm_open is variadic (unavailable to Swift); without O_CREAT the mode argument is ignored, so a 2-arg call is safe.
    typealias ShmOpen2 = @convention(c) (UnsafePointer<CChar>, Int32) -> Int32
    guard let sym = dlsym(dlopen(nil, RTLD_NOW), "shm_open") else { return nil }
    let shmOpen = unsafeBitCast(sym, to: ShmOpen2.self)
    let fd = shmOpen(shmName, O_RDWR)
    if fd < 0 { return nil }
    defer { close(fd) }
    let total = shmSlots * shmSlotBytes
    let p = mmap(nil, total, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
    return p == MAP_FAILED ? nil : p
}

