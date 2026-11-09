# Plan 23: Overlays (image and text layers, templates)

**Goal.** Add image and text layers that work everywhere the compositor runs: live view, stream, editor preview and
export. Ship a small set of good-looking templates (starting soon, be right back, name tag, webcam frame).

**Depends on:** 10 for the engine part (steps 1–3). The UI part (steps 4–5) needs 22.

**Files you own:** new `Sources/StudioKit/Overlays/`, the `.rgba` path of `Render/MetalCore.swift` if it needs
fixes, additions to the Scene tab and scene templates, tests.

## Design

### Assets

- Images are copied on import into `~/Library/Application Support/Elgato HDR/Assets/<sha256-prefix>.<ext>`;
  `LayerSource.file` stores that file name. Supported: PNG, JPEG, HEIC, TIFF, and the first frame of a GIF.
- When a recording starts, every asset referenced by the scene collection is hard-linked or copied into the
  project's `Assets/` folder so a project folder stays self-contained. Lookup order when rendering a project:
  project `Assets/`, then the application support folder.

### Text

```swift
struct TextSpec: Codable, Equatable {
    var string = "Text"
    var fontName = ""                 // empty = system font
    var weight = "semibold"           // regular, medium, semibold, bold, heavy
    var color: [Double] = [1, 1, 1, 1]
    var alignment = "center"
    var plate: [Double]? = nil        // background colour behind the text, nil = none
    var plateRadius = 0.3             // fraction of the plate height
    var platePadding = 0.35           // fraction of the font size
    var shadow = true
}
```

The layer's `frame` defines the box; the font size is the largest that fits the box height (single line) or wraps
within the box width (multi-line when the string contains line breaks). Tokens replaced at render time: `{time}`
(local clock, `HH:mm`), `{timer}` (elapsed recording or stream time). A text layer with tokens re-rasterizes once a
second.

### Texture provider

```swift
final class OverlayTextureCache {
    static let shared: OverlayTextureCache
    /// Returns a premultiplied BGRA sRGB texture for an image or text layer at the pixel size it will be drawn.
    func texture(for layer: Layer, pixelSize: CGSize, assets: [URL]) -> MTLTexture?
}
```

- Images: decode with `CGImageSource` (thumbnail API limited to the larger of the draw size and 2048 px), draw into
  a premultiplied BGRA `CGContext` in sRGB, upload once, cache by file name and size bucket.
- Text: rasterize with CoreText into the same kind of context at exactly the pixel size, cache by the hash of the
  spec, the resolved string and the size.
- Rasterizing happens off the render threads. If a texture is not ready, the layer is skipped for that frame; it
  appears a frame or two later. The reader thread never waits.
- Call sites: `Renderer.drawNow`, `ProgramOutput`, `LayerCompositor.startRequest` map `SourceKey.layer(id)` to
  `DrawLayer(textures: .rgba(texture))`. For export, pre-warm every overlay texture before the reader starts so no
  exported frame is missing an overlay.

Colour: overlays are SDR content. In HDR output the shader places SDR white at 203 nits (existing `sdrToLinear`),
so text and images do not glow next to HDR game highlights.

### UI (after plan 22)

- Add-layer menu in the Scene tab: Image… (open panel), Text, Color. Dragging an image file onto the picture adds
  it at the drop point.
- Text is edited in the inspector (string, font, weight, colour, plate) and updates live. Double-click a text
  layer on the picture focuses the inspector's text field.
- Image inspector: replace file, opacity, corner roundness, shadow, fit or fill.
- Templates in the scene gallery, built only from colour, text and the camera or game layers (no bundled artwork
  beyond what you draw in code): **Starting Soon** (dark gradient-like two-tone background, large title, `{time}`),
  **Be Right Back**, **Ending**, plus layer presets **Name tag** (text on a rounded plate, bottom-left) and
  **Camera frame** (a border ring around the camera layer).

## Steps

1. Asset store and `OverlayTextureCache` for images; golden test rendering a PNG with partial alpha over the game
   in SDR and PQ output.
2. `TextSpec` rasterizer; golden tests for plate, alignment, multi-line; token replacement test.
3. Call sites, including export pre-warming; export test: the fixture project with an image and a text layer
   exports, and a frame extracted from the result contains the overlay (compare a region against the golden).
4. Scene tab additions, drag and drop.
5. Templates and layer presets.

## Acceptance

1. `swift test` passes.
2. Demo run with one 4K PNG and three text layers: live latency within 1 ms of the baseline; no rasterization on
   the reader thread (assert with a debug check on the thread name).
3. A demo recording made in a scene with overlays keeps them in the editor preview and in both exports; the
   project folder contains `Assets/` and still opens after the application support `Assets` folder is renamed.
4. Screenshots of each template in 16:9 and 9:16.

## Pitfalls

- `CGContext` output is premultiplied and bottom-up; the shader un-premultiplies and Metal's origin is top-left.
  Get one golden right first.
- Very large images: never upload more than 4096 px on the long side.
- Fonts chosen by the user may be missing on another Mac; fall back to the system font and keep the stored name.

## Out of scope

Animated images and video overlays, browser sources (alerts, chat widgets), captions, stingers, per-overlay
animations. See plan 90.
