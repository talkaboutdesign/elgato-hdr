import CoreGraphics
import Foundation

/// Pixel size of a source's frames.
struct SourceInfo { var size: CGSize }
/// `layer(id)`: an image, text or color source owned by that layer.
enum SourceKey: Hashable { case game, camera, layer(UUID) }

/// A layer in canvas pixels, ready for `MetalCore.encodeLayers`.
struct ResolvedLayer: Equatable {
    var key: SourceKey
    var dst: CGRect                     // canvas pixels
    var src: CGRect                     // normalized source crop
    var radius, border, shadow: CGFloat // pixels
    var opacity: Double
    var mirror: Bool
    var color: SIMD4<Float>?            // color layers
    /// Clip to `dst` with no edge anti-aliasing. The former fixed shader drew the game that way, so a letterboxed
    /// game whose edge falls on a half pixel keeps whole edge rows instead of blending them with the background.
    var hardEdge = false
}

/// Turns a composition into drawable layers for one canvas size. Pure; the rules are the ones the fixed layouts have
/// always used, so a template resolves to the same rectangles the old shader parameters held.
enum SceneResolver {
    static func resolve(_ c: Composition, canvas: CGSize, sources: [SourceKey: SourceInfo]) -> [ResolvedLayer] {
        // Source availability changes rendering only; authored frames and overlay placement remain intact.
        let gameOnly = sources[.camera] == nil && c.layers.contains { $0.source.type == "camera" && $0.visible && $0.opacity > 0 }
        let mainGame = c.layers.filter { $0.source.type == "game" && $0.visible && $0.opacity > 0 }.max { $0.frame.w * $0.frame.h < $1.frame.w * $1.frame.h }?.id
        return c.layers.compactMap { original in
            var l = original
            if gameOnly && l.id == mainGame { l.frame = NRect(x: 0, y: 0, w: 1, h: 1) }
            guard l.visible, l.opacity > 0 else { return nil }
            var dst = l.frame.rect(in: canvas), src = CGRect(x: 0, y: 0, width: 1, height: 1), color: SIMD4<Float>?
            let key: SourceKey
            switch l.source.type {
            case "game": key = .game
            case "camera": key = .camera
            case "color":
                guard let rgba = rgba(l.source.color) else { return nil }
                key = .layer(l.id); color = rgba
            case "image", "text": key = .layer(l.id)
            default: return nil
            }
            if color == nil {
                guard let size = sources[key]?.size else { return nil }
                if l.fit {
                    dst = LayoutMath.fitRect(size, in: dst)
                    src = LayoutMath.fillCrop(sourceSize: size, dst: size, zoom: l.zoom, panX: l.panX, panY: l.panY)
                } else {
                    src = LayoutMath.fillCrop(sourceSize: size, dst: dst.size, zoom: l.zoom, panX: l.panX, panY: l.panY)
                }
            }
            var r = ResolvedLayer(key: key, dst: dst, src: src,
                                  radius: min(0.5, max(0, l.roundness)) * min(dst.width, dst.height),
                                  border: l.border ? max(2, dst.width * 0.018) : 0,
                                  shadow: l.shadow ? max(6, dst.width * 0.08) : 0,
                                  opacity: min(1, l.opacity), mirror: l.mirror, color: color)
            // Only the plain game: a square-cornered facecam without border or shadow was always anti-aliased.
            r.hardEdge = key == .game && r.radius == 0 && r.border == 0 && r.shadow == 0
            return r
        }
    }

    /// r, g, b and optional a; nil unless at least three components.
    static func rgba(_ v: [Double]?) -> SIMD4<Float>? {
        guard let v = v, v.count >= 3 else { return nil }
        return SIMD4(Float(v[0]), Float(v[1]), Float(v[2]), Float(v.count > 3 ? v[3] : 1))
    }
}

extension Composition {
    var backgroundColor: SIMD4<Float> { SceneResolver.rgba(background) ?? SIMD4(0, 0, 0, 1) }
}
