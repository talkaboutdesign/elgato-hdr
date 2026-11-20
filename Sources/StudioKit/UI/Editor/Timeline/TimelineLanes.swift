import AppKit
import SwiftUI

// Lanes are drawn with Canvas, culled to the visible time range, and hit-tested by `TimelineHitTest` through one
// AppKit input view on top: thousands of SwiftUI gesture views would make scrolling slow. Each lane reads the model
// in `body` (so observation tracks exactly those values) and draws from captured copies.

enum TimelineStyle {
    static let zoom = Color(red: 0.56, green: 0.45, blue: 1.0)
    static let marker = DS.Color.warn
    static let playhead = DS.Color.record
    static let gameWave = Color(red: 0.30, green: 0.78, blue: 0.64)
    static let micWave = Color(red: 1.0, green: 0.62, blue: 0.28)
    static let scenes: [Color] = [
        Color(red: 0.24, green: 0.52, blue: 0.96), Color(red: 0.62, green: 0.38, blue: 0.94), Color(red: 0.13, green: 0.66, blue: 0.70),
        Color(red: 0.95, green: 0.50, blue: 0.20), Color(red: 0.91, green: 0.33, blue: 0.56), Color(red: 0.33, green: 0.68, blue: 0.32),
    ]
    static func sceneColor(_ id: UUID?, in p: Project) -> Color {
        let i = p.scenes.firstIndex { $0.id == id } ?? 0
        return scenes[i % scenes.count]
    }
    static let laneRadius = 6.0

    /// A cut with its removed footage hidden: a hairline through the lanes and a notch on top of the video lane.
    /// Quiet at rest; selected or under the pointer it takes the removed-section colour.
    static let seam = DS.Color.textSecondary
    static let notchSize = CGSize(width: 11, height: 9)
    static func drawSeam(_ ctx: inout GraphicsContext, x: Double, top: Double, bottom: Double, notchY: Double, on: Bool, hot: Bool) {
        let px = x.rounded() + (x.rounded() <= 0 ? 0.75 : 0)
        ctx.fill(Path(CGRect(x: px - 1.25, y: top, width: 2.5, height: bottom - top)), with: .color(.black.opacity(0.35)))
        let color = on || hot ? DS.Color.warn : seam
        ctx.fill(Path(CGRect(x: px - 0.5, y: top, width: 1, height: bottom - top)), with: .color(color))
        let w = notchSize.width * (hot || on ? 1.2 : 1), nh = notchSize.height * (hot || on ? 1.2 : 1)
        var notch = Path()
        notch.move(to: CGPoint(x: px - w / 2, y: notchY))
        notch.addLine(to: CGPoint(x: px + w / 2, y: notchY))
        notch.addLine(to: CGPoint(x: px, y: notchY + nh))
        notch.closeSubpath()
        ctx.fill(notch, with: .color(color))
        ctx.stroke(notch, with: .color(on ? Color.white : Color.black.opacity(0.35)), lineWidth: on ? 1.5 : 0.75)
    }
}

struct TimelineTracks: View {
    let model: EditorModel
    let layout: TimelineLayout

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                ForEach(layout.lanes, id: \.kind) { lane in
                    laneView(lane).frame(width: geo.size.width, height: lane.height).offset(y: lane.y)
                }
                GuidesOverlay(model: model, layout: layout).allowsHitTesting(false)
                PlayheadOverlay(model: model, layout: layout).allowsHitTesting(false)
                TimelineInput(model: model, layout: layout)
            }
            .onAppear { model.setTimelineWidth(geo.size.width) }
            .onChange(of: geo.size.width) { _, w in model.setTimelineWidth(w) }
        }
        .frame(height: layout.height)
        .clipped()
    }

    @ViewBuilder func laneView(_ lane: TimelineLayout.Lane) -> some View {
        switch lane.kind {
        case .ruler: RulerLane(model: model)
        case .scenes: SceneLane(model: model)
        case .zoom: ZoomLane(model: model)
        case .video: VideoLane(model: model)
        case .gameAudio: AudioLane(model: model, mic: false)
        case .micAudio: AudioLane(model: model, mic: true)
        }
    }
}

