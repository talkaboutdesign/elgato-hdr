# Plan 00: Foundation (Swift package, file split, tests, CI, demo source)

**Goal.** Turn the five-file `swiftc` build into a Swift package with tests and CI, split the code into files that
parallel agents can own, and add a synthetic source so the whole app runs without the capture card. **No behaviour
change** for a user with the card.

**Depends on:** nothing. **Blocks:** every other plan.

## Read first

`build.sh`, `package.sh`, `.github/workflows/release.yml`, and all of `app/*.swift` (about 3,400 lines). You will
move every line of it, so read it once fully.

## Step 1: package layout

Create `Package.swift`:

```swift
// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "ElgatoHDR",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "StudioKit", path: "Sources/StudioKit"),
        .executableTarget(name: "ElgatoHDR", dependencies: ["StudioKit"], path: "Sources/ElgatoHDR"),
        .testTarget(name: "StudioKitTests", dependencies: ["StudioKit"], path: "Tests/StudioKitTests"),
    ]
)
```

Tools version 5.9 keeps Swift language mode 5. Do not raise it: the code is full of closures that Swift 6 strict
concurrency would reject, and fixing those is not part of this plan.

All code goes into the `StudioKit` library, including `AppDelegate` and the SwiftUI views. The executable is only:

```swift
// Sources/ElgatoHDR/main.swift
import StudioKit
runApp()
```

and `StudioKit` exposes exactly one public symbol:

```swift
// Sources/StudioKit/App/RunApp.swift
private var appDelegate: AppDelegate?          // keeps the delegate alive (NSApplication.delegate is weak)
public func runApp() {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let d = AppDelegate(); appDelegate = d; app.delegate = d
    app.run()
}
```

Tests use `@testable import StudioKit`, so nothing else needs `public`.

## Step 2: move the code

Move, do not rewrite. Keep every type and function name. The only edits allowed are imports and the `runApp` wrapper.
Use `git mv` for whole files, then split.

| New file under `Sources/StudioKit/` | Contents (from) |
|---|---|
| `Support/Log.swift` | `logFile`, `log`, `readFully` (main.swift) |
| `Capture/HelperClient.swift` | `socketPath`, `shmName`, `shmSlots`, `shmSlotBytes`, `connectHelper`, `spawnHelperWithAdminPrompt`, `mapSharedFrames` |
| `Capture/CaptureTypes.swift` | `ColorMode`, `Presentation`, `Mode`, `modes` |
| `Capture/CaptureSession.swift` | `class Session` |
| `Capture/Camera.swift` | `hostNs`, `nowNs`, `CameraCapture` (Camera.swift) |
| `Render/MetalCore.swift` | `compositorShader`, `CompParams`, `ColorMode.transfer`, `SIMD4(CGRect)`, `MetalCore` (Compositor.swift) |
| `Render/LayerCompositor.swift` | `CompositionInstruction`, `LayerCompositor`, `HDRLayerCompositor`, `SDRLayerCompositor` |
| `Render/LiveRenderer.swift` | `LiveOverlay`, `Renderer` |
| `Audio/AudioPlayer.swift` | `AudioPlayer` |
| `Record/Recorder.swift` | `Recorder` |
| `Record/LayerWriter.swift` | `LayerWriter` (Camera.swift) |
| `Model/Project.swift` | lenient-decoding extension, `CameraAspect` … `Project` (Project.swift "Model" section) |
| `Model/ProjectDoc.swift` | `ProjectDoc` |
| `Model/LayoutMath.swift` | `LayoutMath` |
| `Model/Library.swift` | `Library` |
| `Edit/CompositionBuilder.swift` | `BuiltComposition`, `CompositionBuilder` |
| `Edit/Exporter.swift` | `ExportJob`, `Exporter` |
| `UI/MetalView.swift` | `MetalView` |
| `UI/LibraryView.swift` | `makeLibraryWindow`, `EditorWindows`, `LibraryView`, `ProjectCard`, `LayerIcons`, `Badge`, `formatTime*` |
| `UI/EditorModel.swift` | `ExportState`, `EditorModel` |
| `UI/EditorView.swift` | `EditorView`, `PreviewStage`, `PlayerLayerView`, `StageInteraction`, `TimelineView`, `LayerLanes`, `Inspector` and its helper views, `ExportSection` |
| `UI/DebugSnapshots.swift` | `DebugSnapshots` |
| `App/AppDelegate.swift` | properties, `applicationDidFinishLaunching`, `start`, title, window and termination handling |
| `App/AppDelegate+Menus.swift` | `buildMenu`, `populateCameraMenu`, `refreshChecks`, menu actions |
| `App/AppDelegate+Camera.swift` | `deviceResult`, `applyOverlay`, `setPlacement`, camera and mic actions |
| `App/AppDelegate+Recording.swift` | `recordingsDir`, `startRecording`, `finishRecording`, `runHeadlessExport`, library actions |
| `App/RunApp.swift` | `runApp` |

