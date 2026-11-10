# Plan 30: Editor timeline engine (cuts, scene track, zoom track, render plan)

**Goal.** The editor's data model and render path support what a stream editor needs: cut out sections, change
scenes over time with the same transitions as live, and zoom in on moments with eased motion. Preview and export
stay identical because both evaluate the same pure function. This plan delivers the engine with a minimal UI hook;
the real timeline UI is plan 31.

**Depends on:** 10. Uses the event log from 22 when present (decode leniently when absent).

**Files you own:** `Model/Project.swift`, `Model/ProjectDoc.swift`, `Edit/CompositionBuilder.swift`,
`Edit/Exporter.swift`, `Render/LayerCompositor.swift`, new `Edit/Timeline.swift` and `Edit/RenderPlan.swift`,
`UI/EditorModel.swift` (only to keep it compiling and working), tests. Reuse `Scenes/SceneEngine.swift` from plan
22 for transitions; if 22 has not merged, implement cut and fade here behind the same function signature and leave
morph to be wired when it lands.

## Design

### Project version 2

```swift
struct Segment: Codable, Equatable { var startMs: Double; var endMs: Double }       // kept range of the source
struct SceneSpan: Codable, Equatable { var id = UUID(); var startMs: Double; var sceneID: UUID
                                       var transition = SceneTransition() }        // lasts until the next span
struct ZoomBlock: Codable, Equatable { var id = UUID(); var startMs, endMs: Double
                                       var scale = 1.8; var focusX = 0.5, focusY = 0.5   // normalized in the game picture
                                       var easeMs = 450.0 }
struct Marker: Codable, Equatable { var id = UUID(); var tMs: Double; var label = "" }

struct Timeline: Codable, Equatable {
    var segments: [Segment] = []          // ordered, non-overlapping; empty means "everything"
    var sceneSpans: [SceneSpan] = []
    var zooms: [ZoomBlock] = []
    var markers: [Marker] = []
}
// Project gains: var timeline = Timeline();  scenes and events exist from plan 22 (declare them here if absent)
```

**All times are source milliseconds**: positions in the original recording. Cutting a section never shifts scene
spans, zooms or markers; items inside a removed range are simply not reached.

**Migration when loading version 1** (in `Project.init(from:)`, then `version = 2`):

- `scenes` empty → one scene "Default" built from the old `wide` and `vertical` layouts with
  `Composition.from(layout:)`.
- `timeline.segments` empty and trim set → one segment `[trimStartMs, trimEnd]`.
- `timeline.sceneSpans` empty → from `events` of type `"scene"` when present, else one span at 0 for the first scene.
- `events` `zoomIn`/`zoomOut` pairs → `ZoomBlock`s.
- Keep writing `trimStartMs`/`trimEndMs` as the outer bounds of the segments, and keep `wide`/`vertical`, so an
  older app version still opens the project (it will ignore the new edits).

### Time mapping (`Edit/Timeline.swift`, pure)

```swift
struct TimeMap {
    init(segments: [Segment], sourceDurationMs: Double)
    var durationMs: Double                                  // sum of segment lengths
    func source(fromTimeline t: Double) -> Double
    func timeline(fromSource s: Double) -> Double?          // nil inside a cut
    func cutPoints() -> [Double]                            // timeline positions where a cut occurs
}
```

Editing helpers (pure, unit-tested): `split(atSourceMs:)`, `remove(sourceRange:)`, `restore(sourceRange:)`,
`normalize()` (merge touching segments, drop segments shorter than one frame).

### Render plan (`Edit/RenderPlan.swift`, pure)

```swift
struct RenderPlan {                       // immutable snapshot handed to the compositor
    var scenes: [Scene]; var timeline: Timeline; var map: TimeMap
    var canvas: Canvas; var canvasSize: CGSize
    var sources: [SourceKey: SourceInfo]; var mirrorCamera: Bool
    func layers(atTimelineMs t: Double) -> [ResolvedLayer]
}
```

`layers(atTimelineMs:)`:

1. `s = map.source(fromTimeline: t)`.
2. Scene: the span active at `s`, and the previous one if `s` is within the span's transition duration of its
   start; build the same interpolation the live engine uses (`SceneEngine`), with progress from `s − span.startMs`.
   A transition does not run across a cut: if a cut point lies between the span start and `s`, treat the transition
   as finished.