private func laneBackground(_ ctx: inout GraphicsContext, _ size: CGSize, opacity: Double = 0.05) {
    ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: TimelineStyle.laneRadius), with: .color(.primary.opacity(opacity)))
}

// MARK: - Ruler and markers

struct RulerLane: View {
    let model: EditorModel
    var body: some View {
        let axis = model.drawnAxis, p = model.project
        let markers = p.timeline.markers.filter { !axis.isCollapsed($0.tMs / 1000) }
        let selected: UUID? = { if case .marker(let id) = model.selection { return id }; return nil }()
        let hovered: UUID? = { if case .marker(let id) = model.hover { return id }; return nil }()
        SwiftUI.Canvas { ctx, size in
            let h = Double(size.height), width = Double(size.width)
            // Ticks count shown time (kept footage only while removed footage is hidden), so the ruler ends at
            // the export's length.
            let (major, minor) = axis.ticks()
            let parts = max(1, Int((major / minor).rounded()))
            let e0 = axis.shownTime(axis.visibleStart), e1 = axis.shownTime(axis.visibleEnd), total = axis.shownDuration
            let first = Int((e0 / minor).rounded(.down)), last = Int((e1 / minor).rounded(.up))
            var lines = Path(), majors = Path()
            if last >= first {
                for i in first...last {
                    let t = Double(i) * minor
                    guard t <= total + 1e-6 else { continue }
                    let x = axis.x(axis.sourceTime(shown: t)).rounded() + 0.5
                    if i % parts == 0 {
                        majors.move(to: CGPoint(x: x, y: h - 10)); majors.addLine(to: CGPoint(x: x, y: h))
                        let label = ctx.resolve(Text(formatRuler(t, step: major)).font(.system(size: 10, weight: .medium).monospacedDigit()).foregroundStyle(.secondary))
                        ctx.draw(label, at: CGPoint(x: x + 4, y: 3), anchor: .topLeading)
                    } else {
                        lines.move(to: CGPoint(x: x, y: h - 5)); lines.addLine(to: CGPoint(x: x, y: h))
                    }
                }
            }
            ctx.stroke(lines, with: .color(.primary.opacity(0.22)), lineWidth: 1)
            ctx.stroke(majors, with: .color(.primary.opacity(0.45)), lineWidth: 1)
            ctx.fill(Path(CGRect(x: 0, y: h - 1, width: width, height: 1)), with: .color(.primary.opacity(0.12)))
            for m in markers {
                let x = axis.x(m.tMs / 1000)
                guard x > -120, x < width + 12 else { continue }
                let on = m.id == selected, hot = m.id == hovered
                var flag = Path()
                flag.move(to: CGPoint(x: x, y: h * 0.38)); flag.addLine(to: CGPoint(x: x + 10, y: h * 0.38 + 4))
                flag.addLine(to: CGPoint(x: x, y: h * 0.38 + 8)); flag.closeSubpath()
                ctx.fill(Path(CGRect(x: x - 0.75, y: h * 0.38, width: 1.5, height: h * 0.62)), with: .color(TimelineStyle.marker))
                ctx.fill(flag, with: .color(TimelineStyle.marker.opacity(on || hot ? 1 : 0.85)))
                if on { ctx.stroke(flag, with: .color(.primary), lineWidth: 1.2) }
                if on || hot || !m.label.isEmpty {
                    let t = ctx.resolve(Text(TimelineEdits.markerTitle(m, in: p)).font(.system(size: 10, weight: on ? .semibold : .regular)).foregroundStyle(.primary))
                    let w = t.measure(in: CGSize(width: 160, height: 14)).width
                    let r = CGRect(x: x + 12, y: h * 0.38 - 2, width: w + 8, height: 13)
                    ctx.fill(Path(roundedRect: r, cornerRadius: 3), with: .color(DS.Color.panel))
                    ctx.fill(Path(roundedRect: r, cornerRadius: 3), with: .color(TimelineStyle.marker.opacity(on ? 0.4 : 0.25)))
                    ctx.draw(t, at: CGPoint(x: r.minX + 4, y: r.midY), anchor: .leading)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Scenes

struct SceneLane: View {
    let model: EditorModel
    var body: some View {
        let axis = model.drawnAxis, p = model.project
        let runs = TimelineEdits.sceneRuns(p).filter { !axis.pieces($0.startMs / 1000, $0.endMs / 1000).isEmpty }
        let selected: UUID?? = { if case .scene(let id) = model.selection { return .some(id) }; return .none }()
        let hoverChange: UUID? = { if case .sceneChange(let id) = model.hover { return id }; return nil }()
        let hoverRun: UUID?? = { if case .sceneRun(let id) = model.hover { return .some(id) }; return .none }()
        SwiftUI.Canvas { ctx, size in
            laneBackground(&ctx, size)
            let h = Double(size.height), width = Double(size.width)
            for run in runs {
                let x0 = axis.x(run.startMs / 1000), x1 = axis.x(run.endMs / 1000)
                guard x1 > 0, x0 < width else { continue }
                let id = run.span?.id
                let isSel = selected.map { $0 == id } ?? false
                let isHot = hoverRun.map { $0 == id } ?? false
                let color = TimelineStyle.sceneColor(run.sceneID, in: p)
                let r = CGRect(x: x0 + 1, y: 1, width: max(1, x1 - x0 - 2), height: h - 2)
                let shape = Path(roundedRect: r, cornerRadius: 5)
                ctx.fill(shape, with: .color(color.opacity(isSel ? 1 : isHot ? 0.94 : 0.86)))
                if let t = run.span?.transition, t.style != .cut, run.startMs > 0 {
                    // The transition as a soft wedge at the start of the span.
                    let w = min(r.width / 2, max(4, t.durationMs / 1000 * axis.pps))
                    var wedge = Path()
                    wedge.move(to: CGPoint(x: r.minX, y: r.maxY)); wedge.addLine(to: CGPoint(x: r.minX + w, y: r.minY))
                    wedge.addLine(to: CGPoint(x: r.minX, y: r.minY)); wedge.closeSubpath()
                    ctx.fill(wedge, with: .color(.black.opacity(0.22)))
                }
                if isSel { ctx.stroke(Path(roundedRect: r.insetBy(dx: 0.75, dy: 0.75), cornerRadius: 4.5), with: .color(.white.opacity(0.95)), lineWidth: 1.5) }
                // The name stays readable while the span's start is scrolled off to the left.
                let labelX = max(r.minX, 0) + 8
                if r.maxX - labelX > 24 {
                    var c = ctx
                    c.clip(to: Path(r.insetBy(dx: 4, dy: 0)))
                    let name = ctx.resolve(Text(TimelineEdits.sceneName(run.sceneID, in: p)).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white))
                    c.draw(name, at: CGPoint(x: labelX, y: h / 2), anchor: .leading)
                }
            }
            for run in runs where run.startMs > 0 {
                guard let id = run.span?.id else { continue }
                let x = axis.x(run.startMs / 1000)
                guard x > -4, x < width + 4 else { continue }
                let hot = id == hoverChange
                ctx.fill(Path(roundedRect: CGRect(x: x - 1.5, y: hot ? 2 : 6, width: 3, height: hot ? h - 4 : h - 12), cornerRadius: 1.5),
                         with: .color(.white.opacity(hot ? 1 : 0.55)))
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Zoom

struct ZoomLane: View {
    let model: EditorModel
    var body: some View {
        let axis = model.drawnAxis
        let zooms = model.project.timeline.zooms.filter { !axis.pieces($0.startMs / 1000, $0.endMs / 1000).isEmpty }
        let selected: UUID? = { if case .zoom(let id) = model.selection { return id }; return nil }()
        let hover = model.hover
        SwiftUI.Canvas { ctx, size in
            laneBackground(&ctx, size)
            let h = Double(size.height), width = Double(size.width)
            for z in zooms {
                let x0 = axis.x(z.startMs / 1000), x1 = axis.x(z.endMs / 1000)
                guard x1 > 0, x0 < width else { continue }
                let on = z.id == selected
                var hot = false, hotEdge: Bool?
                if case .zoom(let id) = hover, id == z.id { hot = true }
                if case .zoomEdge(let id, let leading) = hover, id == z.id { hot = true; hotEdge = leading }
                let r = CGRect(x: x0 + 0.5, y: 1, width: max(2, x1 - x0 - 1), height: h - 2)
                ctx.fill(Path(roundedRect: r, cornerRadius: 5), with: .color(TimelineStyle.zoom.opacity(on ? 0.34 : 0.22)))
                // The ease in and out as ramps, so the block reads as the zoom curve it is.
                // A live-style block rises over the live spring and holds until the release; its return follows it.
                let ramp = min(r.width / 2, (z.live ? ZoomBlock.liveSpringMs : z.easeMs) / 1000 * axis.pps)
                let rampOut = z.live ? 0 : ramp
                var curve = Path()
                curve.move(to: CGPoint(x: r.minX, y: r.maxY)); curve.addLine(to: CGPoint(x: r.minX + ramp, y: r.minY + 3))
                curve.addLine(to: CGPoint(x: r.maxX - rampOut, y: r.minY + 3)); curve.addLine(to: CGPoint(x: r.maxX, y: r.maxY)); curve.closeSubpath()
                var c = ctx; c.clip(to: Path(roundedRect: r, cornerRadius: 5))
                c.fill(curve, with: .color(TimelineStyle.zoom.opacity(on ? 1 : hot ? 0.94 : 0.86)))
                if r.width > 40 {
                    let label = ctx.resolve(Text(String(format: "%.1f×", z.scale)).font(.system(size: 10, weight: .bold).monospacedDigit()).foregroundStyle(.white))
                    c.draw(label, at: CGPoint(x: max(r.minX, 0) + 8 + min(ramp, 12), y: h / 2 + 1), anchor: .leading)
                }
                if on { ctx.stroke(Path(roundedRect: r.insetBy(dx: 0.75, dy: 0.75), cornerRadius: 4.5), with: .color(.white.opacity(0.95)), lineWidth: 1.5) }
                if on || hot {
                    for (lead, x) in [(true, r.minX + 3), (false, r.maxX - 3)] {
                        let strong = hotEdge == lead
                        ctx.fill(Path(roundedRect: CGRect(x: x - 1.5, y: 5, width: 3, height: h - 10), cornerRadius: 1.5), with: .color(.white.opacity(strong ? 1 : 0.7)))
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Video

struct VideoLane: View {
    let model: EditorModel
    var body: some View {
        let axis = model.drawnAxis, p = model.project
        let film = model.filmstrip
        let _ = film.revision
        let sections = TimelineEdits.sections(p)
        let splits = TimelineEdits.boundaries(p).filter { $0.left != nil && $0.right != nil }.map(\.ms)
        let selected: CutSection? = { if case .section(let s) = model.selection { return s }; return nil }()
        let hover = model.hover
        let ghost = model.trimGhost
        let interval = FilmstripCache.interval(pps: axis.pps)
        let slots = FilmstripCache.slots(axis, interval: interval)
        let keys = slots.map(\.key)
        let center = Int((axis.visibleStart + axis.visibleEnd) * 500)
        SwiftUI.Canvas { ctx, size in
            let h = Double(size.height), width = Double(size.width)
            let lane = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: TimelineStyle.laneRadius)
            ctx.clip(to: lane)
            ctx.fill(lane, with: .color(Color(white: 0.12)))
            for s in slots {
                let x0 = axis.x(s.t0), x1 = axis.x(s.t1)
                guard x1 > 0, x0 < width, x1 - x0 > 0.01 else { continue }
                let slot = CGRect(x: x0, y: 0, width: x1 - x0, height: h)
                if let img = film.image(for: s.key, interval: s.interval, notBefore: s.from) {
                    let aspect = Double(img.width) / Double(max(1, img.height))
                    let w = max(slot.width, h * aspect)
                    var c = ctx; c.clip(to: Path(slot))
                    c.draw(Image(decorative: img, scale: 1), in: CGRect(x: slot.minX, y: 0, width: w, height: h))
                } else {
                    ctx.fill(Path(slot.insetBy(dx: 0.5, dy: 0)), with: .color(Color(white: 0.17)))
                }
                ctx.fill(Path(CGRect(x: x0, y: 0, width: 0.5, height: h)), with: .color(.black.opacity(0.35)))
            }
            for s in sections {
                let x0 = axis.x(s.startMs / 1000), x1 = axis.x(s.endMs / 1000)
                // Hidden removed footage has no width; it shows while a gap opens or closes and while an edge
                // drag removes more (the layout waits for the release).
                guard x1 > 0, x0 < width, x1 - x0 > 0.25 else { continue }
                let r = CGRect(x: x0, y: 0, width: x1 - x0, height: h)
                if !s.kept {
                    ctx.fill(Path(r), with: .color(.black.opacity(0.62)))
                    var hatch = Path(), x = (x0 / 7).rounded(.down) * 7 - h
                    while x < x1 { hatch.move(to: CGPoint(x: x, y: h)); hatch.addLine(to: CGPoint(x: x + h, y: 0)); x += 7 }
                    var c = ctx; c.clip(to: Path(r))
                    c.stroke(hatch, with: .color(.white.opacity(0.16)), lineWidth: 1)
                }
                if case .section(let hs) = hover, hs == s, s != selected { ctx.fill(Path(r), with: .color(.white.opacity(0.08))) }
            }
            for ms in splits {
                let x = axis.x(ms / 1000)
                guard x > -2, x < width + 2 else { continue }
                ctx.fill(Path(CGRect(x: x - 1, y: 0, width: 2, height: h)), with: .color(.white.opacity(0.9)))
                ctx.fill(Path(ellipseIn: CGRect(x: x - 3, y: h / 2 - 3, width: 6, height: 6)), with: .color(.white))
            }
            if case .cut(let b) = hover {
                let x = axis.x(b.ms / 1000)
                var bracket = Path()
                let dir: Double = b.right != nil && b.left == nil ? 1 : b.left != nil && b.right == nil ? -1 : 0
                bracket.addRoundedRect(in: CGRect(x: x - 2, y: 0, width: 4, height: h), cornerSize: CGSize(width: 2, height: 2))
                if dir != 0 {
                    bracket.addRect(CGRect(x: dir > 0 ? x : x - 7, y: 0, width: 7, height: 3))
                    bracket.addRect(CGRect(x: dir > 0 ? x : x - 7, y: h - 3, width: 7, height: 3))
                }
                ctx.fill(bracket, with: .color(DS.Color.warn))
            }
            if let g = ghost {
                // The dragged seam edge against the frozen layout: footage coming back is tinted, the edge follows
                // the pointer.
                let sx = g.seamX - axis.offset, ex = g.edgeX - axis.offset
                if g.restoring {
                    ctx.fill(Path(CGRect(x: min(sx, ex), y: 0, width: abs(ex - sx), height: h)), with: .color(Color.accentColor.opacity(0.28)))
                }
                ctx.fill(Path(roundedRect: CGRect(x: ex - 2, y: 0, width: 4, height: h), cornerRadius: 2), with: .color(DS.Color.warn))
            }
            if let s = selected {
                let x0 = axis.x(s.startMs / 1000), x1 = axis.x(s.endMs / 1000)
                if s.kept || x1 - x0 > 2 {
                    let r = CGRect(x: x0 + 1, y: 1, width: max(2, x1 - x0 - 2), height: h - 2)
                    ctx.stroke(Path(roundedRect: r, cornerRadius: 4), with: .color(s.kept ? .accentColor : DS.Color.warn), lineWidth: 2.5)
                }
            }
        }
        // Keyed on every slot: a cut can swap one frame for another and leave the count and the ends as they were.
        .task(id: keys) { film.request(keys, center: center) }
        .accessibilityHidden(true)
    }
}

// MARK: - Audio

struct AudioLane: View {
    let model: EditorModel
    let mic: Bool
    var body: some View {
        let axis = model.drawnAxis
        let wave = mic ? model.waveforms.mic : model.waveforms.game
        let layer = mic ? model.project.mic : Optional(model.project.game)
        let offsetMs = layer?.offsetMs ?? 0, volume = layer?.volume ?? 1
        let color = mic ? TimelineStyle.micWave : TimelineStyle.gameWave
        SwiftUI.Canvas { ctx, size in
            laneBackground(&ctx, size, opacity: 0.04)
            let h = Double(size.height), mid = h / 2, width = Double(size.width)
            guard let w = wave else {
                ctx.fill(Path(CGRect(x: 0, y: mid - 0.5, width: width, height: 1)), with: .color(color.opacity(0.3)))
                return
            }
            // Normalized to the layer's loudest moment, then scaled by its volume, so gain changes are visible.
            let gain = (mid - 2) * 0.92 / Double(max(w.peak, 0.02)) * min(volume, 2)
            // One envelope per piece of shown footage: a column never reaches across a seam into removed audio.
            var path = Path()
            let from = max(axis.visibleStart, offsetMs / 1000), to = min(axis.visibleEnd, axis.duration)
            for piece in axis.pieces(from, to) {
                let cols = AudioLane.columns(axis, piece, width: width)
                var top: [CGPoint] = [], bottom: [CGPoint] = []
                for c in cols {
                    let (lo, hi) = w.range(c.t0 * 1000 - offsetMs, max(c.t1 * 1000 - offsetMs, c.t0 * 1000 - offsetMs + 1))
                    top.append(CGPoint(x: c.x, y: max(1, mid - Double(hi) * gain)))
                    bottom.append(CGPoint(x: c.x, y: min(h - 1, mid - Double(lo) * gain)))
                }
                guard top.count > 1 else { continue }
                path.addLines(top)
                path.addLines(bottom.reversed())
                path.closeSubpath()
            }
            ctx.fill(path, with: .color(color.opacity(0.85)))
            ctx.fill(Path(CGRect(x: 0, y: mid - 0.25, width: width, height: 0.5)), with: .color(color.opacity(0.5)))
        }
        .accessibilityHidden(true)
    }
}

extension AudioLane {
    /// Waveform columns 2 points apart over one piece of shown footage (source seconds), each covering the source
    /// time under it and clipped to the piece, the last one ending exactly at it.
    static func columns(_ axis: TimelineAxis, _ piece: ClosedRange<Double>, width: Double, step: Double = 2) -> [(x: Double, t0: Double, t1: Double)] {
        let x0 = max(0, axis.x(piece.lowerBound)), x1 = min(width, axis.x(piece.upperBound))
        guard x1 > x0 else { return [] }
        var out: [(x: Double, t0: Double, t1: Double)] = []
        var x = x0
        while x < x1 {
            let next = min(x + step, x1)
            let a = max(piece.lowerBound, min(piece.upperBound, axis.time(atX: x)))
            let b = next >= x1 ? piece.upperBound : max(a, min(piece.upperBound, axis.time(atX: next)))
            out.append((x, a, b))
            x = next
            if next >= x1 { out.append((x1, b, b)); break }
        }
        return out
    }
}

// MARK: - Overlays

/// Removed ranges dimmed across the lanes (or, hidden, a seam at each cut), marker lines and the snap guide.
struct GuidesOverlay: View {
    let model: EditorModel
    let layout: TimelineLayout
    var body: some View {
        let axis = model.drawnAxis, p = model.project
        let removed = TimelineEdits.removedRanges(p)
        let markers = p.timeline.markers.map(\.tMs).filter { !axis.isCollapsed($0 / 1000) }
        let snap = model.snapGuide
        let seams = axis.visibleSeams()
        let selectedSeam: Double? = { if case .section(let s) = model.selection, !s.kept { return s.startMs / 1000 }; return nil }()
        let hoverSeam: Double? = { if case .seam(let s) = model.hover { return s.startMs / 1000 }; return nil }()
        SwiftUI.Canvas { ctx, size in
            let top = (layout.lane(.scenes)?.y ?? 28)
            let video = layout.lane(.video)
            let width = Double(size.width), height = Double(size.height)
            for r in removed {
                let x0 = axis.x(r.startMs / 1000), x1 = axis.x(r.endMs / 1000)
                guard x1 > 0, x0 < width, x1 - x0 > 0.25 else { continue }
                for lane in layout.lanes where lane.kind != .ruler && lane.kind != video?.kind {
                    ctx.fill(Path(CGRect(x: x0, y: lane.y, width: x1 - x0, height: lane.height)), with: .color(Color(nsColor: .windowBackgroundColor).opacity(0.55)))
                }
            }
            var lines = Path()
            for m in markers {
                let x = axis.x(m / 1000).rounded() + 0.5
                guard x > 0, x < width else { continue }
                lines.move(to: CGPoint(x: x, y: top)); lines.addLine(to: CGPoint(x: x, y: height))
            }
            ctx.stroke(lines, with: .color(TimelineStyle.marker.opacity(0.45)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            if let v = video {
                for seam in seams {
                    let x = seam.x
                    let on = selectedSeam.map { abs($0 - seam.range.lowerBound) < 0.0005 } ?? false
                    let hot = hoverSeam.map { abs($0 - seam.range.lowerBound) < 0.0005 } ?? false
                    TimelineStyle.drawSeam(&ctx, x: x, top: top, bottom: height, notchY: v.y, on: on, hot: hot)
                }
            }
            if let s = snap {
                let x = axis.x(s)
                ctx.fill(Path(CGRect(x: x - 0.75, y: 0, width: 1.5, height: height)), with: .color(DS.Color.warn))
            }
        }
    }
}

struct PlayheadOverlay: View {
    let model: EditorModel
    let layout: TimelineLayout
    var body: some View {
        let axis = model.drawnAxis
        // Dragging a seam edge, the playhead shows the edge's frame and stays on the edge.
        let x = model.trimGhost.map { $0.edgeX - axis.offset } ?? axis.x(model.time)
        let width = axis.width
        ZStack(alignment: .topLeading) {
            if x > -8 && x < width + 8 {
                Rectangle().fill(TimelineStyle.playhead).frame(width: 1.5, height: layout.height).offset(x: x - 0.75)
                PlayheadCap().fill(TimelineStyle.playhead).frame(width: 11, height: 14).offset(x: min(max(x, 5.5), width - 5.5) - 5.5, y: 4)
                    .shadow(color: .black.opacity(0.3), radius: 1, y: 0.5)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct PlayheadCap: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX + 2, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - 2, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY + 2), control: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - 5))
        p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY - 5))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + 2))
        p.addQuadCurve(to: CGPoint(x: r.minX + 2, y: r.minY), control: CGPoint(x: r.minX, y: r.minY))
        return p
    }
}
