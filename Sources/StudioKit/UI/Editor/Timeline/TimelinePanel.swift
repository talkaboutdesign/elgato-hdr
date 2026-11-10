import AppKit
import AVFoundation
import SwiftUI

// MARK: - Timeline

struct TimelinePanel: View {
    @Bindable var model: EditorModel

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Button { model.togglePlay() } label: {
                    Image(systemName: model.playing ? "pause.fill" : "play.fill").frame(width: 18)
                }
                .keyboardShortcut(.space, modifiers: [])
                .buttonStyle(.borderless).font(.title3)
                Text("\(formatTimePrecise(model.time)) / \(formatTime(model.duration))").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                Text("Trimmed: \(formatTime(max(0, model.trimEnd - model.trimStart)))").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                Button("Set In") { model.setIn() }.keyboardShortcut("i", modifiers: [])
                Button("Set Out") { model.setOut() }.keyboardShortcut("o", modifiers: [])
                Button("Reset") { model.update("Reset In and Out") { $0.trimStartMs = 0; $0.trimEndMs = 0 } }
                    .disabled(model.project.trimStartMs == 0 && model.project.trimEndMs == 0)
            }
            HStack(spacing: 12) {
                Button("Split") { model.split() }.keyboardShortcut("b", modifiers: .command)
                Button("Delete Section") { model.deleteSection() }
                Button("Add Zoom Here") { model.addZoom() }
                Spacer()
            }
            LayerLanes(model: model).frame(height: 24 + 22 * CGFloat(1 + (model.hasCamera ? 1 : 0) + (model.hasMic ? 1 : 0)))
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(.bar)
    }
}

/// Ruler, one lane per layer (shifted by its sync offset), trim handles and the playhead.
struct LayerLanes: View {
    @Bindable var model: EditorModel
    @State private var draggingTrim: Int?   // 0 in, 1 out

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, d = max(model.duration, 0.001)
            let x = { (t: Double) -> CGFloat in CGFloat(t / d) * w }
            let lanes: [(String, String, Color, Double)] = [("Game", "gamecontroller.fill", .blue, 0)]
                + (model.hasCamera ? [("Camera", "video.fill", .green, (model.project.camera?.offsetMs ?? 0) / 1000)] : [])
                + (model.hasMic ? [("Mic", "mic.fill", .orange, (model.project.mic?.offsetMs ?? 0) / 1000)] : [])
            ZStack(alignment: .topLeading) {
                // Ruler / scrub area
                Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 18)
                    .overlay(alignment: .leading) {
                        ForEach(Array(stride(from: 0.0, through: d, by: tick(d))), id: \.self) { t in
                            Text(formatTime(t)).font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary)
                                .position(x: x(t) + 14, y: 9)
                        }
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { g in model.seek(Double(g.location.x / w) * d) })
                ForEach(Array(lanes.enumerated()), id: \.offset) { i, lane in
                    let y = 24 + CGFloat(i) * 22
                    let start = max(0, lane.3)
                    RoundedRectangle(cornerRadius: 4).fill(lane.2.opacity(0.75))
                        .frame(width: max(0, x(d) - x(start)), height: 18)
                        .overlay(alignment: .leading) {
                            Label(lane.0, systemImage: lane.1).font(.system(size: 10, weight: .medium)).foregroundStyle(.white).padding(.leading, 6)
                        }
                        .offset(x: x(start), y: y)
                }
                // Dim what's trimmed away
                Rectangle().fill(Color.black.opacity(0.45)).frame(width: x(model.trimStart), height: geo.size.height).allowsHitTesting(false)
                Rectangle().fill(Color.black.opacity(0.45)).frame(width: max(0, w - x(model.trimEnd)), height: geo.size.height)
                    .offset(x: x(model.trimEnd)).allowsHitTesting(false)
                trimHandle(at: x(model.trimStart), height: geo.size.height, leading: true)
                    .gesture(DragGesture().onChanged { g in
                        model.beginGesture()
                        let t = min(max(0, Double(g.location.x / w) * d), model.trimEnd - 0.5)
                        model.update("Trim") { $0.trimStartMs = t * 1000 }; model.seek(t)
                    }.onEnded { _ in model.endGesture() })
                trimHandle(at: x(model.trimEnd), height: geo.size.height, leading: false)
                    .gesture(DragGesture().onChanged { g in
                        model.beginGesture()
                        let t = max(min(d, Double(g.location.x / w) * d), model.trimStart + 0.5)
                        model.update("Trim") { $0.trimEndMs = t >= d - 0.01 ? 0 : t * 1000 }; model.seek(t)
                    }.onEnded { _ in model.endGesture() })
                // Playhead
                Rectangle().fill(Color.red).frame(width: 2, height: geo.size.height).offset(x: x(model.time) - 1).allowsHitTesting(false)
            }
        }
    }

    func trimHandle(at px: CGFloat, height: CGFloat, leading: Bool) -> some View {
        RoundedRectangle(cornerRadius: 2).fill(Color.yellow)
            .frame(width: 6, height: height)
            .frame(width: 16).contentShape(Rectangle())
            .offset(x: px - 8)
            .onHover { $0 ? NSCursor.resizeLeftRight.push() : NSCursor.pop() }
            .help(leading ? "Trim start (I)" : "Trim end (O)")
    }

    func tick(_ d: Double) -> Double { [1, 5, 10, 15, 30, 60, 120, 300, 600].first { d / $0 <= 10 } ?? 1200 }
}

