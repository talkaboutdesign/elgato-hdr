# 42. Picture controls

## Goal

The only manual picture control today is "SDR brightness" (plan 41), hidden in the Stream tab. The user wants to
adjust the picture by hand. Add seven controls for the game and, separately, for the camera: Exposure, Contrast,
Highlights, Shadows, Saturation, Temperature and Tint. They live in the sidebar's Picture section and act on the next
frame everywhere the source is drawn: live window, stream, scene thumbnails, editor preview and exports (roadmap
principle 2, "one compositor everywhere").

Read `AGENTS.md` and `plans/41-sdr-brightness.md` first. This plan follows plan 41's pattern (a global setting in
`UserDefaults`, read by render threads through a locked snapshot, passed into `MetalCore.encodeLayers`); wherever
this plan is silent, do what `sdrWhiteNits` does.

## Decisions (do not reopen)

- **Global settings, not per recording.** One grade for the game and one for the camera, in `UserDefaults`.
  Recordings stay raw (principle 1). The editor and exports apply the current grades, as they do SDR brightness.
- **Neutral costs nothing and changes nothing.** With every control at its default the shader takes today's path
  and output is bit-identical. Every existing golden test must pass unchanged, without regenerating goldens.
- **Grading happens in linear light**, between `toLinear` and `encodeOut`, in the existing `layerFrag`. No second
  pass, no new pipeline, no new texture.
- **Only video layers are graded** (`LayerTextures.Kind.biplanar` with `ResolvedLayer.key` `.game` or `.camera`).
  Images, text, colours, borders, frames and shadows are never graded.
- No third-party code, no LUT files, no presets, no per-scene grades, no histogram or scopes. Those are later work.

## Model: `Sources/StudioKit/App/PictureAdjust.swift` (new)

```swift
struct PictureGrade: Equatable, Codable {
    var exposure = 0.0      // stops,   -2...2
    var contrast = 0.0      // percent, -100...100
    var highlights = 0.0    // percent, -100...100
    var shadows = 0.0       // percent, -100...100
    var saturation = 100.0  // percent, 0...200
    var temperature = 0.0   // percent, -100...100 (positive is warmer)
    var tint = 0.0          // percent, -100...100 (positive is magenta)
    var isNeutral: Bool
    func clamped() -> PictureGrade
    var uniforms: (gain: SIMD4<Float>, tone: SIMD4<Float>)   // see "Uniforms"
}
struct PictureGrades: Equatable { var game = PictureGrade(), camera = PictureGrade() }

@Observable final class PictureAdjust   // modelled on SdrBrightness, same file layout and comments style
```

`PictureAdjust` mirrors `SdrBrightness` exactly: `static let shared` (publishes), `init(store:publishes:)` for
tests, `static var current: PictureGrades` behind an `NSLock` (a single load or store per hold), main-thread
setters that clamp, persist and publish. Persist each grade as JSON `Data` under the keys `pictureGradeGame` and
`pictureGradeCamera`. Decode leniently: a missing or unreadable value is neutral, a missing field takes its default,
non-finite or out-of-range numbers are clamped (write a custom `init(from:)`, do not rely on the synthesized one).
Offer `reset(_ source:)`.

### Uniforms

Computed on the CPU so the shader does no `exp2` per pixel that it can avoid:

- `gain.rgb` = white balance gains times `2^exposure`. With `t = temperature / 100`, `n = tint / 100`:
  `w = (2^(0.30 t + 0.15 n), 2^(-0.30 n), 2^(-0.30 t + 0.15 n))`, then divide `w` by
  `dot(w, (0.2627, 0.6780, 0.0593))` so a neutral grey keeps its luminance, then multiply by `2^exposure`.
- `gain.w` = contrast exponent `1.5^(contrast / 100)` (0.667...1.5).
- `tone.x` = shadows in stops, `shadows / 100 * 1.5`; `tone.y` = highlights in stops, `highlights / 100 * 1.5`.
- `tone.z` = `saturation / 100`.
- `tone.w` = `1` when the grade is not neutral, else `0`. Neutral grades must produce exactly
  `gain = (1, 1, 1, 1)`, `tone = (0, 0, 1, 0)`.

## Shader: `Sources/StudioKit/Render/MetalCore.swift`

Add `float4 gradeGain, gradeTone;` at the end of `LayerU` and the matching fields at the end of `LayerParams`
(defaults as above). Keep the two structs in the same order and check `MemoryLayout<LayerParams>.stride` still
matches the Metal struct (both grow by 32 bytes).

