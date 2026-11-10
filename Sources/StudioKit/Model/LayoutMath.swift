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
}

