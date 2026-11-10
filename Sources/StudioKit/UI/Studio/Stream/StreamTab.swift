// The sidebar's Stream tab: destination cards with their enable switches and live health, the output settings
// shared by every destination, and the encoder line while live.
import AppKit
import SwiftUI

struct StreamTab: View {
    let state: StudioState
    var body: some View {
        let s = state.streaming
        VStack(alignment: .leading, spacing: DS.Space.xl) {
            if s.destinations.isEmpty {
                StreamEmptyState(streaming: s)
            } else {
                DestinationList(streaming: s)
                if s.isActive && !s.canvases.isEmpty { EncoderSection(streaming: s) }
            }
            StreamSettingsSection(streaming: s)
        }
    }
}

struct StreamEmptyState: View {
    let streaming: StreamingState
    var body: some View {
        VStack(spacing: DS.Space.m) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 26, weight: .light)).foregroundStyle(.secondary)
                .frame(width: 60, height: 60)
                .background(Circle().fill(Color.primary.opacity(0.06)))
            Text("Go live everywhere at once").font(.system(size: 15, weight: .semibold))
            Text("Add Twitch, YouTube, Kick or your own server once. Then press Go Live to stream to all of them. Stream keys stay in your Keychain.")
                .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: DS.Space.s) {
                ForEach(Destination.Service.allCases) { service in
                    Button { streaming.editor = DestinationEditorRequest(destination: nil, service: service) } label: {
                        VStack(spacing: 5) {
                            ServiceTile(service: service, size: 30)
                            Text(service == .custom ? "Custom" : service.preset.title).font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(.secondary).lineLimit(1)
                        }
                        .frame(width: 58, height: 62)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(TileButtonStyle())
                    .help("Add \(service.preset.title)")
                }
            }
            .padding(.top, DS.Space.xs)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.Space.l)
    }
}

/// Hover and press highlight for the service tiles.
struct TileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { TileBody(configuration: configuration) }
    private struct TileBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var hover = false
        var body: some View {
            configuration.label
                .background(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : hover ? 0.07 : 0)))
                .scaleEffect(configuration.isPressed && !DS.Motion.reduceMotion ? 0.96 : 1)
                .onHover { hover = $0 }
                .animation(DS.Motion.snappy, value: hover)
                .animation(DS.Motion.snappy, value: configuration.isPressed)
        }
    }
}

struct DestinationList: View {
    let streaming: StreamingState
    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack {
                Text("DESTINATIONS").font(.system(size: 10, weight: .semibold)).kerning(0.6).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    ForEach(Destination.Service.allCases) { service in
                        Button(service.preset.title + "…") { streaming.editor = DestinationEditorRequest(destination: nil, service: service) }
                    }
                } label: {
                    Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                } primaryAction: {
                    streaming.editor = DestinationEditorRequest(destination: nil, service: nil)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Add a destination")
                .accessibilityLabel("Add destination")
            }
            .padding(.horizontal, DS.Space.xs)
            VStack(spacing: 6) {
                ForEach(streaming.destinations) { d in DestinationCard(streaming: streaming, destination: d) }
            }
        }
    }
}

struct DestinationCard: View {
    let streaming: StreamingState
    let destination: Destination
    @State private var hover = false

    var body: some View {
        let d = destination, h = streaming.health(d.id)
        HStack(spacing: DS.Space.m) {
            ServiceTile(service: d.service, size: 30)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(d.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    CanvasBadge(canvas: d.canvas)
                }
                DestinationStatusLine(destination: d, health: h, streaming: streaming.isActive, compact: true) { streaming.actions.retry(d.id) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle(d.name, isOn: Binding(get: { d.enabled }, set: { streaming.actions.setEnabled(d.id, $0) }))
                .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                .help(streaming.isActive ? (d.enabled ? "Stop streaming to \(d.name)" : "Start streaming to \(d.name)")
                                         : (d.enabled ? "\(d.name) is included when you go live" : "Include \(d.name) when you go live"))
        }
        .padding(.horizontal, DS.Space.m).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
            .fill(Color.primary.opacity(hover ? 0.075 : 0.045)))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
            .strokeBorder(borderColor(h.status), lineWidth: 1))
        .opacity(d.enabled || h.status != .off ? 1 : 0.62)
        .contentShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .onTapGesture { streaming.editor = DestinationEditorRequest(destination: d) }
        .onHover { hover = $0 }
        .animation(DS.Motion.snappy, value: hover)
        .animation(DS.Motion.snappy, value: d.enabled)
        .contextMenu {
            Button("Edit…") { streaming.editor = DestinationEditorRequest(destination: d) }
            if let url = d.service.preset.helpURL { Button("Open \(d.service.preset.title) Stream Settings") { NSWorkspace.shared.open(url) } }
            Divider()
            Button("Delete", role: .destructive) { streaming.actions.delete(d.id) }.disabled(streaming.isActive && h.status.isActive)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Edit destination")
    }

