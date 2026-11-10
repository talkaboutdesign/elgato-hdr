# Elgato HDR

A tiny native macOS app that captures the **10-bit HDR** signal from an **Elgato 4K X** and shows it live, in real HDR, and records it to a proper HDR10 file.

macOS hides this. The Elgato 4K X advertises a 10-bit `P010` video format over USB, but Apple's built-in webcam driver only ever exposes the 8-bit modes to apps like QuickTime, OBS, or anything using AVFoundation. So on a Mac you normally cannot see or record the capture card's HDR output at all, even though the same card does it fine on Windows. This project reaches the hidden 10-bit format directly and renders it the way macOS renders HDR video.

The whole thing is a few MB: a small native AppKit/SwiftUI app plus a C helper. No Electron, no third-party frameworks, no background services.

![Elgato HDR showing a game capture](docs/screenshot.png)

---

## What it does

- **Live HDR preview.** Displays the incoming 10-bit `P010` video as true HDR (BT.2020 / PQ by default) on any EDR-capable display, such as a Studio Display, XDR, or a MacBook Pro screen. Colors and highlights use the display's extended brightness range, exactly like HDR video playback.
- **Records HDR10.** Writes a 10-bit HEVC (`Main 10`) `.mov` with BT.2020 / PQ color, HDR10 mastering-display and content-light-level metadata, and AAC audio. The files play back as HDR in QuickTime, Finder, Final Cut, and DaVinci Resolve, and upload correctly to YouTube.
- **Captures audio too.** Pulls the card's USB audio (48 kHz stereo) alongside the video, plays it live with a mute toggle, and muxes it into the recording locked to the video clock.
- **Smooth, in-sync playback.** Frames are paced to the display's refresh so motion is even, and recorded files are stamped on a fixed frame grid so they play back perfectly steady regardless of USB timing jitter.
- **Facecam overlay, like a streamer.** Show any camera (built-in, Studio Display, iPhone Continuity Camera, USB webcam) in a window over the game. Drag it anywhere (it snaps to corners and edges), drag a corner or scroll to resize, and pick circle, rounded or square.
- **Scenes, switched live.** A strip of scenes (Gameplay, Game Only, Camera Focus, Just Camera, and your own) with ⌃1–⌃9. Switching glides each layer to its new place (morph), fades or cuts; a live zoom punches in on the game. Arrange any layer directly on the picture, separately for 16:9 and 9:16.
- **Overlays.** Image and text layers (logos, name tags, a live `{timer}` or the clock), ready-made screens for *Starting Soon*, *Be Right Back* and *Ending*, and presets for a name tag and a camera frame. They show in the window, in every stream, in the scene thumbnails, and in the editor preview, the library and every export of a recording.
- **Go live, to several platforms at once.** Twitch, YouTube, Kick or any RTMP/RTMPS server, in 16:9 and 9:16 at the same time, each showing the scene you are on, with per-destination health.
- **Layered recordings.** Game, camera and microphone are recorded as separate files that start at exactly the same instant, so nothing is baked in. Change the layout, framing, volumes and sync after the fact.
- **An editor that remembers the stream.** Open a recording and every scene switch (with the cut, fade or morph that was live), live zoom and marker is already on the timeline. Cut out the dull parts, retime scenes, add zooms on the action, and move or add any layer right on the picture.
- **One recording, every format.** The editor keeps a widescreen **16:9** and a vertical **9:16** layout of every scene and exports YouTube, 1080p and Shorts/Reels/TikTok versions in one queue, as HDR10 HEVC or SDR H.264.
- **All the card's HDR modes.** 4K30, 1440p60, ultrawide 2560×1080 60, 1080p 120/60/30, and 720p 120, every one of them 10-bit.

### Color modes

| Mode | Use it for |
|------|------------|
| **HDR10 (PQ, BT.2020)** — default | An HDR source (HDR game console, HDR camera) |
| **HLG (BT.2020)** | An HLG source |
| **SDR (BT.709)** | A standard-dynamic-range source, still captured at 10-bit |

---

## Requirements