```metal
// Manual picture controls, in linear light (BT.2020, 1.0 = 10000 nits). The pivot is 18% grey of SDR white.
float3 grade(float3 l, float4 gain, float4 tone) {
    const float p = 0.18 * 0.0203;
    l *= gain.rgb;                                              // white balance and exposure
    float Y = max(luma2020(l), 1e-7);
    float x = Y / p;
    float Y2 = Y * exp2((tone.x + tone.y * x) / (1.0 + x));     // shadows weigh p/(p+Y), highlights Y/(p+Y)
    Y2 = p * pow(Y2 / p, gain.w);                               // contrast around the pivot
    l *= Y2 / Y;                                                // on luminance, so hue is kept
    return max(mix(float3(Y2), l, tone.z), 0.0);                // saturation
}
```

The tone step is monotonic for every allowed value (its log-log slope is at least `1 - 3 ln2 / 4 > 0` because
shadows and highlights differ by at most 3 stops), so no control can invert tones. Keep that comment in the code.

In `layerFrag`, only in the biplanar branch:

```metal
float3 e = yuvToRgb(tY, tC, uv, u.fmt.w, u.flags.x != 0);
if (u.gradeTone.w == 0.0) cc = convert(e, u.fmt.y, out, sdrWhite);           // today's path, untouched
else {
    float3 l = grade(toLinear(e, u.fmt.y), u.gradeGain, u.gradeTone);
    cc = (u.fmt.y == 2 && out == 2) ? linearToSdrPlain(l) : encodeOut(l, out, sdrWhite);
}
```

`linearToSdrPlain(l)` is `pow(clamp(m2020to709 * l / 0.0203, 0.0, 1.0), 1.0 / 2.4)`: the exact inverse of
`sdrToLinear`. It is needed because `linearToSdr` rolls off highlights above 0.7 and applies SDR brightness, and an
SDR source drawn to SDR output (the camera on a stream) must not be tone-mapped: with it, a nearly neutral grade is
continuous with the neutral path. HDR sources into SDR output keep `linearToSdr` with the user's SDR brightness.

`encodeLayers` gains a parameter `grades: PictureGrades = PictureAdjust.current`, next to `sdrWhiteNits`. In the
layer loop set `u.gradeGain` / `u.gradeTone` from `grades.game` or `grades.camera` only when the layer is
`.biplanar` and its `resolved.key` is `.game` or `.camera`; every other draw keeps the neutral defaults.
The opaque-cover optimisation is unaffected (a grade does not change coverage).

## Where grades flow

Find every `sdrWhiteNits` in `Sources/` (`grep -rn sdrWhiteNits Sources`) and carry `grades` beside it:

- `LiveRenderer`, `ProgramOutput`, `SceneThumbnailer`, `AppDelegate+ScenesDebug`: read `PictureAdjust.current` once
  per frame, on the thread that already reads `SdrBrightness.current`. One lock hold per frame, never per layer.
- `LayerCompositor` / `CompositionBuilder`: commit 27759e9 fixed SDR brightness for the length of an export
  (`sdrWhiteNits: waitForOverlays ? SdrBrightness.current : nil`). Do the same for grades: an export captures them
  when it starts, the editor preview reads them per frame.
- `Render/LiveRenderer.swift` has paths that draw the game without `encodeLayers` (search for the pass-through and
  snapshot paths). If any path shows the game in the live window while bypassing `layerFrag`, grade must still
  apply there; say in the pull request which paths exist and what you did. Do not add a pass to the neutral case.

## UI

`Sources/StudioKit/UI/Studio/StudioSidebar.swift`, `PictureSection`, under the Presentation switch:

- A `Divider().opacity(0.4)`, then a `SegmentedSwitch` "Game | Camera" choosing which grade the sliders edit
  (view state only, defaults to Game).
- Seven `LabeledSlider`s in this order: Exposure (`%+.1f EV`, step 0.1), Contrast, Highlights, Shadows
  (`%+.0f`), Saturation (`%.0f%%`), Temperature, Tint (`%+.0f`). Whole numbers except Exposure, rounded in the
  setter so the read-out does not flicker. Double-click resets one control (built into `LabeledSlider`).
