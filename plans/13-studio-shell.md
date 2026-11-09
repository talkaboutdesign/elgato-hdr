# Plan 13: Studio window, design system and observable app state

**Goal.** Give the app a real main window: the live picture in the middle, a control bar with Record and Go Live,
a collapsible sidebar, a status display that replaces the window title, and a shared design system the later UI
plans build on. All current features stay reachable; menus stay.

**Depends on:** 00. **Blocks:** 21, 22, 31.

**Files you own:** `App/AppDelegate*.swift`, `UI/MetalView.swift`, new `UI/Studio/` (window, bar, sidebar, HUD),
new `UI/DesignSystem.swift`, new `App/StudioState.swift`. Do not edit `Render/`, `Model/`, `Record/` or the editor
views (restyling the editor is plan 31).

## Read first

`App/AppDelegate*.swift` fully, `UI/MetalView.swift`, `UI/LibraryView.swift` (for the existing SwiftUI idiom), and
section 1 of `plans/README.md` (product principles).

## Design

### State (`App/StudioState.swift`)

`AppDelegate` keeps doing the work. `StudioState` is the single observable object the UI reads and the only way the
UI asks for things.

```swift
final class StudioState: ObservableObject {
    // connection and signal
    @Published var connection: Connection        // .connecting, .live, .noSignal(String), .demo
    @Published var signal: String                // "2560×1440 · 60 fps · HDR10"
    @Published var latencyMs: Double
    @Published var modeIndex: Int
    @Published var colorMode: ColorMode
    @Published var presentation: Presentation
    @Published var muted: Bool
    // devices
    @Published var cameras: [DeviceInfo]; @Published var cameraID: String?
    @Published var microphones: [DeviceInfo]; @Published var micID: String?
    @Published var micLevel: Float
    @Published var placement: CameraPlacement; @Published var cameraMirror: Bool
    // recording
    @Published var recording: Bool; @Published var recordingElapsed: TimeInterval; @Published var recordingLayers: [String]
    // streaming (filled by plans 20 and 21; show the control disabled until then)
    @Published var streaming: StreamUIState
    // transient messages
    @Published var toast: Toast?
    // intents: closures set by AppDelegate
    var actions: StudioActions
}
```

Rules: `AppDelegate` writes to `StudioState` on the main thread only. Per-second statistics are published at most
once a second; `micLevel` at most 20 times a second from a timer, not from the audio queue. Every existing menu
action and every new control call the same `AppDelegate` method, so menu check marks and the UI cannot disagree
(`refreshChecks()` reads from `StudioState`).

### Window

```
┌──────────────────────────────────────────────────────────────────────────┐
│ ● ● ●   Elgato HDR            [16:9 | 9:16]         ◉ Record   ▲ Go Live │  unified toolbar
├─────────────────────────────────────────────────────────┬────────────────┤
│                                                         │  Scene         │
│                  live picture (MetalView)               │  Audio         │  sidebar, 300 pt,
│                                                         │  Stream        │  toggle ⌥⌘S
│   ┌ status pill: 1440p60 HDR · 22 ms ┐                  │                │
├─────────────────────────────────────────────────────────┤                │
│  scene strip (placeholder until plan 22)   │ mic meter  │                │
└─────────────────────────────────────────────────────────┴────────────────┘
```

- Build it in AppKit: an `NSSplitViewController` whose left item holds a plain `NSView` container with `MetalView`
  on top and an `NSHostingView` bottom bar; the right item is an `NSHostingController` sidebar. `MetalView` stays an
  AppKit view added directly, **not** wrapped in SwiftUI: its `CAMetalLayer` must not be re-laid-out by SwiftUI
  updates.
- Remove `window.contentAspectRatio`; `MetalView.videoRect` already letterboxes. Minimum window size 960×600.
- Toolbar (`NSToolbar`, unified style, `fullSizeContentView`, dark appearance for this window): canvas switch
  (disabled with a "coming with scenes" tooltip until plan 22), Record button, Go Live button (disabled until plan
  20).
- **Record button:** red circle; while recording it becomes a rounded square with a running `mm:ss` timer in
  monospaced digits and a soft pulse. Same action as ⌘R.
- **Status pill:** bottom-left over the picture, material background. Shows signal and latency, or "No signal" /
  "Connecting…" / "Demo source". Fades out after 3 seconds without mouse movement, like video player controls.
