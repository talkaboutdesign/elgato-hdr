import AVFoundation
import AppKit
let disc = AVCaptureDevice.DiscoverySession(deviceTypes: [.external, .builtInWideAngleCamera], mediaType: .video, position: .unspecified)
for d in disc.devices where d.localizedName.contains("Elgato") {
    print("Device:", d.localizedName, d.uniqueID, d.modelID)
    for f in d.formats {
        let desc = f.formatDescription
        let dims = CMVideoFormatDescriptionGetDimensions(desc)
        let fcc = CMFormatDescriptionGetMediaSubType(desc)
        let s = String(format: "%c%c%c%c", (fcc>>24)&255, (fcc>>16)&255, (fcc>>8)&255, fcc&255)
        let rates = f.videoSupportedFrameRateRanges.map { String(format: "%.2f", $0.maxFrameRate) }.joined(separator: "/")
        print("  \(s) \(dims.width)x\(dims.height) @ \(rates)")
    }
}
for s in NSScreen.screens {
    print("Screen:", s.localizedName, "EDR max potential:", s.maximumPotentialExtendedDynamicRangeColorComponentValue, "current:", s.maximumExtendedDynamicRangeColorComponentValue, "ref:", s.maximumReferenceExtendedDynamicRangeColorComponentValue)
}
