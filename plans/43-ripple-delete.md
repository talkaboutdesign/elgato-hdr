# 43. Deleting footage removes it from the timeline

## Goal

In the editor, pressing ⌫ on a section leaves it on the timeline, hatched and dimmed. The user's words: "When
deleting the footage in editing mode, don't just grey it out. Actually remove those portions from the timeline."

After this plan, a deleted section disappears and the footage after it slides left to close the gap. The timeline
shows only what will be exported, at its exported length and with exported time on the ruler. Nothing is lost: the
project stays non-destructive, and removed footage can be brought back.

Read `AGENTS.md`, then the "Cuts" parts of `plans/30-editor-timeline-engine.md` and `plans/31-editor-ui.md`.

## What exists (do not rebuild it)

- Cuts are data, not file edits: `project.timeline.segments` are the kept source ranges, all times are source
  milliseconds (`Edit/Timeline.swift`, `TimeMap`). Exports already leave removed sections out. **Do not change the
  model, `project.json`, `TimeMap`, `CompositionBuilder` or the exporter.**
- The editor preview is built with `ignoreCuts: true`: player time is source time and playback skips removed
  sections with boundary observers (`UI/Editor/EditorModel+Playback.swift`). Keep that.
- `TimelineAxis.collapsed` (`UI/Editor/Timeline/TimelineAxis.swift`) already draws removed ranges as a fixed 8-point
  gap when `EditorModel.hideRemoved` is on (H, the eye button). That mode is the starting point for this plan.

So this is a presentation change in `Sources/StudioKit/UI/Editor/**` and `UI/EditorModel.swift`, plus tests.

## Behaviour

Two views of the same project, switched with H and the eye button:

**Default: removed footage is gone.** (`hideRemoved`, today off by default, becomes on by default.)

1. A removed range takes no width at all: `TimelineAxis` gap is 0 in this mode. Kept sections butt against each
   other. Filmstrip, waveforms, scene spans, zoom blocks and markers inside a removed range are not drawn; an item
   that straddles a cut is drawn as its kept parts, meeting at the seam.
2. A **seam** marks each cut: a thin vertical line through the lanes with a small notch at the top of the video
   lane, in a design-system colour that reads as "cut here" without shouting. Hovering it shows a tooltip such as
   "12.4 s removed". Clicking the seam's notch selects the removed section (the existing
   `.section(CutSection(kept: false))` selection), so the inspector shows "Removed" with its Restore button. A
   removed range at the very start or end of the recording gets its seam at that end.
3. ⌫ on a kept section removes it, the gap closes with a short animation (`DS.Motion`, a plain cut under Reduce
   Motion), the selection clears, and the playhead lands on the first kept frame after the cut (or the last kept
   frame if nothing follows). ⌫ with a seam selected restores that section and selects it. The current
   "second ⌫ undoes the removal in place" behaviour only remains in the other view.
4. **Time read-outs are export time.** The ruler labels, the playhead timecode, the duration read-out and the
   section inspector's Start/End count kept footage only (`TimeMap.timeline(fromSource:)`), so the end of the ruler
   is the export's length. Scene, zoom and marker inspectors show the same export time. Internally everything
   stays in source time.
5. The playhead can never rest inside removed footage: scrubbing, clicking the ruler, frame and second stepping,
   jump-to-marker and jump-to-cut all land on kept frames. Stepping across a seam goes from the last kept frame
   before it to the first after it.
6. Trimming still works. At a seam two edges coincide: the end of the section on the left and the start of the
   one on the right. Grabbing just left of the seam drags the left section's end (rightwards restores footage
   from the removed range, leftwards removes more); just right of it drags the right section's start. While an
   edge is dragged the timeline must not jump under the pointer: keep the axis layout frozen for the gesture, show
   the change live in the dragged section, and re-lay out once on release (the same rule plan 31 set for hatching).
7. Split (S, ⌘B), In/Out, zoom blocks, scene changes, markers, snapping and undo/redo behave as today in export
   positions. Undo of a removal re-opens the gap with the same animation and restores the previous selection and
   playhead.
