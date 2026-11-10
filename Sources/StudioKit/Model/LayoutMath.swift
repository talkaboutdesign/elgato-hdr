import AppKit
import AVFoundation

// MARK: - Layout resolution

enum LayoutMath {
    /// Crops `src` (normalized) so it fills `dst` with the given aspect, zoom and pan.
    static func fillCrop(sourceSize: CGSize, dst: CGSize, zoom: Double, panX: Double, panY: Double) -> CGRect {
        guard sourceSize.width > 0, sourceSize.height > 0, dst.width > 0, dst.height > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let sa = sourceSize.width / sourceSize.height, da = dst.width / dst.height
        var w = 1.0, h = 1.0
        if sa > da { w = da / sa } else { h = sa / da }
        let z = max(1, zoom); w /= z; h /= z
        let cx = min(max(panX, w / 2), 1 - w / 2), cy = min(max(panY, h / 2), 1 - h / 2)
        return CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
    }

    static func fitRect(_ src: CGSize, in r: CGRect) -> CGRect {
        guard src.width > 0, src.height > 0 else { return r }
        let s = min(r.width / src.width, r.height / src.height)
        let w = (src.width * s).rounded(), h = (src.height * s).rounded()
        return CGRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h)
    }

    /// Resolves a layout into shader parameters for a canvas of `canvas` pixels.
    static func params(layout: CanvasLayout, canvas: CGSize, screen: CGSize, camera: CGSize?, mirror: Bool,
                       screenTransfer: Int32, outTransfer: Int32) -> CompParams {
        var p = CompParams()
        p.canvas = SIMD4(Float(canvas.width), Float(canvas.height), 0, 0)
        p.bg = SIMD4(0.06, 0.06, 0.07, 1)
        p.fmt = SIMD4(screenTransfer, outTransfer, 10, 8)
        p.fmt2 = SIMD4(2, screenTransfer == 2 ? 1 : 0, 1, 0)
        let full = CGRect(origin: .zero, size: canvas)
        var screenDst = full, camDst = CGRect.zero, radius: CGFloat = 0, border: CGFloat = 0, shadow: CGFloat = 0
        var showScreen = true, showCam = camera != nil
        switch layout.kind {
        case .pip:
            camDst = layout.camera.rect(in: canvas)
            radius = layout.camera.radius(for: camDst)
            if layout.fit { screenDst = fitRect(screen, in: full) }
            border = layout.camera.border ? max(2, camDst.width * 0.018) : 0
            shadow = layout.camera.shadow ? max(6, camDst.width * 0.08) : 0
        case .stacked:
            if showCam {
                let ch = (canvas.height * layout.split).rounded()
                camDst = CGRect(x: 0, y: 0, width: canvas.width, height: ch)
                screenDst = CGRect(x: 0, y: ch, width: canvas.width, height: canvas.height - ch)
            }
            if layout.fit { screenDst = fitRect(screen, in: screenDst) }
        case .screenOnly: showCam = false; if layout.fit { screenDst = fitRect(screen, in: full) }
        case .cameraOnly: showScreen = false; camDst = full
        }
        p.screenDst = SIMD4(screenDst)
        p.screenSrc = SIMD4(layout.fit ? fillCrop(sourceSize: screen, dst: screen, zoom: layout.zoom, panX: layout.panX, panY: layout.panY)
                                       : fillCrop(sourceSize: screen, dst: screenDst.size, zoom: layout.zoom, panX: layout.panX, panY: layout.panY))
        if let cs = camera, showCam {
            p.camDst = SIMD4(camDst)
            p.camSrc = SIMD4(fillCrop(sourceSize: cs, dst: camDst.size, zoom: 1, panX: 0.5, panY: 0.5))
        }
        p.shape = SIMD4(Float(radius), Float(border), Float(shadow), 0)
        p.flags = SIMD4(showScreen ? 1 : 0, showCam ? 1 : 0, mirror ? 1 : 0, 0)
        return p
    }
}