- **Sidebar tabs.** *Scene*: for now the camera controls that live in the Camera menu today (device pickers, shape,
  window aspect, size, position grid, mirror, border, shadow) bound to `StudioState`. *Audio*: game mute, mic picker,
  live mic meter. *Stream*: an empty state that explains destinations arrive later.
- **Focus mode:** ⌘F enters full screen and hides sidebar, bottom bar and toolbar so the game fills the display;
  moving the mouse to the top edge reveals the toolbar. Leaving full screen restores the panels as they were.
- **Toasts** replace status messages that were written to the title ("saved Capture …", "stop recording to switch
  cameras"). Blocking `NSAlert`s remain only for permission problems.
- **First launch:** before the administrator prompt appears, show a sheet that explains in two sentences why it is
  needed and offers "Continue" and "Try the demo source". Store a default so it shows once.

### Design system (`UI/DesignSystem.swift`)

One `enum DS` with nested namespaces, used by every later UI plan:

- `DS.Space`: 4, 8, 12, 16, 24, 32. `DS.Radius`: 6 (controls), 10 (cards), 14 (panels).
- `DS.Color`: `canvas` (near black behind video), `panel`, `stroke`, `textSecondary`, `record` (red), `live`
  (purple-pink), `ok`, `warn`. Define them as dynamic `NSColor`s; the studio window is dark-only, the library and
  editor follow the system.
- `DS.Motion`: `snappy = .spring(response: 0.28, dampingFraction: 0.86)`, `gentle = .spring(response: 0.45,
  dampingFraction: 0.82)`; honour Reduce Motion with a cross-fade.
- Components: `PillButton`, `IconButton` (hover highlight, tooltip), `MeterBar` (peak hold, green/yellow/red),
  `StatusPill`, `Card` (hover lift as `ProjectCard` does today), `SegmentedSwitch`, `ToastView`, `EmptyState`,
  `InspectorSection`, `LabeledSlider` (value read-out in monospaced digits, double-click to reset).
- Typography: system font only; numbers that change use `.monospacedDigit()` and
  `.contentTransition(.numericText())`.
- Every interactive element has a tooltip with its shortcut and an accessibility label.

Add a debug-only gallery window (`--design-gallery`) that shows every component in its states. It is the reference
later agents copy from.

## Steps

1. `StudioState` and `StudioActions`; route existing `AppDelegate` state through it without changing the UI. All
   current behaviour still works from the menus.
2. `DesignSystem.swift` and the gallery.
3. Window structure with `MetalView`, bottom bar, sidebar, toolbar; remove the aspect lock.
4. Record button, status pill, toasts; stop writing statistics into `window.title` (title becomes the app name).
5. Sidebar tabs bound to state; the Camera menu remains and stays in sync.
6. Focus mode and first-launch sheet.
7. Update README screenshots and the shortcuts table.

## Acceptance

1. `swift test` passes (add tests for any pure logic, for example the elapsed-time formatter and state reducers).
2. Demo run in Game presentation with the sidebar open and the mic meter moving: the "helper->screen" average is
   within 1 ms of the plan 00 baseline and `tickGaps` in the pacing log line stays at its previous level. Paste both.
3. Screenshots in the pull request (`screencapture -l <windowID>` or the `EHDR_SNAPSHOT` facility; the video area
   may be black in snapshots): idle, recording, sidebar tabs, focus mode, first-launch sheet, design gallery.
4. Every item of the old menus still works; list each menu item and how you checked it.
5. Resizing the window continuously for ten seconds while the demo plays causes no crash and no stuck layout.

## Pitfalls

- Anything published more often than a few times a second re-evaluates SwiftUI bodies on the main thread, which is
  the same thread the display link uses in Smooth mode. Keep fast-changing values in small leaf views.
- `MetalView.layout()` sets the drawable size; a split view animating its divider calls it every frame. That is
  fine, but do not add work there.
- Full screen with a tearing-capable presentation mode (`immediate`) relies on the Metal layer covering the screen.
  In focus mode nothing may overlap the picture except the auto-hiding pill.
- Keep ⌘1…⌘7 for input modes; scenes get ⌃1…⌃9 in plan 22.

## Out of scope

Scenes, destinations, the editor's look, onboarding beyond the single sheet, preferences window, renaming the app.
