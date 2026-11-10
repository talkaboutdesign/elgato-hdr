# Plan 11: RTMP / RTMPS publisher

**Goal.** A dependency-free library that publishes already-encoded H.264 and AAC to any RTMP or RTMPS ingest
(Twitch, YouTube, Kick, custom), with reconnect, back-pressure handling and statistics. No UI, no encoder, no app
wiring: plan 20 connects it.

**Depends on:** 00. **Files you own:** everything under new `Sources/StudioKit/Streaming/RTMP/` and
`Tests/StudioKitTests/RTMP/`. Touch nothing else.

## Public surface

```swift
struct StreamEndpoint: Equatable {
    var scheme: String      // "rtmp" | "rtmps"
    var host: String
    var port: Int           // default 1935 for rtmp, 443 for rtmps
    var app: String         // path after the host, without leading slash, query kept ("live2", "app", "live?x=1")
    var tcUrl: String       // "\(scheme)://\(host):\(port)/\(app)"
    init?(url: String)      // accepts with or without port and trailing slash; rejects other schemes
}

struct StreamMetadata { var width, height: Int; var fps: Double; var videoKbps, audioKbps: Int }

final class RTMPPublisher {
    enum State: Equatable { case idle, connecting, publishing, reconnecting(attempt: Int, inSeconds: Double), failed(String) }
    struct Stats { var bytesSent: Int64; var kbps: Double; var droppedFrames: Int; var pendingMs: Double; var reconnects: Int }

    init(endpoint: StreamEndpoint, streamKey: String, metadata: StreamMetadata)
    var onState: ((State) -> Void)?          // called on the publisher's queue
    var onNeedKeyframe: (() -> Void)?        // ask the encoder for an IDR (after connect and after dropping)
    func start()
    func stop()                              // sends FCUnpublish/deleteStream, then closes
    func setVideoConfig(sps: Data, pps: Data)                       // raw NAL units without start codes
    func setAudioConfig(audioSpecificConfig: Data)
    func sendVideo(_ avcc: Data, ptsNs: UInt64, dtsNs: UInt64, keyframe: Bool)   // 4-byte length-prefixed NALs
    func sendAudio(_ aac: Data, ptsNs: UInt64)                                   // one raw AAC frame, no ADTS
    var stats: Stats { get }                 // thread-safe snapshot
}
```

All timestamps are host-clock nanoseconds from the caller. The publisher subtracts the timestamp of the first frame
it actually sends on the current connection and converts to milliseconds.

## Protocol reference (everything needed; verify against the Adobe RTMP 1.0 specification when unsure)

**Handshake (plain version 3).** Send `C0 = 0x03` and `C1` = 1536 bytes (4 bytes time 0, 4 bytes zero, 1528 random).
Read `S0` (1), `S1` (1536), `S2` (1536). Send `C2` = `S1` echoed. Do not validate `S2`.

**Chunks.** Basic header 1 byte: `fmt << 6 | chunkStreamId` (ids 2…63). Message header for `fmt 0`: timestamp (3
bytes big-endian), length (3), type id (1), message stream id (4, **little-endian**). `fmt 3`: no header. When the
timestamp is ≥ 0xFFFFFF write 0xFFFFFF and append a 4-byte big-endian extended timestamp, and repeat that extended
timestamp after every `fmt 3` continuation header of the same message. Sending: first chunk of every message as
`fmt 0`, continuations as `fmt 3`. Receiving: implement all four formats (1 = delta, length, type; 2 = delta only).
Streams longer than 4 h 39 min cross 0xFFFFFF, so the extended path needs a test.

**Chunk size.** Default is 128 in both directions. Right after the handshake send Set Chunk Size (type 1) with 4096.
Honour the peer's Set Chunk Size when parsing.

**Control messages** (chunk stream 2, message stream 0): type 1 Set Chunk Size (4 bytes), type 3 Acknowledgement
(4 bytes: total bytes received), type 4 User Control (2-byte event + data; answer event 6 "ping request" with event 7
and the same 4-byte payload), type 5 Window Acknowledgement Size (4 bytes), type 6 Set Peer Bandwidth (5 bytes).
After receiving a window size `W`, send an Acknowledgement each time another `W` bytes have been received.

**AMF0.** Number `0x00` + 8-byte big-endian double; Boolean `0x01` + 1 byte; String `0x02` + 2-byte length + UTF-8;
Object `0x03` + (2-byte key length, key, value)* + `00 00 09`; Null `0x05`; ECMA array `0x08` + 4-byte count + object
body + `00 00 09`. Decode those plus Undefined `0x06` and Strict array `0x0A` (servers send them in replies).

**Commands** (type 20, chunk stream 3). Transaction ids increase from 1.

1. `["connect", 1, {app, type: "nonprivate", flashVer: "FMLE/3.0 (compatible; ElgatoHDR)", tcUrl}]`
   → wait for `_result` with transaction 1. `_error` or a status code containing `Rejected` is a failure.
2. `["releaseStream", 2, null, key]`, `["FCPublish", 3, null, key]`, `["createStream", 4, null]`
   → `_result` for transaction 4 carries the message stream id as its fourth value. Ignore replies to 2 and 3.
3. On that stream id (chunk stream 4): `["publish", 5, null, key, "live"]`
   → wait for `onStatus` whose info object has `code == "NetStream.Publish.Start"`. Any other `NetStream.Publish.*`
   or `NetConnection.Connect.*` error code is a failure; surface its `description`.
