// The toolbar's Go Live button and its two popovers. Idle: "Go Live" with a count of enabled destinations; a click
// opens a checklist with a prominent confirm button, so going live always takes two deliberate clicks. Live: the
// button reads "LIVE 12:34" and opens per-destination health with End Stream.
import AppKit
import SwiftUI

struct GoLiveControl: View {
    let state: StudioState

    var body: some View {
        @Bindable var s = state.streaming
        GoLivePill(streaming: state.streaming) { s.showGoLivePopover.toggle() }
            .popover(isPresented: $s.showGoLivePopover, arrowEdge: .bottom) {
                Group {
                    if s.isActive { HealthPopover(streaming: s) } else { GoLivePopover(state: state) }
                }
                .environment(\.colorScheme, .dark)
            }
    }
}

struct GoLivePill: View {
    let streaming: StreamingState
    let action: () -> Void
    @State private var hover = false
    @State private var pressed = false

    var body: some View {
        let count = streaming.enabledCount
        Button(action: action) {
            Group {
                switch streaming.phase {
                case .live(let since): live(since)
                case .connecting: connecting
                default: idle(count)
                }
            }
            .font(.system(size: 13, weight: .semibold))
            .padding(.leading, 10).padding(.trailing, 11).frame(height: 28)
            .background(Capsule().fill(fill))
            .overlay(Capsule().strokeBorder(Color.white.opacity(streaming.isActive || count > 0 ? 0.18 : 0.08)))
            .contentShape(Capsule())
            .scaleEffect(pressed ? 0.97 : 1)
        }
        .buttonStyle(PressTracking(pressed: $pressed))
        .onHover { hover = $0 }
        .animation(DS.Motion.snappy, value: hover)
        .animation(DS.Motion.snappy, value: pressed)
        .animation(DS.Motion.snappy, value: streaming.phase)
        .help(help)
        .accessibilityLabel(accessibility)
    }

    private var fill: Color {
        if streaming.isActive { return DS.Color.live.opacity(hover ? 1 : 0.9) }
        return streaming.enabledCount > 0 ? DS.Color.live.opacity(hover ? 0.95 : 0.82) : Color.white.opacity(hover ? 0.14 : 0.08)
    }

    private func idle(_ count: Int) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 12, weight: .semibold))
            Text("Go Live")
            if count > 0 {
                Text("\(count)").font(.system(size: 11, weight: .bold).monospacedDigit())
                    .foregroundStyle(DS.Color.live)
                    .frame(minWidth: 17, minHeight: 17)
                    .background(Circle().fill(Color.white))
                    .contentTransition(.numericText())
            }
        }
        .foregroundStyle(count > 0 ? Color.white : Color.primary)
    }

    private var connecting: some View {
        HStack(spacing: 7) {
            ProgressView().controlSize(.mini).tint(.white)
            Text("Connecting…")
        }
        .foregroundStyle(.white)
    }

    private func live(_ since: Date) -> some View {
        SwiftUI.TimelineView(.periodic(from: since, by: 1)) { context in
            HStack(spacing: 6) {
                Circle().fill(Color.white).frame(width: 7, height: 7)
                Text("LIVE").kerning(0.6)
                Text(StudioFormat.elapsed(context.date.timeIntervalSince(since)))
                    .monospacedDigit().contentTransition(.numericText())
                if problems > 0 {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(Color.yellow)
                        .help("\(problems) destination\(problems == 1 ? "" : "s") need attention")
                }
            }
            .foregroundStyle(.white)
        }
    }

    private var problems: Int {
        streaming.destinations.filter {
            switch streaming.health($0.id).status { case .reconnecting, .failed: return true; default: return $0.enabled && streaming.health($0.id).slowUpload }
        }.count
    }
    private var help: String {
        if streaming.isActive { return "Stream health and End Stream (⇧⌘L)" }
        let n = streaming.enabledCount
        return n == 0 ? "Choose where to stream (⇧⌘L)" : "Go live to \(n) destination\(n == 1 ? "" : "s") (⇧⌘L)"
    }
    private var accessibility: String {
        switch streaming.phase {
        case .live: "Live. Show stream health"
        case .connecting: "Connecting. Show stream health"
        default: "Go Live, \(streaming.enabledCount) destinations on"
        }
    }
}

// MARK: - Idle popover

