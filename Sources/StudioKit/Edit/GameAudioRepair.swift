import AVFoundation

/// Where game audio recorded before the audio clock fix (plan 44) belongs in recording time.
///
/// The old recorder's slew ran the wrong way: once its error passed 2 ms it dropped (or repeated) a fixed share of
/// every chunk for the rest of the recording, so the game audio in those files is squeezed (or stretched) from that
/// moment on. The map is piecewise linear: knots of (seconds in the file's audio, seconds of recording), increasing in
/// both; playback, export and the waveform go through it. The files are never rewritten.
struct AudioTimeMap: Codable, Equatable {
    var points: [[Double]]

    init?(points: [[Double]]) {
        guard points.count >= 2, points.allSatisfy({ $0.count == 2 && $0[0].isFinite && $0[1].isFinite }),
              zip(points, points.dropFirst()).allSatisfy({ $1[0] > $0[0] && $1[1] > $0[1] }) else { return nil }
        self.points = points
    }
    enum CodingKeys: String, CodingKey { case points }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        guard let m = AudioTimeMap(points: try c.decode([[Double]].self, forKey: .points)) else {
            throw DecodingError.dataCorruptedError(forKey: .points, in: c, debugDescription: "not an increasing time map")
        }
        self = m
    }

    var audioRange: ClosedRange<Double> { points[0][0]...points[points.count - 1][0] }
    var recordingRange: ClosedRange<Double> { points[0][1]...points[points.count - 1][1] }
    /// Recording seconds where the knots are (the pieces the composition scales separately).
    var recordingKnots: [Double] { points.map { $0[1] } }

    /// Audio-file seconds heard at recording second `t` (extended linearly beyond the ends).
    func audio(at t: Double) -> Double { Self.interpolate(t, points.map { ($0[1], $0[0]) }) }
    /// Recording second at which audio-file second `a` is heard.
    func recording(at a: Double) -> Double { Self.interpolate(a, points.map { ($0[0], $0[1]) }) }

    private static func interpolate(_ x: Double, _ knots: [(Double, Double)]) -> Double {
        var i = 0
        while i < knots.count - 2 && x > knots[i + 1].0 { i += 1 }
        let (x0, y0) = knots[i], (x1, y1) = knots[i + 1]
        return y0 + (x - x0) * (y1 - y0) / (x1 - x0)
    }
}

enum GameAudioRepair {
    /// The share of each chunk the old slew dropped or repeated: the capture helper flushes 768-sample chunks (two
    /// 8 ms USB transfers) and the slew took `n / 100` = 7 of them. Measured on the two affected recordings by
    /// correlating game audio with its echo in mic.mov: the squeeze rate was 0.991 throughout.
    static let runawayRate = 7.0 / 768
    /// Below this difference between audio and video durations nothing is corrected.
    static let threshold = 0.001

    /// The map for a recording whose game audio spans `audio` and video spans `video` (seconds in the file). Before the
    /// runaway began the audio was in place; after it, a constant share was dropped (or repeated), so the start of the
    /// runaway follows from how much is missing. When the difference is too large for that, it is spread over the
    /// whole recording.
    static func map(video: ClosedRange<Double>, audio: ClosedRange<Double>) -> AudioTimeMap? {
        let videoLength = video.upperBound - video.lowerBound, audioLength = audio.upperBound - audio.lowerBound
        guard videoLength > 0, audioLength > 0, abs(audioLength - videoLength) > threshold * videoLength else { return nil }
        let missing = video.upperBound - audio.upperBound
        let runawayStart = video.upperBound - abs(missing) / runawayRate
        var points = [[audio.lowerBound, audio.lowerBound]]
        if runawayStart > audio.lowerBound + 1 { points.append([runawayStart, runawayStart]) }
        points.append([audio.upperBound, video.upperBound])
        return AudioTimeMap(points: points)
    }

    /// Checks a project recorded before the fix: nil when it needs nothing (or was already checked and corrected).
    static func detect(_ project: Project, game url: URL) async -> AudioTimeMap? {
        guard !project.audioClock, project.gameAudioSync == nil else { return nil }
        let asset = AVURLAsset(url: url)
        guard let v = try? await asset.loadTracks(withMediaType: .video).first, let a = try? await asset.loadTracks(withMediaType: .audio).first,
              let vr = try? await v.load(.timeRange), let ar = try? await a.load(.timeRange),
              vr.duration.seconds > 0, ar.duration.seconds > 0 else { return nil }
        guard let m = map(video: vr.start.seconds...vr.end.seconds, audio: ar.start.seconds...ar.end.seconds) else { return nil }
        log(String(format: "game audio sync: %@ has %.3f s of game audio for %.3f s of video; re-timed from %.1f s on",
                   url.deletingLastPathComponent().lastPathComponent, ar.duration.seconds, vr.duration.seconds, m.points.count > 2 ? m.points[1][1] : m.points[0][1]))
        return m
    }

    /// How far the correction moves the end of the game audio, for the editor's note.
    static func shift(_ m: AudioTimeMap) -> Double { m.points[m.points.count - 1][1] - m.points[m.points.count - 1][0] }
}
