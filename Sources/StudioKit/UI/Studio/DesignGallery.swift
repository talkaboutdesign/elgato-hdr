#if DEBUG
import AppKit
import SwiftUI

/// `--design-gallery`: every design-system component in its states, dark and light side by side.
/// The reference for later UI work; not shipped in release builds.
enum DesignGallery {
    static func open() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1840, height: 1000),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.title = "Design Gallery"
        w.isReleasedWhenClosed = false
        let host = NSHostingController(rootView: GalleryRoot())
        host.sizingOptions = []
        w.contentViewController = host
        w.setContentSize(NSSize(width: 1840, height: 1000))
        w.center()
        w.makeKeyAndOrderFront(nil)
        return w
    }
}

private struct GalleryRoot: View {
    var body: some View {
        HStack(spacing: 0) {
            GalleryColumn().environment(\.colorScheme, .dark).background(Color(nsColor: .windowBackgroundColor)).colorScheme(.dark)
            Divider()
            GalleryColumn().environment(\.colorScheme, .light).background(Color(nsColor: .windowBackgroundColor)).colorScheme(.light)
        }
    }
}

private struct GalleryColumn: View {
    @Environment(\.colorScheme) var scheme
    @State private var seg = 1
    @State private var shape = CameraShape.rounded
    @State private var slider = 0.34
    let idle = GalleryColumn.state(recording: false)
    let rec = GalleryColumn.state(recording: true)

    static func state(recording: Bool) -> StudioState {
        let s = StudioState()
        s.recording = recording; s.recordingElapsed = 247
        s.micID = "m"; s.microphones = [DeviceInfo(id: "m", name: "Studio Display Microphone")]; s.micLevel = 0.3
        return s
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.l) {
                Text(scheme == .dark ? "Dark" : "Light").font(.title2.bold())
                HStack(alignment: .top, spacing: DS.Space.xxl) {
                    VStack(alignment: .leading, spacing: DS.Space.xl) { left }.frame(width: 400, alignment: .leading)
                    VStack(alignment: .leading, spacing: DS.Space.xl) { right }.frame(width: 440, alignment: .leading)
                }
            }
            .padding(DS.Space.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder var left: some View {

                group("Colour") {
                    HStack(spacing: DS.Space.s) {
                        ForEach(Array([("canvas", DS.Color.canvas), ("panel", DS.Color.panel), ("raised", DS.Color.raised), ("stroke", DS.Color.stroke),
                                       ("record", DS.Color.record), ("live", DS.Color.live), ("ok", DS.Color.ok), ("warn", DS.Color.warn)].enumerated()), id: \.offset) { _, c in
                            VStack(spacing: 4) {
                                RoundedRectangle(cornerRadius: DS.Radius.control).fill(c.1).frame(width: 40, height: 30)
                                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.control).strokeBorder(Color.primary.opacity(0.15)))
                                Text(c.0).font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                        }
                    }
                    HStack(alignment: .bottom, spacing: DS.Space.s) {
                        ForEach([DS.Space.xs, DS.Space.s, DS.Space.m, DS.Space.l, DS.Space.xl, DS.Space.xxl], id: \.self) { v in
                            VStack(spacing: 4) { Rectangle().fill(Color.accentColor.opacity(0.6)).frame(width: v, height: v); Text("\(Int(v))").font(.system(size: 10)).foregroundStyle(.secondary) }
                        }
                        Spacer().frame(width: DS.Space.xl)
                        ForEach([DS.Radius.control, DS.Radius.card, DS.Radius.panel], id: \.self) { r in
                            VStack(spacing: 4) { RoundedRectangle(cornerRadius: r, style: .continuous).strokeBorder(Color.primary.opacity(0.5)).frame(width: 40, height: 32); Text("r\(Int(r))").font(.system(size: 10)).foregroundStyle(.secondary) }
                        }
                    }
                }

                group("PillButton · IconButton") {
                    HStack(spacing: DS.Space.s) {
                        PillButton("Export", systemImage: "square.and.arrow.up", help: "Export") {}
                        PillButton("Go Live", systemImage: "dot.radiowaves.left.and.right", tint: DS.Color.live, prominent: true, help: "Go Live") {}
                        PillButton("Go Live", systemImage: "dot.radiowaves.left.and.right", tint: DS.Color.live, prominent: true, help: "Disabled") {}.disabled(true)
                    }
                    HStack(spacing: DS.Space.s) {
                        IconButton(systemImage: "speaker.wave.2.fill", help: "Mute (⌘M)") {}
                        IconButton(systemImage: "speaker.slash.fill", help: "Muted", isOn: true) {}
                        IconButton(systemImage: "sidebar.right", help: "Disabled") {}.disabled(true)
                    }
                }

                group("Record · Go Live · Canvas (toolbar, dark only)") {
                    HStack(spacing: DS.Space.s) {
                        RecordButton(state: idle).fixedSize()
                        RecordButton(state: rec)
                        GoLiveButton(state: idle).fixedSize()
                        CanvasSwitch()
                    }
                }

                group("MeterBar") {
                    VStack(alignment: .leading, spacing: DS.Space.s) {
                        ForEach([Float(0.01), 0.1, 0.3, 0.75, 1], id: \.self) { l in
                            HStack { Text(String(format: "%.0f dB", StudioFormat.dbfs(l))).font(.system(size: 10).monospacedDigit()).frame(width: 44, alignment: .trailing); MeterBar(level: l).frame(width: 200) }
                        }
                        HStack { Text("off").font(.system(size: 10)).frame(width: 44, alignment: .trailing); MeterBar(level: 0.5, active: false).frame(width: 200) }
                    }
                }

    }

