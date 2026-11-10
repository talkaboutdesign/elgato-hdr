import CoreGraphics
import Foundation

/// What the window draws. The canvases are 16:9 and 9:16, so an ultrawide game is cropped by most scenes and the
/// player can lose HUD at the edges. In focus mode (full screen) the window can instead show the clean game: the whole
/// frame in its own aspect, letterboxed, with no camera, overlays, crop or zoom. Stream, recording, thumbnails and the
/// window outside focus mode keep showing the scene. It is a simpler draw than any scene, so it adds no latency.
enum WindowPicture {
    static let defaultsKey = "cleanGameInFocusMode"
    /// The menu setting, on unless turned off.
    static func setting(_ d: UserDefaults = .standard) -> Bool { d.object(forKey: defaultsKey) as? Bool ?? true }
    static func clean(setting: Bool, focusMode: Bool) -> Bool { setting && focusMode }

    /// The canvas (whole pixels, centred in `drawable`) and the picture on it. Clean: the game alone, the full
    /// source on the full canvas, which has the game's aspect. Otherwise the scene on the shown canvas.
    static func picture(clean: Bool, scene: LiveSceneState, canvas: Canvas, game: CGSize, drawable: CGSize,
                        sources: [SourceKey: SourceInfo], atNs t: UInt64) -> (size: CGSize, frame: SceneFrame) {
        let size = Self.size(clean: clean, canvas: canvas, game: game, drawable: drawable)
        guard clean else { return (size, scene.frame(canvas: canvas, size: size, sources: sources, atNs: t)) }
        var l = ResolvedLayer(key: .game, dst: CGRect(origin: .zero, size: size), src: CGRect(x: 0, y: 0, width: 1, height: 1),
                              radius: 0, border: 0, shadow: 0, opacity: 1, mirror: false, color: nil)
        l.hardEdge = true
        return (size, SceneFrame(background: SIMD4(0, 0, 0, 1), layers: size.width > 0 && size.height > 0 ? [l] : []))
    }

    /// The canvas in drawable pixels. Whole pixels, so canvas pixels are target pixels: only then may encodeLayers
    /// draw the full-canvas game on its opaque path and skip the background. The game's hard edge keeps whole rows
    /// either way.
    static func size(clean: Bool, canvas: Canvas, game: CGSize, drawable: CGSize) -> CGSize {
        fit(clean ? game : canvas == .wide ? CGSize(width: 16, height: 9) : CGSize(width: 9, height: 16), in: drawable)
    }

    static func fit(_ aspect: CGSize, in d: CGSize) -> CGSize {
        guard aspect.width > 0, aspect.height > 0, d.width > 0, d.height > 0 else { return .zero }
        let s = min(d.width / aspect.width, d.height / aspect.height)
        return CGSize(width: min(d.width, (aspect.width * s).rounded()), height: min(d.height, (aspect.height * s).rounded()))
    }
}
