# Plan 20: Program output, video encoder and the first Go Live

**Goal.** Render the scene to a stream-sized picture, encode it to H.264, mix and encode audio, and publish to one
RTMP destination, in 16:9 or 9:16, while the live view and recording keep working. Minimal UI (a menu item and
launch arguments); the real destinations UI is plan 21.

**Depends on:** 10, 11, 12. **Blocks:** 21.

**Files you own:** new `Sources/StudioKit/Streaming/` (except `RTMP/`), a small hook in `Render/LiveRenderer.swift`,
`App/AppDelegate+Streaming.swift` (new), tests. Do not change the RTMP library or the mixer; report bugs you find in
them.

## Read first

`Render/LiveRenderer.swift` (`submit`, `drawNow`), `Render/MetalCore.swift` (`encodeLayers`), `Capture/CaptureSession.swift`
(where frames and audio arrive), plans 11 and 12 (their public surfaces), `Record/Recorder.swift` (how timestamps are
derived from `startNs`).

## Design

### ProgramOutput: scene to pixel buffers

```swift
final class ProgramOutput {
    init(canvas: Canvas, size: CGSize, fps: Double)                 // 1920×1080 or 1080×1920, 60 or 30
    var composition: () -> Composition                              // supplied by the app; read on the render thread
    var onFrame: ((CVPixelBuffer, _ hostNs: UInt64) -> Void)?
    /// Called on the reader thread for every game frame. Renders only when the output's frame index advances.
    func gameFrame(y: MTLTexture, c: MTLTexture, size: CGSize, colorMode: ColorMode, camera: CVPixelBuffer?, hostNs: UInt64)
    func start(); func stop()
}
```

- Target: a `CVPixelBufferPool` of `kCVPixelFormatType_32BGRA`, IOSurface-backed and Metal compatible, wrapped as a
  `.bgra8Unorm` texture through `MetalCore.texture`. Render with `encodeLayers(outTransfer: 2)`: the shader's
  existing tone mapping turns HDR game frames into SDR BT.709. Tag the buffer BT.709.
- **Frame selection.** `index = floor((hostNs − startNs) × fps)`. Render when `index` is greater than the last
  rendered index; otherwise skip. A 120 fps game therefore feeds a 60 fps stream every second frame, and a 30 fps
  game produces 30 distinct frames (the encoder is told the real timestamps; do not duplicate frames).
- **Shared-memory lifetime.** Game textures point into the helper's ring and are overwritten about two frames later.
  Encode and commit the program pass inside `gameFrame`, on the reader thread, exactly as `drawNow` does for the
  window. Deliver the pixel buffer from the command buffer's completion handler.
- **No game signal.** If no game frame arrived for 150 ms, a 30 Hz timer renders the composition without the game
  source (it resolves to nothing, the background shows) so "be right back" scenes and the stream itself stay alive
  when the console is off or the card is unplugged.
- **Hook.** Add `var programOutputs: [ProgramOutput]` to `Renderer` (guarded by its lock) and call each from
  `submit(slot:w:h:arrivalNs:)` before the presentation branch. With an empty list the live path is unchanged.

### VideoEncoder

```swift
final class VideoEncoder {
    struct Settings { var width, height: Int; var fps: Double; var bitrate: Int }      // bits per second
    init?(settings: Settings)
    var onConfig: ((_ sps: Data, _ pps: Data) -> Void)?
    var onFrame: ((_ avcc: Data, _ ptsNs: UInt64, _ keyframe: Bool) -> Void)?
    func encode(_ pb: CVPixelBuffer, hostNs: UInt64)
    func requestKeyframe()
    func finish()
}
```

`VTCompressionSession`, H.264, hardware required. Properties: `RealTime` true, `ProfileLevel` High auto level,
`H264EntropyMode` CABAC, `AllowFrameReordering` false (no B-frames, so decode time equals presentation time),
`MaxKeyFrameIntervalDuration` 2 seconds and `MaxKeyFrameInterval` `2 × fps`, `AverageBitRate`, `DataRateLimits`
`[bitrate / 8 × 1.15, 1]`, `ExpectedFrameRate`, colour properties BT.709. Presentation time = `hostNs` as a
nanosecond `CMTime`. In the output callback: on keyframes read SPS and PPS with
`CMVideoFormatDescriptionGetH264ParameterSetAtIndex` and call `onConfig` when they change; copy the block buffer
(already 4-byte length-prefixed) for `onFrame`; the keyframe flag is the absence of
`kCMSampleAttachmentKey_NotSync`.

### StreamSession: the conductor

