# Elgato HDR

Tiny native macOS viewer/recorder for the Elgato 4K X's hidden 10-bit P010 (HDR) mode, which macOS's own UVC driver never exposes.

- `app/main.swift` — AppKit app: EDR display via AVSampleBufferDisplayLayer, audio playback, HEVC Main10 HDR10 recording (Cmd-R).
- `tools/uvc_capture.c` — root helper: libusb UVC bypass (probe/commit format 7 = P010, bulk EP 0x82), UAC1 audio, socket server.
- `tools/*.c`, `tools/*.py` — descriptor dumps and the mode sweep test client.
- `build.sh` — builds `dist/Elgato HDR.app` (bundles helper + libusb). Requires Xcode CLT and `brew install libusb`.

The app launches the helper once with a native admin prompt; it stays alive across mode switches and exits ~20 s after the app quits.
