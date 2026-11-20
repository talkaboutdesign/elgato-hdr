# 44. Recording audio/video sync

## Goal

Recordings lose sync between the game picture and the game sound, and it gets worse the longer the recording runs.
Fix the recorder so new recordings stay in sync for hours, find out whether the mic layer has a problem of its own,
and make the recordings the user already has play and export in sync, without rewriting their files.

Read `AGENTS.md` first.

## What is known (verified on the user's recordings, 20 November 2026)

`Recorder.appendAudio` (`Sources/StudioKit/Record/Recorder.swift`) places game audio at
`pts = audioAnchor + audioSamplesWritten / 48000` and compares that with when the chunk really arrived
(`expected = endT - n / 48000`). When they differ by more than 2 ms it "slews": drops or repeats up to 1% of the
chunk's samples. **The direction is inverted.** `err = expected - pts > 0` means fewer samples have been written
than time has passed (audio is behind), and the code then *drops* samples, which leaves it further behind;
`err < 0` repeats samples and puts it further ahead. It is positive feedback: after the first error over 2 ms it
corrects the wrong way at the 1% limit for the rest of the recording.

Evidence from `~/Library/Logs/Elgato HDR.log` ("saved game.mov (… audio slew N samples …)") and `ffprobe`:

| Recording | Video frames | Slew (samples) | Result |
|---|---|---|---|
| (earlier) | 22,418 | -180,431 | audio stretched, lags the picture |
| (earlier) | 37,039 | -376,563 | audio stretched, lags the picture |
| Capture 2026-11-20 10.57.00 | 73,877 | +993,370 | audio squeezed, leads the picture |
| Capture 2026-11-20 12.23.34 | 88,097 | +1,273,427 | video 2940.200 s, game audio 2913.749 s |

In the last one, written plus dropped samples come to 48,001 per second of recording: the capture card's audio
clock is fine and the recorder discarded 26.5 s of good audio. Video timestamps (an exact frame grid) and the
camera layer (2940.19 s) are correct. The mic layer is 2938.09 s, 2.1 s shorter than the video; nobody has looked
at why. The bug has been there since commit b439e1b (September, "audio slewing").

Both recordings above are still in `~/Movies/Elgato HDR/`. **They are the user's real recordings: read them, never
modify, move or delete them or their `project.json`.** Copy what you need into a scratch folder.

## Part 1: fix the recorder

- Make the correction converge: behind (fewer samples than elapsed time) inserts, ahead removes. Write it so the
  direction is obvious from the names, not from a sign convention in a comment.
- Decide what the correction should actually track, and say why in a comment. Arrival times of USB audio chunks
  jitter by several milliseconds and occasionally stall; a control loop that reacts to each chunk's raw error will
  wobble audibly. The loop must follow the long-term rate difference between the audio sample clock and the host
  clock (tens of parts per million for a healthy device) and ignore per-chunk jitter: for example a smoothed error
  with a dead band and a small maximum correction. A correction of 1% is audible as a pitch step; keep steady-state
  corrections far smaller, and reserve larger ones for recovering from a real gap (chunks lost while
  `isReadyForMoreMediaData` was false, or dropped by USB). A long gap is better filled with silence in one step than
  slewed over minutes: pick thresholds and justify them.
- Pull the decision into a small pure type (input: chunk length and arrival time; output: samples to insert or
  remove) so it can be tested without an `AVAssetWriter`. `Streaming/` and `Audio/Mixer/` already contain drift
  control for the stream (`grep -rn -i drift Sources`): read it, reuse it if it fits, and say in the pull request
  whether the stream path has or does not have the same mistake.
- Keep the log line, and add what is needed to see a problem next time: at the end of a recording, log video
  duration, audio duration and their difference, and warn in the log when they differ by more than 50 ms.

## Part 2: the mic layer