8. Zoom and scroll: "fit" fits the kept footage. After a removal or restore the view keeps the playhead on screen;
   a fitted timeline stays fitted.

**Show removed: today's view.** H or the eye button shows removed sections at scale, hatched and dimmed, exactly as
now, with source time on the ruler, for finding and restoring footage. Its tooltip and the shortcut list say
"Show removed footage" / "Hide removed footage". The choice persists in `UserDefaults` under `editorShowRemoved`
(absent means hidden).

Wording: update the section inspector ("Removed sections stay on the timeline, hatched…") and any tooltip, toast
or shortcut title that describes the old behaviour. `Tests/StudioKitTests/WordingTests.swift` polices wording
rules; follow them.

## Implementation notes

- `TimelineAxis` is a pure value shared by lanes, input and tests. Give it the gap as a property (0 when hidden,
  the hatched view has no collapsed ranges at all) rather than a second code path. Check every use of
  `TimelineAxis.gap`, and `contentX` / `time(atContentX:)` at exactly a seam: `time(atContentX:)` must return the
  first kept time after the seam, never a time inside the removed range, and `contentX` of any time inside a removed
  range is the seam's x.
- Drawing: find every place that iterates over source time to draw (`TimelineLanes.swift`, `FilmstripCache`,
  `WaveformCache`, `GuidesOverlay`) and make it skip collapsed ranges. Filmstrip tiles and waveform columns must be
  taken from the right source times on each side of a seam: no tile may straddle one.
- Hit testing (`TimelineInput.swift`): seams, coinciding edges (point 6), and items clipped by a cut.
- Ruler ticks are laid out in export time in the default view (a tick every N seconds of kept footage), not source
  ticks squeezed around seams.
- `EditorModel+Timeline.swift` `updateCollapsed()` already feeds the axis; the playhead rules belong in
  `EditorModel+Playback.swift`.
- `EditorHarness` (DEBUG, drives the editor in tests and locked-screen runs): keep `hide on|off` working and add
  what you need to exercise seams (`select seam <n>`, a dump of the axis and read-outs).