Stored properties must stay in the class body in `AppDelegate.swift`; extensions hold methods only. Delete `app/`
when empty; move `app/Info.plist` to `Resources/Info.plist`.

## Step 3: build scripts

Rewrite `build.sh` so the Swift part is:

```sh
CONFIG="${1:-release}"
swift build -c "$CONFIG" --arch arm64
BIN="$(swift build -c "$CONFIG" --arch arm64 --show-bin-path)"
cp "$BIN/ElgatoHDR" "$APP/Contents/MacOS/ElgatoHDR"
cp Resources/Info.plist "$APP/Contents/"
```

Everything else in the script (helper compile, libusb copy, `install_name_tool`, ad-hoc `codesign`) stays. `./build.sh
debug` must work and define `DEBUG` (SwiftPM does this for debug builds). `package.sh` reads the version from the new
plist path. Add `.build/` to `.gitignore`.

## Step 4: demo source

The point: exercise `Session`, `Renderer`, `Recorder` and the audio path **unchanged**, with frames that come from
the app itself.

Create `App/DemoSource.swift`:

- `final class DemoSource { init(width: Int, height: Int, fps: Double); let memory: UnsafeMutableRawPointer;
  let readFD: Int32; func start(); func stop() }`.
- `memory` is `mmap(nil, shmSlots * shmSlotBytes, PROT_READ|PROT_WRITE, MAP_ANON|MAP_PRIVATE, -1, 0)`: the same size
  and layout the helper's shared memory has, so `Renderer.init(layer:shm:)` works as is.
- `socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)`; the app's `Session` reads `fds[0]`; a writer thread owns `fds[1]`.
- The writer thread speaks the helper's wire protocol, which is defined by `Session.run()`: a 32-byte little-endian
  header `{ 'U','V','C', type; u32 a; u32 b; u32 c; u32 size; u64 timeNs; u32 seq }`.
  - Video (`type 0x53`): `a` = width, `b` = height, `size` = `width*height*3`, `timeNs` = `nowNs()`, no payload on
    the socket. Before sending, fill slot `seq % shmSlots` at `memory + slot * shmSlotBytes`: a Y plane of `w*h`
    16-bit little-endian samples then an interleaved CbCr plane of `w/2 * h/2` pairs, 10-bit video-range values in
    the **high** 10 bits (P010: `code << 6`).
  - Audio (`type 0x41`): `a` = 48000, `b` = 2, `c` = 16, `size` = byte count, `timeNs` = time the chunk **ends**,
    followed by interleaved signed 16-bit stereo. Send about 10 ms per chunk.
- Picture: PQ-coded colour bars in the top half, a grey ramp below, a white square moving left to right once per
  second, and the frame number drawn as an 8-bit binary strip (eight squares) so tests can identify frames. For the
  first frame of each second the whole strip at the bottom flashes white. Fill with a precomputed background copied by
  `memcpy` plus the few moving rectangles; a 4K frame must cost under 3 ms.
- Sound: silence with a 1 kHz, 50 ms beep starting exactly at the flash frame. Flash plus beep is the A/V sync marker
  used by later plans.
- Pace with `clock_gettime_nsec_np(CLOCK_UPTIME_RAW)` and absolute deadlines, not `usleep(period)`.

Wire it in `AppDelegate`:

- `--demo-source [WxH@FPS]` (default `2560x1440@60`): `start()` skips `connectHelper`/`spawnHelper…`/`mapSharedFrames`
  and builds `Renderer` and `Session` from the demo source instead. The title shows "demo source".
- `--demo-camera`: add `func injectDemo()` to `CameraCapture` that starts a 30 fps timer on `videoQueue` producing
  1280×720 `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange` buffers (IOSurface-backed, Metal compatible; a moving
  gradient is enough) with BT.709 attachments, stores each in `_latest`, calls `cameraRecorder?.appendVideo`, and
  feeds `micRecorder` 48 kHz mono float sample buffers containing the same beep. `cameraOn`/`micOn` must report true
  in this mode (add a private `demo` flag). No `AVCaptureDevice` is touched, so no permission dialog appears.

## Step 5: tests