- macOS 14 or newer (built and tested on Apple Silicon).
- An **Elgato 4K X** capture card. Other Elgato cards that expose a `P010` UVC format may work but are untested.
- An HDR / EDR-capable display to see the HDR preview (SDR displays still work, just tone-mapped by macOS).
- Optional: any camera and microphone macOS can see, for the facecam and commentary layers. macOS asks for camera and microphone access the first time you turn them on.
- For building from source: **Xcode Command Line Tools** and **[Homebrew](https://brew.sh)**.

---

## Install

### Option A — download a release

1. Grab the latest `ElgatoHDR-<version>.zip` from the [Releases](../../releases) page and unzip it.
2. Move **Elgato HDR.app** to `/Applications`.
3. The app is signed only for local use, not notarized by Apple, so the first launch is blocked by Gatekeeper. Open it once with **right-click → Open**, then click **Open** in the dialog. After that it launches normally. (Command-line equivalent: `xattr -dr com.apple.quarantine "/Applications/Elgato HDR.app"`.)

### Option B — build from source

```sh
git clone <this-repo-url> elgato-hdr
cd elgato-hdr
brew install libusb          # the helper links against libusb
xcode-select --install       # if you don't already have the CLT
swift build                  # compile StudioKit and the executable (Swift 5 mode)
swift test                   # unit, compositor golden and export tests
./build.sh                   # release bundle: dist/Elgato HDR.app
./build.sh debug             # debug bundle, includes --make-fixture and --design-gallery
open "dist/Elgato HDR.app"
```

---

## Using it

1. Plug an HDR source into the Elgato 4K X and connect the card to your Mac.
2. Launch **Elgato HDR**. The first time, a short sheet explains why the app needs your password, then macOS shows its **administrator prompt** — this is required (see [How it works](#how-it-works)). Enter your password and the live picture appears. No card at hand? Choose **Try the Demo Source** on that sheet.
3. Pick your source resolution and colour mode in the sidebar's **Scene** tab, under **Picture** (or the **Input** and **Color** menus).
4. Optional: choose your camera (select the camera layer in the **Scene** tab) and your microphone in the **Audio** tab, or press **⌘K** and use the **Camera** menu. Drag the camera where you want it on the picture.
5. Click **Record** in the toolbar, or press **⌘R**, to start and stop recording. Each recording is saved as its own folder in `~/Movies/Elgato HDR/`.
6. Press **⌘O** to open the **Recordings** library. Double-click a recording to edit and export it.

### The studio window

- **Toolbar:** the **Record** button turns into a running timer while recording. **Go Live** shows how many destinations are on; clicking it lists them with switches and a confirm button, so going live always takes two clicks. While live it reads **LIVE 12:34** and opens per-destination health with **End Stream**. The **16:9 / 9:16** switch picks which canvas the window shows and you edit; streams always get their own canvas, whichever is shown.
- **Picture:** the active scene, letterboxed to any window size. Click a layer to select it, drag to move (it snaps to edges, centres and other layers; ⌥ turns snapping off), drag a handle to resize, scroll to scale, arrow keys to nudge, ⌫ to delete an image, text or colour layer (the game and camera are hidden instead). Double-click the game or camera to crop it, or a text layer to edit its words. Drop an image file on the picture to add it there. The status pill in the bottom-left corner shows the signal and the delay to the screen (or *Connecting…*, *No signal*, *Demo source*); it fades away when you stop moving the mouse.
- **Bottom bar:** the scene strip with a live thumbnail of every scene (click to switch, drag to reorder, right-click to rename, duplicate or delete, **+** for the template gallery), game-audio monitoring and a live microphone meter.
- **Sidebar** (⌥⌘S): **Scene** holds the active scene's layers (topmost first, with an eye to hide each and **+** to add one), an inspector for the selected layer, the transition and live zoom, and the picture settings; **Audio** holds game monitoring and the microphone with its level; **Stream** lists your destinations with their switches and, while live, each one's state, bitrate, dropped frames and uptime, plus the output settings (resolution, frame rate, bitrate with the total upload, mic delay).
- **Focus mode** (⌘F): full screen with the sidebar and bottom bar out of the way, so the game fills the display. Move the pointer to the top edge for the toolbar; leaving full screen brings the panels back as they were.
  With **View › Show Clean Game Picture in Focus Mode** (on by default) the full-screen picture is the whole game in its own aspect, without camera, overlays, crop or zoom: an ultrawide game is letterboxed instead of cropped to 16:9, so no HUD is lost. The stream, recordings and scene thumbnails still show the scene.
- Messages such as *Recording saved* appear briefly at the top of the picture instead of in the window title.

### Scenes and overlays

Every scene has its own 16:9 and 9:16 layout: a stack of layers drawn bottom first. The **+** in the Scene tab's
**Layers** list adds:

- **Image…**: a PNG, JPEG, HEIC, TIFF or GIF (its first frame). Or drag the file onto the picture. The inspector
  replaces the file and sets fill or fit, corners, opacity, border and shadow.
- **Text**: type in the inspector and the picture follows as you type. Font, weight, alignment, colour, a rounded
  plate behind it and a shadow. `{timer}` shows how long you have been live (or, when not live, recording; otherwise
  0:00) and `{time}` the clock; both update by themselves.
- **Color**: a solid backdrop.
- **Game** and **Camera**, and the presets **Name Tag** (your name on a plate, bottom left) and **Camera Frame** (a
  coloured ring around the camera).

The **+** at the end of the scene strip adds a scene from a template: the layouts, or the screens **Starting Soon**
(title and the clock), **Be Right Back** (with the live timer) and **Ending** (your camera in a ring). Templates are
built from colour, text and camera layers, so everything in them can be edited. Switching to a scene that shares a
layer with the current one (a duplicate, say) glides that layer to its new place.

Scenes are saved in `~/Library/Application Support/Elgato HDR/scenes.json`; imported images are copied into
`~/Library/Application Support/Elgato HDR/Assets/` under a name made from their contents, so moving or deleting the
original does not break a scene.

### Streaming

Add Twitch, YouTube, Kick or any RTMP/RTMPS server in the sidebar's **Stream** tab (or **Stream → Add Destination…**):
pick the service, paste the stream key (the URL is prefilled for Twitch and YouTube; Kick gives you a personal URL),
choose 16:9 or 9:16, and use **Test Connection** to check URL and key without going live. Every destination on the
same canvas shares one encode; each uploads its own copy, so three destinations at 6,000 kbps need about 18.5 Mbps
of upload. While live you can switch single destinations off and on; one failing never stops the others.

To stream: click **Go Live** (or ⇧⌘L), check the destinations, and confirm. Each stream shows the scene you are on in
its own canvas: a widescreen destination the scene's 16:9 layout, a vertical one its 9:16 layout, with the same
transitions, live zoom and overlays as the window, frame for frame. Switch scenes with the strip or ⌃1–⌃9 while live,
start and stop recordings, or change the capture mode or reconnect the card: the stream keeps running (it shows the
scene without the game until the picture is back). Focus mode's clean game picture is for your screen only; viewers
always get the scene.

Stream keys are stored in your login Keychain, never in files or logs. The app is ad-hoc signed until it is
notarized (plan 90), so after installing a new build macOS may ask for your password the first time the app reads
a saved key; choose **Always Allow**. If you deny it, enter the key again in the destination's sheet.

### Editing and exporting

Open a recording from the library (⌘O, then double-click it). The editor shows the edit exactly as it will be
exported, scenes, transitions, zooms and overlays included, in HDR when the export is HDR.

![The editor: a text layer added to a recording's scene, selected on the picture](docs/editor.png)

- **What happened live is already there.** Each scene switch comes back with the transition that was live (cut, fade
  or morph, and its duration), each live zoom as a zoom block and each ⌃M marker as a marker, so the export plays
  what viewers saw until you change it.
- **Cut.** The timeline shows the whole recording. **S** or **⌘B** splits at the playhead, **⌫** removes the selected
  section (it stays hatched, so ⌫ again or **Restore** brings it back), **I** and **O** set the in and out points,
  **H** hides removed sections. Playback skips what you removed.
- **Scenes over time.** Click a span on the scene track to pick another scene or change its transition; drag its
  edge to retime it; **⌃1–⌃9** change the scene at the playhead. **Add from Live Scenes** (in the scene picker and the
  **Scene** button above the timeline) copies one of your live scenes, with its images, into the recording.
- **Zoom on the action.** **Z** adds a zoom block at the playhead; drag the target on the picture to choose the point
  it closes in on, and the block's edges to time it.
- **Arrange any layer on the picture**, as in the live window: click a layer of the scene at the playhead, drag to
  move it (it snaps; ⌥ turns snapping off), drag a handle to resize, arrow keys nudge, ⌫ deletes (the game and camera
  are hidden instead), double-click crops the game or camera or edits a text layer. The inspector has the same layer
  list and controls as the live **Scene** tab: add images, text and colour, reorder, hide. Edits change the
  recording's own copy of the scene; **Save as Live Scene** (the scene's ⋯ menu) adds it to your live scenes.
- **Overlays in the edit.** `{timer}` counts time on the edited timeline (it starts at 0:00 and leaves out what you
  cut); `{time}` shows the clock when that moment was recorded. An image whose file is gone is left out, and the
  export sheet lists it.
- **Undo** with ⌘Z and ⇧⌘Z; a whole drag is one step.
- **Audio & Sync** (in the inspector with nothing selected) sets the game and mic volumes and nudges the camera or
  mic in milliseconds, if your voice runs ahead of the gameplay because of the card's delay.
- **Export** (⌘E) offers **YouTube** (16:9 at the source resolution up to 4K, HDR when recorded in HDR),
  **YouTube 1080p SDR**, **Shorts, Reels, TikTok** (9:16, 1080×1920, SDR, 60 fps) and **Custom**. Tick several and they
  run as a queue, with progress in the toolbar; the finished file can be dragged from the toast straight into an
  upload. Exports go into the recording's `Exports` folder. While you are live or recording they wait for the video
  encoder and run slower; the export sheet says so before you start.

A recording folder contains:

```
game.mov       10-bit HEVC HDR video + game audio (the card's signal, untouched)
camera.mov     H.264 facecam (only if the camera was on)
mic.mov        AAC microphone (only if a mic was selected; mic.m4a in older recordings)
project.json   The recording's own copy of its scenes, the live events (scene switches with their transitions, zooms,
               markers) as they happened, and every edit (cuts, scene changes, zooms, markers, volumes, sync);
               nothing is baked into the video files
Assets/        The images its scenes use, copied in when recording starts and when you add one in the editor, so the
               folder stays complete when it is moved
thumbnail.jpg  Library card (the 16:9 edit at the first marker)
Exports/       Rendered videos
.cache/        Filmstrip, waveforms and hover frames; safe to delete
```

### Menus and shortcuts

| Menu | Item | Shortcut |
|------|------|----------|
| Input | 4K 30 … 720p 120 | ⌘1 – ⌘7 |
| Color | HDR10 / HLG / SDR | — |
| Audio | Mute | ⌘M |
| Camera | Show / Hide Camera | ⌘K |
| Camera | Bigger / Smaller | ⌘= / ⌘- |
| Camera | Camera, microphone, shape, position, mirror, border, shadow | — (also on right-click in the live view, and in the sidebar) |
| Record | Start / Stop Recording | ⌘R (also the toolbar's Record button) |
| Record | Recordings Library | ⌘O |
| Record | Show Recordings in Finder | — |
| Stream | Go Live… / Stream Health… | ⇧⌘L (also the toolbar's Go Live button) |
| Stream | End Stream, Add Destination…, Destinations and Settings | — |
| View | Show Live View | ⌘0 |
| View | Focus Mode (Full Screen) | ⌘F |
| View | Hide / Show Sidebar | ⌥⌘S |
| View | Smooth / Game / Lowest Latency | ⌘J / ⌘G / ⌘L |
| View | Reconnect | ⇧⌘R |
| View | Show Clean Game Picture in Focus Mode | — |
| Scenes | Switch to a scene | ⌃1 – ⌃9 (also a click in the scene strip) |
| Scenes | Next / Previous Scene | ⌃⇧→ / ⌃⇧← |
| Scenes | Zoom In on Game / Zoom Out | ⌃Z, or hold ⌃⇧Space to zoom while held; arrow keys move the zoom |
| Scenes | Add Marker (while recording) | ⌃M |

macOS keeps ⌃Space (input sources) and ⌃← / ⌃→ (Mission Control) for itself, so the scene shortcuts add ⇧. While you
type in a field, ⌃Z, the arrow keys and ⌫ go to the field, never to the picture.

In the editor (**⌘/** lists every shortcut):

| Keys | Action |
|------|--------|
| Space · J K L | Play or pause · shuttle backward, stop, forward (again for 2× and 4×) |
| ← → · ⇧← ⇧→ · ↑ ↓ | One frame · one second · previous or next edit point |
| S or ⌘B · ⌫ | Split at the playhead · remove (or restore) the selected section, or delete the selected item |
| I · O · ⌥X | In point · out point · clear both |
| Z · M · ⇧M ⌥M | Add a zoom · add a marker · next or previous marker |
| ⌃1 – ⌃9 | Change to scene 1…9 at the playhead |
| With a layer selected | ← → ↑ ↓ nudge 1 px (⇧ 10 px), ⌫ delete, Esc deselect |
| = - · ⇧Z · H | Zoom the timeline · show all of it · hide removed sections |
| ⌘Z ⇧⌘Z · ⌘E | Undo, redo · export |

The **View** menu picks how frames reach the screen. None of these affect recordings.

| Setting | What it does | Measured delay, 1440p60 on a 120 Hz MacBook Pro |
|---------|--------------|------|
| **Smooth** (default) | Holds each frame briefly so motion is perfectly even | ~48 ms |
| **Game** | Shows each frame as soon as it arrives, synced to the display refresh (no tearing) | ~22 ms |
| **Lowest Latency** | Shows each frame immediately without waiting for the refresh; can tear in full screen | ~5 ms |

Delays are from a frame finishing its USB transfer to it being shown, as reported by macOS; the card's own processing comes on top. For playing, use **1440p 60** or **1080p 120** with Game: 4K 30 is the only 4K HDR mode the USB link has bandwidth for, so a 4K60 source is captured at half its frame rate.

---

## How it works

The moving parts:

1. **`tools/uvc_capture.c` — a small root helper.** Using [libusb](https://libusb.info), it detaches Apple's USB video driver from the card and talks the USB Video Class protocol directly. It negotiates the hidden `P010` format (format index 7), reads the video off the card's bulk endpoint, reassembles frames, and also captures the card's USB audio. Detaching the kernel driver requires root on macOS, which is why the app asks for your password once and launches the helper with administrator privileges. The helper runs as a small server, stays alive across resolution changes, and exits on its own about 20 seconds after the app quits, handing the card back to macOS so other apps see it again.

2. **Shared-memory hand-off.** The helper writes each frame straight into a shared-memory ring the app reads with zero copies. Only tiny header messages travel over a Unix socket. This keeps 4K frames off the CPU's memory-copy path entirely.

3. **`Sources/StudioKit/` — the AppKit app.** A Metal shader converts the 10-bit `P010` planes to RGB directly from shared memory and draws into a PQ / HLG / BT.709 layer with the right EDR metadata, so macOS lights it up as HDR. A display-link scheduler paces frames onto the refresh grid for even motion. Audio plays through AVAudioEngine on a dedicated thread. Recording uses the hardware HEVC `Main 10` encoder via AVAssetWriter, stamping video on a fixed frame grid and gently slewing audio to keep A/V sync locked.

4. **One compositor for every picture.** A scene is a list of layers per canvas (game, camera, image, text, colour). `SceneResolver` turns one into draw rectangles and `MetalCore.encodeLayers` draws them, decoding each source by its own colour tags and writing PQ, HLG or tone-mapped SDR. The live window, every stream, the scene thumbnails, the editor preview and every export go through it, so they show the same picture. Images and text become textures in one `OverlayTextureCache`, made off the render threads.

5. **Scenes and transitions are one pure function of time.** `LiveSceneState` gives the layers of the picture at any host time: the scene, a cut, fade or morph from the previous one, and the live zoom. The window and each stream lane ask it for their own frame time, so they agree frame for frame. A recording logs each switch, with its transition, as an event; the editor turns the events into scene spans and its `RenderPlan` evaluates the same engine at each frame of the edit, so the export replays exactly what was live.

6. **Streaming.** Each canvas (16:9, 9:16) is rendered once (`ProgramOutput`), encoded once with VideoToolbox H.264, and sent by one RTMP/RTMPS connection per destination, written on Network.framework. Game audio and the microphone are mixed on the host clock and encoded to AAC. Stream keys live in the Keychain.

7. **Layers, editor and export.** The camera and microphone are captured with AVCaptureSession and written to their own files on the same host clock as the game, so the layers line up without any baked-in mix. The editor plays the recording through AVFoundation with the compositor as its custom video compositor; cuts map edit time to recording time, and an export reads the same composition through AVAssetReader into AVAssetWriter.

Measured latency from a frame arriving over USB to it appearing on screen is a few milliseconds of app work on top of the card's own processing; the app favors smooth, in-sync output over shaving off the last milliseconds.

### A note on HDR metadata

The recorded files carry standard HDR10 mastering metadata (1000-nit peak, P3 primaries). The Elgato does not pass the source's original HDMI HDR metadata over USB, so these are sensible defaults rather than the exact values the source mastered to. Players use them only as a tone-mapping hint; the actual 10-bit pixels are untouched, so the picture is correct either way.

### Troubleshooting

- The app logs to `~/Library/Logs/Elgato HDR.log`. Include it when reporting a problem.
- If the camera or microphone fails to start, the app shows an alert with a shortcut to **System Settings → Privacy & Security**, where you can grant access.

---

## Project layout

```
Package.swift                 Swift 5.9 package; one StudioKit library, executable and tests
Sources/ElgatoHDR/main.swift   Three-line executable entry point
Sources/StudioKit/App/        App delegate extensions, demo source, debug fixture writer
Sources/StudioKit/Capture/    Helper protocol, sessions, camera + microphone capture
Sources/StudioKit/Render/     Shared Metal compositor and live renderer
Sources/StudioKit/Scenes/     Scene collection, transitions and live zoom, templates, thumbnails
Sources/StudioKit/Overlays/   Image assets, text rasterizer and the overlay texture cache
Sources/StudioKit/Streaming/  Program outputs, H.264 encoder, stream session, destinations, RTMP
Sources/StudioKit/Audio/      Audio playback, the stream's audio mixer and AAC encoder
Sources/StudioKit/Record/     Game and layer writers
Sources/StudioKit/Model/      Project, layout math and library
Sources/StudioKit/Edit/       Timeline, render plan, composition builder and exporter
Sources/StudioKit/UI/         Design system, studio window, library, editor and the picture views
Sources/StudioKit/Support/    Logging and socket reads
Tests/StudioKitTests/         Layout, coding, protocol, golden and export tests
Resources/Info.plist          App bundle metadata
tools/uvc_capture.c   Root helper: libusb UVC bypass, P010 capture, USB audio, shm server
tools/*.c             USB descriptor dumps used while reverse-engineering the card
tools/modetest.py     Test client that sweeps every capture mode
build.sh              Builds dist/Elgato HDR.app (bundles the helper and libusb)
package.sh            Builds and zips a distributable release
```

---

## Contributing

Contributions are welcome. Bug reports, new capture-device support, and improvements to latency, color, or recording are all useful.

- Open an issue describing what you see, ideally with the card model and macOS version.
- For code changes, keep the app small and dependency-free, and test that live view, audio, and recording all still work before opening a pull request.
- Descriptor dumps from other Elgato (or other-brand) capture cards that expose a 10-bit UVC format are especially welcome — they are how support for more devices gets added.

---

## License

[MIT](LICENSE). This is an independent project and is not affiliated with or endorsed by Elgato or Corsair.


### Development without capture hardware

Always launch the bundle (its Info.plist supplies the privacy declarations):

```sh
"dist/Elgato HDR.app/Contents/MacOS/ElgatoHDR" --demo-source --demo-camera -presentation game --record 5
# Optional game format, default 2560x1440@60:
"dist/Elgato HDR.app/Contents/MacOS/ElgatoHDR" --demo-source 1920x1080@60 --demo-camera
# Debug bundle only; a relative name creates a project inside the recordings library:
"dist/Elgato HDR.app/Contents/MacOS/ElgatoHDR" --demo-source --demo-camera --make-fixture "Demo Fixture"
```

Demo mode uses synthetic P010 game video, game audio, a 720p camera and mono mic without helper privileges or
camera/microphone access. Use both flags to bypass saved real-device selections. The moving picture flashes with
a 50 ms 1 kHz beep each second. Recordings and exports use the normal code paths.
Logs are in `~/Library/Logs/Elgato HDR.log` and stderr.

### Development streaming controls

The following controls require `./build.sh debug`. The user-facing `--record <seconds>` flag also works in release.

Streaming without touching your own destinations or keys: `EHDR_STREAMING_FILE=<path>` uses another
`streaming.json`, `EHDR_KEYCHAIN_SERVICE=<name>` another Keychain service, and `--go-live-for <seconds>` goes live to
the enabled destinations and quits afterwards (with `EHDR_STREAM_KEY` as the key for all of them; used by
`scripts/stream-selftest.sh`). Debug builds take `EHDR_STREAM_UI="tab@1,popover@4,sheet:twitch@8,close@12"` to open
the stream UI for `EHDR_SNAPSHOT` screenshots.

`RECORD_GOLDENS=1 swift test --filter CompositorGoldenTests` regenerates the twelve PQ/HLG/SDR layout goldens;
review changes before committing. Metal tests skip without a Metal device; export tests skip without hardware HEVC.
CI runs build, tests and release bundling on macOS 15. No ffmpeg runtime dependency is used.
