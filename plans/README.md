# Studio roadmap: from HDR viewer to game streaming, recording and editing app

Master plan. Each numbered file in this folder is a self-contained work order for one agent. Read this file first, then
your own plan, then the code it names. Nothing else is required.

## 1. Product target

"Screen Studio, but for game capture and streaming": a native Mac app where you plug in a capture card, look great
immediately, go live to several platforms at once, and afterwards turn the same session into a widescreen video and
vertical shorts without re-recording.

What the user asked for, mapped to plans:

| Ask | Plan |
|---|---|
| Record in 16:9 and 9:16 | exists (editor export); live 9:16 program output in 20 |
| Streaming destinations, multistream (YouTube + Twitch + Kick), custom URL and key | 11, 20, 21 |
| Scenes, switch between them while live | 10, 22 |
| Move the camera, switch between game and overlay layouts | exists for camera; generalized to any layer in 10, 22 |
| Overlays | 23 |
| Video editor: cut streams, zoom in on action | 30, 31 |
| Polished, delightful native Mac UI | 13, then 21, 22, 31 |

Product principles (apply them when a plan leaves a choice open):

1. **Record everything as separate layers, decide later.** Game, camera and mic stay independent files. Live choices
   (scene switches, zooms, markers) are recorded as events, never baked in, so the editor can replay and change them.
2. **One compositor everywhere.** Live view, stream output, editor preview and export all draw through the same Metal
   code, so what you see is what viewers and exports get.
3. **The game monitor is sacred.** Nothing may add latency or jitter to the live game picture. Measured today: about
   22 ms in Game mode at 1440p60. Every plan that touches the live path must re-measure it.
4. **Good by default.** A new user gets a good-looking scene set, sensible stream settings and one obvious button for
   each of Record and Go Live. Options are discoverable, not required.
5. **Small and native.** Swift, AppKit/SwiftUI, Metal, AVFoundation, VideoToolbox, Network.framework. No third-party
   dependencies, no Electron, no bundled ffmpeg.

## 2. Where the code is today (audit, November 2026)

About 3,400 lines of Swift in five files plus a 388-line C helper, built by `swiftc app/*.swift`.

Strengths worth protecting:

- Zero-copy capture path: root helper (`tools/uvc_capture.c`) writes P010 frames into a shared-memory ring, the app
  renders them straight from that memory (`Renderer` in `app/main.swift`).
- Three presentation modes with measured latency and a vsync-grid pacer.
- Layered recording on one host clock (`Recorder`, `LayerWriter`), non-destructive `project.json`, lenient decoding.
- One shader for live, preview and export with correct PQ / HLG / SDR conversion and tone mapping
  (`app/Compositor.swift`).
- Working library and editor with independent 16:9 and 9:16 layouts and dual export (`app/LibraryUI.swift`).

Problems found, most important first:

| # | Finding | Evidence | Fixed by |
|---|---|---|---|
| 1 | **A crash or power loss destroys the whole recording.** The writers never set `movieFragmentInterval`, so the file index is only written at stop. The library's "crash recovery" then tries to finalize a file that cannot be opened. Fatal for multi-hour streams. | `Recorder.init`, `LayerWriter.init` | 01 |
| 2 | **No tests and no CI on pull requests.** Only a tag-triggered release build exists. Every later plan needs a safety net. | `.github/workflows/release.yml` | 00 |
| 3 | **Nothing can be developed or tested without the capture card and an admin prompt.** Agents and CI have neither. | `AppDelegate.start()` | 00 (demo source) |
| 4 | **The compositor is hard-wired to exactly two layers** (game, camera) with one fixed uniform block. Scenes, overlays and zoom animation cannot be expressed. | `composite()` in `compositorShader`, `CompParams` | 10 |
| 5 | **The editor renders one static layout for the whole recording** (a single instruction with fixed parameters), and trim is the only edit. No cuts, no time-varying layout. | `CompositionBuilder.videoComposition` | 30 |
| 6 | **No encoder or network path for streaming exists**, and no audio mixer: game audio and mic never meet outside export. | n/a | 11, 12, 20 |
| 7 | **`AppDelegate` is the whole app**: about 480 lines owning capture, camera, recording, menus and state, with status shown in the window title. No observable state for a real UI to bind to. | `AppDelegate` in `app/main.swift` | 00 (split), 13 (state + UI) |
| 8 | Likely data race: the smooth-mode texture ring is rebuilt on the reader thread (`ensureRing`) while the display link reads it on the main thread (`tick`). Can crash on a resolution change. | `Renderer` | 10 (touches this code; fix there) |
| 9 | The root helper trusts every local process: socket and shared memory are mode 0666 in `/tmp`, and root appends to `/tmp/elgato-uvc.log`. Acceptable for a personal tool, not for a distributed product. Also asks for the admin password on most launches. | `serve()`, `shm_setup()`, `spawnHelperWithAdminPrompt()` | 90 (daemon) |
| 10 | The published release (v1.0.0, September) lacks the facecam and editor; the app is unsigned and not notarized. | GitHub releases | 90 |

