// hdrview: minimal native macOS HDR viewer for a raw P010 stream on stdin (from uvc_capture).
// Wraps each frame in a CVPixelBuffer (x420, 10-bit biplanar) tagged BT.2020 + PQ, displays via AVSampleBufferDisplayLayer (EDR).
//   uvc_capture ... | hdrview [--hlg | --sdr] [--title T]
import AppKit
import AVFoundation
import CoreMedia
import CoreVideo

enum ColorMode { case pq, hlg, sdr }
var colorMode: ColorMode = .pq
var windowTitle = "Elgato 4K X — HDR"
var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--hlg": colorMode = .hlg
    case "--sdr": colorMode = .sdr
    case "--pq": colorMode = .pq
    case "--title": windowTitle = args.isEmpty ? windowTitle : args.removeFirst()
    default: FileHandle.standardError.write("unknown arg \(a)\n".data(using: .utf8)!)
    }
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

final class Reader {
    let layer: AVSampleBufferDisplayLayer
    var pool: CVPixelBufferPool?
    var fmtDesc: CMVideoFormatDescription?
    var w = 0, h = 0
    var frames = 0
    var lastReport = Date()
    var onInfo: ((String) -> Void)?
    init(layer: AVSampleBufferDisplayLayer) { self.layer = layer }

    func makePool(w: Int, h: Int) {
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: w,
            kCVPixelBufferHeightKey as String: h,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        var p: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey as String: 4] as CFDictionary, attrs as CFDictionary, &p)
        pool = p
        fmtDesc = nil
    }

    func tag(_ pb: CVPixelBuffer) {
        let (prim, tf, mat): (CFString, CFString, CFString)
        switch colorMode {
        case .pq:  (prim, tf, mat) = (kCVImageBufferColorPrimaries_ITU_R_2020, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, kCVImageBufferYCbCrMatrix_ITU_R_2020)
        case .hlg: (prim, tf, mat) = (kCVImageBufferColorPrimaries_ITU_R_2020, kCVImageBufferTransferFunction_ITU_R_2100_HLG, kCVImageBufferYCbCrMatrix_ITU_R_2020)
        case .sdr: (prim, tf, mat) = (kCVImageBufferColorPrimaries_ITU_R_709_2, kCVImageBufferTransferFunction_ITU_R_709_2, kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        }
        CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, prim, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, tf, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, mat, .shouldPropagate)
        if colorMode == .pq {
            // Nominal HDR10 mastering metadata so the compositor knows the peak (1000 nits).
            CVBufferSetAttachment(pb, kCVImageBufferMasteringDisplayColorVolumeKey,
                "G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,50)" as CFString, .shouldPropagate)
            CVBufferSetAttachment(pb, kCVImageBufferContentLightLevelInfoKey, "1000,400" as CFString, .shouldPropagate)
        }
    }

    func run() {
        let fd: Int32 = 0
        var hdr = [UInt8](repeating: 0, count: 32)
        while true {
            let ok = hdr.withUnsafeMutableBytes { readFully(fd, $0.baseAddress!, 32) }
            if !ok { break }
            guard hdr[0] == 0x55, hdr[1] == 0x56, hdr[2] == 0x43, hdr[3] == 0x46 else {
                FileHandle.standardError.write("bad stream magic\n".data(using: .utf8)!); break
            }
            func u32(_ o: Int) -> Int { Int(hdr[o]) | Int(hdr[o+1]) << 8 | Int(hdr[o+2]) << 16 | Int(hdr[o+3]) << 24 }
            let fw = u32(4), fh = u32(8), size = u32(16)
            let fourcc = String(bytes: hdr[12..<16], encoding: .ascii) ?? "?"
            if fourcc != "P010" || size != fw * fh * 3 {
                FileHandle.standardError.write("unsupported frame \(fourcc) \(fw)x\(fh) size \(size)\n".data(using: .utf8)!)
                var junk = [UInt8](repeating: 0, count: size)
                _ = junk.withUnsafeMutableBytes { readFully(fd, $0.baseAddress!, size) }
                continue
            }
            if fw != w || fh != h || pool == nil { w = fw; h = fh; makePool(w: w, h: h); onInfo?("\(w)x\(h) P010") }
            var pbOpt: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool!, &pbOpt)
            guard let pb = pbOpt else { break }
            CVPixelBufferLockBaseAddress(pb, [])
            let y = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!, ys = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
            let c = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!, cs = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
            var good = true
            let rowY = w * 2, rowC = w * 2
            if ys == rowY { good = readFully(fd, y, rowY * h) }
            else { for r in 0..<h where good { good = readFully(fd, y + r * ys, rowY) } }
            if good {
                if cs == rowC { good = readFully(fd, c, rowC * (h / 2)) }
                else { for r in 0..<(h/2) where good { good = readFully(fd, c + r * cs, rowC) } }
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            if !good { break }
            tag(pb)
            if fmtDesc == nil { CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pb, formatDescriptionOut: &fmtDesc) }
            var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
            var sb: CMSampleBuffer?
            CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pb, formatDescription: fmtDesc!, sampleTiming: &timing, sampleBufferOut: &sb)
            if let sb = sb {
                if let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true) as? [CFMutableDictionary], let d = atts.first {
                    CFDictionarySetValue(d, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
                }
                let layer = self.layer
                DispatchQueue.main.async {
                    if layer.status == .failed { layer.flush() }
                    layer.enqueue(sb)
                }
            }
            frames += 1
            let now = Date()
            if now.timeIntervalSince(lastReport) >= 1 {
                let fps = Double(frames) / now.timeIntervalSince(lastReport)
                frames = 0; lastReport = now
                onInfo?(String(format: "%dx%d P010  %.1f fps", w, h, fps))
            }
        }
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var reader: Reader!
    func applicationDidFinishLaunching(_ n: Notification) {
        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = NSColor.black.cgColor
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720))
        view.wantsLayer = true
        view.layer = layer
        view.layerContentsRedrawPolicy = .never
        window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = windowTitle
        window.contentView = view
        window.contentAspectRatio = NSSize(width: 16, height: 9)
        window.backgroundColor = .black
        window.collectionBehavior = [.fullScreenPrimary]
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        let menu = NSMenu(); let app = NSMenuItem(); menu.addItem(app)
        let sub = NSMenu()
        sub.addItem(withTitle: "Toggle Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        sub.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        app.submenu = sub; NSApp.mainMenu = menu

        reader = Reader(layer: layer)
        let title = windowTitle
        reader.onInfo = { [weak self] s in DispatchQueue.main.async { self?.window.title = "\(title)  •  \(s)" } }
        Thread.detachNewThread { [reader] in reader!.run() }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
