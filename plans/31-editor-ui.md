# Plan 31: Editor UI (timeline, zoom blocks, scene track, undo, export presets)

**Goal.** Turn the editor from "trim and lay out" into a fast, pleasant stream editor: find the good parts, cut
the rest, add zooms on the action, pick scenes over time, and export a widescreen video and vertical shorts from
the same session. Built on the plan 30 engine and the plan 13 design system.

**Depends on:** 13, 30. Better with 22 and 23 merged (scene templates, overlays in the inspector).

**Files you own:** `UI/EditorModel.swift`, `UI/EditorView.swift` (split it into `UI/Editor/*.swift`),
`UI/LibraryView.swift`, new `UI/Editor/Timeline/`, tests for model logic.

## Read first

`UI/EditorModel.swift` and `UI/EditorView.swift` as they stand, `Edit/Timeline.swift`, `Edit/RenderPlan.swift`,
`UI/DesignSystem.swift` and the design gallery. Look at how `StageInteraction` does direct manipulation today.

## Design

### Window layout

```
┌────────────────────────────────────────────────────────────────────────────┐
│ ‹ Library   Capture 2026-11-09        [16:9 | 9:16]        ↶ ↷     Export ▾ │
├───────────────────────────────────────────────────────────┬────────────────┤
│                                                           │  Inspector     │
│                    preview (canvas-fitted)                │  (selection-   │
│                                                           │   dependent)   │
├───────────────────────────────────────────────────────────┴────────────────┤
│ ▶ 0:12.4 / 4:31    ✂ Split  ⌫ Delete  ⊕ Zoom  ⚑ Marker        − ━━●━━ +    │
│ ┌ markers ────────⚑────────────⚑──────────────────────────────────────────┐ │
│ │ scenes  ▐ Gameplay ▐ Camera Focus ▐ Gameplay                            │ │
│ │ zoom          ▂▂▂▂▂            ▂▂▂                                     │ │
│ │ video   [filmstrip thumbnails, removed sections hatched]                │ │
│ │ game ♪  [waveform]                                                      │ │
│ │ mic ♪   [waveform]                                                      │ │
│ └─────────────────────────────────────────────────────────────────────────┘ │
└────────────────────────────────────────────────────────────────────────────┘
```

### Timeline behaviour

- **Scale and scroll.** The timeline shows source time. Pinch or ⌘-scroll zooms around the pointer; horizontal
  scroll pans; "fit" (⇧Z) shows everything. A minimap strip appears when zoomed in.
- **Playhead.** Click or drag in the ruler scrubs with frame accuracy. Space plays. J/K/L shuttle (L repeatedly:
  1×, 2×, 4×). ← → step one frame, ⇧ ← → one second. Playback skips removed sections.
- **Cuts.** S or ⌘B splits at the playhead. Clicking a section between two splits selects it; ⌫ removes it (it
  stays visible, hatched and dimmed, and collapses to a thin gap when "Hide removed" is on); clicking a removed
  section and pressing ⌫ again, or "Restore", brings it back. Dragging a section's edge trims it. I and O still set
  the outer in and out points. Removing never moves anything else on screen in source-time view, which keeps the
  mental model simple.
- **Scene track.** Coloured spans with scene names. Drag a boundary to retime it (snaps to playhead, markers and
  cuts). Click a span to select it; the inspector shows a scene picker with thumbnails and the transition style
  and duration. "Add scene change" (⌃1…⌃9 in the editor inserts a change to that scene at the playhead).
- **Zoom track.** Z adds a block at the playhead (default 3 s). Drag to move, drag edges to resize. With a block
  selected the inspector shows scale and ease sliders, and the preview shows a focus target that can be dragged on
  the game picture; the preview parks at the block's middle while adjusting so the result is visible.
- **Markers.** M adds one; markers recorded live appear automatically. ⇧M / ⌥M jump to next and previous. A
  marker can be named. "Make short from marker" sets in and out to 30 seconds around it and switches to 9:16.
- **Filmstrip and waveforms.** Thumbnails from `AVAssetImageGenerator` on the game file (not the composite), one
  per 80 pt at the current zoom, generated lazily and cached in memory and on disk under the project's
  `.cache/` folder. Waveforms: read each audio track once in the background into a peak array (one min/max pair per
  10 ms), cache it as a file next to the thumbnails, draw with `Canvas`.