## 3. Target architecture

```
                 ┌────────────── sources ──────────────┐
 root helper ──► │ Game (P010, shared memory)          │
 AVCapture ────► │ Camera (420v)   Mic (float mono)    │        events (scene, zoom, marker)
 files ────────► │ Images / text (BGRA textures)       │               │
                 └──────────────┬──────────────────────┘               ▼
                                │                               project.json
        Scene (per canvas: ordered layers) ── SceneResolver ──► [ResolvedLayer]
                                │
                     MetalCore.encodeLayers  (one draw per layer, PQ/HLG/SDR out)
        ┌───────────────┬───────┴────────────┬──────────────────────┐
   live window     ProgramOutput 16:9   ProgramOutput 9:16     AVVideoCompositing
   (low latency)        │                     │                (editor preview, export)
                   VideoEncoder          VideoEncoder
                        └──── StreamSession ──┘◄── AudioMixer ── AACEncoder
                              │      │      │
                           RTMP   RTMP   RTMP   (one connection per destination)

   Recording stays as today: game.mov + camera.mov + mic layer, untouched by scenes.
```

Key decisions (already made; do not reopen inside a plan):

- **Swift package, one library target.** All code lives in `StudioKit`; the executable is a three-line `main.swift`.
  Tests use `@testable import StudioKit`, so no `public` annotations are needed. Swift language mode 5.
- **Scenes are lists of layers; layout kinds become templates.** "Camera overlay", "Split" and so on generate layers
  instead of being shader branches.
- **Blending stays in the output encoding**, exactly as the current shader does, so existing output is bit-compatible
  and golden tests can prove the refactor.
- **Streaming is our own RTMP/RTMPS publisher** over Network.framework with VideoToolbox H.264 and AAC. About 1,000
  lines, fully testable against a local `ffmpeg -listen` server. First version streams tone-mapped SDR; HDR to YouTube
  (HEVC over Enhanced RTMP) is a later plan.
- **One video encoder per canvas, fanned out to every destination on that canvas.** Three destinations cost one encode
  (or two when one of them is vertical), but three uploads.
- **Stream keys live in the Keychain**, never in JSON, defaults or logs.
- **The editor keeps AVFoundation** (`AVPlayer` preview, `AVAssetReader` export). Time-varying layout comes from the
  compositor evaluating a pure `RenderPlan` at each frame time.
- **Times in a project are source milliseconds** (position in the recording). Cuts map timeline time to source time;
  events never need shifting.

## 4. Plans and order

