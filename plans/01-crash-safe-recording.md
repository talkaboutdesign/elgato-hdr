# Plan 01: Crash-safe recording

**Goal.** A crash, a force quit or a power cut loses at most the last few seconds of a recording instead of all of it.

**Depends on:** 00. **Files:** `Record/Recorder.swift`, `Record/LayerWriter.swift`, `Model/ProjectDoc.swift`,
`Model/Library.swift`, `App/AppDelegate+Recording.swift`, new tests.

## Why

`AVAssetWriter` writes the sample index (the `moov` atom) when `finishWriting` runs. `Recorder` and `LayerWriter`
never set `movieFragmentInterval`, so a file whose writer did not finish has no index and cannot be opened.
`Library.reload()` already detects projects left in state `"recording"` and calls `finalize`, but there is nothing
readable to finalize.

## Steps

1. **Fragmented writing.** In `Recorder.init` and both `LayerWriter` initializers, before `startWriting()`:
   `writer.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)`. This applies to QuickTime movie
   files.
2. **Mic container.** The mic layer is an `.m4a`, which does not take movie fragments. Record new mic layers as an
   audio-only QuickTime movie named `mic.mov` (`AVAssetWriter(outputURL:fileType: .mov)`, same AAC settings). The file
   name is stored in `project.json` (`LayerInfo.file`), so old projects with `mic.m4a` keep opening. Update the one
   place that writes the name (`startRecording`) and the README's folder listing.
3. **Recovery.** In `ProjectDoc.finalize`, after loading the game asset: if a layer file listed in the project is
   missing or has zero duration, set that layer to `nil` instead of leaving a dangling reference. If the game file
   itself cannot be read, set `state = "damaged"` and keep the folder; show a "DAMAGED" badge in `ProjectCard` instead
   of looping on recovery at every reload. Make `Library.reload()` attempt recovery once per project per launch.
4. **Disk guard.** While recording, check free space on the recordings volume every 5 seconds
   (`URLResourceKey.volumeAvailableCapacityForImportantUsageKey`). Below 2 GB: stop the recording cleanly through the
   normal `finishRecording` path and show an alert that names the reason. Refuse to start a recording below 5 GB.
5. **Tests.**
   - Unit: write three seconds with `Recorder` into a temp file, then **do not** call `finish`; release the writer
     and open the file with `AVURLAsset`. Assert a duration of at least two seconds. Same for both `LayerWriter`
     kinds.
   - Unit: `finalize` on a project whose camera file is missing clears `camera`; on a project with a garbage
     `game.mov` sets `"damaged"`.

## Acceptance

1. `swift test` passes.
2. Kill test, pasted into the pull request:
   ```sh
   "dist/Elgato HDR.app/Contents/MacOS/ElgatoHDR" --demo-source --demo-camera --record 60 &
   sleep 15; kill -9 $!
   ffprobe -v error -show_entries format=duration "$HOME/Movies/Elgato HDR/<newest>/game.mov"
   ```
   Duration is at least 8 seconds for `game.mov`, `camera.mov` and `mic.mov`.
3. Relaunch with `--demo-source --library`: the recording appears, loses its "RECOVERING" badge within a few seconds,
   opens in the editor and plays.
4. A normal recording (stop with ⌘R) still plays in QuickTime Player and its export passes the plan 00 export test.

## Pitfalls

- Set the interval before `startWriting()`; later it is ignored.
- A fragmented movie that was finished normally is a regular movie; nothing else changes for the editor.
- Do not shorten the interval below one second: every fragment costs a small index write on the recorder queue.

## Out of scope

Pausing and resuming a recording, splitting long recordings into several files, recovering the last partial fragment.
