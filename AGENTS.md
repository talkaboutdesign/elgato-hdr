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

**Older compiler on CI.** GitHub builds with Xcode 16.4 (Swift 6.1), which is stricter and slower at type inference
than the Swift on the development machine. Code that compiles locally has failed there three ways so far: a missing
framework import that a newer SDK pulled in transitively (import every framework whose symbols a file uses, for
example `VideoToolbox` for `kVT…`), long arithmetic inside closures ("unable to type-check this expression in
reasonable time": give closure parameters explicit types and split arithmetic into typed `let`s), and array literals
mixing `Float` context with `Double` arithmetic (wrap in `Float(...)`). Check the CI result of your pull request and
fix it before reporting done.

**Proving your work**

- Every plan ends with acceptance checks. Run them and paste the real output in the pull request. If a check fails
  or you could not run it, say so plainly.
- If your change touches the live render path, report the "helper->screen" latency line from the log in demo mode
  before and after, in Game mode. A regression of more than 1 ms average needs an explanation.
- One pull request per plan, branch `plan/<number>-<slug>`, based on `main`. Do not merge it yourself.

**When to stop and ask.** A step in your plan contradicts the code as you find it; an acceptance check cannot pass
for a reason outside your files; or you would have to change a decision listed in section 3.

