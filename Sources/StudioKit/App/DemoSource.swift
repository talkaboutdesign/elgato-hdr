import Foundation
import Darwin
import AVFoundation

/// Synthetic helper: timestamps, slot layout and socket framing are identical to the hardware path.
final class DemoSource {
    let width: Int, height: Int, fps: Double
    let memory: UnsafeMutableRawPointer
    let readFD: Int32
    private let writeFD: Int32
    private let queue = DispatchQueue(label: "demo-source")
    private let lock = NSLock()
    private let queueKey = DispatchSpecificKey<Bool>()
    private var running = false
    private var started = false
    private let background: [UInt16]
    static var epoch: UInt64 = 0

    init(width: Int, height: Int, fps: Double) {
        precondition(width > 0 && height > 0 && width % 2 == 0 && height % 2 == 0 && width * height * 3 <= shmSlotBytes && fps > 0 && fps <= 240)
        self.width = width; self.height = height; self.fps = fps
        let p = mmap(nil, shmSlots * shmSlotBytes, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0)
        precondition(p != MAP_FAILED); memory = p!
        var fds: [Int32] = [0, 0]
        precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        readFD = fds[0]; writeFD = fds[1]
        var one: Int32 = 1
        setsockopt(writeFD, SOL_SOCKET, SO_NOSIGPIPE, &one, 4)
        // BT.2020 YCbCr from PQ-coded RGB bars (white is 1000 nits).
        let bars: [(Double, Double, Double)] = [(0.752,0.752,0.752),(0.752,0.752,0),(0,0.752,0.752),(0,0.752,0),(0.752,0,0.752),(0.752,0,0),(0,0,0.752),(0,0,0)]
        var bg = [UInt16](repeating: 512 << 6, count: width * height * 3 / 2)
        for y in 0..<height {
            for x in 0..<width {
                let rgb = bars[min(7, x * 8 / width)]
                let l = y < height / 2 ? 0.2627 * rgb.0 + 0.6780 * rgb.1 + 0.0593 * rgb.2 : Double(x) / Double(width - 1) * 0.752
                bg[y * width + x] = UInt16((64 + 876 * l).rounded()) << 6
                if y < height / 2 && y % 2 == 0 && x % 2 == 0 {
                    let i = width * height + y / 2 * width + x
                    bg[i] = UInt16((512 + 896 * (rgb.2 - l) / 1.8814).rounded()) << 6
                    bg[i+1] = UInt16((512 + 896 * (rgb.0 - l) / 1.4746).rounded()) << 6
                }
            }
        }
        background = bg
        // Fault in all slots before pacing starts, so first-use VM work cannot delay a frame.
        bg.withUnsafeBytes { bytes in
            for slot in 0..<shmSlots { memcpy(memory + slot * shmSlotBytes, bytes.baseAddress!, width * height * 3) }
        }
        queue.setSpecific(key: queueKey, value: true)
    }

    deinit { stop(); close(readFD); close(writeFD); munmap(memory, shmSlots * shmSlotBytes) }
    func start() {
        lock.lock()
        guard !started else { lock.unlock(); return }
        started = true; running = true
        let epoch = nowNs(); Self.epoch = epoch
        lock.unlock()
        queue.async { [self] in run(epoch: epoch) }
    }
    func stop() {
        lock.lock(); running = false; lock.unlock()
        shutdown(writeFD, SHUT_RDWR)
        if DispatchQueue.getSpecific(key: queueKey) == nil { queue.sync {} }
    }
    private var active: Bool { lock.lock(); defer { lock.unlock() }; return running }

    /// Copy the static picture, then touch only moving rectangles. Also used by the fixture writer.
    func fill(_ dst: UnsafeMutableRawPointer, frame: Int) {
        background.withUnsafeBytes { memcpy(dst, $0.baseAddress!, width * height * 3) }
        let y = dst.assumingMemoryBound(to: UInt16.self)
        let c = y + width * height
        func rect(_ x: Int, _ top: Int, _ w: Int, _ h: Int, _ code: UInt16) {
            let luma = (code << 6).littleEndian, neutral = UInt16(512 << 6).littleEndian
            for row in top..<min(height, top+h) {
                (y + row * width + x).update(repeating: luma, count: min(width, x+w)-x)
            }
            let left = x/2*2, right = min(width, (x+w+1)/2*2)
            for row in top/2..<min(height/2, (top+h+1)/2) {
                (c + row * width + left).update(repeating: neutral, count: right-left)
            }
        }
        let phase = Double(frame) / fps
        let side = max(2, height / 12)
        rect(Int(phase.truncatingRemainder(dividingBy: 1) * Double(width-side)), height*3/4, side, side, 940)
        let flash = frame == Int(ceil(floor(phase) * fps))
        for bit in 0..<8 { rect(bit*width/8, height-height/16, width/8, height/16, flash || (frame >> bit) & 1 != 0 ? 940 : 64) }
    }

