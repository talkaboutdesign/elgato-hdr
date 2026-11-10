import AppKit
import AVFoundation
import SwiftUI

/// The aspect-fitted canvas preview. On top: the zoom focus target while a zoom block is selected, otherwise layer
/// editing on the scene at the playhead (the live window's rules, `LayerInteraction`).
struct PreviewStage: View {
    let model: EditorModel

    var body: some View {
        ZStack {
            DS.Color.canvas
            ZStack {
                PlayerLayerView(player: model.player)
                #if DEBUG
                SnapshotFrameOverlay(model: model)
                #endif
                StageOverlay(model: model)
            }
            .aspectRatio(model.canvas.aspect, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .shadow(color: .black.opacity(0.5), radius: 14, y: 2)
            .padding(DS.Space.xl)
            .animation(DS.Motion.gentle, value: model.canvas)
            if let e = model.loadError {
                ToastView(toast: Toast(text: "The preview could not load", detail: e, style: .error))
            }
            VStack {
                Spacer()
                EditorToastOverlay(model: model).padding(.bottom, DS.Space.xl + DS.Space.s)
            }
        }
        .frame(minHeight: 260)
    }
}

/// Picks the overlay: the zoom target while a zoom block is selected, otherwise layer editing on the picture.
struct StageOverlay: View {
    let model: EditorModel
    var body: some View {
        // A live-style zoom centres as live did; it has no focus point to drag.
        if case .zoom(let id) = model.selection, model.zoomBlock(id)?.live != true {
            FocusTargetOverlay(model: model, id: id)
        } else {
            EditorLayerStage(model: model)
        }
    }
}

/// The point a zoom block closes in on, dragged on the game picture. The zoom keeps that source point fixed on
/// screen, so the target sits at the same canvas spot whether the preview shows the block zoomed or not.
struct FocusTargetOverlay: View {
    let model: EditorModel
    let id: UUID
    @State private var dragging = false

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let canvas = model.canvas.size(.hd)
            let k = size.width / canvas.width
            if let z = model.zoomBlock(id), let g = gameLayers(z, canvas: canvas) {
                let zs = g.zoomed.src, dst = g.zoomed.dst
                let pos = CGPoint(x: (dst.minX + (z.focusX - zs.minX) / zs.width * dst.width) * k,
                                  y: (dst.minY + (z.focusY - zs.minY) / zs.height * dst.height) * k)
                ZStack(alignment: .topLeading) {
                    Color.clear.contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { v in drag(to: v.location, k: k, plain: g.plain) }
                            .onEnded { _ in dragging = false; model.endGesture() })
                    FocusTarget(scale: z.scale, active: dragging)
                        .position(pos)
                        .allowsHitTesting(false)
                }
            } else {
                Text("This scene has no game layer to zoom into.")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule()).environment(\.colorScheme, .dark)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Zoom focus")
        .accessibilityHint("Drag to choose the point the zoom closes in on")
    }

    private func gameLayers(_ z: ZoomBlock, canvas: CGSize) -> (zoomed: ResolvedLayer, plain: ResolvedLayer)? {
        var plan = model.renderPlan(size: canvas)
        let mid = (z.startMs + z.endMs) / 2
        guard let zoomed = plan.layers(atTimelineMs: mid).first(where: { $0.key == .game }) else { return nil }
        plan.timeline.zooms = []
        guard let plain = plan.layers(atTimelineMs: mid).first(where: { $0.key == .game }) else { return nil }
        return (zoomed, plain)
    }

    private func drag(to p: CGPoint, k: Double, plain: ResolvedLayer) {
        if !dragging { dragging = true; model.beginGesture(); model.parkOnZoom(id) }
        let c = CGPoint(x: p.x / k, y: p.y / k), d = plain.dst, s = plain.src
        let fx = s.minX + (c.x - d.minX) / d.width * s.width, fy = s.minY + (c.y - d.minY) / d.height * s.height
        let x = min(s.maxX, max(s.minX, fx)), y = min(s.maxY, max(s.minY, fy))
        model.updateZoom(id, "Zoom Focus") { $0.focusX = (x * 1000).rounded() / 1000; $0.focusY = (y * 1000).rounded() / 1000 }
    }
}

