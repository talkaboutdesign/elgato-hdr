import AppKit
import AVFoundation
import SwiftUI

/// The aspect-fitted canvas preview with direct manipulation on top.
struct PreviewStage: View {
    @Bindable var model: EditorModel

    var body: some View {
        ZStack {
            Color(white: 0.09)
            ZStack {
                PlayerLayerView(player: model.player)
                StageInteraction(model: model)
            }
            .aspectRatio(model.canvas.aspect, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .shadow(color: .black.opacity(0.5), radius: 12)
            .padding(24)
            if let e = model.loadError {
                Text(e).foregroundStyle(.white).padding(10).background(.red.opacity(0.8), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .frame(minHeight: 300)
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
    @Bindable var model: EditorModel
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
