import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import VideoToolbox
import Metal
import QuartzCore

/// Also kept in ~/Library/Logs/Elgato HDR.log so a normal (Finder) launch can be diagnosed.
let logFile: FileHandle? = {
    let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/Elgato HDR.log")
    if (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int).map({ $0 > 5_000_000 }) ?? true {
        FileManager.default.createFile(atPath: url.path, contents: nil)
    }
    let h = try? FileHandle(forWritingTo: url); h?.seekToEndOfFile(); return h
}()
func log(_ s: String) {
    let d = (s + "\n").data(using: .utf8)!
    FileHandle.standardError.write(d); logFile?.write(d)
    LogTap.shared.record(s)
}

/// Lets tests read what reached the log, for example to prove that a stream key never does.
final class LogTap: @unchecked Sendable {
    static let shared = LogTap()
    private let lock = NSLock()
    private var lines: [String]?
    func start() { lock.lock(); lines = []; lock.unlock() }
    /// Returns everything logged since `start` and stops collecting.
    func stop() -> [String] { lock.lock(); defer { lines = nil; lock.unlock() }; return lines ?? [] }
    fileprivate func record(_ s: String) { lock.lock(); lines?.append(s); lock.unlock() }
}

func readFully(_ fd: Int32, _ p: UnsafeMutableRawPointer, _ n: Int) -> Bool {
    var got = 0
    while got < n {
        let r = read(fd, p + got, n - got)
        if r == 0 { return false }
        if r < 0 { if errno == EINTR { continue }; return false }
        got += r
    }
    return true
}

