// Small pieces shared by the Stream tab, the add/edit sheet and the Go Live popovers.
import AppKit
import SwiftUI

extension Color {
    init(rgb: UInt32) {
        self.init(.sRGB, red: Double(rgb >> 16 & 0xFF) / 255, green: Double(rgb >> 8 & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255)
    }
}

/// Monogram tile for a service: a coloured rounded square with a letter. No platform logos are bundled.
struct ServiceTile: View {
    let service: Destination.Service
    var size: CGFloat = 28
    var body: some View {
        let p = service.preset
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(LinearGradient(colors: [Color(rgb: p.tint).opacity(0.92), Color(rgb: p.tint)], startPoint: .top, endPoint: .bottom))
            .overlay {
                if service == .custom {
                    Image(systemName: "server.rack").font(.system(size: size * 0.46, weight: .semibold))
                } else {
                    Text(p.monogram).font(.system(size: size * 0.56, weight: .heavy, design: .rounded))
                }
            }
            .foregroundStyle(p.darkMonogram ? Color.black.opacity(0.85) : Color.white)
            .overlay(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).strokeBorder(Color.white.opacity(0.14)))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct CanvasBadge: View {
    let canvas: Canvas
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: canvas == .wide ? "rectangle" : "rectangle.portrait").font(.system(size: 8, weight: .semibold))
            Text(canvas.label).font(.system(size: 10, weight: .semibold).monospacedDigit())
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6).frame(height: 18)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
        .overlay(Capsule().strokeBorder(DS.Color.stroke))
        .help(canvas.title)
        .accessibilityLabel(canvas.title)
    }
}

/// Connecting amber, live green, reconnecting amber pulsing, failed red.
struct StatusDot: View {
    let status: DestinationStatus
    var size: CGFloat = 8
    @State private var pulse = false
    var color: Color {
        switch status {
        case .off: Color.secondary.opacity(0.5)
        case .connecting, .reconnecting: DS.Color.warn
        case .live: DS.Color.ok
        case .failed: DS.Color.record
        }
    }
    var pulsing: Bool { if case .reconnecting = status { return true }; return false }
    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
            .shadow(color: status == .live ? color.opacity(0.7) : .clear, radius: 3)
            .opacity(pulsing && pulse ? 0.3 : 1)
            .animation(pulsing && !DS.Motion.reduceMotion ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default, value: pulse)
            .onAppear { pulse = true }
            .accessibilityHidden(true)
    }
}

enum StreamFormat {
    static func mbps(_ kbps: Double) -> String {
        kbps >= 1000 ? String(format: "%.1f Mbps", kbps / 1000) : String(format: "%.0f kbps", max(0, kbps))
    }
    static func kbps(_ v: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal
        return (f.string(from: NSNumber(value: v)) ?? "\(v)") + " kbps"
    }
    static func statusTitle(_ s: DestinationStatus) -> String {
        switch s {
        case .off: "Off"
        case .connecting: "Connecting…"
        case .live: "Live"
        case .reconnecting(let n): n > 1 ? "Reconnecting (attempt \(n))…" : "Reconnecting…"
        case .failed(let why): why
        }
    }
    /// "6.1 Mbps · 0 dropped · 12:01" while live; `compact` (the narrow sidebar card) mentions drops only when there are some.
    static func liveLine(_ h: DestinationHealth, now: Date, compact: Bool = false) -> String {
        var parts = [mbps(h.kbps)]
        if !compact || h.dropped > 0 { parts.append("\(h.dropped) dropped") }
        if let since = h.liveSince { parts.append(StudioFormat.elapsed(now.timeIntervalSince(since))) }
        return parts.joined(separator: " · ")
    }
    /// Encoder line per canvas: "16:9 · 60 fps · render 1.2 ms · encode 3.4 ms".
    static func canvasLine(_ c: CanvasHealth) -> String {
        String(format: "%@ · %.0f fps · render %.1f ms · encode %.1f ms", c.canvas.label, c.fps, c.renderMs, c.encodeMs)
            + (c.dropped > 0 ? " · \(c.dropped) dropped" : "")
    }
}

/// Second line of a destination row: host when idle, health while streaming. Shared by the card and the popover.
struct DestinationStatusLine: View {
    let destination: Destination
    let health: DestinationHealth
    let streaming: Bool
    var compact = false
    var retry: (() -> Void)? = nil

    var body: some View {
        if streaming && health.status != .off {
            SwiftUI.TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        StatusDot(status: health.status, size: 6)
                        Text(text(now: context.date))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(isFailed ? AnyShapeStyle(DS.Color.record) : AnyShapeStyle(.secondary))
                            .lineLimit(1).truncationMode(.tail)
                        if isFailed, let retry {
                            Button("Retry", action: retry).buttonStyle(.link).font(.system(size: 11, weight: .semibold))
                                .help("Try \(destination.name) again")
                        }
                    }
                    if let hint {
                        // The server's own words for a failure; a warning for problems that may still clear up.
                        Label(hint, systemImage: isFailed ? "text.bubble" : "exclamationmark.triangle.fill")
                            .font(.system(size: 10.5)).foregroundStyle(isFailed ? AnyShapeStyle(.secondary) : AnyShapeStyle(DS.Color.warn))
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .help(health.detail ?? "")
        } else {
            Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
    }

    private var isFailed: Bool { if case .failed = health.status { return true }; return false }
    private var subtitle: String {
        if case .failed(let why) = health.status { return why }
        let host = destination.host
        return host.isEmpty ? "No server URL yet" : host
    }
    private var hint: String? {
        if health.slowUpload { return "Upload too slow for this bitrate" }
        switch health.status {
        case .reconnecting, .failed: return health.detail.flatMap { $0 == StreamFormat.statusTitle(health.status) ? nil : $0 }
        default: return nil
        }
    }
    private func text(now: Date) -> String {
        switch health.status {
        case .live: StreamFormat.liveLine(health, now: now, compact: compact)
        default: StreamFormat.statusTitle(health.status)
        }
    }
}