- A "Reset" button (`.buttonStyle(.link)` or the design system's quiet button, whichever the sidebar already uses),
  disabled while the selected grade is neutral, that resets the selected source.
- When the game grade is selected, show `SdrBrightnessControl()` below the sliders as well. Leave it in the Stream
  tab and the export sheet too.
- Each slider gets a one-line `.help`. Accessibility labels come from `LabeledSlider`.
- A View menu item is not needed.

Use design system components and tokens only (`DS.*`, `InspectorSection`, `InspectorRow`, `LabeledSlider`,
`SegmentedSwitch`). If the section gets too tall for the sidebar at the minimum window height, it must scroll with
the rest of the tab, not clip.

`Sources/StudioKit/UI/Editor/ExportSheet.swift`: when either grade is not neutral, show one secondary line under
the existing controls: "Picture adjustments from the Studio sidebar are applied." No controls there.

## Tests: `Tests/PictureAdjustTests.swift` (new)

Model the rendering tests on the existing SDR brightness tests (`grep -rln SdrBrightness Tests`).

1. Model: defaults are neutral; clamping; JSON round trip; lenient decode (missing key, missing field, garbage,
   NaN, out of range); a private `UserDefaults` suite, never `.standard`; `publishes: false` leaves `current` alone.
2. Neutral uniforms are exactly `(1,1,1,1)` and `(0,0,1,0)`; a neutral `encodeLayers` render is byte-identical to a
   render without the parameter, for PQ->PQ, PQ->SDR and SDR->SDR.
3. Direction, each on a mid-grey and a colour patch, PQ source to SDR and to PQ output, and SDR source (camera) to
   SDR output: exposure +1 raises luma and -1 lowers it; contrast + moves a dark patch down and a bright patch up;
   shadows + raises a dark patch much more than a bright one; highlights - lowers a bright patch much more than a
   dark one; saturation 0 gives R = G = B (within one code value) and 200 raises chroma; temperature + raises R/B;
   tint + lowers G relative to R and B.
4. Continuity: exposure 0.01 EV on an SDR->SDR patch at code value 0.9 differs from neutral by at most one 8-bit
   code value (this is what `linearToSdrPlain` is for).
5. Monotonicity: a 64-step grey ramp stays non-decreasing at the four corners shadows/highlights = +-100 with
   contrast +-100.
6. Scope: with a strong game grade, an image layer, a colour layer and the camera layer render exactly as before.
7. Export fixity: grades changed after an export's composition is built do not change that export.

All existing tests, including every golden test, must pass without changing a golden file.

## Acceptance checks (paste real output in the pull request)

1. `swift build` and `swift test` pass. CI (Xcode 16.4, Swift 6.1) is green: see "Older compiler on CI" in
   `AGENTS.md`; give closure parameters explicit types and split long arithmetic.
2. Bundled demo run (`./build.sh`, then the app with `--demo-source --demo-camera`): `EHDR_SNAPSHOT` of the sidebar
   showing the new controls for Game and for Camera, at the default and the minimum window size, attached to the
   pull request.
3. Before/after scene renders with a visible grade (use the existing debug dump hooks; see `dumptest.sh`,
   `AppDelegate+ScenesDebug.swift`), attached.
4. Live cost in Game mode, demo source, 60 s each, at neutral and with every control non-neutral for both sources:
   the `draw ms/frame` and `reader cost` log lines, plus "helper->screen" if the screen is unlocked (if it is
   locked it reads 0.0: say so, do not report it as a result). Neutral must match `main` within noise. If the
   non-neutral case adds more than 0.3 ms per frame at 1440p60, stop and report.
5. A stream check with the script the repository already has (`scripts/stream-scenes-check.sh`) still passes.

## Environment notes

- The screen is usually locked: nothing is presented, `screencapture` fails. Use `EHDR_SNAPSHOT` and the debug dumps.
- Demo runs write the real defaults domain `dev.max.elgato-hdr`. Afterwards delete only the keys your run wrote
  (`defaults delete dev.max.elgato-hdr <key>`), including `pictureGradeGame` / `pictureGradeCamera`. Never delete
  the whole domain. Pass `-recordingsDir <scratch>` and set `EHDR_SCENES_FILE` to a scratch file.
- The user's own copy of the app may be running from another checkout. Never `pkill` by name; kill only PIDs you
  started.
- Branch `plan/42-picture-controls` (this plan is already committed there), pull request against `main`. Do not
  merge. Finish by updating the status table in `plans/README.md` with a row for plan 42 and appending
  "## Acceptance results" to this file.

## When to stop and ask

The neutral path cannot stay bit-identical; a live path bypasses `layerFrag` in a way that would need a second
render pass; or the cost limit in check 4 is exceeded.
