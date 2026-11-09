# Plan 10: Scene model and layer compositor

**Goal.** Replace the hard-wired "game plus camera" shader with a compositor that draws any ordered list of layers,
and introduce the scene data model. The four existing layouts must render **identically** through the new path. No
user-visible change.

**Depends on:** 00. **Blocks:** 20, 22, 23, 30.

**Files you own:** `Render/MetalCore.swift`, `Render/LayerCompositor.swift`, `Render/LiveRenderer.swift`,
`Model/LayoutMath.swift`, new `Model/Scene.swift`, new `Render/SceneResolver.swift`, tests. One-line call-site
changes are allowed in `Edit/CompositionBuilder.swift`. Do not touch UI files or `Model/Project.swift`.

## Read first

`Render/MetalCore.swift` completely (the shader's colour maths is correct and stays), `Model/LayoutMath.swift`,
`Render/LiveRenderer.swift` (`drawNow`), `Render/LayerCompositor.swift` (`startRequest`), and the golden tests from
plan 00.

## Design

### Model (`Model/Scene.swift`)

```swift
enum Canvas            // exists: .wide (16:9), .vertical (9:16)

struct NRect: Codable, Equatable { var x, y, w, h: Double }     // normalized to the canvas, origin top-left

struct LayerSource: Codable, Equatable {
    var type: String            // "game" | "camera" | "image" | "text" | "color"
    var file: String?           // image: asset file name          (plan 23)
    var text: TextSpec?         // text                             (plan 23; declare as an empty Codable struct now)
    var color: [Double]?        // color: r, g, b, a in SDR BT.709 code values 0…1
    static let game = LayerSource(type: "game"), camera = LayerSource(type: "camera")
}

struct Layer: Codable, Equatable, Identifiable {
    var id = UUID()
    var name = ""
    var source: LayerSource
    var frame = NRect(x: 0, y: 0, w: 1, h: 1)   // where it sits on the canvas
    var fit = false          // false: crop the source to fill the frame; true: letterbox inside the frame
    var zoom = 1.0           // ≥ 1, crops further in
    var panX = 0.5, panY = 0.5                   // centre of the crop, normalized to the source
    var roundness = 0.0      // corner radius as a fraction of the frame's shorter side, 0…0.5
    var border = false, shadow = false, mirror = false
    var opacity = 1.0
    var visible = true
}

struct Composition: Codable, Equatable {        // one canvas of one scene
    var background: [Double] = [0.06, 0.06, 0.07, 1]
    var layers: [Layer] = []                    // bottom first
}

struct Scene: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var wide = Composition(), vertical = Composition()
    func composition(_ c: Canvas) -> Composition
}
```

Every struct decodes leniently with the existing `c.v(key, fallback)` helper (write `init(from:)` by hand as
`CameraPlacement` does) so later plans can add fields.

**Templates.** `extension Composition { static func from(layout: CanvasLayout, canvas: CGSize, hasCamera: Bool,
mirror: Bool) -> Composition }` converts today's `CanvasLayout` into layers:

| `LayoutKind` | Layers produced (bottom first) |
|---|---|
| `pip` | game full canvas (`fit`, `zoom`, `pan` from the layout); camera with `frame` = `layout.camera.rect(in: canvas)` normalized, `roundness`, `border`, `shadow` from the placement |
| `stacked` | with a camera: camera `frame` (0, 0, 1, split) then game `frame` (0, split, 1, 1 − split); without: game full |
| `screenOnly` | game full |
| `cameraOnly` | camera full |

Round the split row exactly as `LayoutMath.params` does (`(canvas.height * split).rounded()`), or goldens will differ
by a pixel row.

### Resolver (`Render/SceneResolver.swift`)

A pure function, no Metal:

```swift
struct SourceInfo { var size: CGSize }                       // pixel size of the source's frames
enum SourceKey: Hashable { case game, camera, layer(UUID) }  // layer(id): image/text/color owned by that layer

struct ResolvedLayer: Equatable {
    var key: SourceKey
    var dst: CGRect          // canvas pixels
    var src: CGRect          // normalized source crop
    var radius, border, shadow: CGFloat     // pixels
    var opacity: Double
    var mirror: Bool
    var color: SIMD4<Float>? // for color layers
}

enum SceneResolver {
    static func resolve(_ c: Composition, canvas: CGSize, sources: [SourceKey: SourceInfo]) -> [ResolvedLayer]
}
```

Rules, copied from `LayoutMath.params` so results match: a layer whose source is absent from `sources` (for example
no camera) is skipped; `fit` shrinks `dst` with `LayoutMath.fitRect` and uses the full-source crop adjusted by zoom
and pan; otherwise `src = LayoutMath.fillCrop(sourceSize:dst:zoom:panX:panY:)`; `border = max(2, dst.width * 0.018)`
when on; `shadow = max(6, dst.width * 0.08)` when on; `radius = min(0.5, roundness) * min(dst.width, dst.height)`.

### Renderer (`Render/MetalCore.swift`)

Add, next to the existing code:

```swift
struct LayerTextures {
    enum Kind { case biplanar(y: MTLTexture, c: MTLTexture, bits: Int32, transfer: Int32, bt709: Bool)
                case rgba(MTLTexture)                 // sRGB-encoded, premultiplied alpha (plan 23 uses it)
                case none }                           // color layers
}
struct DrawLayer { var resolved: ResolvedLayer; var textures: LayerTextures.Kind }

func encodeLayers(_ cb: MTLCommandBuffer, target: MTLTexture, viewport: MTLViewport? = nil,
                  canvas: CGSize, background: SIMD4<Float>, outTransfer: Int32, layers: [DrawLayer])
```

Implementation:

- One render pass. Clear to black, then draw the background as a full-canvas color layer, then one full-viewport
  quad per layer with a new fragment function `layerFrag` and a small per-layer uniform struct (canvas size, `dst`,
  `src`, shape, opacity, flags, formats, color). Set a scissor rectangle of `dst` grown by the shadow size so large
  canvases do not pay for full-screen quads.
- Blending on the colour attachment: source-over with **non-premultiplied** shader output
  (`rgb: sourceAlpha / oneMinusSourceAlpha`, `alpha: one / oneMinusSourceAlpha`). Pipelines are cached by
  `"fragment/pixelFormat"` today; add the blend flag to the key.
- `layerFrag` computes, for canvas pixel `p`: shape coverage `a = clamp(0.5 − sdRoundRect(p, …), 0, 1) × opacity`;
  shadow alpha `s = 0.45 × (1 − smoothstep(−shadow/2, shadow, sdRoundRect(p − (0, 0.35·shadow), …))) × opacity`
  (zero when shadow is off); the layer colour `cc` (sampled and converted with the existing `yuvToRgb` and `convert`,
  including the border mix exactly as `composite()` does it). It returns alpha `A = a + s − a·s` and colour
  `cc × a / A` (black when `A` is 0). Over the destination this equals the current two-step
  `mix(mix(col, 0, s), cc, a)`. Write that identity in a comment; it is why goldens match.
- The `.rgba` kind samples one texture, un-premultiplies, treats the colour as SDR BT.709 (`convert(rgb, 2, out)`)
  and multiplies coverage by the texture alpha.
- When a layer's transfer equals the output transfer, `convert` returns its input untouched. Keep that: the live
  game picture must pass through bit-exact.

Keep `encodeComposite`, `composite()` and `CompParams` until the last step, then delete them.

### Call sites

- `Renderer.drawNow`: build a `Composition` with `Composition.from(layout: CanvasLayout(kind: .pip, camera:
  ov.placement), …)`, resolve it for the view-sized canvas, and call `encodeLayers`. Game textures are `.biplanar`
  with `bits: 10`, `transfer: colorMode.transfer`, `bt709: colorMode == .sdr`; camera from `MetalCore.planes(pb)` with
  transfer 2 and BT.709.
- `CompositionInstruction`: replace `params: CompParams` with `composition: Composition`, `canvas: CGSize`,
  `outTransfer: Int32`, `screenSize`, `cameraSize`. `LayerCompositor.startRequest` resolves per request and reads each
  source's transfer and matrix from the buffer's attachments, as `CompParams.adopt(screen:)` and `adopt(camera:)` do
  today (move that logic into a helper that returns `(transfer, bt709)` for a pixel buffer).
- `CompositionBuilder.videoComposition`: build the instruction from `Composition.from(layout: p.layout(canvas), …)`.

### Fix on the way (audit finding 8)

`Renderer.ring`, `ringW`, `ringH` are written on the reader thread in `ensureRing` and read on the main thread in
`tick`. Guard them with the existing `lock`: build the new textures outside the lock, swap them in under it, and have
`tick` copy the pair it needs while holding the lock.

## Steps

1. Model, templates, resolver, with unit tests: for each `LayoutKind`, both canvases, with and without camera, assert
   that the resolved rectangles equal the `screenDst`/`screenSrc`/`camDst`/`camSrc`/`shape` values from
   `LayoutMath.params` (tolerance 0.001).
2. `layerFrag` and `encodeLayers`. Extend the plan 00 golden test with a second render path through
   `Composition.from` → `resolve` → `encodeLayers` and assert it matches the **same** golden files. Do not
   regenerate goldens. Tolerance 0.002.
3. New goldens for what the old shader could not do: three overlapping layers with different opacity, a color layer,
   an `.rgba` layer with partial alpha, game as a small rounded window over a full-canvas camera.
4. Switch the three call sites. Run the plan 00 export tests.
5. Ring race fix.
6. Delete `encodeComposite`, `composite()`, `compositeFrag`, `CompParams`, `LayoutMath.params` once nothing uses
   them. Keep `fillCrop` and `fitRect`.

## Acceptance

1. `swift test` passes, including the unchanged plan 00 goldens rendered through the new path.
2. Demo run in Game presentation: the log's "helper->screen" average is within 1 ms of the plan 00 baseline, and
   "draw … ms/frame" does not grow by more than 0.2 ms. Paste both lines, before and after.
3. Fixture project export for both canvases, HDR and SDR, passes the plan 00 `ExportTests`.
4. A screenshot comparison of one exported frame before and after this plan (use
   `ffmpeg -ss 1 -i <export> -frames:v 1 frame.png` on both builds): maximum pixel difference at most 2 of 255.

## Pitfalls

- Metal texture coordinates and canvas pixels both have a top-left origin here; the vertex function already flips Y.
  Reuse `vtx`.
- A uniform struct shared between Swift and Metal must have identical layout: use only `SIMD4<Float>` and
  `SIMD4<Int32>` members, as `CompParams` does.
- Blending happens in the output encoding (PQ, HLG or gamma), which is not physically linear. That is intentional and
  matches today's output; do not "fix" it in this plan.
- The HDR export path renders into an `.rgba16Float` intermediate and then converts to P010. Its alpha channel is
  ignored; make sure the clear alpha is 1.
- Shared-memory textures are only valid for about two frame times. Encode and commit in the same call as today; do
  not defer the draw to another queue.

## Out of scope

Persisting scenes, any UI, image or text sources (only the `.rgba` shader path and its golden), transitions,
changing `project.json`.
