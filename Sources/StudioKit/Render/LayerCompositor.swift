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
    let plan: RenderPlan
    let canvas: CGSize
    let outTransfer: Int32
    let screenTransfer: Int32       // assumed for game frames that carry no transfer tag
    let screenSize: CGSize          // the tracks' natural sizes: what the layout is resolved against
    let cameraSize: CGSize?
    let hdrOutput: Bool
    /// A frame was composed before one of its overlays was ready (preview only; exports wait).
    let onOverlaysPending: (() -> Void)?

    init(timeRange: CMTimeRange, screenTrack: CMPersistentTrackID, cameraTrack: CMPersistentTrackID, plan: RenderPlan,
         outTransfer: Int32, screenTransfer: Int32, screenSize: CGSize, cameraSize: CGSize?, onOverlaysPending: (() -> Void)? = nil) {
        self.timeRange = timeRange; self.screenTrack = screenTrack; self.cameraTrack = cameraTrack; self.onOverlaysPending = onOverlaysPending
        self.plan = plan; self.canvas = plan.canvasSize; self.outTransfer = outTransfer; self.screenTransfer = screenTransfer
        self.screenSize = screenSize; self.cameraSize = cameraSize; hdrOutput = outTransfer != 2
        requiredSourceTrackIDs = [screenTrack, cameraTrack].filter { $0 != kCMPersistentTrackID_Invalid }.map { NSNumber(value: $0) }
    }
}

/// Base compositor. Sources keep their native 8/10-bit biplanar YCbCr; HDR writes 10-bit P010 (BT.2020), SDR
/// one writes 8-bit BGRA (BT.709).
class LayerCompositor: NSObject, AVVideoCompositing {
    class var hdr: Bool { false }
    var sourcePixelBufferAttributes: [String: any Sendable]? {
        [kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange],
         kCVPixelBufferMetalCompatibilityKey as String: true]
    }
    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [kCVPixelBufferPixelFormatTypeKey as String: [Self.hdr ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_32BGRA],
         kCVPixelBufferMetalCompatibilityKey as String: true]
    }
    // Keep SDR camera samples in their own encoding. Otherwise AVFoundation converts them to the game's PQ
    // space with different SDR-white levels in AVAssetImageGenerator and AVAssetReader.
    // Previously that implicit conversion changed camera brightness/colour before our own transfer conversion.
    var canConformColorOfSourceFrames: Bool { true }
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
            var textures: [SourceKey: LayerTextures.Kind] = [:]
            for (key, track, size, fallback) in [(SourceKey.game, ins.screenTrack, Optional(ins.screenSize), ins.screenTransfer), (.camera, ins.cameraTrack, ins.cameraSize, 2)] {
                guard track != kCMPersistentTrackID_Invalid, size != nil, let pb = request.sourceFrame(byTrackID: track), let p = core.planes(pb) else { continue }
                let tags = MetalCore.colorTags(pb, fallback: fallback)
                keep += p.2
                textures[key] = .biplanar(y: p.0, c: p.1, bits: p.3, transfer: tags.transfer, bt709: tags.bt709)
            }
            var plan = ins.plan
            if textures[.camera] == nil { plan.sources.removeValue(forKey: .camera) }
            let ms = request.compositionTime.seconds * 1000
            // Image and text layers, as live: an export waits for each texture, the preview takes what is ready.
            let overlays = plan.overlays(atTimelineMs: ms)
            if overlays.pending { ins.onOverlaysPending?() }
            plan.sources.merge(overlays.sources) { own, _ in own }
            textures.merge(overlays.textures) { own, _ in own }
            let layers = DrawLayer.pair(plan.layers(atTimelineMs: ms), textures)
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
                core.encodeLayers(cb, target: mid, canvas: ins.canvas, background: ins.plan.background(atTimelineMs: request.compositionTime.seconds * 1000), outTransfer: ins.outTransfer, layers: layers)
                core.encodeConvert(cb, fragment: "lumaFrag", source: mid, target: yT)
                core.encodeConvert(cb, fragment: "chromaFrag", source: mid, target: cT)
                tag(out, hdrTransfer: ins.outTransfer)
            } else {
                guard let (t, ref) = core.texture(out, .bgra8Unorm) else { request.finish(with: NSError(domain: "Compositor", code: 3)); return }
                keep.append(ref)
                core.encodeLayers(cb, target: t, canvas: ins.canvas, background: ins.plan.background(atTimelineMs: request.compositionTime.seconds * 1000), outTransfer: ins.outTransfer, layers: layers)
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
        if hdrTransfer != nil {
            // chromaFrag averages a 2x2 luma footprint: the sample sits at its centre, not its left edge.
            CVBufferSetAttachment(pb, kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocation_Center, .shouldPropagate)
            CVBufferSetAttachment(pb, kCVImageBufferChromaLocationBottomFieldKey, kCVImageBufferChromaLocation_Center, .shouldPropagate)
        }
        CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, prim, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, tf, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, mat, .shouldPropagate)
    }
}

final class HDRLayerCompositor: LayerCompositor { override class var hdr: Bool { true } }
final class SDRLayerCompositor: LayerCompositor { override class var hdr: Bool { false } }