struct FocusTarget: View {
    let scale: Double
    let active: Bool
    var body: some View {
        ZStack {
            Circle().fill(.black.opacity(0.18)).frame(width: 46, height: 46)
            Circle().strokeBorder(.white, lineWidth: 2).frame(width: 46, height: 46)
            Circle().strokeBorder(TimelineStyle.zoom, lineWidth: 2).frame(width: 40, height: 40)
            Path { p in
                p.move(to: CGPoint(x: 23, y: 6)); p.addLine(to: CGPoint(x: 23, y: 16))
                p.move(to: CGPoint(x: 23, y: 30)); p.addLine(to: CGPoint(x: 23, y: 40))
                p.move(to: CGPoint(x: 6, y: 23)); p.addLine(to: CGPoint(x: 16, y: 23))
                p.move(to: CGPoint(x: 30, y: 23)); p.addLine(to: CGPoint(x: 40, y: 23))
            }
            .stroke(.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: 46, height: 46)
            Circle().fill(.white).frame(width: 5, height: 5)
            Text(String(format: "%.1f×", scale)).font(.system(size: 10, weight: .bold).monospacedDigit()).foregroundStyle(.white)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(Capsule().fill(TimelineStyle.zoom))
                .offset(y: 34)
        }
        .scaleEffect(active ? 1.08 : 1)
        .shadow(color: .black.opacity(0.45), radius: 4, y: 1)
        .animation(DS.Motion.snappy, value: active)
    }
}

/// Export results and confirmations. An exported file can be dragged straight into a browser upload.
struct EditorToastOverlay: View {
    let model: EditorModel
    var body: some View {
        ZStack {
            if let t = model.toast {
                EditorToastView(toast: t) { withAnimation(DS.Motion.gentle) { model.toast = nil } }
                    .id(t.id)
                    .transition(DS.Motion.transition(.move(edge: .bottom).combined(with: .opacity)))
            }
        }
        .animation(DS.Motion.gentle, value: model.toast?.id)
    }
}

struct EditorToastView: View {
    let toast: EditorToast
    let dismiss: () -> Void
    var tint: Color { toast.style.tint }
    var body: some View {
        HStack(spacing: DS.Space.m) {
            if let f = toast.file {
                Image(nsImage: NSWorkspace.shared.icon(forFile: f.path)).resizable().frame(width: 34, height: 34)
                    .onDrag { NSItemProvider(contentsOf: f) ?? NSItemProvider() }
                    .help("Drag the file into a browser upload or another app")
            } else {
                Image(systemName: toast.style.symbol).foregroundStyle(tint).font(.system(size: 13, weight: .semibold))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(toast.text).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                if let d = toast.detail { Text(d).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
            }
            if let f = toast.file {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([f]) }.controlSize(.small)
            }
            Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                .buttonStyle(.borderless).foregroundStyle(.secondary).help("Dismiss").accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, DS.Space.l).padding(.vertical, 10)
        .frame(maxWidth: 520)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous).strokeBorder(Color.white.opacity(0.10)))
        .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
        .accessibilityElement(children: .contain)
    }
}

struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer
    final class View: NSView {
        let playerLayer = AVPlayerLayer()
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer = playerLayer
            playerLayer.videoGravity = .resizeAspect
            playerLayer.backgroundColor = NSColor.black.cgColor
        }
        required init?(coder: NSCoder) { fatalError() }
    }
    func makeNSView(context: Context) -> View { let v = View(); v.playerLayer.player = player; return v }
    func updateNSView(_ v: View, context: Context) { if v.playerLayer.player !== player { v.playerLayer.player = player } }
}