    private func borderColor(_ s: DestinationStatus) -> Color {
        switch s {
        case .live: DS.Color.ok.opacity(0.35)
        case .failed: DS.Color.record.opacity(0.5)
        case .reconnecting: DS.Color.warn.opacity(0.45)
        default: DS.Color.stroke
        }
    }
}

struct EncoderSection: View {
    let streaming: StreamingState
    var body: some View {
        InspectorSection(title: "Encoder") {
            ForEach(streaming.canvases, id: \.canvas) { c in
                HStack(spacing: DS.Space.s) {
                    Image(systemName: c.canvas == .wide ? "rectangle" : "rectangle.portrait").font(.system(size: 10)).foregroundStyle(.secondary)
                    Text(String(format: "%.0f fps", c.fps)).font(.system(size: 12, weight: .medium).monospacedDigit())
                    Spacer()
                    Text(String(format: "render %.1f · encode %.1f ms", c.renderMs, c.encodeMs))
                        .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                }
                .help(StreamFormat.canvasLine(c))
            }
        }
    }
}

struct StreamSettingsSection: View {
    let streaming: StreamingState
    @State private var draftKbps: Double?
    @State private var draftDelay: Double?

    var body: some View {
        let s = streaming.settings, live = streaming.isActive
        InspectorSection(title: "Output") {
            InspectorRow(label: "Resolution") {
                SegmentedSwitch(selection: binding(\.resolution), options: [
                    .init(value: 1080, label: "1080p", help: "1920×1080, or 1080×1920 vertical"),
                    .init(value: 720, label: "720p", help: "1280×720, or 720×1280 vertical"),
                ]).frame(width: 140)
            }
            .disabled(live)
            Picker("When the encoder is overloaded", selection: Binding(get: { streaming.settings.overloadPolicy }, set: { value in
                var settings = streaming.settings; settings.overloadPolicy = value; streaming.actions.updateSettings(settings)
            })) {
                ForEach(EncoderOverloadPolicy.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            InspectorRow(label: "Frame rate") {
                SegmentedSwitch(selection: binding(\.fps), options: [
                    .init(value: 60, label: "60 fps", help: "Smoothest motion; needs more bitrate"),
                    .init(value: 30, label: "30 fps", help: "For slower uploads"),
                ]).frame(width: 140)
            }
            .disabled(live)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Bitrate").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Text(StreamFormat.kbps(Int(draftKbps ?? Double(s.videoKbps))))
                        .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                }
                Slider(value: Binding(get: { draftKbps ?? Double(s.videoKbps) }, set: { draftKbps = ($0 / 250).rounded() * 250 }),
                       in: Double(StreamSettings.bitrateRange.lowerBound)...Double(StreamSettings.bitrateRange.upperBound)) { editing in
                    if !editing, let v = draftKbps { var n = streaming.settings; n.videoKbps = Int(v); streaming.actions.updateSettings(n); draftKbps = nil }
                }
                .controlSize(.small)
                .accessibilityLabel("Video bitrate")
                Text(uploadLine(kbps: Int(draftKbps ?? Double(s.videoKbps))))
                    .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                if let warning = twitchWarning(kbps: Int(draftKbps ?? Double(s.videoKbps))) {
                    Label(warning, systemImage: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(DS.Color.warn)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .disabled(live)
            .help("Video bitrate for every destination. Each destination uploads its own copy.")
            if live {
                Text("Resolution, frame rate and bitrate apply the next time you go live.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Divider().opacity(0.4)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Mic delay").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.0f ms", draftDelay ?? s.micDelayMs)).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                }
                Slider(value: Binding(get: { draftDelay ?? s.micDelayMs }, set: { draftDelay = ($0 / 10).rounded() * 10 }), in: 0...500) { editing in
                    if !editing, let v = draftDelay { var n = streaming.settings; n.micDelayMs = v; streaming.actions.updateSettings(n); draftDelay = nil }
                }
                .controlSize(.small)
                .accessibilityLabel("Microphone delay")
            }
            .help("Delays your voice in the stream to match the game picture. Applies immediately.")
        }
    }

    private func binding(_ key: WritableKeyPath<StreamSettings, Int>) -> Binding<Int> {
        Binding(get: { streaming.settings[keyPath: key] }, set: { var n = streaming.settings; n[keyPath: key] = $0; streaming.actions.updateSettings(n) })
    }
    private func uploadLine(kbps: Int) -> String {
        var s = streaming.settings; s.videoKbps = kbps
        return StreamPlanner.uploadSummary(enabled: streaming.enabledCount, settings: s)
    }
    private func twitchWarning(kbps: Int) -> String? {
        guard kbps > 6000, streaming.destinations.contains(where: { $0.enabled && $0.service == .twitch }) else { return nil }
        return "Twitch may reject more than 6,000 kbps."
    }
}
