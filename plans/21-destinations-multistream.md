# Plan 21: Destinations, multistream and stream health UI

**Goal.** The user adds Twitch, YouTube, Kick or a custom server once, ticks the ones to use, and presses Go Live.
Each destination can be widescreen or vertical. The app shows per-destination health and survives one of them
failing.

**Depends on:** 13, 20. **Files you own:** new `Sources/StudioKit/Streaming/Destinations/`, new `UI/Studio/Stream/`,
`App/AppDelegate+Streaming.swift` (replace the temporary wiring from plan 20), the Stream tab of the sidebar, tests.

## Design

### Model and storage

```swift
struct Destination: Codable, Identifiable, Equatable {
    var id = UUID()
    var service: Service            // .twitch, .youtube, .kick, .custom
    var name: String                // "Twitch", "YouTube Shorts", user-editable
    var url: String                 // rtmp(s)://host[:port]/app
    var canvas: Canvas              // .wide or .vertical
    var enabled = true
}
struct StreamSettings: Codable {    // one set for all destinations in this version
    var resolution: Int = 1080      // 1080 or 720 (short side)
    var fps: Int = 60               // 60 or 30
    var videoKbps: Int = 6000
    var audioKbps: Int = 160
    var micDelayMs: Double = 0
}
```

- Destinations and settings: `~/Library/Application Support/Elgato HDR/streaming.json`, lenient decoding.
- Stream keys: Keychain generic passwords, service `dev.max.elgato-hdr.stream-key`, account = destination id.
  `KeychainStore` with `set`, `get`, `delete`; deleting a destination deletes its key. The key is read only at the
  moment a stream starts.

### Service presets

| Service | Default URL | Notes shown in the UI |
|---|---|---|
| Twitch | `rtmps://ingest.global-contribute.live-video.net:443/app` | Key: dashboard → Settings → Stream. Bitrate above 6,000 kbps may be rejected. |
| YouTube | `rtmps://a.rtmps.youtube.com:443/live2` | Key: YouTube Studio → Go Live → Stream. A vertical 9:16 stream is published as a vertical live. |
| Kick | empty; the user pastes it | Kick gives every creator a personal RTMPS URL and key: dashboard → Settings → Stream URL & Key. |
| Custom | empty | Any RTMP or RTMPS server. |

**Verify each default URL and the dashboard paths against the platform's own help pages while implementing** (they
change; the search done during planning found conflicting third-party values for Twitch and Kick). The URL field is
always editable, and each preset has a "Where do I find this?" link that opens the platform's stream settings page.

### Grouping

`StreamPlanner.plan(destinations:settings:) -> [StreamSession.Output]`: pure function. Enabled destinations are
grouped by canvas; each group becomes one output (one render, one encode) with one publisher per destination.
Output size: wide `1920×1080` or `1280×720`; vertical `1080×1920` or `720×1280`. Total upload =
`(videoKbps + audioKbps) × number of destinations`; expose it for the UI.

### Session control

- Go Live starts every enabled destination. While live, a destination can be stopped or started on its own:
  `StreamSession.addPublisher(_:to:)` and `removePublisher(_:)` (add them; a publisher that joins late already
  waits for config and a keyframe by design of plan 11).
- If the last publisher of an output is removed, that output's render and encode stop; if every destination has
  stopped or failed permanently, the session ends and the UI says why.
- One destination's failure never stops the others.

### UI

- **Stream tab (sidebar).** A list of destination cards: service icon (SF Symbols or simple monogram tiles; no
  third-party logos bundled), name, canvas badge (`16:9` / `9:16`), enable switch. "Add destination" opens a sheet:
  pick a service, then URL (prefilled), stream key (secure field with a reveal button and paste support), canvas,
  name. A "Test connection" button runs connect-through-publish against the server and then disconnects, reporting
  "Connected" or the failing stage and server message.
- **Settings card** under the list: resolution, frame rate, bitrate slider (2,500…9,000 kbps) with the total upload
  shown ("3 destinations · about 18.5 Mbps upload"), mic delay.
- **Go Live button (toolbar).** Idle: "Go Live" with a count badge of enabled destinations; click opens a popover
  that lists them with switches and a prominent confirm button, so going live is always two deliberate clicks.
  Live: the button turns into "LIVE 12:34" in `DS.Color.live`; click opens the health popover with "End Stream".
- **Health popover and Stream tab while live.** Per destination: state dot (connecting amber, live green,
  reconnecting amber pulsing, failed red), current kbps, dropped frames, uptime, a retry button when failed. Session
  line: encoder fps, render and encode ms. A destination that keeps dropping frames shows the hint "Upload too slow
  for this bitrate".
- Quitting or closing the window while live asks for confirmation.
- Errors are toasts with the destination name: "Twitch: stream key rejected".

## Steps

1. `Destination`, `StreamSettings`, storage, `KeychainStore`, `StreamPlanner`, with tests (Keychain tests use a
   separate service name and clean up).
2. `addPublisher` / `removePublisher` on `StreamSession` with a test against two `FakeRTMPServer`s (from plan 11's
   test target; move it to a shared test support folder if needed).
3. Stream tab, add/edit sheet, test connection.
4. Go Live button states, popovers, health display fed from `StreamSession.onStats` through `StudioState.streaming`.
5. Remove the temporary launch arguments from plan 20 except the debug `--go-live-for` flag, which now uses the
   stored destinations; keep `EHDR_STREAM_KEY` only in the self-test script path.

## Acceptance

1. `swift test` passes.
2. Three local listeners (ports 1935, 1936 wide; 1937 vertical), three destinations: all three files valid, the two
   wide ones have identical video frame counts (one encoder), the vertical one is 1080×1920. Paste `ffprobe` output.
3. Kill one listener mid-stream: its card shows reconnecting, the other two keep their bitrate, and it recovers
   when the listener restarts. Screenshots of each state.
4. A wrong key against `FakeRTMPServer` configured to reject: the card shows "stream key rejected" and does not
   retry.
5. `strings` on `streaming.json`, on the user defaults plist and on the log after a session shows no stream key.
6. Screenshots: empty Stream tab, add sheet for each service, Go Live popover, live health popover.

Needs the user (cannot be done by an agent): one real stream per platform with real keys. List the exact steps in
the pull request.

## Pitfalls

- Keychain items created by an ad-hoc-signed build are tied to that build's signature; after a rebuild macOS may
  prompt the user to allow access. Use `kSecAttrAccessibleAfterFirstUnlock`, handle `errSecAuthFailed` and
  `errSecInteractionNotAllowed` by asking the user to re-enter the key, and mention the limitation in the README
  until the app is properly signed (plan 90).
- Never put the key into a SwiftUI `@Published` property that lives beyond the edit sheet.
- A pasted URL may already contain the key as its last path component (people copy "URL + key" joined). If the
  path has more than one component for a known service, offer to split it.

## Out of scope

Platform sign-in, setting titles or categories, chat, per-destination bitrate or resolution, SRT, stream delay,
HDR.
