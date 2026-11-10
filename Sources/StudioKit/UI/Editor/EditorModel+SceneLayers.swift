import CoreGraphics
import Foundation
import SwiftUI

/// The inspector's layout controls and the preview's direct manipulation act on the scene the playhead shows. A
/// scene migrated from a fixed layout (`legacyLayout`) keeps the layout controls; any other scene (templates, plan 22
/// scenes) is edited through its own game and camera layers and never rebuilt from the project's default layout.
extension EditorModel {
    enum SceneLayerRole { case game, camera
        var type: String { self == .game ? "game" : "camera" }
    }

    /// What the inspector and the preview offer for the active scene on the current canvas.
    struct SceneControls: Equatable {
        var legacy = false        // layout kind, camera placement and split: the fixed-layout controls
        var game = false          // fit, zoom, pan of the scene's game layer
        var camera = false        // corners, border, shadow, move and resize of its camera layer
    }

    /// The scene at the playhead, resolved as `RenderPlan` resolves it (spans of deleted scenes are ignored).
    var activeSceneIndex: Int? {
        project.scenes.firstIndex { $0.id == activeSceneID } ?? (project.scenes.isEmpty ? nil : 0)
    }
    var activeScene: Scene? { activeSceneIndex.map { project.scenes[$0] } }

    var sceneControls: SceneControls {
        // No scenes at all renders the project's default layout (`Project.defaultScene`).
        guard let c = activeScene?.composition(canvas) else { return SceneControls(legacy: true, game: true, camera: hasCamera) }
        if c.legacyLayout != nil { return SceneControls(legacy: true, game: true, camera: hasCamera) }
        return SceneControls(legacy: false, game: c.layers.contains { $0.source.type == "game" },
                             camera: hasCamera && c.layers.contains { $0.source.type == "camera" })
    }

    func sceneLayer(_ role: SceneLayerRole) -> Layer? {
        activeScene?.composition(canvas).layers.first { $0.source.type == role.type }
    }

    /// Edits one layer of the active scene in place; the scene's other layers are untouched.
    func updateSceneLayer(_ role: SceneLayerRole, _ name: String, _ f: (inout Layer) -> Void) {
        guard let i = activeSceneIndex else { return }
        let c = canvas
        update(name) { p in
            guard i < p.scenes.count else { return }
            var comp = p.scenes[i].composition(c)
            guard comp.legacyLayout == nil, let j = comp.layers.firstIndex(where: { $0.source.type == role.type }) else { return }
            f(&comp.layers[j])
            if c == .wide { p.scenes[i].wide = comp } else { p.scenes[i].vertical = comp }
        }
    }

    func sceneLayerBinding<T>(_ role: SceneLayerRole, _ kp: WritableKeyPath<Layer, T>, _ name: String, fallback: T) -> Binding<T> {
        Binding(get: { self.sceneLayer(role)?[keyPath: kp] ?? fallback },
                set: { v in self.updateSceneLayer(role, name) { $0[keyPath: kp] = v } })
    }

    /// Reframes the game layer by a drag on the preview (`stage` is the preview's size), from the pan it had when the
    /// drag began: the picture follows the pointer.
    func panSceneGame(from start: (x: Double, y: Double), translation: CGSize, stage: CGSize) {
        guard let g = sceneLayer(.game), stage.width > 0, stage.height > 0 else { return }
        let frame = renderPlan(size: stage).layers(atTimelineMs: playheadMs).first { $0.key == .game }?.dst ?? g.frame.rect(in: stage)
        let source = gameSize
        let crop = g.fit ? LayoutMath.fillCrop(sourceSize: source, dst: source, zoom: g.zoom, panX: g.panX, panY: g.panY)
                         : LayoutMath.fillCrop(sourceSize: source, dst: frame.size, zoom: g.zoom, panX: g.panX, panY: g.panY)
        let dx = Double(translation.width / max(1, frame.width)) * crop.width
        let dy = Double(translation.height / max(1, frame.height)) * crop.height
        updateSceneLayer(.game, "Reframe") { $0.panX = min(1, max(0, start.x - dx)); $0.panY = min(1, max(0, start.y - dy)) }
    }

    /// Moves the camera layer with the pointer, kept inside the canvas.
    func moveSceneCamera(from start: NRect, translation: CGSize, stage: CGSize) {
        let sw = Double(stage.width), sh = Double(stage.height)
        guard sw > 0, sh > 0 else { return }
        let x: Double = start.x + Double(translation.width) / sw, y: Double = start.y + Double(translation.height) / sh
        updateSceneLayer(.camera, "Move Camera") {
            $0.frame.x = min(1 - start.w, max(0, x)); $0.frame.y = min(1 - start.h, max(0, y))
        }
    }

    /// Resizes the camera layer around its centre from a corner drag, keeping its proportions.
    func resizeSceneCamera(from start: NRect, corner: CGPoint, stage: CGSize) {
        let sw = Double(stage.width), sh = Double(stage.height), px = Double(corner.x), py = Double(corner.y)
        guard sw > 0, sh > 0, start.w > 0, start.h > 0 else { return }
        let cx: Double = (start.x + start.w / 2) * sw, cy: Double = (start.y + start.h / 2) * sh
        let kx: Double = abs(px - cx) / (start.w * sw / 2), ky: Double = abs(py - cy) / (start.h * sh / 2)
        let smallest: Double = 0.08 / min(start.w, start.h)
        let scale: Double = min(1 / start.w, 1 / start.h, max(smallest, max(kx, ky)))
        let w = start.w * scale, h = start.h * scale
        updateSceneLayer(.camera, "Resize Camera") {
            $0.frame = NRect(x: min(1 - w, max(0, start.x + start.w / 2 - w / 2)), y: min(1 - h, max(0, start.y + start.h / 2 - h / 2)), w: w, h: h)
        }
    }
}