Status as of 10 November 2026: every numbered plan is on `main`; plan 40 (the final integration) is in review (#18).

| Plan | What | Depends on | Status on `main` |
|---|---|---|---|
| [00](00-foundation.md) | Swift package, file split, tests, CI, demo source | none | Done (#3) |
| [01](01-crash-safe-recording.md) | Fragmented writers, recovery, disk guard | 00 | Done (#6) |
| [10](10-scene-compositor.md) | Scene model, layer compositor, parity with today | 00 | Done (#7) |
| [11](11-rtmp-publisher.md) | RTMP/RTMPS publisher, FLV, AMF0 | 00 | Done (#5) |
| [12](12-audio-mixer.md) | Audio mixer, drift control, AAC encoder | 00 | Done (#4) |
| [13](13-studio-shell.md) | Design system, main window, observable app state | 00 | Done (#9) |
| [20](20-program-output-go-live.md) | Program render, H.264 encoder, stream session, first Go Live | 10, 11, 12 | Done (#8) |
| [21](21-destinations-multistream.md) | Destinations, Keychain, multistream, health UI | 13, 20 | Done (#12) |
| [22](22-live-scenes.md) | Scene collection, switching, transitions, layer editing, event log | 10, 13 | Done (#13, live integration #15, review fixes #16, #17) |
| [23](23-overlays.md) | Image and text layers, templates | 10 (UI parts after 22) | Done: engine #10, live UI and templates #15, editor and exports in plan 40 |
| [30](30-editor-timeline-engine.md) | Project v2, cuts, scene and zoom tracks, render plan | 10 (events from 22) | Done (#11) |
| [31](31-editor-ui.md) | Timeline UI, zoom blocks, undo, export presets | 13, 30 | Done (#14); step 7 (edit any layer in the preview) in plan 40 |
| 40 | Final integration: the editor replays live transitions, overlays in the editor and exports, layer editing in the editor, docs | all of the above | In review (#18) |
| [90](90-later.md) | Briefs: daemon and notarization, more sources, HDR streaming, replay buffer, web overlays, captions | various | Not started |

### Done

One line per plan on what turned out differently from the plan; the pull requests have the details.

- **00** Foundation: demo source drives the real capture path; CI builds with Xcode 16.4 (Swift 6.1), which is stricter
  than the development machine (see "Older compiler on CI").
- **01** Crash-safe recording: the mic layer is checked to the last whole AAC packet (≥ 2 s − 2048 samples), not 2 s.
- **10** Scene compositor: an opaque full-canvas layer skips everything beneath it, and the live letterbox snaps to
  whole pixels; a `hardEdge` flag keeps the old shader's hard-clipped game edges for golden parity.
- **11** RTMP publisher: as planned; verified against a local `ffmpeg -listen` server.
- **12** Audio mixer: as planned.
- **13** Studio shell: `@Observable` instead of `ObservableObject` (per-property tracking keeps the 20 Hz meter from
  redrawing the window); the README screenshot was not replaced (snapshots cannot capture the Metal picture).
- **20** Go Live: frame selection on the host clock without duplicating frames; `--go-live-for` makes the stream
  self-test bounded.
- **21** Destinations: the stream session became per-canvas lanes so destinations can join and leave while live;
  saturated lanes reduce their frame rate automatically (see Known limits).
- **22** Live scenes: extra morph rules (a rising layer passes in front late, unmatched layers sink, layers that will
  be covered hold opaque), so morphs never dip to the background or double-expose.
- **23** Overlays: images decode to power-of-two sizes for the size drawn (not "draw size or 2048 px"); text breaks
  lines only where the string does and shrinks to fit. Editor, library and export support landed in plan 40.
- **30** Timeline engine: as planned; transitions end at cuts in the preview exactly as in the export.
- **31** Editor UI: `@Observable` model with its own undo manager; removing and restoring sections works on the kept
  ranges directly so other split points survive; zoom blocks never overlap in the UI. Step 7 landed in plan 40.
- **41** SDR brightness: one global "SDR white" setting (default 150 nits, was a fixed 203) for every HDR -> SDR
  conversion; [plan](41-sdr-brightness.md).

### Known limits

- **Hardware encoder capacity.** Recording (10-bit HEVC), a 16:9 stream and a 9:16 stream share the Mac's video
  encoder. When a lane cannot keep up, the app halves that canvas's frame rate (the 9:16 one first by default; Stream
  settings choose which, or never) and says so in the health popover and a toast; it returns to full rate when the
  load changes. Recording at 1440p60 while streaming two 1080p60 canvases starts the vertical lane at 30 fps.
- **Exports while live or recording.** Exports use the same encoder after the live work, so they run slower and can
  pause while the encoder is busy; the export sheet says so before you start. Nothing is dropped.
- **Overlays are static images and text.** No animated GIFs (first frame only), video, browser sources, alerts or
  chat. Text has two live tokens: `{time}` (clock) and `{timer}` (stream or recording time live; edited-timeline time
  in an edit). Fonts missing on another Mac fall back to the system font.
- **The capture helper needs the administrator prompt.** Detaching Apple's video driver from the card needs root, so
  the app asks for the password when the helper is not running. A launch daemon is in plan 90.
- **The app is unsigned.** Ad-hoc signed and not notarized: the first launch needs right-click → Open, and after a
  rebuild macOS may ask once before the app reads a saved stream key from the Keychain. Developer ID and
  notarization are in plan 90.

Waves (plans in a wave run in parallel, each in its own worktree and pull request):

- **Wave 0:** 00. Everything else waits for it to merge.
- **Wave 1:** 01, 10, 11, 12, 13. File ownership does not overlap (see each plan's "Files").
- **Wave 2:** 20, 22, 23 (engine part), 30.
- **Wave 3:** 21, 23 (UI part), 31.
- **Wave 4:** items from 90, re-planned against the code as it then stands.

Known overlaps, resolved by merge order: 01 merges before 13 (both edit `App/AppDelegate+Recording.swift`; 01 is
small). 22 merges before 30 (both add fields to `Model/Project.swift`; 30 declares `scenes` and `events` only if 22
has not). Whoever merges second rebases.

The model split is a judgment call, not a measurement: Opus on visual and interaction work, Astra on protocol, engine
and test-heavy work, and each pull request reviewed by the other model before merge.

Milestones the user can try:

- **M1 after wave 1:** same app, new window, crash-safe recordings, runs without the card in demo mode.
- **M2 after 20:** live on Twitch or YouTube from the Record menu with a pasted key.
- **M3 after wave 3:** scenes, overlays, multistream with health display, timeline editor with cuts and zooms.

## 5. Ground rules for every agent

Read this section before touching code. Before plan 00 merges the build is `./build.sh` and sources are in `app/`;
afterwards use the commands below.

**Build, test, run**

```sh
brew install libusb                 # once
swift build                         # compile
swift test                          # unit tests, must pass before you open a pull request
./build.sh                          # release bundle in dist/Elgato HDR.app
"dist/Elgato HDR.app/Contents/MacOS/ElgatoHDR" --demo-source --demo-camera
```

- You have **no capture card, no admin password and nobody to click permission dialogs.** Use `--demo-source`
  (synthetic game video and audio through the real capture code path) and `--demo-camera` (synthetic camera and mic).
  Never call `spawnHelperWithAdminPrompt` in a test. Always run the bundled app, not `.build/debug/ElgatoHDR`: without
  the bundle's `Info.plist` macOS kills the process when the camera is touched.
- Logs go to `~/Library/Logs/Elgato HDR.log` and stderr. Read them to verify behaviour.
- `ffmpeg` and `ffprobe` are available at `/opt/homebrew/bin` on the development machine for verification only. Never
  make the app depend on them.

**Code**

- No third-party dependencies. If you believe one is unavoidable, stop and report instead of adding it.
- Match the existing style: compact Swift, comments that explain why (timing, colour and threading reasons), no
  comment that restates the code.
- Stay inside the files your plan lists. If you need a change elsewhere, make the smallest possible hook and say so
  in the pull request description.
- Threading: the reader thread (`Session.run`) must never block on the main thread, on a lock held across I/O, or on
  a drawable. UI state changes go through `DispatchQueue.main`.
- Never log, print or persist a stream key outside the Keychain. Redact URLs that contain one.
- Keep `project.json` backward compatible: decode with the lenient `c.v(key, fallback)` helper, add fields, do not
  rename or remove them without a migration and a fixture test.

**Proving your work**

- Every plan ends with acceptance checks. Run them and paste the real output in the pull request. If a check fails
  or you could not run it, say so plainly.
- If your change touches the live render path, report the "helper->screen" latency line from the log in demo mode
  before and after, in Game mode. A regression of more than 1 ms average needs an explanation.
- One pull request per plan, branch `plan/<number>-<slug>`, based on `main`. Do not merge it yourself.

**When to stop and ask.** A step in your plan contradicts the code as you find it; an acceptance check cannot pass
for a reason outside your files; or you would have to change a decision listed in section 3.

## 6. What needs the real hardware

Agents verify with the demo source. These checks need the user's Elgato 4K X and are run by the user at each
milestone:

1. Live view in all three presentation modes at 1440p60 and 4K30; latency line in the log matches the README table.
2. A two-minute recording with camera and mic plays in sync and opens in the editor.
3. Pull the USB cable during a recording: the app survives and the recording up to that point opens (after plan 01).
4. A real stream to each platform with the user's own keys (after plans 20 and 21).

## 7. Open product decisions (defaults are in place; none blocks wave 0 or 1)

| Decision | Default until told otherwise |
|---|---|
| Name. "Elgato" is a Corsair trademark; fine for a personal tool, a risk for a public product. | Keep "Elgato HDR" and bundle id; all user-visible name strings go through one constant so a rename is one line. |
| Other capture sources (other cards, Mac screen for native games). | Elgato 4K X only until plan 90; plan 10's source abstraction keeps the door open. |
| Platform sign-in (set title and category, read chat). | Stream keys only. Sign-in is a later plan. |
| Minimum macOS. | Stay on 14. |
| Distribution (Developer ID, notarization, auto update, paid or free). | Unsigned zip as today until plan 90. |
