# Plan 22: Live scenes, transitions, layer editing and the event log

**Goal.** The user has a strip of scenes, switches between them with a click or ⌃1…⌃9 while live, sees the layout
glide from one to the other, and can arrange any layer of a scene directly on the picture, separately for 16:9 and
9:16. Every switch, zoom and marker made during a recording is saved so the editor can replay it.

**Depends on:** 10, 13. Works with 20 when present (the stream shows the active scene).

**Files you own:** new `Sources/StudioKit/Scenes/`, `UI/MetalView.swift`, new `UI/Studio/Scenes/`, the Scene tab of
the sidebar, `App/AppDelegate+Scenes.swift` (new), small hooks in `Render/LiveRenderer.swift` and
`App/AppDelegate+Recording.swift`, additive fields in `Model/Project.swift`, tests.

## Design

### Scene collection

```swift
struct SceneCollection: Codable { var scenes: [Scene]; var activeID: UUID; var transition = SceneTransition() }
struct SceneTransition: Codable, Equatable { var style: Style = .morph; var durationMs = 380.0
                                             enum Style: String, Codable { case cut, fade, morph } }
```

Stored in `~/Library/Application Support/Elgato HDR/scenes.json`, saved 0.5 s after the last change. On first
launch create these scenes (build them with `Composition.from(layout:)` and by hand):

| Scene | 16:9 | 9:16 |
|---|---|---|
| Gameplay | game full, camera bottom-right rounded with shadow (migrate the user's saved `livePlacement`) | camera top 36%, game below (today's vertical default) |
| Game Only | game full | game full, cropped to fill |
| Camera Focus | camera full, game as a rounded window bottom-right at 34% | camera full, game window across the bottom |
| Just Camera | camera full | camera full |

### Evaluation and transitions (`Scenes/SceneEngine.swift`, pure and unit-tested)

```swift
struct LiveSceneState {           // value type; the renderer holds one behind its lock
    var from: Scene?, to: Scene
    var startNs: UInt64, transition: SceneTransition
    var punchIn: PunchIn?          // live zoom, see below
    func layers(canvas: Canvas, size: CGSize, sources: [SourceKey: SourceInfo], atNs: UInt64) -> [ResolvedLayer]
}
```

- Outside a transition: `SceneResolver.resolve(to.composition(canvas), …)`.
- `cut`: immediate. `fade`: both resolved lists are drawn, old with opacity `1 − e`, new with `e`.
- `morph`: resolve both; match layers that show the same source (`game` with `game`, `camera` with `camera`, an
  overlay layer with the same `id`). Matched layers interpolate `dst`, `src`, `radius`, `border`, `shadow` and
  `opacity` with eased progress `e`; z-order follows the target scene. Unmatched old layers fade out, unmatched new
  layers fade in. This is the signature motion: the camera slides and grows from its corner to full screen.
- Easing: a critically damped spring evaluated analytically, `e(t) = 1 − (1 + ωt)·exp(−ωt)` with `ω` chosen so that
  `e(duration) ≈ 0.99`; with Reduce Motion use `fade` at 150 ms.
- A switch during a transition starts from the currently interpolated layers (freeze them as a synthetic "from"),
  so rapid switching never jumps.

`Renderer.drawNow` and every `ProgramOutput` ask the same `LiveSceneState` for layers at the frame's host time, so
window, stream and (later) the replay in the editor agree.

### Punch-in zoom

Holding ⌃Space (or toggling ⌃Z) zooms the game layer to 1.6× around its current pan centre with the same spring;
releasing returns. Arrow keys while zoomed move the focus. It scales the game layer's `src` crop in every scene.
The amount is a setting (1.3…2.5×).

### Editing layers on the picture (`UI/MetalView.swift`)

Generalize today's camera-only interaction:

- Click selects the topmost layer under the pointer; the selection shows a solid outline with eight handles. Click
  on empty space deselects. In focus mode (full screen) editing is off.
- Drag moves; handles resize (corners keep aspect unless ⇧ is held; the game and camera keep their aspect by
  default and crop instead when ⌥-dragging an edge). Scroll or pinch over a selected layer resizes around its
  centre, as today.
- Snapping with visible guide lines: canvas edges with the existing 4% margin, canvas centre lines, and the edges
  and centres of other layers. ⌥ disables snapping. Reuse `CameraPlacement.anchors` for the corner presets.
