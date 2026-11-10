import AppKit
import SwiftUI

// The bottom panel: transport and edit tools, then the lanes. Each lane is its own view reading only what it draws,
// so the 60 Hz playhead and a scroll each redraw the least they can.

struct TimelinePanel: View {
    let model: EditorModel

    var body: some View {
        let layout = TimelineLayout.make(hasMic: model.hasMic)
        VStack(spacing: 0) {
            TransportBar(model: model)
            Rectangle().fill(DS.Color.stroke).frame(height: 1)
            HStack(alignment: .top, spacing: 0) {
                TrackHeaders(layout: layout).frame(width: TrackHeaders.width)
                TimelineTracks(model: model, layout: layout)
            }
            .padding(.top, 6).padding(.trailing, DS.Space.m)
            Minimap(model: model).padding(.leading, TrackHeaders.width).padding(.trailing, DS.Space.m).padding(.vertical, 6)
        }
        .background(DS.Color.panel)
    }
}

// MARK: - Transport

struct TransportBar: View {
    let model: EditorModel

    var body: some View {
        HStack(spacing: DS.Space.s) {
            PlayButton(model: model)
            TimeReadout(model: model).frame(minWidth: 168, alignment: .leading)
            Rectangle().fill(DS.Color.stroke).frame(width: 1, height: 20)
            EditToolbar(model: model)
            Spacer(minLength: DS.Space.s)
            TimelineZoomControl(model: model)
        }
        .padding(.horizontal, DS.Space.m)
        .frame(height: 42)
    }
}

struct PlayButton: View {
    let model: EditorModel
    var body: some View {
        let playing = model.playing
        let rate = model.shuttleRate
        Button { model.togglePlay() } label: {
            ZStack {
                Circle().fill(Color.primary.opacity(0.08))
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .offset(x: playing ? 0 : 1)
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: 30, height: 30)
            .overlay(alignment: .bottomTrailing) {
                if abs(rate) > 1 || rate < 0 {
                    Text(rate < 0 ? "◀\(Int(-rate))×" : "\(Int(rate))×").font(.system(size: 8, weight: .bold).monospacedDigit())
                        .padding(.horizontal, 3).padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor)).foregroundStyle(.white)
                        .offset(x: 8, y: 4)
                }
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(playing ? "Pause (Space)" : "Play (Space) · J K L shuttle")
        .accessibilityLabel(playing ? "Pause" : "Play")
    }
}

struct TimeReadout: View {
    let model: EditorModel
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(formatTimecode(model.time, fps: model.project.fps)).font(.system(size: 13, weight: .semibold).monospacedDigit())
            Text("/ " + formatTime(model.duration)).font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
            let kept = model.keptDuration
            if abs(kept - model.duration) > 0.05 {
                Text("· \(formatTime(kept)) kept").font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                    .help("Length after cuts")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Playhead")
    }
}

struct EditToolbar: View {
    let model: EditorModel
    var body: some View {
        let locked = model.editsLocked
        HStack(spacing: 2) {
            ToolButton(title: "Split", systemImage: "scissors", help: "Split at the playhead (S or ⌘B)") { model.split() }
            ToolButton(title: deleteTitle, systemImage: deleteSymbol, help: deleteHelp) { model.deleteSelection() }
            ToolButton(title: "Zoom", systemImage: "plus.magnifyingglass", help: "Add a zoom at the playhead (Z)") { model.addZoom() }
            ToolButton(title: "Marker", systemImage: "flag", help: "Add a marker at the playhead (M)") { model.addMarker() }
            SceneChangeMenu(model: model)
        }
        .disabled(locked)
    }

    private var deleteTitle: String {
        if case .section(let s) = model.selection, !s.kept { return "Restore" }
        return "Delete"
    }
    private var deleteSymbol: String { deleteTitle == "Restore" ? "arrow.uturn.backward.circle" : "delete.left" }
    private var deleteHelp: String {
        switch model.selection {
        case .section(let s): return s.kept ? "Remove the selected section (⌫)" : "Bring the removed section back (⌫)"
        case .scene: return "Delete the selected scene change (⌫)"
        case .zoom: return "Delete the selected zoom (⌫)"
        case .marker: return "Delete the selected marker (⌫)"
        case .none: return "Remove the section under the playhead (⌫)"
        }
    }
}

/// Compact icon-and-title button for the transport row.
struct ToolButton: View {
    let title: String
    let systemImage: String
    let help: String
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.titleAndIcon)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 8).frame(height: 26)
                .foregroundStyle(enabled ? Color.primary.opacity(0.85) : Color.secondary.opacity(0.6))
                .background(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).fill(Color.primary.opacity(hover && enabled ? 0.08 : 0)))
                .contentShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(DS.Motion.snappy, value: hover)
        .help(help)
        .accessibilityLabel(title)
        .accessibilityHint(help)
    }
}