4. Data message (type 18) on the stream: `["@setDataFrame", "onMetaData", ecmaArray{width, height, framerate,
   videodatarate, videocodecid: 7, audiodatarate, audiosamplerate: 48000, audiosamplesize: 16, stereo: true,
   audiocodecid: 10, encoder: "ElgatoHDR"}]`.
5. Video (type 9, chunk stream 6) and audio (type 8, chunk stream 4) messages, timestamp = decode time in ms.
6. Stop: `["FCUnpublish", n, null, key]`, `["deleteStream", n, null, streamId]`, then close.

**FLV payloads.**

- H.264 config: `17 00 00 00 00` + AVCDecoderConfigurationRecord =
  `01, sps[1], sps[2], sps[3], FF, E1, spsLength(2 BE), sps, 01, ppsLength(2 BE), pps`.
- H.264 frame: `17` (keyframe) or `27` (other), `01`, composition offset `(pts − dts)` in ms as 3 bytes big-endian
  signed, then the AVCC data unchanged.
- AAC config: `AF 00` + AudioSpecificConfig (`11 90` for AAC-LC 48 kHz stereo).
- AAC frame: `AF 01` + raw frame.

## Behaviour

- **Transport:** `NWConnection` on a private serial queue; TLS parameters for `rtmps`, plain TCP for `rtmp`;
  `noDelay` on. Connection timeout 8 s for each stage (TCP/TLS, handshake, connect, publish).
- **Start-up gating:** nothing is sent before `Publish.Start`. Then: metadata, video config, audio config, and video
  only from the next keyframe on (call `onNeedKeyframe` immediately so that is soon). Audio older than the first
  video frame is discarded. Timestamps restart at zero on every connection.
- **Back-pressure:** count bytes handed to `NWConnection.send` and bytes confirmed by its completion handler.
  `pendingMs = pendingBytes × 8 / bitrate`. Above 1,500 ms: drop every video frame until the next keyframe, call
  `onNeedKeyframe` once, keep sending audio, count drops. Above 6,000 ms or on any send or receive error: reconnect.
- **Reconnect:** close, wait 1, 2, 4, 8, 15, 30, 30… seconds, try again, forever until `stop()`. An authentication
  failure (`Publish.BadName`, connect rejected) is `failed` and is **not** retried: the key is wrong.
- **Statistics:** `kbps` is a sliding average over the last 3 seconds of confirmed bytes.
- **Secrets:** the stream key must never appear in a log line or an error string. Log the host and app only.

## Steps

1. `AMF0.swift` (encode/decode an `enum AMFValue`), with byte-exact tests for each type and for a full `connect`
   command.
2. `RTMPChunker.swift`: `func chunks(for message: RTMPMessage, chunkSize: Int) -> Data` and a streaming
   `RTMPDechunker` that accepts arbitrary byte slices and emits messages. Tests: message shorter than, equal to and
   longer than the chunk size; extended timestamp; bytes fed one at a time; interleaved chunk streams; a peer chunk
   size change mid-stream.
3. `FLVTags.swift`: the four payload builders with golden-byte tests.
4. `StreamEndpoint` parsing tests: `rtmp://host/app`, `rtmps://host:443/app/`, `rtmp://host/live2?backup=1`, invalid
   scheme, missing app.
5. `RTMPPublisher.swift` state machine.
6. Test server: in the test target, `FakeRTMPServer` on `NWListener` (loopback, random port) that performs the
   server side of the handshake, parses chunks with `RTMPDechunker`, answers `connect`, `createStream`, `publish`,
   and records every message. Tests: happy path delivers config before the first frame and starts on a keyframe;
   `BadName` leads to `.failed` without retry; server closing the socket leads to `.reconnecting` and a second
   successful session with timestamps restarting near zero; a server that stops reading triggers frame dropping and
   then recovery.
7. Integration test, enabled when `RTMP_FFMPEG_TEST=1` and `/opt/homebrew/bin/ffmpeg` exists: start
   `ffmpeg -loglevel error -listen 1 -i rtmp://127.0.0.1:<port>/live/testkey -c copy -f flv <tmp>.flv`, publish five
   seconds of real H.264 (encode generated frames with a `VTCompressionSession` helper in the test target, no
   B-frames, keyframe every 2 s) and AAC (a tone through `AVAudioConverter`), stop, then assert with
   `ffprobe -v error -show_streams -of json`: codec `h264` with the right size, codec `aac` at 48000 Hz stereo,
   durations within 0.3 s of five seconds.

## Acceptance

1. `swift test` passes; `RTMP_FFMPEG_TEST=1 swift test --filter RTMP` passes locally. Paste the `ffprobe` summary.
2. `grep -rn "streamKey" Sources/StudioKit/Streaming | grep -i log` finds nothing that prints the key.
3. No file outside the two directories changed.

## Pitfalls

- The message stream id in the chunk header is little-endian; everything else is big-endian.
- `NWConnection.receive` may deliver any slice of bytes. The dechunker must be fully incremental.
- Some servers send `onBWDone` and other commands the client can ignore. Unknown commands are not errors.
- Kick and Twitch ingest sit behind AWS IVS and require RTMPS on 443; plain RTMP will simply time out. That is a
  configuration matter for plan 21, but make the time-out error message say which stage failed.
- Do not block the caller: `sendVideo`/`sendAudio` copy into the queue and return.

## Out of scope

HEVC and Enhanced RTMP (plan 90), SRT, HLS, the encoder, Keychain, any UI.