`Record/LayerWriter.swift` writes `mic.mov` and `camera.mov`. Find out why the mic track ended 2.1 s short of the
video in the 49-minute recording (start offset, lost buffers, drift between the microphone's clock and the host
clock, or tail lost at stop) and whether mic audio drifts against the picture during a recording. Fix what is
wrong with the same rules as part 1. If the mic is only short at the tail, say so and fix only that.

## Part 3: existing recordings

Recordings made before this fix have game audio that is uniformly too short or too long. Make the editor, preview
and exports play them in sync **without touching the media files**:

- Detect it when a project is opened: the game audio track's duration differs from the game video track's by more
  than 0.1%.
- Store a correction in `project.json` as a new optional field (lenient decoding, absent means none; see the
  `project.json` rule in `AGENTS.md`) and apply it where the composition is built (`Edit/CompositionBuilder.swift`):
  stretch the game audio to the video's length, keeping pitch (choose the `AVAudioTimePitchAlgorithm` deliberately).
- The runaway did not necessarily start at 0:00, so a uniform stretch is an approximation. Measure the residual
  error on the two real recordings at several points (the game audio also leaks into `mic.mov` through the room when
  the user plays on speakers, and `camera.mov` shows the user reacting: cross-correlating game audio against mic
  audio in short windows across the recording is one way; propose another if that signal is too weak) and report
  the numbers. If a piecewise correction is clearly better and cheap, do that; if no reliable measurement is
  possible, ship the uniform stretch and say that the residual is unknown.
- Show a one-line note in the editor when a correction is applied, so the user knows why.

## Tests

1. The pure drift type: a clock 100 ppm fast and 100 ppm slow over a simulated hour converges and stays within
   10 ms of the host clock; arrival jitter of ±8 ms with no rate error produces no correction at all; a 500 ms gap is
   recovered within the bound you chose; corrections never run away (the regression test for this bug: feed the
   exact failure, a single 3 ms error, and assert the error shrinks).
2. A real `Recorder` driven with synthetic frames and jittered audio for a simulated long recording (drive it with
   timestamps, not real time): audio and video track durations agree within 20 ms, and a click placed at a known
   time lands within 10 ms of where it was put.
3. Mic layer: the same duration check through `LayerWriter`.
4. Project decoding: old files without the field, files with it, garbage values; and a fixture whose game audio is
   1% short composes to an audio track as long as the video.
5. Every existing test passes.

## Acceptance checks (paste real output in the pull request)

1. `swift build`, `swift test`; CI green (Xcode 16.4 / Swift 6.1).
2. A demo recording of at least 10 minutes with the bundled app (`--demo-source --demo-camera`; the demo source's
   audio is synthetic, so also check a click or tone edge against the picture at the start, middle and end with
   `ffprobe`/`ffmpeg`): track durations and the measured offset at each point. State the limits: the demo source
   does not have a USB device's jitter or clock, so the real proof needs the user's capture card.
3. Copies of the two real recordings opened through the new code: the correction detected, the composed audio
   length, and the residual measurements from part 3. Exports of a short range near the start and near the end.
4. What was found for the mic layer.

## Environment notes

- The user's own copy of the app is usually running from another checkout with a live capture card. Never `pkill`
  by name; kill only PIDs you started. Do not touch `/tmp/elgato-uvc.sock` or the capture helper.
- Runs write the real defaults domain `dev.max.elgato-hdr`: copy it before your first run, afterwards restore only
  keys your runs changed (leave `muted` as found). Pass `-recordingsDir <scratch>`; never record into
  `~/Movies/Elgato HDR`.
- The real recordings are 13 GB and 10 GB; check free disk space before copying and work on trimmed copies where
  you can (`ffmpeg -c copy` of a range is fine for analysis).
- Branch `plan/44-recording-av-sync` (this plan is committed there), one pull request against `main`, do not merge.
  Finish with a plan 44 row in `plans/README.md` and "## Acceptance results" appended to this file.

## When to stop and ask

A fix would need to change the capture helper (`tools/uvc_capture.c`) or the shared-memory protocol; part 3 cannot
be done without rewriting media files; or the evidence contradicts the diagnosis above.