struct SceneChangeMenu: View {
    let model: EditorModel
    var body: some View {
        Menu {
            Section("Change scene at the playhead") {
                ForEach(Array(model.sceneChoices.enumerated()), id: \.element.id) { i, c in
                    Button { model.addSceneChange(c) } label: {
                        Text(c.sceneID == nil && c.template != nil ? "\(c.name) (new)" : c.name)
                    }
                    .shortcutLabel(i < 9 ? KeyEquivalent(Character("\(i + 1)")) : nil, modifiers: .control)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "rectangle.3.group").accessibilityHidden(true)
                Text("Scene")
            }
            .font(.system(size: 12, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
        .padding(.horizontal, 6)
        .help("Change to another scene at the playhead (⌃1…⌃9)")
        .accessibilityLabel("Scene change")
    }
}

extension View {
    /// Shows a shortcut next to a menu item. The editor's key handler sees the key first, so it never fires twice.
    @ViewBuilder func shortcutLabel(_ key: KeyEquivalent?, modifiers: EventModifiers) -> some View {
        if let key = key { self.keyboardShortcut(key, modifiers: modifiers) } else { self }
    }
}

struct TimelineZoomControl: View {
    let model: EditorModel
    var body: some View {
        let fraction = model.axis.zoomFraction
        HStack(spacing: 4) {
            IconButton(systemImage: model.hideRemoved ? "eye.slash" : "eye", help: model.hideRemoved ? "Show removed sections (H)" : "Hide removed sections (H)", isOn: model.hideRemoved, size: 26) {
                model.hideRemoved.toggle()
            }
            Rectangle().fill(DS.Color.stroke).frame(width: 1, height: 18).padding(.horizontal, 4)
            IconButton(systemImage: "minus.magnifyingglass", help: "Zoom out (-)", size: 24) { model.zoomTimeline(in: false) }
            Slider(value: Binding(get: { fraction }, set: { model.setZoomFraction($0) }), in: 0...1)
                .controlSize(.mini)
                .frame(width: 96)
                .accessibilityLabel("Timeline zoom")
            IconButton(systemImage: "plus.magnifyingglass", help: "Zoom in (=)", size: 24) { model.zoomTimeline(in: true) }
            IconButton(systemImage: "arrow.left.and.right.square", help: "Show the whole recording (⇧Z)", size: 24) { model.fitTimeline() }
        }
    }
}

// MARK: - Headers and minimap

struct TrackHeaders: View {
    static let width = 88.0
    let layout: TimelineLayout
    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(layout.lanes.filter { $0.kind != .ruler }, id: \.kind) { lane in
                HStack(spacing: 6) {
                    Image(systemName: lane.symbol).font(.system(size: 10, weight: .medium)).frame(width: 14)
                    Text(lane.title).font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(.secondary)
                .frame(width: Self.width - DS.Space.m, height: lane.height, alignment: .leading)
                .offset(x: DS.Space.m, y: lane.y)
            }
        }
        .frame(height: layout.height, alignment: .topLeading)
        .accessibilityHidden(true)
    }
}

/// The whole recording in a thin strip with the visible window; shown when zoomed in. Drag to scroll.
struct Minimap: View {
    let model: EditorModel
    var body: some View {
        let axis = model.axis
        let sections = TimelineEdits.sections(model.project)
        let markers = model.project.timeline.markers.map(\.tMs)
        let d = max(axis.duration, 0.001)
        GeometryReader { geo in
            let w = geo.size.width
            SwiftUI.Canvas { ctx, size in
                let h = size.height
                ctx.fill(Path(roundedRect: CGRect(x: 0, y: 3, width: w, height: h - 6), cornerRadius: 2), with: .color(.primary.opacity(0.10)))
                for s in sections where !s.kept {
                    let r = CGRect(x: s.startMs / 1000 / d * w, y: 3, width: (s.endMs - s.startMs) / 1000 / d * w, height: h - 6)
                    ctx.fill(Path(r), with: .color(.primary.opacity(0.18)))
                }
                for m in markers { ctx.fill(Path(CGRect(x: m / 1000 / d * w - 0.5, y: 2, width: 1, height: h - 4)), with: .color(DS.Color.warn)) }
                let x0 = axis.visibleStart / d * w, x1 = axis.visibleEnd / d * w
                let win = CGRect(x: x0, y: 0.5, width: max(6, x1 - x0), height: h - 1)
                ctx.fill(Path(roundedRect: win, cornerRadius: 3), with: .color(.accentColor.opacity(0.18)))
                ctx.stroke(Path(roundedRect: win, cornerRadius: 3), with: .color(.accentColor.opacity(0.8)), lineWidth: 1)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                var a = model.axis
                let center = Double(g.location.x / w) * d
                a.offset = a.contentX(center) - a.width / 2
                a.clampOffset()
                model.axis = a
            })
        }
        .frame(height: 12)
        .opacity(axis.isZoomedIn ? 1 : 0)
        .allowsHitTesting(axis.isZoomedIn)
        .help("Drag to scroll the timeline")
        .accessibilityLabel("Timeline overview")
    }
}

// MARK: - Formatting

func formatTimecode(_ s: Double, fps: Double) -> String {
    guard s.isFinite, s >= 0 else { return "0:00.00" }
    let f = max(1, fps.rounded())
    let frames = Int((s * f).rounded())
    let secs = frames / Int(f), frame = frames % Int(f)
    let base = secs >= 3600 ? String(format: "%d:%02d:%02d", secs / 3600, secs / 60 % 60, secs % 60) : String(format: "%d:%02d", secs / 60, secs % 60)
    return base + String(format: ".%02d", frame)
}

/// Ruler labels: whole seconds when the step allows, else tenths.
func formatRuler(_ s: Double, step: Double) -> String {
    if step >= 1 { return formatTime(s) }
    let t = (s * 10).rounded() / 10
    return String(format: "%d:%04.1f", Int(t) / 60, t.truncatingRemainder(dividingBy: 60))
}