struct GoLivePopover: View {
    let state: StudioState
    var body: some View {
        let s = state.streaming
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Go Live").font(.system(size: 15, weight: .semibold))
                Text(s.destinations.isEmpty ? "Add where you want to stream first." : "Choose where to stream.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, DS.Space.l).padding(.top, DS.Space.l).padding(.bottom, DS.Space.m)

            if s.destinations.isEmpty {
                HStack(spacing: DS.Space.s) {
                    ForEach(Destination.Service.allCases) { service in ServiceTile(service: service, size: 26) }
                }
                .padding(.horizontal, DS.Space.l).padding(.bottom, DS.Space.l)
                Divider().opacity(0.5)
                Button { s.showGoLivePopover = false; s.actions.addDestination() } label: {
                    Label("Add Destination…", systemImage: "plus").frame(maxWidth: .infinity)
                }
                .controlSize(.large).buttonStyle(.borderedProminent)
                .padding(DS.Space.l)
            } else {
                Divider().opacity(0.5)
                VStack(spacing: 2) {
                    ForEach(s.destinations) { d in
                        HStack(spacing: DS.Space.m) {
                            ServiceTile(service: d.service, size: 26)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(d.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                Text(failure(d) ?? d.host).font(.system(size: 11))
                                    .foregroundStyle(failure(d) == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(DS.Color.record)).lineLimit(1)
                            }
                            Spacer(minLength: DS.Space.s)
                            CanvasBadge(canvas: d.canvas)
                            Toggle(d.name, isOn: Binding(get: { d.enabled }, set: { s.actions.setEnabled(d.id, $0) }))
                                .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                        }
                        .padding(.horizontal, DS.Space.l).padding(.vertical, 7)
                        .opacity(d.enabled ? 1 : 0.6)
                    }
                }
                .padding(.vertical, DS.Space.xs)
                Divider().opacity(0.5)
                VStack(alignment: .leading, spacing: DS.Space.m) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: "\(s.settings.resolution)p\(s.settings.fps) · \(StreamFormat.kbps(s.settings.videoKbps))")
                        Text(verbatim: s.uploadSummary)
                    }
                    .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                    Button { s.showGoLivePopover = false; s.actions.goLive() } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "dot.radiowaves.left.and.right")
                            Text(s.enabledCount == 0 ? "Turn On a Destination" : s.enabledCount == 1 ? "Go Live" : "Go Live to \(s.enabledCount) Destinations")
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity).frame(height: 32)
                        .foregroundStyle(.white)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(DS.Color.live.opacity(s.enabledCount == 0 ? 0.35 : 1)))
                        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(s.enabledCount == 0)
                    .keyboardShortcut(.defaultAction)
                    Button("Edit Destinations…") { s.showGoLivePopover = false; s.actions.showStreamTab() }
                        .buttonStyle(.link).font(.system(size: 12)).frame(maxWidth: .infinity)
                }
                .padding(DS.Space.l)
            }
        }
        .frame(width: 340)
    }

    /// A destination that failed last time keeps its reason visible here.
    private func failure(_ d: Destination) -> String? {
        if case .failed(let why) = state.streaming.health(d.id).status { return why }
        return nil
    }
}

// MARK: - Health popover

struct HealthPopover: View {
    let streaming: StreamingState
    var body: some View {
        let s = streaming
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DS.Space.s) {
                if let since = s.liveSince {
                    SwiftUI.TimelineView(.periodic(from: since, by: 1)) { ctx in
                        HStack(spacing: 6) {
                            Circle().fill(DS.Color.live).frame(width: 8, height: 8)
                            Text("LIVE").font(.system(size: 13, weight: .bold)).kerning(0.6).foregroundStyle(DS.Color.live)
                            Text(StudioFormat.elapsed(ctx.date.timeIntervalSince(since))).font(.system(size: 13, weight: .semibold).monospacedDigit())
                        }
                    }
                } else {
                    ProgressView().controlSize(.small)
                    Text("Connecting…").font(.system(size: 13, weight: .semibold))
                }
                Spacer()
                Button(role: .destructive) { s.showGoLivePopover = false; s.actions.endStream() } label: {
                    Text("End Stream").font(.system(size: 12, weight: .semibold)).padding(.horizontal, 4)
                }
                .controlSize(.regular).tint(DS.Color.record).buttonStyle(.borderedProminent)
                .help("Stop streaming to every destination")
            }
            .padding(DS.Space.l)

            Divider().opacity(0.5)
            VStack(spacing: 0) {
                ForEach(s.destinations.filter { $0.enabled || s.health($0.id).status != .off }) { d in
                    HStack(alignment: .top, spacing: DS.Space.m) {
                        ServiceTile(service: d.service, size: 26)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(d.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                CanvasBadge(canvas: d.canvas)
                            }
                            DestinationStatusLine(destination: d, health: s.health(d.id), streaming: true) { s.actions.retry(d.id) }
                        }
                        Spacer(minLength: DS.Space.s)
                        Toggle(d.name, isOn: Binding(get: { d.enabled }, set: { s.actions.setEnabled(d.id, $0) }))
                            .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                            .help(d.enabled ? "Stop streaming to \(d.name)" : "Start streaming to \(d.name)")
                    }
                    .padding(.horizontal, DS.Space.l).padding(.vertical, 9)
                }
                let off = s.destinations.filter { !$0.enabled && s.health($0.id).status == .off }
                if !off.isEmpty {
                    Menu {
                        ForEach(off) { d in Button("\(d.name) (\(d.canvas.label))") { s.actions.setEnabled(d.id, true) } }
                    } label: { Label("Add a destination to this stream", systemImage: "plus.circle") }
                        .menuStyle(.borderlessButton).fixedSize().font(.system(size: 12))
                        .padding(.horizontal, DS.Space.l).padding(.vertical, DS.Space.s)
                }
            }
            .padding(.vertical, DS.Space.xs)

            if !s.canvases.isEmpty {
                Divider().opacity(0.5)
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(s.canvases, id: \.canvas) { c in
                        Text(StreamFormat.canvasLine(c)).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, DS.Space.l).padding(.vertical, DS.Space.m)
            }
        }
        .frame(width: 360)
    }
}
