import AVFoundation
import CoreVideo
import Metal

// MARK: - AVFoundation custom compositor (editor preview + export)

final class CompositionInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let screenTrack: CMPersistentTrackID
    let cameraTrack: CMPersistentTrackID
    let params: CompParams
    let hdrOutput: Bool

    init(timeRange: CMTimeRange, screenTrack: CMPersistentTrackID, cameraTrack: CMPersistentTrackID, params: CompParams, hdrOutput: Bool) {
        self.timeRange = timeRange; self.screenTrack = screenTrack; self.cameraTrack = cameraTrack
        self.params = params; self.hdrOutput = hdrOutput
        requiredSourceTrackIDs = [screenTrack, cameraTrack].filter { $0 != kCMPersistentTrackID_Invalid }.map { NSNumber(value: $0) }
    }
}

/// Base compositor. Sources arrive as 10-bit biplanar YCbCr; the HDR subclass writes 10-bit P010 (BT.2020), the SDR
/// one writes 8-bit BGRA (BT.709).
class LayerCompositor: NSObject, AVVideoCompositing {
    class var hdr: Bool { false }
    var sourcePixelBufferAttributes: [String: any Sendable]? {
        [kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange],
         kCVPixelBufferMetalCompatibilityKey as String: true]
    }
    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [kCVPixelBufferPixelFormatTypeKey as String: [Self.hdr ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_32BGRA],
         kCVPixelBufferMetalCompatibilityKey as String: true]
    }
    var supportsHDRSourceFrames: Bool { true }
    var supportsWideColorSourceFrames: Bool { true }
    let renderQueue = DispatchQueue(label: "compositor")
    var intermediate: MTLTexture?

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}
    func cancelAllPendingVideoCompositionRequests() {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        renderQueue.async { [self] in
            guard let ins = request.videoCompositionInstruction as? CompositionInstruction,
                  let out = request.renderContext.newPixelBuffer() else {
                request.finish(with: NSError(domain: "Compositor", code: 1)); return
            }
            let core = MetalCore.shared
            var keep: [CVMetalTexture] = []
            var params = ins.params
            var screen: (MTLTexture, MTLTexture)?
            if ins.screenTrack != kCMPersistentTrackID_Invalid, let pb = request.sourceFrame(byTrackID: ins.screenTrack), let p = core.planes(pb) {
                screen = (p.0, p.1); keep += p.2; params.fmt.z = p.3; params.adopt(screen: pb)
            } else { params.flags.x = 0 }
            var camera: (MTLTexture, MTLTexture)?
            if ins.cameraTrack != kCMPersistentTrackID_Invalid, let pb = request.sourceFrame(byTrackID: ins.cameraTrack), let p = core.planes(pb) {
                camera = (p.0, p.1); keep += p.2; params.fmt.w = p.3; params.adopt(camera: pb)
            } else { params.flags.y = 0 }
            guard let cb = core.queue.makeCommandBuffer() else { request.finish(with: NSError(domain: "Compositor", code: 2)); return }
            let w = CVPixelBufferGetWidth(out), h = CVPixelBufferGetHeight(out)
            if Self.hdr {
                if intermediate?.width != w || intermediate?.height != h {
                    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
                    d.usage = [.renderTarget, .shaderRead]; d.storageMode = .private
                    intermediate = core.device.makeTexture(descriptor: d)
                }
                guard let mid = intermediate, let (yT, yRef) = core.texture(out, .r16Unorm, plane: 0), let (cT, cRef) = core.texture(out, .rg16Unorm, plane: 1) else {
                    request.finish(with: NSError(domain: "Compositor", code: 3)); return
                }
                keep += [yRef, cRef]
                core.encodeComposite(cb, target: mid, screen: screen, camera: camera, params: params)
                core.encodeConvert(cb, fragment: "lumaFrag", source: mid, target: yT)
                core.encodeConvert(cb, fragment: "chromaFrag", source: mid, target: cT)
                tag(out, hdrTransfer: params.fmt.y)
            } else {
                guard let (t, ref) = core.texture(out, .bgra8Unorm) else { request.finish(with: NSError(domain: "Compositor", code: 3)); return }
                keep.append(ref)
                core.encodeComposite(cb, target: t, screen: screen, camera: camera, params: params)
                tag(out, hdrTransfer: nil)
            }
            cb.addCompletedHandler { _ in
                _ = keep
                request.finish(withComposedVideoFrame: out)
            }
            cb.commit()
        }
    }

    private func tag(_ pb: CVPixelBuffer, hdrTransfer: Int32?) {
        let (prim, tf, mat): (CFString, CFString, CFString) = switch hdrTransfer {
        case 0: (kCVImageBufferColorPrimaries_ITU_R_2020, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, kCVImageBufferYCbCrMatrix_ITU_R_2020)
        case 1: (kCVImageBufferColorPrimaries_ITU_R_2020, kCVImageBufferTransferFunction_ITU_R_2100_HLG, kCVImageBufferYCbCrMatrix_ITU_R_2020)
        default: (kCVImageBufferColorPrimaries_ITU_R_709_2, kCVImageBufferTransferFunction_ITU_R_709_2, kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        }
        CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, prim, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, tf, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, mat, .shouldPropagate)
    }
}

final class HDRLayerCompositor: LayerCompositor { override class var hdr: Bool { true } }
final class SDRLayerCompositor: LayerCompositor { override class var hdr: Bool { false } }
