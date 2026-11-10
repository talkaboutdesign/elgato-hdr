import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import VideoToolbox
import Metal
import QuartzCore

// MARK: - Stream session (socket headers + audio, frames via shared memory)

final class Session {
    let fd: Int32
    let renderer: Renderer
    let shm: UnsafeMutableRawPointer
    var w = 0, h = 0, frames = 0
    var lastReport = Date()
    /// Synchronous reader-thread tap; copy the bytes before returning. Set before run().
    var onGameAudio: ((UnsafeRawPointer, Int, UInt64) -> Void)?
    var onInfo: ((String) -> Void)?
    var stopped = false
    var audio: AudioPlayer?
    var recorder: Recorder?
    var lastFrameNs: UInt64 = 0
    var latestSeq: UInt32 = 0
    var audioScratch = [UInt8](repeating: 0, count: 1 << 16)
    var pool: CVPixelBufferPool?
    let copyQueue = DispatchQueue(label: "record-copy")
    var tWait = 0.0, tDraw = 0.0, tDrawMax = 0.0

    init(fd: Int32, renderer: Renderer, shm: UnsafeMutableRawPointer) { self.fd = fd; self.renderer = renderer; self.shm = shm }
    func stop() { stopped = true; shutdown(fd, SHUT_RDWR); close(fd) }

    func makePool(w: Int, h: Int) {
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        var p: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey as String: 4] as CFDictionary, attrs as CFDictionary, &p)
        pool = p
    }

    /// Copy a shared-memory slot into a pixel buffer for the encoder (only while recording).
    func copyForRecording(slot: Int, seq: UInt32, w: Int, h: Int, ns: UInt64, colorMode: ColorMode) {
        guard let rec = recorder else { return }
        copyQueue.async { [self] in
            if pool == nil { makePool(w: w, h: h) }
            var pbOpt: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool!, [kCVPixelBufferPoolAllocationThresholdKey as String: 16] as CFDictionary, &pbOpt)
            guard let pb = pbOpt else { return }
            let src = shm + slot * shmSlotBytes
            CVPixelBufferLockBaseAddress(pb, [])
            let y = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!, ys = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
            let c = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!, cs = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
            let row = w * 2
            if ys == row { memcpy(y, src, row * h) } else { for r in 0..<h { memcpy(y + r * ys, src + r * row, row) } }
            let csrc = src + row * h
            if cs == row { memcpy(c, csrc, row * (h / 2)) } else { for r in 0..<(h / 2) { memcpy(c + r * cs, csrc + r * row, row) } }
            CVPixelBufferUnlockBaseAddress(pb, [])
            if latestSeq &- seq >= UInt32(shmSlots) { return } // slot was overwritten mid-copy; drop
            let (prim, tf, mat): (CFString, CFString, CFString)
            switch colorMode {
            case .pq:  (prim, tf, mat) = (kCVImageBufferColorPrimaries_ITU_R_2020, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, kCVImageBufferYCbCrMatrix_ITU_R_2020)
            case .hlg: (prim, tf, mat) = (kCVImageBufferColorPrimaries_ITU_R_2020, kCVImageBufferTransferFunction_ITU_R_2100_HLG, kCVImageBufferYCbCrMatrix_ITU_R_2020)
            case .sdr: (prim, tf, mat) = (kCVImageBufferColorPrimaries_ITU_R_709_2, kCVImageBufferTransferFunction_ITU_R_709_2, kCVImageBufferYCbCrMatrix_ITU_R_709_2)
            }
            CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, prim, .shouldPropagate)
            CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, tf, .shouldPropagate)
            CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, mat, .shouldPropagate)
            rec.appendVideo(pb, ns: ns)
        }
    }

    func run() {
        var hdr = [UInt8](repeating: 0, count: 32)
        while !stopped {
            let t0 = CFAbsoluteTimeGetCurrent()
            guard hdr.withUnsafeMutableBytes({ readFully(fd, $0.baseAddress!, 32) }) else { break }
            tWait += CFAbsoluteTimeGetCurrent() - t0
            guard hdr[0] == 0x55, hdr[1] == 0x56, hdr[2] == 0x43 else { log("bad stream magic"); break }
            func u32(_ o: Int) -> Int { Int(hdr[o]) | Int(hdr[o+1]) << 8 | Int(hdr[o+2]) << 16 | Int(hdr[o+3]) << 24 }
            let a = u32(4), b = u32(8), size = u32(16), seq = UInt32(truncatingIfNeeded: u32(28))
            let tNs = hdr[20..<28].enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) }
            switch hdr[3] {
            case 0x41: // "UVCA" audio chunk
                if size > audioScratch.count { audioScratch = [UInt8](repeating: 0, count: size) }
                guard audioScratch.withUnsafeMutableBytes({ readFully(fd, $0.baseAddress!, size) }) else { return finish() }
                if a == 48000, b == 2, u32(12) == 16 {
                    if let rec = recorder { rec.appendAudio(Data(audioScratch[0..<size]), ns: tNs) }
                    audioScratch.withUnsafeBytes {
                        audio?.push($0.baseAddress!, size)
                        onGameAudio?($0.baseAddress!, size, tNs)
                    }
                }
            case 0x53: // "UVCS" frame in shared memory slot seq % 3
                guard size == a * b * 3, size <= shmSlotBytes else { log("unexpected frame size"); return finish() }
                if a != w || b != h { w = a; h = b; pool = nil; onInfo?("\(w)x\(h) P010") }
                latestSeq = seq; lastFrameNs = tNs
                let slot = Int(seq % UInt32(shmSlots))
                let t1 = CFAbsoluteTimeGetCurrent()
                renderer.submit(slot: slot, w: w, h: h, arrivalNs: tNs)
                let dd = CFAbsoluteTimeGetCurrent() - t1; tDraw += dd; tDrawMax = max(tDrawMax, dd)
                if recorder != nil { copyForRecording(slot: slot, seq: seq, w: w, h: h, ns: tNs, colorMode: renderer.colorMode) }
                frames += 1
            case 0x46: // "UVCF" inline frame: helper without shared memory; skip payload
                var junk = [UInt8](repeating: 0, count: size)
                guard junk.withUnsafeMutableBytes({ readFully(fd, $0.baseAddress!, size) }) else { return finish() }
                if frames == 0 { log("helper is streaming inline frames (old helper?)"); onInfo?("helper too old: restart helper") }
            default: log("unknown chunk"); return finish()
            }
            let now = Date()
            if now.timeIntervalSince(lastReport) >= 1 {
                let dt = now.timeIntervalSince(lastReport)
                let fps = Double(frames) / dt
                let (avg, mx, n) = renderer.takeStats()
                log(String(format: "video: %.1f fps  helper->screen %.1f ms avg / %.1f max (%d)  wait %.0f ms  draw %.1f ms/frame (max %.1f)", fps, avg, mx, n, tWait * 1000, frames > 0 ? tDraw * 1000 / Double(frames) : 0, tDrawMax * 1000))
                onInfo?(String(format: "%dx%d 10-bit  %.1f fps  •  %.0f ms to screen", w, h, fps, avg))
                frames = 0; lastReport = now; tWait = 0; tDraw = 0; tDrawMax = 0
            }
        }
        finish()
    }
    func finish() { if !stopped { close(fd); onInfo?("stream ended") } }
}