3. Zoom: for each block, weight `w(s)` rises with ease-in-out cubic over `easeMs` after `startMs` and falls over
   `easeMs` before `endMs`. Apply to every layer whose source is the game: scale its `src` rectangle by
   `1 / lerp(1, scale, w)` around the focus point (mapped into the layer's current crop) and clamp it inside the
   source. Overlapping blocks: the larger weight wins. The same focus works for both canvases because it is
   expressed in the game picture, not in the canvas.
4. Return resolved layers for `encodeLayers`.

### Composition and compositor

- `CompositionBuilder.build`: for each segment, `insertTimeRange` the game video, game audio, camera (shifted by
  its `offsetMs`) and mic (shifted) for that source range, appended in order. A camera or mic range that falls
  partly outside its file inserts what exists; the compositor already treats a missing camera frame as "no camera".
  Replace the current remove-range trimming. The `trimmed: false` path used by the preview becomes
  `ignoreCuts: true` (full source, used when the UI shows removed sections greyed out; plan 31 decides which mode to
  preview in).
- Audio at cuts: add a 6 ms volume ramp down before and up after each cut point with
  `AVMutableAudioMixInputParameters.setVolumeRamp` to avoid clicks.
- `CompositionInstruction` carries a `RenderPlan` instead of a static composition. `LayerCompositor.startRequest`
  calls `plan.layers(atTimelineMs: request.compositionTime.seconds × 1000)`. One instruction for the whole
  duration, `containsTweening = true`.
- `EditorModel.restyle()` keeps working: any change to scenes or timeline that does not alter segments swaps the
  video composition only; a change to segments rebuilds the composition.
- Thumbnail: render at the first marker if any, else as today.

### Minimal UI hook (so the engine is usable before plan 31)

In the existing editor: "Split" (⌘B) and "Delete Section" buttons acting on the playhead and the In/Out range, and
"Add Zoom Here" which inserts a three-second block at the playhead with focus at the centre. Nothing more.

## Steps

1. Types, lenient decoding, migration, with fixture tests: a version-1 file, a version-1 file with trim, a plan-22
   style file with events, and round trips.
2. `TimeMap` and editing helpers with tests (boundaries, empty segments meaning everything, adjacent cuts).
3. `RenderPlan.layers` with tests: scene before, during and after a transition; no transition across a cut; zoom
   weights at block start, plateau and end; focus near an edge stays inside the source; both canvases.
4. Builder and compositor changes.
5. Export tests on the fixture project: (a) two cuts → duration equals the kept total within one frame, and the
   binary frame-number strip from the demo picture, read from frames extracted on both sides of a cut point, jumps
   by the removed amount; (b) a zoom block → the moving square appears larger at the block's middle than outside
   it; (c) two scene spans → the camera region differs before and after; all for both canvases, SDR and HDR.
6. Minimal UI hook.

## Acceptance

1. `swift test` passes; paste the export test summary.
2. Opening every project created by earlier versions in `Tests/…/Fixtures` produces the same first-frame image as
   before this plan (golden comparison within 2 of 255).
3. Preview and export agree: for the fixture with cuts, zoom and two scenes, frames grabbed from
   `AVAssetImageGenerator` on the preview composition and from the exported file at the same five times match
   within 3 of 255.
4. Export speed for the fixture is not slower than before by more than 10% (report both timings).

## Pitfalls

- `request.compositionTime` is timeline time. Source frames arrive already mapped by AVFoundation; only the plan
  evaluation needs the explicit mapping.
- `insertTimeRange` at a cut needs times on the track's own timescale; build `CMTime`s with timescale 60000 for
  video ranges and snap segment bounds to source frame boundaries, or a duplicated or dropped frame appears at
  each cut.
- B-frames in `game.mov` (the recorder allows frame reordering) make cut-in points depend on preceding frames;
  AVFoundation handles decoding, but seeking in the preview right at a cut can be slow. Measure it; do not change
  the recorder settings in this plan.
- `RenderPlan` is read on the compositor's queue while the UI edits the project: it must be a value captured at
  instruction creation, never a reference to live model objects.

## Out of scope

Timeline UI, reordering or duplicating segments, speed changes, audio editing beyond the click-free cut, per-span
overlays timing, undo (plan 31).
