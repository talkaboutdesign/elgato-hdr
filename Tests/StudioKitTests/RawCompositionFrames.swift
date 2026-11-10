import XCTest
import AVFoundation
import CoreMedia
import CoreVideo
@testable import StudioKit

enum RawCompositionFrames {
    static func frame(_ asset: AVAsset, video: AVVideoComposition? = nil, ms: Double, hdr: Bool) throws -> CVPixelBuffer {
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: hdr ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_32BGRA]
        let output: AVAssetReaderOutput
        if let video = video {
            let composed = AVAssetReaderVideoCompositionOutput(videoTracks: asset.tracks(withMediaType: .video), videoSettings: settings)
            composed.videoComposition = video; output = composed
        } else { output = AVAssetReaderTrackOutput(track: try XCTUnwrap(asset.tracks(withMediaType: .video).first), outputSettings: settings) }
        reader.add(output)
        // Decode on the composition's frame grid; a nonzero reader start can shift AVFoundation's sampling phase.
        reader.timeRange = CMTimeRange(start: .zero, duration: CompositionBuilder.time(ms + 100))
        guard reader.startReading() else { throw reader.error ?? CompositionBuilder.err("Cannot start reader") }
        var selected: CMSampleBuffer?
        while let sample = output.copyNextSampleBuffer() {
            if CMSampleBufferGetPresentationTimeStamp(sample).seconds * 1000 >= ms - 0.001 { selected = sample; break }
        }
        guard let sample = selected, let buffer = CMSampleBufferGetImageBuffer(sample) else {
            throw reader.error ?? CompositionBuilder.err("No frame at \(ms)")
        }
        reader.cancelReading(); return buffer
    }
    static func codes(_ pb: CVPixelBuffer) -> [Double] {
        CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        var values: [Double] = []
        if CVPixelBufferIsPlanar(pb) {
            for plane in 0..<2 {
                let width = CVPixelBufferGetWidthOfPlane(pb, plane) * (plane == 0 ? 1 : 2)
                let height = CVPixelBufferGetHeightOfPlane(pb, plane)
                let base = CVPixelBufferGetBaseAddressOfPlane(pb, plane)!, stride = CVPixelBufferGetBytesPerRowOfPlane(pb, plane)
                for y in 0..<height {
                    let row = (base + y*stride).assumingMemoryBound(to: UInt16.self)
                    for x in 0..<width { values.append(Double(row[x] >> 6)) }
                }
            }
        } else {
            let base = CVPixelBufferGetBaseAddress(pb)!, stride = CVPixelBufferGetBytesPerRow(pb)
            for y in 0..<CVPixelBufferGetHeight(pb) {
                let row = (base + y*stride).assumingMemoryBound(to: UInt8.self)
                for x in 0..<CVPixelBufferGetWidth(pb)*4 { values.append(Double(row[x])) }
            }
        }
        return values
    }
    static func yuv(_ pb: CVPixelBuffer) -> [[Double]] {
        let raw = codes(pb), w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), count = w*h
        if CVPixelBufferIsPlanar(pb) {
            let y = raw[..<count].map { ($0-64)/876 }
            let cb = stride(from: count, to: raw.count, by: 2).map { (raw[$0]-512)/896 }
            let cr = stride(from: count+1, to: raw.count, by: 2).map { (raw[$0]-512)/896 }
            return [y, cb, cr]
        }
        var luma = [Double](repeating: 0, count: count), cb = [Double](repeating: 0, count: count/4), cr = cb
        for y in 0..<h { for x in 0..<w {
            let i = y*w+x, b = raw[i*4]/255, g = raw[i*4+1]/255, r = raw[i*4+2]/255
            let value = 0.2126*r + 0.7152*g + 0.0722*b
            luma[i] = value
            let c = (y/2)*(w/2)+x/2
            cb[c] += (b-value)/1.8556/4; cr[c] += (r-value)/1.5748/4
        } }
        return [luma, cb, cr]
    }
    static func assertEncoding(_ reference: CVPixelBuffer, _ decoded: CVPixelBuffer, file: StaticString = #filePath, line: UInt = #line) {
        for (plane, pair) in zip(yuv(reference), yuv(decoded)).enumerated() {
            let errors = zip(pair.0, pair.1).map { abs($0-$1) }.sorted()
            let mse = errors.reduce(0) { $0 + $1*$1 } / Double(errors.count)
            let psnr = -10*log10(max(1e-20, mse)), percentile = errors[min(errors.count-1, Int(Double(errors.count)*0.999))]
            XCTAssertTrue(percentile <= (plane == 0 ? 3 : 8)/255.0 || psnr >= (plane == 0 ? 40 : 35), "plane \(plane): p99.9 \(percentile*255)/255, PSNR \(psnr)", file: file, line: line)
        }
    }
}