    @ViewBuilder var right: some View {
                group("StatusPill · ToastView") {
                    HStack(spacing: DS.Space.s) {
                        StatusPill(text: "1440p60 HDR · 22 ms", dot: DS.Color.ok).fixedSize()
                        StatusPill(text: "Connecting…", dot: DS.Color.warn, pulsing: true).fixedSize()
                        StatusPill(text: "No signal", dot: DS.Color.record).fixedSize()
                    }
                    .padding(DS.Space.s).background(DS.Color.canvas, in: RoundedRectangle(cornerRadius: DS.Radius.card))
                    VStack(alignment: .leading, spacing: DS.Space.s) {
                        ToastView(toast: Toast(text: "Recording saved", detail: "Capture 2026-11-09 18.24 [game + camera + mic]", style: .success))
                        ToastView(toast: Toast(text: "Stop recording to switch cameras", style: .warning))
                        ToastView(toast: Toast(text: "Helper not reachable", detail: "Reconnect from the View menu", style: .error))
                    }
                }

                group("SegmentedSwitch · LabeledSlider") {
                    SegmentedSwitch(selection: $seg, options: [.init(value: 0, label: "Scene"), .init(value: 1, label: "Audio"), .init(value: 2, label: "Stream")]).frame(width: 260)
                    SegmentedSwitch(selection: $shape, options: CameraShape.allCases.map { .init(value: $0, label: $0.label, systemImage: $0.symbol) }, iconOnly: true).frame(width: 132)
                    SegmentedSwitch(selection: $seg, options: [.init(value: 0, label: "16:9"), .init(value: 1, label: "9:16")]).frame(width: 120).disabled(true)
                    LabeledSlider(label: "Size", value: $slider, range: 0.08...1, defaultValue: 0.34).frame(width: 260)
                }

                group("Card · InspectorSection · EmptyState") {
                    HStack(alignment: .top, spacing: DS.Space.l) {
                        Card { Text("Card").font(.system(size: 12)).frame(width: 84, height: 56) }
                        Card(selected: true) { Text("Selected").font(.system(size: 12)).frame(width: 84, height: 56) }
                        InspectorSection(title: "Camera window") {
                            InspectorRow(label: "Aspect") { Text("1:1").font(.system(size: 12)) }
                            ToggleRow(label: "Shadow", isOn: true) { _ in }
                        }
                        .frame(width: 220)
                    }
                    EmptyState(systemImage: "dot.radiowaves.left.and.right", title: "Go live from here", message: "Destinations arrive in a later update.", actionTitle: "Learn More") {}
                }
    }

    func group<C: View>(_ title: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            c()
        }
    }
}
#endif
