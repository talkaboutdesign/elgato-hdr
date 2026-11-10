import AppKit
import AVFoundation
import CoreGraphics
import ImageIO
import Observation
import QuartzCore
import UniformTypeIdentifiers

/// Thumbnails of the game file (not the composite: it is the same at every scene and cheap to decode) for the video
/// lane. Slot times are multiples of a power-of-two interval, so every zoom level reuses the frames of the coarser
/// ones. Generated lazily for what is on screen, nearest the middle first, kept in memory and in the project's
/// disposable `.cache/filmstrip` folder.
@Observable
final class FilmstripCache {
    /// Bumped when new images arrive (coalesced); the video lane reads it to redraw.
    var revision = 0
    @ObservationIgnored private var images: [Int: CGImage] = [:]
    @ObservationIgnored private var wanted: [Int] = []
    @ObservationIgnored private var center = 0
    @ObservationIgnored private var inFlight = Set<Int>()
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var bumpPending = false
    @ObservationIgnored private var cancelled = false
    @ObservationIgnored private var firstLogged = false
    @ObservationIgnored private let opened = CACurrentMediaTime()
    @ObservationIgnored private let dir: URL
    @ObservationIgnored private let generator: AVAssetImageGenerator
    @ObservationIgnored private let label: String

    static let ladder: [Int] = (0..<13).map { 125 << $0 }      // 0.125 s … 512 s
    static let slotWidth = 80.0
    static let pixelSize = CGSize(width: 192, height: 108)
    static let memoryLimit = 600

    init(doc: ProjectDoc) {
        dir = doc.dir.appendingPathComponent(".cache/filmstrip", isDirectory: true)
        label = doc.dir.lastPathComponent
        let g = AVAssetImageGenerator(asset: AVURLAsset(url: doc.url(doc.project.game.file)))
        g.appliesPreferredTrackTransform = true
        g.maximumSize = Self.pixelSize
        // The game is HDR (PQ or HLG); thumbnails are drawn in SDR UI, so ask for tone-mapped frames where possible.
        if #available(macOS 15, *) { g.dynamicRangePolicy = .forceSDR }
        generator = g
    }

    /// Thumbnail spacing in milliseconds for a zoom level.
    static func interval(pps: Double) -> Int {
        ladder.first { Double($0) / 1000 * pps >= slotWidth } ?? ladder[ladder.count - 1]
    }

    /// The image for a slot, else the nearest coarser one already cached (a placeholder while it loads).
    func image(for key: Int, interval: Int) -> CGImage? {
        if let i = images[key] { return i }
        var step = interval * 2
        while step <= Self.ladder[Self.ladder.count - 1] {
            if let i = images[key / step * step] { return i }
            step *= 2
        }
        return nil
    }

    /// Replaces the wish list with what is on screen. Called on scroll and zoom; cheap.
    func request(_ keys: [Int], center c: Int) {
        guard !cancelled else { return }
        center = c
        wanted = keys.filter { images[$0] == nil && !inFlight.contains($0) }.sorted { abs($0 - c) < abs($1 - c) }
        if worker == nil && !wanted.isEmpty { startWorker() }
    }

    func cancel() {
        cancelled = true
        wanted = []
        worker?.cancel(); worker = nil
        generator.cancelAllCGImageGeneration()
    }

    private func startWorker() {
        let dir = self.dir, generator = self.generator
        worker = Task.detached(priority: .utility) { [weak self] in
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            while !Task.isCancelled {
                guard let me = self, let key = await me.nextKey() else { break }
                let file = dir.appendingPathComponent("\(key).jpg")
                var image = Self.read(file)
                if image == nil {
                    let t = CMTime(value: CMTimeValue(key), timescale: 1000)
                    image = try? await generator.image(at: t).image
                    if let img = image { Self.write(img, to: file) }
                }
                await me.deliver(key, image)
            }
            await self?.workerFinished()
        }
    }

    @MainActor private func workerFinished() { worker = nil; if !cancelled && !wanted.isEmpty { startWorker() } }

    @MainActor private func nextKey() -> Int? {
        guard !cancelled else { return nil }
        while !wanted.isEmpty {
            let k = wanted.removeFirst()
            if images[k] == nil && !inFlight.contains(k) { inFlight.insert(k); return k }
        }
        return nil
    }

    @MainActor private func deliver(_ key: Int, _ image: CGImage?) {
        inFlight.remove(key)
        guard let image = image, !cancelled else { return }
        images[key] = image
        if images.count > Self.memoryLimit {
            // Evict what is furthest from the view.
            let c = center
            for k in images.keys.sorted(by: { abs($0 - c) > abs($1 - c) }).prefix(images.count - Self.memoryLimit) { images[k] = nil }
        }
        if !firstLogged { firstLogged = true; log(String(format: "editor: first thumbnail %.0f ms after opening (%@)", (CACurrentMediaTime() - opened) * 1000, label)) }
        guard !bumpPending else { return }
        bumpPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.bumpPending = false; self?.revision += 1 }
    }

    private static func read(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
    private static func write(_ image: CGImage, to url: URL) {
        guard let dst = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dst, image, [kCGImageDestinationLossyCompressionQuality: 0.72] as CFDictionary)
        CGImageDestinationFinalize(dst)
    }
}
