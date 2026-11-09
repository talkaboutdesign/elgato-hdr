# Plan 90: Later work (briefs, not yet executable)

These are scoped but deliberately not detailed: each depends on code that plans 00–31 will write. Before starting
one, the planner turns its brief into a full work order against the code as it then stands. Order is by value.

## 90.1 Clip that: replay buffer and instant shorts

The feature most likely to make the app loved. A hotkey (and a marker button) saves the last 30–120 seconds as a
project, even when not recording, and opens it directly in the 9:16 editor with a suggested cut around the moment.

- Keep a rolling window of encoded game, camera and mic samples in memory (compressed samples, not frames:
  1440p60 HEVC at 25 Mbps is about 190 MB per minute) and write them out with `AVAssetWriter` in passthrough mode
  on demand.
- Requires the game encoder to run continuously, so measure the idle cost first.
- Editor entry point "Make short from marker" already exists in plan 31.

## 90.2 Privileged helper as a launch daemon, signing, notarization, updates

- Replace the AppleScript administrator prompt on every launch with a one-time approval: `SMAppService.daemon`
  with a bundled launchd property list; socket and shared memory move out of `/tmp`, the helper checks the peer's
  code signature (`SecCodeCheckValidity` on the audit token), permissions become owner-only. Fixes audit finding 9.
- Needs an Apple Developer ID. Sign with hardened runtime, notarize in CI, staple, publish a DMG.
- Auto update: Sparkle is the standard but is a third-party dependency; decide then whether the "no dependencies"
  rule gets its first exception or the app only shows a "new version available" link.
- Decide the product name and bundle identifier before the first signed release (changing the identifier later
  resets permissions and Keychain access).

## 90.3 HDR streaming to YouTube

- HEVC Main 10 over Enhanced RTMP (extended video tag header with FourCC `hvc1`,
  HEVCDecoderConfigurationRecord as the sequence header). YouTube's current guidance recommends HEVC over RTMPS
  for HDR and falls back to HLS ingest; confirm at the time.
- Program output renders P010 PQ (the compositor's HDR export path already does this) for that destination only;
  other destinations keep SDR. That is a third encoder, so check hardware session limits and thermals.

## 90.4 More sources

- **Other capture cards and cameras as the game source** through `AVCaptureSession` (8-bit SDR). Needs a
  `VideoSource` protocol in front of `Session`: the renderer already takes textures plus format information.
- **Mac screen or window** (native Mac games, cloud gaming in a browser) through ScreenCaptureKit, including its
  HDR capture mode and application audio.
- **System and application audio** as mixer inputs (voice chat): Core Audio process taps (macOS 14.2+).
- **Second camera**, **media file** playback layers.

## 90.5 Web overlays, alerts and chat

- Browser layers for alert and chat widgets from the common services. Offscreen `WKWebView` with a transparent
  background; capturing it into a texture at 30 fps efficiently is the hard part (options: `takeSnapshot`, layer
  rendering, or ScreenCaptureKit on an offscreen window). Prototype and measure before committing.
- Native chat panel in the sidebar and optional chat overlay need platform sign-in (90.7).

## 90.6 Voice and captions

- Microphone clean-up: system voice isolation where available, a noise gate and a simple compressor in the mixer.
- Captions for shorts: on-device transcription (Speech framework), caption styles as animated text layers, `.srt`
  export.
- Remove silences and "find the loud moments" (suggest markers from audio energy and, for supported games, from
  kill-feed style cues later).

## 90.7 Platform accounts

- OAuth sign-in for Twitch, YouTube and Kick: fetch the ingest URL and key automatically, set title and category
  before going live, show viewer counts, read chat, and upload exported videos directly.
- Client credentials must not ship in an open-source binary without thought; decide the approach (public client
  with PKCE, or user-supplied app credentials).

## 90.8 Stream quality and control

- Adaptive bitrate when a destination's backlog grows, per-destination bitrate and resolution, stream delay,
  dedicated program recording, studio mode (separate preview and program), global hotkeys while another app is in
  front, Stream Deck and MIDI control, per-scene audio settings, stinger transitions.

## 90.9 Editor depth

- Speed ramps and slow motion from 120 fps captures, reordering and multi-recording projects, music with automatic
  ducking under voice, transitions between cuts, shareable style presets, a ⌘K command palette, 1:1 canvas.