    private func send(_ data: Data) -> Bool {
        data.withUnsafeBytes { bytes in
            var sent = 0
            while sent < bytes.count {
                let n = write(writeFD, bytes.baseAddress! + sent, bytes.count - sent)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { return false }; sent += n
            }
            return true
        }
    }
    private func header(_ type: UInt8, _ a: Int, _ b: Int, _ c: Int, _ size: Int, _ ns: UInt64, _ seq: UInt32) -> Data {
        var d = Data([0x55,0x56,0x43,type])
        for v in [UInt32(a),UInt32(b),UInt32(c),UInt32(size)] { var le = v.littleEndian; withUnsafeBytes(of: &le) { d.append(contentsOf: $0) } }
        var t = ns.littleEndian; withUnsafeBytes(of: &t) { d.append(contentsOf: $0) }
        var s = seq.littleEndian; withUnsafeBytes(of: &s) { d.append(contentsOf: $0) }; return d
    }
    private func run(epoch: UInt64) {
        var frame = 0, audio = 0
        var fillTotal = 0.0, fillMax = 0.0
        while active {
            let videoTime = epoch + UInt64(Double(frame) * 1e9 / fps)
            let audioTime = epoch + UInt64(audio + 1) * 10_000_000
            let deadline = min(videoTime, audioTime)
            // Recompute remaining time against an absolute uptime deadline after every wake.
            while active && nowNs() < deadline {
                let left = deadline - min(deadline, nowNs())
                var ts = timespec(tv_sec: Int(left / 1_000_000_000), tv_nsec: Int(left % 1_000_000_000))
                nanosleep(&ts, nil)
            }
            guard active else { break }
            if videoTime <= audioTime {
                let fillStart = nowNs()
                fill(memory + frame % shmSlots * shmSlotBytes, frame: frame)
                let fillMs = Double(nowNs() - fillStart) / 1e6
                fillTotal += fillMs; fillMax = max(fillMax, fillMs)
                if frame == Int(fps * 3) { log(String(format: "demo fill: %.3f ms avg / %.3f max (%dx%d)", fillTotal / Double(frame+1), fillMax, width, height)) }
                guard send(header(0x53, width, height, 0, width*height*3, nowNs(), UInt32(truncatingIfNeeded: frame))) else { break }
                frame += 1
            } else {
                var samples = [Int16](repeating: 0, count: 960)
                for i in 0..<480 {
                    let sample = audio * 480 + i
                    let second = Int(Double(sample) / 48000)
                    let flashSample = Int((ceil(Double(second) * fps) / fps * 48000).rounded())
                    let pos = sample - flashSample
                    let v: Int16 = pos >= 0 && pos < 2400 ? Int16(sin(Double(pos) * 2 * .pi / 48) * 8000) : 0
                    samples[i*2] = v; samples[i*2+1] = v
                }
                guard send(header(0x41,48000,2,16,1920,audioTime,UInt32(audio))),
                      samples.withUnsafeBytes({ send(Data($0)) }) else { break }
                audio += 1
            }
        }
    }

    static func configuration(_ args: [String]) -> (Int, Int, Double)? {
        guard let i = args.firstIndex(of: "--demo-source") else { return nil }
        guard i+1 < args.count, !args[i+1].hasPrefix("-") else { return (2560,1440,60) }
        let parts = args[i+1].split(whereSeparator: { $0 == "x" || $0 == "@" })
        guard parts.count == 3, let w = Int(parts[0]), let h = Int(parts[1]), let f = Double(parts[2]),
              w > 0, h > 0, w <= 7680, h <= 4320, w % 2 == 0, h % 2 == 0, w*h*3 <= shmSlotBytes, f.isFinite, f > 0, f <= 240 else {
            log("invalid demo format; expected even WxH@FPS within one shared-memory slot"); exit(2)
        }
        return (w,h,f)
    }
}
