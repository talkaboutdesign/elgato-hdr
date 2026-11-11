# 41. SDR brightness

## Goal

Streamed and SDR-exported HDR games looked dark. The HDR -> SDR conversion mapped exactly 203 nits (BT.2408) to SDR
white, but many games keep midtones and UI well below that (a Call of Duty frame: 99th percentile 150 nits, median
0.9 nits, SDR mean 0.16). Add one global "SDR brightness" setting with a brighter default.

## Design

- `sdrWhiteNits`: the HDR source luminance that becomes SDR white. Default 150 (was 203), range 80...300, stored in
  `UserDefaults` under `sdrWhiteNits`, clamped when read (`App/SdrBrightness.swift`).
- Shader (`Render/MetalCore.swift`): `linearToSdr(l, sdrWhite)` scales linear light by `203 / sdrWhite` and puts the
  roll-off peak at `W = 1000 / sdrWhite` SDR-white units, so 1000 source nits still lands on white and highlights
  compress instead of clipping. At 203 it is the former curve exactly. Only HDR (PQ/HLG) sources drawn into SDR
  output are affected: SDR sources never reach `linearToSdr` (`convert` returns early when transfers match) and HDR
  output does not use it. The value travels in `LayerU.canvas.z` / `LayerParams.canvas.z`.
- `encodeLayers(..., sdrWhiteNits:)` defaults to `SdrBrightness.current`, a plain `Float` written on the main thread
  and read lock-free by the render threads (an aligned 32-bit load cannot tear on arm64). The live window, program
  output (stream), scene thumbnails and the editor/export compositor all read it per frame, so a change shows on the
  next frame, also while live. `layerFrag` is the only HDR -> SDR conversion in the app.
- Live window: in HDR the game passes through as PQ/HLG and is unchanged; in SDR mode it uses the same setting.
- UI: "SDR brightness" `LabeledSlider` in the Stream tab's Output section and in the export sheet when an HDR
  recording is exported to an SDR preset. It shows a percentage (`150 / nits * 100`, 50%...188%, 100% = default);
  double-click resets to 100%.

## Acceptance results

- `swift build`, `swift test`: pass (see PR).
- Real 2560x1440 PQ frames through `encodeLayers` to 8-bit SDR (`EHDR_P010_DIR=... swift test --filter
  SdrBrightnessTests/testRealFramesReport`), BT.709 luma of gamma-encoded output:

  | frame | white | mean | p99 | pixels with a channel at 255 |
  |---|---|---|---|---|
  | g20 | 203 | 0.1624 | 0.8510 | 0% |
  | g20 | 150 | 0.1824 | 0.8980 | 0% |
  | slot0 | 203 | 0.2291 | 0.9529 | 0.00003% |
  | slot0 | 150 | 0.2542 | 0.9686 | 0.00003% |

  g20's mean rises by 12%, slightly less than the 0.19-0.20 estimated in the work order: below the knee the encoded
  value scales by (203/150)^(1/2.4) = 1.134, which bounds the gain for a frame that is mostly midtones.
- Live latency in Game mode could not be measured: the screen was locked, so "helper->screen" reads 0.0 ms before
  and after; draw time is unchanged (0.3 ms/frame).