- Arrow keys nudge by 1 px (⇧: 10 px). ⌫ deletes overlay layers (game and camera can be hidden, not deleted).
- Double-click the game or camera layer to enter crop mode: drag pans the source inside the frame, scroll zooms.
- The canvas switch in the toolbar (`16:9 | 9:16`) changes which composition the window shows and edits. The 9:16
  view is letterboxed in the window. While it shows 9:16, the status pill says so, because the game is then
  cropped for the player too.

### Scene strip and Scene tab

- **Strip (bottom bar).** One card per scene with a live thumbnail (render the scene at 160×90 or 90×160 through
  `encodeLayers` twice a second into a small texture and show it; reuse the current game and camera textures), the
  name, and its shortcut number. The active scene has an accent ring; the card being transitioned to animates.
  Click switches. Drag reorders. Right-click: rename, duplicate, delete, "Update from current layout". A plus
  button adds a scene from a template gallery.
- **Scene tab (sidebar).** Layer list for the active scene and canvas (drag to reorder, eye to hide, name),
  buttons to add layers (camera, game, later image and text from plan 23), and an inspector for the selected
  layer: position and size fields, fit or fill, zoom, corner roundness, border, shadow, mirror, opacity. A "Copy
  layout to 9:16 / 16:9" action. Transition style and duration. The camera controls plan 13 put here move into the
  camera layer's inspector.
- Menu **Scenes**: the scene list with ⌃1…⌃9, Next/Previous (⌃→ / ⌃←), transition style.

### Event log (additive fields in `Project`)

```swift
struct SessionEvent: Codable, Equatable { var tMs: Double; var type: String      // "scene" | "zoomIn" | "zoomOut" | "marker"
                                          var sceneID: UUID?; var zoom: Double?; var focusX: Double?; var focusY: Double? }
// Project gains (lenient, default empty):  var scenes: [Scene] = [];  var events: [SessionEvent] = []
```

At `startRecording`, copy the whole scene collection into `project.scenes` and write a `"scene"` event at 0 for the
active scene. While recording, append an event for every switch, punch-in start and end, and marker (⌃M), with
`tMs` = host time minus the recording's `startNs`. Save `project.json` at most once every 5 seconds and at stop.
The existing fields `wide` and `vertical` keep being written from the scene active at start so the current editor
still opens the project; plan 30 switches the editor to scenes and events.

## Steps

1. `SceneCollection`, storage, defaults, migration of `livePlacement`; tests.
2. `SceneEngine` with tests: cut, fade and morph at progress 0, 0.5 and 1; unmatched layers; retargeting mid-way;
   punch-in.
3. Renderer and `ProgramOutput` read `LiveSceneState`; menu and shortcuts switch scenes (no strip yet). Golden test:
   a morph at 50% between Gameplay and Camera Focus.
4. Scene strip with thumbnails.
5. Layer selection, move, resize, snapping, crop mode in `MetalView`; canvas switch.
6. Scene tab: layer list and inspector.
7. Event log.

## Acceptance

1. `swift test` passes.
2. Demo run: switching scenes 20 times in 10 seconds (add a debug flag `--scene-torture`) causes no dropped
   presentation frames beyond the baseline (compare `drops` and `slips` in the pacing log) and Game-mode latency
   stays within 1 ms of the baseline.
3. A screen recording (or a sequence of 6 frames exported via a debug dump of the drawable) of one morph, attached
   to the pull request.
4. With plan 20 present: the self-test stream switches scenes at 5 s and 10 s; frames extracted from the received
   file at 4, 5.2 and 6 seconds show before, mid-transition and after.
5. A 15-second demo recording with three scene switches and one punch-in: `project.json` contains `scenes` and five
   or more `events` with plausible times; the current editor still opens it.
6. Screenshots: strip, Scene tab with a selected layer, snapping guides, 9:16 editing.

## Pitfalls

- `LiveSceneState` is read on the reader thread for every frame. Copy it under the renderer's lock; never touch
  `SceneCollection` (main-thread state) from there.
- Thumbnails must not render on the reader thread or delay it: use a separate low-priority queue and the smooth
  mode ring or the latest camera buffer; skip a thumbnail pass if the previous one has not finished.
- `MetalView` receives mouse events in view points with a flipped Y relative to canvas pixels; reuse `canvasPoint`
  and `videoRect`.
- Keep the old Camera menu working by mapping its actions onto the camera layer of the active scene.

## Out of scope

Image, text and web layers (plan 23), per-scene audio settings, scene-specific transitions, studio mode with a
separate preview and program, global hotkeys when the app is in the background, Stream Deck.
