#if DEBUG
import AVFoundation
import VideoToolbox

/// Shared by the bundled --make-fixture command and export tests; never opens capture devices.
enum FixtureProject {
    static func make(at dir: URL, frameCount: Int = 120) async throws -> ProjectDoc {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let zero: UInt64 = 1_000_000_000
        let recorder = try Recorder(url: dir.appendingPathComponent("game.mov"), width: 1920, height: 1080, fps: 60, colorMode: .pq, startNs: zero)
        let camera = try LayerWriter(cameraURL: dir.appendingPathComponent("camera.mov"), width: 1280, height: 720, startNs: zero)
        let mic = try LayerWriter(micURL: dir.appendingPathComponent("mic.mov"), startNs: zero)
        let source = DemoSource(width: 1920, height: 1080, fps: 60)
        for frame in 0..<frameCount {
            var out: CVPixelBuffer?
            CVPixelBufferCreate(nil, 1920, 1080, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &out)
            guard let pb = out else { throw CompositionBuilder.err("fixture pixel buffer") }
            source.fill(source.memory, frame: frame)
            CVPixelBufferLockBaseAddress(pb, [])
            for plane in 0..<2 {
                let dst = CVPixelBufferGetBaseAddressOfPlane(pb, plane)!, stride = CVPixelBufferGetBytesPerRowOfPlane(pb, plane)
                let src = source.memory + (plane == 0 ? 0 : 1920*1080*2)
                for row in 0..<(plane == 0 ? 1080 : 540) { memcpy(dst + row*stride, src + row*3840, 3840) }
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
            CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, .shouldPropagate)
            CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
            let ns = zero + UInt64(Double(frame) * 1e9 / 60)
            recorder.appendVideo(pb, ns: ns)
            // A nanosecond after zero satisfies LayerWriter's strict positive timestamp guard.
            if frame % 2 == 0 { camera.appendVideo(CameraCapture.demoPixelBuffer(frame: frame/2), ns: ns+1) }
            if let sb = CameraCapture.demoAudio(sample: frame*800, count: 800) { mic.appendAudio(sb, ns: ns+1) }
            var stereo = [Int16](repeating: 0, count: 1600)
            for i in 0..<800 {
                let p = (frame*800+i) % 48000
                let v: Int16 = p < 2400 ? Int16(sin(Double(p)*2 * .pi/48)*8000) : 0
                stereo[i*2] = v; stereo[i*2+1] = v
            }
            recorder.appendAudio(stereo.withUnsafeBytes { Data($0) }, ns: ns+16_666_667)
            // Real-time writers intentionally drop on backpressure. Feed at their advertised cadence.
            try await Task.sleep(nanoseconds: 16_666_667)
        }
        let msg = await withCheckedContinuation { c in recorder.finish { c.resume(returning: $0) } }
        let camOK = await withCheckedContinuation { c in camera.finish { c.resume(returning: $0) } }
        let micOK = await withCheckedContinuation { c in mic.finish { c.resume(returning: $0) } }
        guard recorder.writer.status == .completed, camOK, micOK else { throw CompositionBuilder.err("fixture writing failed: \(msg)") }
        var p = Project(name: dir.lastPathComponent, createdAt: Date())
        p.width = 1920; p.height = 1080; p.fps = 60
        p.camera = LayerInfo(file: "camera.mov"); p.mic = LayerInfo(file: "mic.mov")
        let doc = ProjectDoc(dir: dir, project: p)
        await withCheckedContinuation { c in doc.finalize { c.resume() } }
        return doc
    }
}
#endif
