# Plan 12: Audio mixer and AAC encoder

**Goal.** Mix game audio and microphone into one stereo 48 kHz program signal on the host clock, with per-source
gain, mute, delay and meters, and encode it to AAC for streaming. Library and tests only; plan 20 wires it to the
stream.

**Depends on:** 00. **Files you own:** new `Sources/StudioKit/Audio/Mixer/`, `Tests/StudioKitTests/Audio/`. Allowed
hooks elsewhere: one optional closure on `Session` and one on `CameraCapture` (step 5).

## Why this is not trivial

The capture card's audio clock, the microphone's clock and the Mac's host clock all run at slightly different
rates. Over an hour a 100 ppm difference is 360 ms. The recorder already handles this for one source by slewing
(`Recorder.appendAudio`). A mixer must do it per source, continuously, without clicks.

## Design

```swift
final class AudioMixer {
    init(sampleRate: Double = 48000, blockFrames: Int = 1024, targetLatencyMs: Double = 60)
    func addInput(_ id: String) -> MixerInput             // "game", "mic", later "system"
    /// Produces every block that ends at or before `hostNs − targetLatency`. Deterministic: tests call it directly.
    func render(upTo hostNs: UInt64)
    var onBlock: ((_ interleavedStereo: UnsafePointer<Float>, _ frames: Int, _ startHostNs: UInt64) -> Void)?
    var masterGain: Float
    var masterMeter: Meter { get }
    func start()                                           // real-time driver: a timer thread calling render(upTo: now)
    func stop()
}

final class MixerInput {
    var gain: Float                // linear, 0…4
    var muted: Bool
    var delayMs: Double            // 0…1000, extra delay to line a source up with the delayed game picture
    var meter: Meter { get }       // peak and RMS over the last block, readable from any thread
    /// Interleaved float stereo at 48 kHz; `endHostNs` is when the last sample was captured.
    func push(_ samples: UnsafePointer<Float>, frames: Int, endHostNs: UInt64)
    func pushInt16Stereo(_ bytes: UnsafeRawPointer, byteCount: Int, endHostNs: UInt64)
    func pushFloatMono(_ samples: UnsafePointer<Float>, frames: Int, endHostNs: UInt64)
    var underruns: Int { get }
    var driftPPM: Double { get }
}
struct Meter { var peak: Float; var rms: Float }
```

**Timeline model.** The mixer's output block `n` covers host time `t0 + n × 1024 / 48000`. Each input keeps a ring
buffer (2 seconds) and remembers, for its newest sample, the host time it was captured. For an output block starting
at host time `T`, an input should supply the samples captured at `T − delay`.

**Drift control.** Each input has a resampling ratio `r` close to 1. Per block, compute the position error between
where the read pointer is and where the timestamps say it should be, low-pass it (time constant about 2 seconds),
and steer `r` proportionally, clamped to ±0.5%. Resample with linear interpolation between neighbouring frames (good
enough at these ratios; note it in a comment). Hard corrections only as a safety net: if the error exceeds 150 ms,
jump the read pointer and count it.

**Underrun.** If an input has no data for the needed range (source stopped, device unplugged), output silence for
that input and count an underrun. When data returns, re-anchor from its timestamps.

**Master.** Sum, apply master gain, then a soft clip above −1 dBFS (`x / (1 + |x|)` style knee) so two loud
sources cannot produce digital clipping.

**Threading.** `push` is called from the reader thread and from the camera audio queue; `render` from the mixer
thread. Use one `os_unfair_lock` per input held only for the ring copy. No allocation inside `push` or `render`.

**Driver.** `start()` runs a thread with a `DispatchSourceTimer` every 10 ms (leeway 1 ms) that calls
`render(upTo: nowNs())`. Blocks are therefore produced about `targetLatency` behind real time, in bursts of zero to
two per tick; their `startHostNs` is exact regardless of timer jitter.

### AAC encoder (`AACEncoder.swift`)

```swift
final class AACEncoder {
    init?(bitrate: Int = 160_000)                         // 48 kHz stereo AAC-LC
    let audioSpecificConfig: Data                         // 0x11 0x90
    /// Feed exactly 1024 frames; returns zero or one encoded frame with the host time of its first sample.
    func encode(_ interleavedStereo: UnsafePointer<Float>, startHostNs: UInt64) -> (data: Data, ptsNs: UInt64)?
}
```

Use `AVAudioConverter` from interleaved float PCM to `kAudioFormatMPEG4AAC`. The encoder delays output by its
priming frames (2,112 samples): track input and output frame counts so each returned packet carries the timestamp of
the input block it actually contains.

## Steps

1. Ring buffer and `MixerInput` with unit tests for conversion helpers (int16 stereo, float mono to stereo).
2. `AudioMixer.render` with the timeline model, no drift control yet. Test: one input, sine pushed with perfect
   timestamps for ten virtual seconds; output equals the input delayed by the target latency (compare after
   alignment, error below −60 dB).
3. Drift control. Tests with a simulated source clock: +300 ppm, −300 ppm, and jittery chunk arrival (±8 ms). For
   each, 120 virtual seconds: no hard jumps, no underruns after the first second, the sine's phase is continuous
   (largest sample-to-sample step stays below the bound for that frequency and amplitude), and `driftPPM` converges
   to within 50 ppm of the simulated value.
4. Gain, mute, delay, meters, master soft clip, underrun and re-anchor tests. Two-input mix test.
5. Hooks: `var onGameAudio: ((UnsafeRawPointer, Int, UInt64) -> Void)?` on `Session`, called in the `0x41` branch of
   `run()` with the chunk bytes and its end time; `var onMicAudio: ((CMSampleBuffer, UInt64) -> Void)?` on
   `CameraCapture`, called in `captureOutput` for audio (and from the demo camera). Both default to nil and change
   nothing when unset.
6. `AACEncoder` with a test that encodes five seconds of a tone, decodes it back with `AVAudioConverter`, and checks
   the frame count and that the tone's frequency peak is where expected.
7. Real-time smoke test (not in CI): run the driver for five seconds with a synthetic pusher thread; assert the
   number of blocks is within one of the expected count.

## Acceptance

1. `swift test` passes; paste the drift test summary lines (measured ppm, underruns, jumps).
2. `render` for one block with two inputs takes under 0.2 ms in a release build (measure in a test, print it).
3. Existing live audio playback and recording are untouched: run the demo for 30 seconds and confirm the
   `audio: … dropped, backlog …` log lines look as they did before.

## Pitfalls

- The game audio timestamp is the time the chunk **ended**; the mic's sample buffer timestamp is when it
  **started**. Convert at the hook, not inside the mixer.
- Do not use `AVAudioEngine` for mixing: it runs on the output device's clock and would tie the stream to the
  speakers.
- Float denormals: keep meters and filters from decaying forever (clamp tiny values to zero).

## Out of scope

Noise suppression, compressor or EQ, system or Discord audio capture, monitoring the mix on headphones, per-source
audio tracks in the stream.