- Performance: laying out the timeline must stay as fast as today (the log line "editor: timeline laid out N ms
  after opening"); a recording with 200 cuts must still scroll and zoom smoothly. Do not rebuild the AVFoundation
  composition for a view switch: it does not depend on it.

## Tests (`Tests/StudioKitTests/`)

Extend `EditorTimelineTests.swift` and add files as needed.

1. Axis with gap 0: `contentX` and `time(atContentX:)` round trip for kept times; removed times map to the seam;
   seam x maps to the first kept time after it; `contentWidth` equals kept duration times scale; fit scale; several
   adjacent and leading/trailing removed ranges; zoom anchoring and `reveal` across seams.
2. Export-time read-outs for a project with three cuts, including a leading one.
3. Delete: selection clears, playhead lands on the first kept frame after the cut (and the last kept frame when the
   removed section was last); undo restores selection and playhead.
4. Seam selection and restore; trimming each of the two coinciding edges changes the right segment.
5. Stepping and scrubbing never produce a time inside a removed range.
6. Items straddling a cut produce the expected drawn pieces (test the pure geometry function, not pixels).
7. The preference: default hidden, persisted, a private `UserDefaults` suite in tests.
8. All existing tests pass. Where an existing test asserts the old default, change the test deliberately and list
   each such change in the pull request.

## Acceptance checks (paste real output in the pull request)

1. `swift build`, `swift test`; CI green (Xcode 16.4 / Swift 6.1, see `AGENTS.md`).
2. With the bundled app and the editor harness on the fixture or a demo recording: snapshots (`EHDR_SNAPSHOT`) of
   the timeline before a removal, after it (gap closed, seam visible, ruler ends at the export length), with a seam
   selected, and in "Show removed". Attach them.
3. An export of a project with two cuts has the same length the ruler shows, within one frame (`ffprobe`).
4. A 200-cut project: timeline layout time from the log, before and after this change.
5. State plainly what could not be checked without a person (animation feel, pointer feel of the coinciding edges,
   VoiceOver).

## Environment notes

- The screen is usually locked: nothing is presented and `screencapture` fails; use `EHDR_SNAPSHOT` and the harness.
- Runs write the real defaults domain `dev.max.elgato-hdr`. Afterwards delete only keys your run wrote (including
  `editorShowRemoved`); never the whole domain. Use `-recordingsDir <scratch>`.
- The user's own copy of the app is running from another checkout with a live capture. Never `pkill` by name; kill
  only PIDs you started.
- Branch `plan/43-ripple-delete` (this plan is committed there), one pull request against `main`, do not merge.
  Finish by adding a plan 43 row to the status table in `plans/README.md` and "## Acceptance results" to this file.

## When to stop and ask

The change cannot be made without touching the model, `TimeMap`, the composition or the exporter; or keeping the
preview in source time makes a required behaviour impossible.

## Acceptance results

Debug bundle, `--demo-source --demo-camera`, `-recordingsDir` in a scratch folder, driven by the editor harness on a
90 s fixture recording (`LongFixtureMaker`, opt-in) and a 200-cut copy of it. `defaults` checked before and after:
only `NSWindow Frame StudioWindow` had moved (restored); `editorShowRemoved` absent, `muted` unchanged.

1. `swift build`: complete. `swift test`: 371 tests, 0 failures, 11 opt-in skips (353 before this plan, 18 new in
   `RippleDeleteTests.swift`). Three existing tests asserted the old default view and now set `hideRemoved = false`
   (`testSelectionFollowsEditsAndDeleteToggles`, `testDragsLandWhereReleasedAndSnapToOthers`,
   `testDragsThroughMouseEventsLeaveNoIntermediateEdits`); `testCollapsedRangesDrawAsGaps` sets its 8-point gap
   explicitly. CI: see the pull request.
2. Snapshots (`EHDR_SNAPSHOT`) attached to the pull request: before a removal, after it (gap closed, seam, ruler ends
   at 1:15), two cuts (ruler ends at 1:05), seam selected (inspector "Removed", Cut at 0:20.00, Restore), seam under
   the pointer, Show removed (hatched, source ruler to 1:30, "1:05 kept"), and undo re-opening the gap. Harness
   `axis` dumps: after the first removal `shown=75.000 seams=1 [314.7@20.000-35.000] ruler-last-label=1:15
   readout=0:20.00 / 1:15 playhead=35.000`; undo restored the selection (kept 0:45–0:55) and the playhead.
3. Export (YouTube 1080p SDR) of the two-cut project (kept 0–20, 35–60, 70–90): ruler and read-out 1:05;
   `ffprobe`: video 65.000000 s (3900 frames at 60 fps), audio 65.000000 s, format 65.000000 s. Same length.
4. 200-cut project (201 kept pieces of 17 frames), debug bundle, `perftest` (lane draw cost over 120 zoom and scroll
   frames at 1180 pt), two passes each:

   | build, view | timeline laid out | lane draw average / p95 |
   |---|---|---|
   | `main`, removed shown | 153 ms | 4.18 / 6.95 ms, 4.00 / 7.02 ms |
   | `main`, "Hide removed" (8 pt gaps) | 132 ms | 79.99 / 84.16 ms, 79.97 / 84.22 ms |
   | this branch, removed hidden (default) | 134 ms | 4.67 / 7.49 ms, 4.74 / 7.94 ms |
   | this branch, Show removed | 143 ms | 4.57 / 8.67 ms, 3.87 / 7.32 ms |

   A first version of the axis walked every cut per mapping and drew at about 200 ms per frame with 200 cuts; the
   axis now keeps prefix sums and maps by binary search.
5. Not checkable without a person: the feel of the close and open animation (spring of `DS.Motion.snappy`, a plain
   cut under Reduce Motion), the pointer feel of the two coinciding edges at a seam (unit tests drive them through
   `TimelineInteraction`; the harness `drag` works in source time and cannot aim at one side of a seam), the seam
   tooltip appearing (set as the input view's `toolTip`; needs a resting pointer), and VoiceOver.
