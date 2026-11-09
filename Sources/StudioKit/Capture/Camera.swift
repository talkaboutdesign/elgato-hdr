// Camera + microphone capture for the facecam overlay, and the per-layer writers that record them next to the game.
// All layers share one clock: sample times are converted to host time, which is the same base as the helper's
// CLOCK_UPTIME_RAW frame stamps, so every layer file starts at the same zero.
import AppKit
import AVFoundation
import CoreMedia

func hostNs(_ t: CMTime) -> UInt64 { let s = CMTimeGetSeconds(t); return s > 0 ? UInt64(s * 1e9) : 0 }
func nowNs() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    let videoOutput = AVCaptureVideoDataOutput()
    let audioOutput = AVCaptureAudioDataOutput()
    let videoQueue = DispatchQueue(label: "camera-video")
    let audioQueue = DispatchQueue(label: "camera-audio")
    let sessionQueue = DispatchQueue(label: "camera-session")
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?

    let lock = NSLock()
    private var _latest: CVPixelBuffer?
    /// Most recent camera frame (420v), read by the live renderer on every draw.
    var latest: CVPixelBuffer? { lock.lock(); defer { lock.unlock() }; return _latest }
    var cameraRecorder: LayerWriter?
    var micRecorder: LayerWriter?
    var onState: (() -> Void)?
    private(set) var micLevel: Float = 0

    static func cameras() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                         mediaType: .video, position: .unspecified).devices
            .filter { !$0.localizedName.localizedCaseInsensitiveContains("Elgato 4K X") && !$0.localizedName.localizedCaseInsensitiveContains("Game Capture") }
    }
    static func microphones() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
            .filter { !$0.localizedName.localizedCaseInsensitiveContains("Elgato 4K X") && !$0.localizedName.localizedCaseInsensitiveContains("Game Capture") }
    }

    override init() {
        super.init()
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                     kCVPixelBufferMetalCompatibilityKey as String: true]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        // Mono 48 kHz float: deterministic for the writer whatever the mic's native format is.
        audioOutput.audioSettings = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1,
                                     AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false]
        audioOutput.setSampleBufferDelegate(self, queue: audioQueue)
    }

    var cameraOn: Bool { videoInput != nil }
    var micOn: Bool { audioInput != nil }
    var cameraName: String? { videoInput?.device.localizedName }
    var micName: String? { audioInput?.device.localizedName }

    /// Selects a camera (nil = off). Asks for permission on first use.
    func setCamera(uniqueID: String?, completion: @escaping (String?) -> Void) {
        withAccess(.video, enabled: uniqueID != nil, completion: completion) { [self] in
            session.beginConfiguration()
            if let i = videoInput { session.removeInput(i); videoInput = nil }
            if session.outputs.contains(videoOutput) { session.removeOutput(videoOutput) }
            var err: String?
            if let id = uniqueID {
                if let dev = AVCaptureDevice(uniqueID: id), let input = try? AVCaptureDeviceInput(device: dev), session.canAddInput(input) {
                    session.addInput(input); videoInput = input
                    if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
                    configureFormat(dev)
                } else { err = "camera unavailable" }
            }
            session.commitConfiguration()
            if videoInput == nil { lock.lock(); _latest = nil; lock.unlock() }
            runIfNeeded()
            return err
        }
    }

    func setMicrophone(uniqueID: String?, completion: @escaping (String?) -> Void) {
        withAccess(.audio, enabled: uniqueID != nil, completion: completion) { [self] in
            session.beginConfiguration()
            if let i = audioInput { session.removeInput(i); audioInput = nil }
            if session.outputs.contains(audioOutput) { session.removeOutput(audioOutput) }
            var err: String?
            if let id = uniqueID {
                if let dev = AVCaptureDevice(uniqueID: id) {
                    do {
                        let input = try AVCaptureDeviceInput(device: dev)
                        if session.canAddInput(input) {
                            session.addInput(input); audioInput = input
                            if session.canAddOutput(audioOutput) { session.addOutput(audioOutput) } else { err = "microphone output could not be added" }
                        } else { err = "\(dev.localizedName) can't be used together with the camera" }
                    } catch { err = "\(dev.localizedName): \(error.localizedDescription)" }
                } else { err = "microphone not found (disconnected?)" }
            }
            session.commitConfiguration()
            runIfNeeded()
            return err
        }
    }

    private func withAccess(_ type: AVMediaType, enabled: Bool, completion: @escaping (String?) -> Void, apply: @escaping () -> String?) {
        let go = { self.sessionQueue.async { let e = apply(); DispatchQueue.main.async { self.onState?(); completion(e) } } }
        guard enabled else { go(); return }
        let status = AVCaptureDevice.authorizationStatus(for: type)
        log("\(type == .video ? "camera" : "microphone") permission: \(["not determined", "restricted", "denied", "authorized"][min(3, status.rawValue)])")
        switch status {
        case .authorized: go()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: type) { ok in
                log("\(type == .video ? "camera" : "microphone") permission answered: \(ok ? "allowed" : "denied")")
                if ok { go() } else { DispatchQueue.main.async { completion("\(type == .video ? "camera" : "microphone") access denied") } }
            }
        default:
            completion("\(type == .video ? "camera" : "microphone") access denied: enable it in System Settings › Privacy & Security")
        }
    }

    /// Prefer 1080p at the highest frame rate up to 60, falling back to whatever is closest.
    private func configureFormat(_ dev: AVCaptureDevice) {
        func score(_ f: AVCaptureDevice.Format) -> Double {
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            let fps = f.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            return -abs(Double(d.height) - 1080) * 10 + min(fps, 60)
        }
        guard let best = dev.formats.max(by: { score($0) < score($1) }) else { return }
        do {
            try dev.lockForConfiguration()
            dev.activeFormat = best
            // Use the device's own durations: cameras report rates like 30.00003 fps and throw (an uncatchable
            // NSException) on anything that doesn't match a supported range exactly.
            let ranges = best.videoSupportedFrameRateRanges
            if let r = ranges.filter({ $0.maxFrameRate <= 60.5 }).max(by: { $0.maxFrameRate < $1.maxFrameRate })
                ?? ranges.min(by: { $0.maxFrameRate < $1.maxFrameRate }) {
                dev.activeVideoMinFrameDuration = r.minFrameDuration
                dev.activeVideoMaxFrameDuration = r.minFrameDuration
            }
            dev.unlockForConfiguration()
        } catch { log("camera format: \(error)") }
    }

    private func runIfNeeded() {
        let want = videoInput != nil || audioInput != nil
        if want && !session.isRunning { session.startRunning() }
        if !want && session.isRunning { session.stopRunning() }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        // Capture timestamps are on the session clock; express them in host time to line up with the game layer.
        let pts = CMSyncConvertTime(CMSampleBufferGetPresentationTimeStamp(sb), from: session.synchronizationClock ?? CMClockGetHostTimeClock(), to: CMClockGetHostTimeClock())
        if output === videoOutput {
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { return }
            lock.lock(); _latest = pb; let rec = cameraRecorder; lock.unlock()
            rec?.appendVideo(pb, ns: hostNs(pts))
        } else {
            lock.lock(); let rec = micRecorder; lock.unlock()
            rec?.appendAudio(sb, ns: hostNs(pts))
            meter(sb)
        }
    }

    private func meter(_ sb: CMSampleBuffer) {
        guard let bb = CMSampleBufferGetDataBuffer(sb) else { return }
        var len = 0; var p: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &len, dataPointerOut: &p) == noErr, let p = p else { return }
        let n = len / 4
        var peak: Float = 0
        p.withMemoryRebound(to: Float.self, capacity: n) { f in for i in 0..<n { peak = max(peak, abs(f[i])) } }
        micLevel = max(peak, micLevel * 0.85)
    }

    func attach(camera: LayerWriter?, mic: LayerWriter?) { lock.lock(); cameraRecorder = camera; micRecorder = mic; lock.unlock() }
}