### Inspector

Selection-dependent: nothing selected → project settings (name, audio volumes, sync offsets, mirror; the existing
"Audio & Sync" controls). Scene span → scene and transition. Zoom block → zoom controls. A layer selected in the
preview → the same layer inspector as the live Scene tab from plan 22 (share the view). Editing a scene in the
editor changes the project's copy, never the live collection; offer "Save as live scene".

### Preview

Keep `AVPlayerLayer` and the `StageInteraction` overlay; generalize the overlay to select and move any layer of the
scene active at the playhead (share hit-testing and snapping code with plan 22's `MetalView` logic by extracting it
into a small pure helper used by both).

### Undo

All edits go through `EditorModel.update`. Register each with the window's `UndoManager` by storing the previous
`Project` value (it is a small struct). Coalesce continuous drags into one undo step (begin on gesture start, commit
on end). ⌘Z / ⇧⌘Z; the toolbar buttons reflect availability.

### Export

- The Export button opens a sheet with presets as cards: **YouTube** (16:9, source resolution up to 4K, HDR when
  the source is HDR), **YouTube 1080p SDR**, **Shorts / Reels / TikTok** (9:16, 1080×1920, SDR, 60 fps),
  **Custom** (the current controls). Several can be ticked; they run as a queue.
- While exporting: a progress capsule in the toolbar with a popover listing each job, time remaining, cancel. The
  editor stays usable for looking around but edits are disabled until the queue finishes.
- On completion: a toast with "Show in Finder" and a draggable file proxy so the result can be dropped straight
  into a browser upload.

### Library

Restyle with the design system: larger cards, hover scrubbing of the thumbnail (move the pointer across a card to
preview five evenly spaced frames, generated lazily), duration and layer badges, a "Live sessions" filter for
projects that contain stream events. Opening a project animates into the editor in the same window (a
library-to-editor navigation), with "‹ Library" to go back; opening in a separate window stays available from the
context menu.

## Steps

1. Split `EditorView.swift` into files without behaviour change; route edits through `UndoManager`.
2. Timeline scaffold: scale, scroll, ruler, playhead, keyboard transport.
3. Filmstrip and waveform caches (background tasks, cancellation when the window closes).
4. Cuts UI on the plan 30 helpers; "Hide removed".
5. Scene track and zoom track with their inspectors and the focus target.
6. Markers.
7. Generalized preview interaction.
8. Export sheet, queue, progress capsule.
9. Library restyle and in-window navigation.

## Acceptance

1. `swift test` passes (model logic: undo coalescing, snapping, selection, export queue ordering).
2. With the fixture project (and a five-minute demo recording for scale): scrubbing stays responsive (a seek
   completes within 100 ms on average; log it), timeline zoom and scroll hold 60 fps (check with the Core Animation
   FPS HUD or a signpost count), and opening the editor shows a usable timeline within one second while thumbnails
   and waveforms fill in.
3. Scripted pass through the debug harness (`EHDR_OPEN=0` plus new debug actions): split twice, delete the middle,
   add a zoom, add a scene change, undo everything, redo everything; the final `project.json` equals the expected
   fixture.
4. Export both a YouTube and a Shorts preset in one queue; both files pass the plan 30 checks.
5. Screenshots: each track in use, each inspector state, export sheet, export progress, library.
6. VoiceOver reads every toolbar and transport control by name; every action in the timeline has a keyboard
   shortcut listed in a new "Keyboard Shortcuts" help window.

## Pitfalls

- SwiftUI gestures on thousands of timeline elements get slow. Draw tracks with `Canvas` and handle hit-testing
  yourself; only the selected item gets real views for its handles.
- Seeking `AVPlayer` on every drag event queues seeks. Keep one seek in flight and remember only the latest target
  (seek again from the completion handler if it changed).
- Rebuilding the composition on every drag frame when trimming a section is too slow: update the timeline model
  live (the hatching moves) and rebuild once on gesture end.
- Do not store caches inside `project.json`; the `.cache/` folder is disposable and excluded from "Duplicate".

## Out of scope

Reordering clips, multiple recordings in one project, transitions between cuts, speed ramps, text-based editing
from a transcript, captions, music, direct upload to platforms (plan 90).
