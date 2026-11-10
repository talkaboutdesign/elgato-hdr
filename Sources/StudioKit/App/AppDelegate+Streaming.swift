import AppKit

extension AppDelegate {
    func addStreamMenu(to main: NSMenu) {
        let item = NSMenuItem(), menu = NSMenu(title: "Stream")
        let toggle = NSMenuItem(title: "Go Live", action: #selector(toggleStream), keyEquivalent: "l")
        toggle.target = self; toggle.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(toggle); item.submenu = menu; main.addItem(item); streamItem = toggle
    }
    @objc func toggleStream() { if streamSession == nil { goLive() } else { endStream() } }
    func goLive() {
        guard streamSession == nil, let renderer else { return }
        let defaults = UserDefaults.standard
        guard let url = defaults.string(forKey: "streamURL"), let endpoint = StreamEndpoint(url: url),
              let key = ProcessInfo.processInfo.environment["EHDR_STREAM_KEY"], !key.isEmpty else {
            log("stream: provide -streamURL (server/app only) and EHDR_STREAM_KEY"); return
        }
        let kbps = defaults.object(forKey: "streamBitrate") == nil ? 6000 : defaults.integer(forKey: "streamBitrate")
        guard (100...100_000).contains(kbps) else { log("stream: bitrate must be 100…100000 kbps"); return }
        let canvas: Canvas = defaults.string(forKey: "streamCanvas") == "vertical" ? .vertical : .wide
        func output(_ canvas: Canvas, _ endpoint: StreamEndpoint) -> StreamSession.Output {
            let size = canvas == .wide ? CGSize(width: 1920, height: 1080) : CGSize(width: 1080, height: 1920)
            let publisher = RTMPPublisher(endpoint: endpoint, streamKey: key,
                metadata: StreamMetadata(width: Int(size.width), height: Int(size.height), fps: 60, videoKbps: kbps, audioKbps: 160))
            publisher.onState = { state in log("stream \(canvas.rawValue): \(state)") }
            return .init(canvas: canvas, size: size, fps: 60, videoBitrate: kbps * 1000, publishers: [publisher])
        }
        var outputs = [output(canvas, endpoint)]
        // Development-only second destination exercises the same multi-canvas conductor used by plan 21.
        if let second = defaults.string(forKey: "streamSecondURL"), let endpoint = StreamEndpoint(url: second) {
            outputs.append(output(canvas == .wide ? .vertical : .wide, endpoint))
        }
        let stream = StreamSession(outputs: outputs, audioBitrate: 160_000, renderer: renderer, mixer: streamMixer)
        stream.onError = { error in log("stream: \(error)") }
        stream.onStats = { [weak self] stats in
            log(String(format: "stream %@: %.1f fps render %.3f ms encode %.3f ms callback %.3f ms dropped render=%d encoder=%d", stats.canvas.rawValue,
                       stats.fps, stats.renderMs, stats.encodeMs, stats.latencyMs, stats.renderDropped, stats.encoderDropped))
            if let recorder = self?.recorder {
                recorder.queue.async { log("stream recording: frames=\(recorder.videoFrames) dropped=\(recorder.droppedVideo) gaps=\(recorder.gapFrames)") }
            }
            for p in stats.publishers { log(String(format: "stream upload: %.0f kbps pendingMs=%.2f dropped=%d reconnects=%d", p.kbps, p.pendingMs, p.droppedFrames, p.reconnects)) }
        }
        if stream.start() { streamSession = stream; streamItem?.title = "End Stream" }
    }
    func endStream() { streamSession?.stop(); streamSession = nil; streamItem?.title = "Go Live" }
    func scheduleStreaming() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--go-live-for"), i + 1 < args.count,
              let seconds = Double(args[i + 1]), seconds.isFinite, seconds > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.goLive()
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                self?.endStream()
                // Termination drains any layered recording through the existing delegate path.
                if args.contains("--demo-source") { NSApp.terminate(nil) }
            }
        }
    }
}
