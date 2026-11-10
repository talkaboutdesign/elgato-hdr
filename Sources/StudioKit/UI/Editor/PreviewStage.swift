import AppKit
import AVFoundation
import SwiftUI

/// The aspect-fitted canvas preview. On top: the zoom focus target while a zoom block is selected, otherwise the
/// camera and game direct manipulation of the active legacy-layout scene.
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

/// Picks the overlay; reading the playhead here keeps that 60 Hz read out of the stage's body.
struct StageOverlay: View {
    let model: EditorModel
    var body: some View {
        if case .zoom(let id) = model.selection {
            FocusTargetOverlay(model: model, id: id)
        } else if editableSceneShowing && !model.editsLocked {
            StageInteraction(model: model)
        }
    }
    private var editableSceneShowing: Bool {
        let p = model.project
        let id = p.timeline.activeSceneID(atSourceMs: model.playheadMs) ?? p.scenes.first?.id
        return p.scenes.first { $0.id == id }?.composition(model.canvas).legacyLayout != nil
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
    var tint: Color {
        switch toast.style { case .info: .accentColor; case .success: DS.Color.ok; case .warning: DS.Color.warn; case .error: DS.Color.record }
    }
    var body: some View {
        HStack(spacing: DS.Space.m) {
            if let f = toast.file {
                Image(nsImage: NSWorkspace.shared.icon(forFile: f.path)).resizable().frame(width: 34, height: 34)
                    .onDrag { NSItemProvider(contentsOf: f) ?? NSItemProvider() }
                    .help("Drag the file into a browser upload or another app")
            } else {
                Image(systemName: Toast(text: "", style: toast.style).symbol).foregroundStyle(tint).font(.system(size: 15, weight: .semibold))
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

/// Drag the camera window (snaps to corners/edges), drag its corner to resize, drag the game to reframe it, and drag
/// the divider of a split layout.
struct StageInteraction: View {
    let model: EditorModel
    @State private var hover = false
    @State private var moveStart: (CGPoint, CameraPlacement)?
    @State private var panStart: (Double, Double)?
    @State private var resizing = false

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let l = model.layout
            let showCam = model.hasCamera && (l.kind == .pip)
            let camRect = l.camera.rect(in: size)
            let screenRegion = l.kind == .stacked && model.hasCamera
                ? CGRect(x: 0, y: size.height * l.split, width: size.width, height: size.height * (1 - l.split))
                : CGRect(origin: .zero, size: size)
            ZStack(alignment: .topLeading) {
                // Game framing (pan) on the whole stage.
                Color.clear.contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 2)
                        .onChanged { g in model.beginGesture(); pan(g, region: screenRegion) }
                        .onEnded { _ in panStart = nil; model.endGesture() })
                    .help(l.kind == .cameraOnly ? "" : "Drag to reframe the game")

                if l.kind == .stacked && model.hasCamera {
                    Rectangle().fill(Color.white.opacity(0.001)).frame(width: size.width, height: 16)
                        .overlay(Capsule().fill(.white.opacity(0.85)).frame(width: 44, height: 5).shadow(radius: 2))
                        .position(x: size.width / 2, y: size.height * l.split)
                        .gesture(DragGesture()
                            .onChanged { g in model.beginGesture(); model.binding(\.split).wrappedValue = min(0.7, max(0.2, g.location.y / size.height)) }
                            .onEnded { _ in model.endGesture() })
                        .onHover { $0 ? NSCursor.resizeUpDown.push() : NSCursor.pop() }
                }

                if showCam {
                    let r = l.camera.radius(for: camRect)
                    RoundedRectangle(cornerRadius: r + 3, style: .circular)
                        .strokeBorder(.white.opacity(hover || moveStart != nil || resizing ? 0.9 : 0), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                        .frame(width: camRect.width + 6, height: camRect.height + 6)
                        .contentShape(RoundedRectangle(cornerRadius: r))
                        .position(x: camRect.midX, y: camRect.midY)
                        .onHover { hover = $0; $0 ? NSCursor.openHand.push() : NSCursor.pop() }
                        .gesture(DragGesture(minimumDistance: 1)
                            .onChanged { g in
                                model.beginGesture()
                                if moveStart == nil { moveStart = (CGPoint(x: g.startLocation.x - camRect.midX, y: g.startLocation.y - camRect.midY), l.camera) }
                                guard let (grab, start) = moveStart else { return }
                                var p = start
                                p.move(to: CGPoint(x: g.location.x - grab.x, y: g.location.y - grab.y), canvas: size, snap: !NSEvent.modifierFlags.contains(.option))
                                model.binding(\.camera).wrappedValue = p
                            }
                            .onEnded { _ in moveStart = nil; model.endGesture() })
                    ForEach(0..<4, id: \.self) { i in
                        let c = CGPoint(x: i % 2 == 0 ? camRect.minX : camRect.maxX, y: i < 2 ? camRect.minY : camRect.maxY)
                        Circle().fill(.white).frame(width: 10, height: 10).shadow(radius: 1.5)
                            .opacity(hover || resizing ? 1 : 0)
                            .frame(width: 22, height: 22).contentShape(Rectangle())
                            .position(c)
                            .onHover { h in hover = h || hover; h ? NSCursor.crosshair.push() : NSCursor.pop() }
                            .gesture(DragGesture()
                                .onChanged { g in
                                    model.beginGesture()
                                    resizing = true
                                    var p = l.camera
                                    let a = p.aspect.value
                                    let halfShort = max(abs(g.location.x - camRect.midX) / (a >= 1 ? a : 1), abs(g.location.y - camRect.midY) * (a >= 1 ? 1 : a))
                                    p.size = min(1, max(0.08, Double(2 * halfShort / min(size.width, size.height))))
                                    model.binding(\.camera).wrappedValue = p
                                }
                                .onEnded { _ in resizing = false; model.endGesture() })
                    }
                }
            }
        }
    }

    private func pan(_ g: DragGesture.Value, region: CGRect) {
        let l = model.layout
        guard l.kind != .cameraOnly else { return }
        if panStart == nil { panStart = (l.panX, l.panY) }
        guard let (x0, y0) = panStart, let b = modelScreenSize() else { return }
        let crop = l.fit ? LayoutMath.fillCrop(sourceSize: b, dst: b, zoom: l.zoom, panX: l.panX, panY: l.panY)
                         : LayoutMath.fillCrop(sourceSize: b, dst: region.size, zoom: l.zoom, panX: l.panX, panY: l.panY)
        var nl = l
        nl.panX = min(1, max(0, x0 - Double(g.translation.width / region.width) * crop.width))
        nl.panY = min(1, max(0, y0 - Double(g.translation.height / region.height) * crop.height))
        model.layout = nl
    }
    private func modelScreenSize() -> CGSize? {
        let p = model.project
        return p.width > 0 ? CGSize(width: p.width, height: p.height) : CGSize(width: 16, height: 9)
    }
}
