import AppKit
import Metal
import QuartzCore

/// The live view. Besides hosting the Metal layer it lets you arrange the active scene's layers directly on the
/// picture (`LayerCanvasView`, with the rules in `LayerInteraction`, shared with the editor preview).
final class MetalView: LayerCanvasView {
    let metalLayer: CAMetalLayer
    /// Pixel size of the game frames, for laying out layers outside the renderer.
    var gameSize = CGSize(width: 1920, height: 1080)
    weak var scenes: SceneModel? { didSet { editing = scenes } }

    init(frame: NSRect) {
        let l = CAMetalLayer()
        metalLayer = l
        super.init(frame: frame, host: l)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); updateDrawableSize() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); updateDrawableSize() }
    func updateDrawableSize() {
        let s = window?.backingScaleFactor ?? 2
        metalLayer.contentsScale = s
        metalLayer.drawableSize = CGSize(width: bounds.width * s, height: bounds.height * s)
    }
}