Create under `Tests/StudioKitTests/`:

1. `LayoutMathTests`: `fillCrop` for wider, taller and equal sources, zoom 2, pan clamping at the edges; `fitRect`;
   `CameraPlacement.rect(in:)` clamps inside the canvas for both canvases; `anchors` returns eight points;
   `move(to:canvas:snap:)` snaps within 5% and not beyond.
2. `ProjectCodingTests`: decode a version-1 `project.json` fixture (write one by hand under
   `Tests/StudioKitTests/Fixtures/`, including a file with only `name` set) and check defaults; encode-decode round
   trip equality.
3. `CompositorGoldenTests`: build synthetic textures (game 64×36 10-bit, camera 32×32 8-bit, both with a few flat
   colour patches), render through `MetalCore.shared.encodeComposite` into a 128×72 `.rgba16Float` texture for each
   of: pip with shadow and border, stacked, screen only, camera only; each for output transfer PQ, HLG and SDR. Read
   back a 16×9 grid of pixels and compare with JSON goldens in `Fixtures/golden/`. Tolerance 0.002 per channel.
   Setting the environment variable `RECORD_GOLDENS=1` rewrites the goldens. **These goldens are the contract plan 10
   must keep.** Skip with `XCTSkip` when `MTLCreateSystemDefaultDevice()` is nil.
4. `FixtureProject` helper plus `ExportTests`: write a two-second project to a temp directory with `Recorder` (HEVC
   Main 10, PQ, 1920×1080, 60 fps; generate the pixel buffers directly), `LayerWriter` camera and mic layers, and
   `ProjectDoc.finalize`. Then run `Exporter` for both canvases in HDR and SDR and assert with `AVURLAsset`: video
   dimensions, duration within one frame, codec (`hvc1` or `avc1`), transfer function tag, an audio track present.
   Skip when no hardware HEVC encoder is available (CI virtual machines may lack one).
5. `DemoSourceTests`: start a `DemoSource` at 320×180@30, read ten headers from the socket and validate magic, sizes,
   increasing `seq`, and monotonic timestamps.

Also add a debug-only flag `--make-fixture <dir>` to the app that writes the fixture project into the library folder
so humans and agents can open the editor on known content.

## Step 6: CI and docs

- `.github/workflows/ci.yml` on `pull_request` and pushes to `main`, runner `macos-15`: `brew install libusb`,
  `swift build`, `swift test`, `./build.sh`.
- `release.yml` keeps working with the new paths.
- Add `AGENTS.md` at the repository root with the content of section 5 of `plans/README.md` (copy it; agents read
  `AGENTS.md` automatically) and a `CLAUDE.md` containing the single line `See AGENTS.md.`
- Update the "Project layout" and build sections of `README.md`.

## Acceptance

Paste the output of each in the pull request.

1. `swift build && swift test` pass locally; note any test skipped and why.
2. `./build.sh` produces `dist/Elgato HDR.app`; `codesign -v` on it succeeds.
3. `"dist/Elgato HDR.app/Contents/MacOS/ElgatoHDR" --demo-source --demo-camera --record 5` runs for ten seconds; the
   log shows about 60 fps, a "saved Capture … [game + camera + mic]" line, and the new folder in
   `~/Movies/Elgato HDR/` contains `game.mov`, `camera.mov`, `mic.m4a`, `project.json`, `thumbnail.jpg`.
4. `… --export "<that folder>" sdr hd` exits 0 and writes two files into `Exports/`. Check one with
   `ffprobe -v error -show_streams`.
5. `git diff --stat main` shows moves and the new files only; grep confirms no type or function was renamed.
6. Latency line "helper->screen" in demo mode, Game presentation (`-presentation game`), recorded in the pull request
   as the baseline later plans compare against.

## Pitfalls

- Top-level code is only legal in `main.swift`. After the move, the old globals `app` and `delegate` exist only
  inside `runApp()`.
- `AppDelegate` uses `#selector` on methods that will sit in extensions: keep them `@objc`.
- `Bundle.main` lookups for `uvc_capture` only work in the bundled app. That is fine; do not "fix" it.
- The shader is compiled from a string at runtime. Do not move it to a `.metal` file (SwiftPM resource bundles break
  the hand-assembled app bundle).
- `swift test` loads `StudioKit` in a process without a window server session on CI. Nothing at file scope may touch
  `NSApp` or create windows; `MetalCore.shared` is lazy and must stay so.

## Out of scope

Any behaviour change, renaming, access-control clean-up, Swift 6 mode, new UI, fixing the audit findings (they have
their own plans).