```swift
final class StreamSession {
    struct Output { var canvas: Canvas; var size: CGSize; var fps: Double; var videoBitrate: Int
                    var publishers: [RTMPPublisher] }
    init(outputs: [Output], audioBitrate: Int, renderer: Renderer, mixer: AudioMixer)
    func start(); func stop()
    var onStats: ((Stats) -> Void)?       // per second: encoder fps, render ms, encode ms, per publisher stats
}
```

- One `ProgramOutput` and one `VideoEncoder` per output; every encoded frame goes to every publisher of that output.
- One `AudioMixer` (inputs `"game"` and `"mic"`, fed through the plan 12 hooks) and one `AACEncoder`; every audio
  frame goes to **all** publishers of all outputs.
- `publisher.onNeedKeyframe` calls `encoder.requestKeyframe()`.
- All timestamps handed to publishers are host nanoseconds. Video: the game frame's arrival time. Audio: the mixer
  block's start time. Because the capture card delays video relative to a microphone, expose
  `mixer.input("mic").delayMs` (default 0) for plan 21's sync setting.

### App wiring (temporary UI)

- New **Stream** menu: "Go Live" / "End Stream" (⇧⌘L).
- Destination from user defaults for now: `-streamURL rtmp://…`, `-streamCanvas wide|vertical`, `-streamBitrate
  6000`, and the key from the environment variable `EHDR_STREAM_KEY` (so it never lands in defaults or shell
  history files that list arguments). Plan 21 replaces all of this.
- The composition provider: `Composition.from(layout: CanvasLayout(kind: .pip, camera: livePlacement), …)` for wide
  and `CanvasLayout.verticalDefault` for vertical. Plan 22 swaps in real scenes.
- Publish state and statistics into `StudioState.streaming` if plan 13 has merged; otherwise log them.

## Steps

1. `VideoEncoder` with a test: encode 120 generated frames, assert config arrives before the first frame, keyframes
   every 2 seconds, `requestKeyframe()` yields one within two frames, measured bitrate within 25% of the target.
2. `ProgramOutput` with a test using synthetic textures: 180 game frames at 120 fps produce 90 output frames at
   60 fps with increasing timestamps; the no-signal timer produces frames when game frames stop.
3. `StreamSession` and the hooks; app wiring.
4. End-to-end script `scripts/stream-selftest.sh` (commit it): starts
   `ffmpeg -listen 1 -i rtmp://127.0.0.1:1935/live/test -t 20 -c copy /tmp/selftest.flv`, launches the app with
   `--demo-source --demo-camera`, the stream arguments and `--go-live-for 25` (add this debug flag: go live after 3
   seconds, end after N), then prints an `ffprobe` summary.
5. A/V sync check in the same script: the demo source flashes and beeps once a second. Extract the first flash frame
   time (`ffmpeg … -vf "crop=iw:ih/20:0:ih*19/20,signalstats" -f null -` and read `YAVG` jumps) and the first beep
   onset (`-af silencedetect`), print the difference.
6. Performance pass with the demo source at 4K30 and 1440p60 while also recording: log render and encode
   milliseconds per frame, CPU from `top -l 1 -pid`, and the live latency line.

## Acceptance

1. `swift test` passes.
2. `scripts/stream-selftest.sh` for wide and for vertical: `ffprobe` shows `h264` at the requested size and about
   60 fps, `aac` 48 kHz stereo, duration within one second of 20. Paste the output.
3. Flash-to-beep difference within ±45 ms.
4. With two outputs (wide and vertical to two local listeners on ports 1935 and 1936) both files are valid.
5. While streaming and recording at 1440p60: no growth in recorder "dropped" counts, live latency within 1.5 ms of
   the baseline in Game mode, and no `pendingMs` growth on loopback. Paste the log lines.
6. Killing the `ffmpeg` listener mid-stream puts the publisher into `reconnecting` without affecting the live view
   or the recording; restarting the listener resumes the stream.

## Pitfalls

- `VTCompressionSessionEncodeFrame` must not be called on the reader thread: hand the pixel buffer to an encoder
  queue. If that queue is more than two frames behind, drop the new frame and count it.
- BGRA input makes VideoToolbox convert to 4:2:0 internally. That is acceptable at 1080p. If the performance pass
  shows more than 2 ms per frame of encode overhead, render NV12 with two extra passes modelled on `lumaFrag` and
  `chromaFrag` (8-bit, BT.709 coefficients, video range) and say so in the pull request.
- A hardware encoder session can fail to start when too many are open. Surface the error; do not fall back to
  software silently.
- The stream key comes from the environment in this plan. Do not echo the environment or the full URL to the log.
- Do not start the mixer's driver thread until a stream starts; stop it when the stream ends.

## Out of scope

Destinations UI, Keychain, per-destination bitrate, HDR streaming, recording the program output to disk, scene
switching, stream delay.
