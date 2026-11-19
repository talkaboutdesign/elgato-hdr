// Inspector sidebar of the studio window: Scene (layers, transition and picture), Audio, Stream.
// Every control goes through StudioState.actions, the same AppDelegate methods the menus call.
import AppKit
import SwiftUI

enum SidebarTab: String, CaseIterable { case scene, audio, stream }

struct StudioSidebar: View {
    let state: StudioState
    @AppStorage("sidebarTab") private var tab = SidebarTab.scene

    var body: some View {
        VStack(spacing: 0) {
            SegmentedSwitch(selection: $tab, options: [
                .init(value: .scene, label: "Scene", help: "Scene: layers, transition and picture"),
                .init(value: .audio, label: "Audio", help: "Audio: game sound and microphone"),
                .init(value: .stream, label: "Stream", help: "Stream destinations"),
            ], height: 28)
            .padding(.horizontal, DS.Space.l).padding(.top, DS.Space.m).padding(.bottom, DS.Space.m)
            Divider().opacity(0.5)
            ScrollView {
                Group {
                    switch tab {
                    case .scene: SceneTab(state: state)
                    case .audio: AudioTab(state: state)
                    case .stream: StreamTab(state: state)
                    }
                }
                .padding(DS.Space.l)
                .transition(.opacity)
            }
            .scrollIndicators(.automatic)
            #if DEBUG
            // `EHDR_SIDEBAR_BOTTOM=1`: open scrolled to the end of the tab (the Picture section), for harness snapshots.
            .defaultScrollAnchor(ProcessInfo.processInfo.environment["EHDR_SIDEBAR_BOTTOM"] != nil ? .bottom : nil)
            #endif
        }
        .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.Color.panel)
        .environment(\.colorScheme, .dark)
        .animation(DS.Motion.fade, value: tab)
        .onAppear { state.actions.refreshDevices() }
    }
}

// MARK: - Scene (the tab itself lives in Scenes/SceneTab.swift)

struct PictureSection: View {
    let state: StudioState
    var body: some View {
        InspectorSection(title: "Picture") {
            InspectorRow(label: "Input") {
                Picker("Input", selection: Binding(get: { state.modeIndex }, set: { state.actions.selectMode($0) })) {
                    ForEach(Array(modes.enumerated()), id: \.offset) { i, m in Text(m.name).tag(i) }
                }
                .labelsHidden().pickerStyle(.menu).fixedSize()
                .disabled(state.connection == .demo)
                .help(state.connection == .demo ? "The demo source has a fixed format" : "Capture mode (⌘1 – ⌘7)")
            }
            InspectorRow(label: "Color") {
                Picker("Color", selection: Binding(get: { state.colorMode }, set: { state.actions.selectColor($0) })) {
                    Text("HDR10").tag(ColorMode.pq); Text("HLG").tag(ColorMode.hlg); Text("SDR").tag(ColorMode.sdr)
                }
                .labelsHidden().pickerStyle(.menu).fixedSize()
                .help("How the source is encoded")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Presentation").font(.system(size: 12)).foregroundStyle(.secondary)
                SegmentedSwitch(selection: Binding(get: { state.presentation }, set: { state.actions.selectPresentation($0) }), options: [
                    .init(value: .smooth, label: "Smooth", help: "Smooth: even motion, about 48 ms (⌘J)"),
                    .init(value: .game, label: "Game", help: "Game: low latency, no tearing, about 22 ms (⌘G)"),
                    .init(value: .immediate, label: "Lowest", help: "Lowest latency: may tear in full screen, about 5 ms (⌘L)"),
                ])
            }
            Divider().opacity(0.4)
            PictureControls()
        }
    }
}

/// Exposure, contrast, tone and colour for the game or the camera (`PictureAdjust`). They change the live window,
/// streams, thumbnails, the editor preview and exports on the next frame; recordings stay raw.
struct PictureControls: View {
    var adjust = PictureAdjust.shared
    @State private var source = PictureAdjust.Source.game

    private struct Control {
        let label: String, key: WritableKeyPath<PictureGrade, Double>, range: ClosedRange<Double>, format: String, help: String
        var steps: Double = 1      // per unit
    }
    private static let controls: [Control] = [
        Control(label: "Exposure", key: \.exposure, range: PictureGrade.exposureRange, format: "%+.1f EV",
                help: "Brightens or darkens the whole picture, in stops", steps: 10),
        Control(label: "Contrast", key: \.contrast, range: PictureGrade.percentRange, format: "%+.0f",
                help: "Spreads or flattens tones around the midtones"),
        Control(label: "Highlights", key: \.highlights, range: PictureGrade.percentRange, format: "%+.0f",
                help: "Brightens or recovers the brightest parts"),
        Control(label: "Shadows", key: \.shadows, range: PictureGrade.percentRange, format: "%+.0f",
                help: "Lifts or deepens the darkest parts"),
        Control(label: "Saturation", key: \.saturation, range: PictureGrade.saturationRange, format: "%.0f%%",
                help: "Colour intensity: 0% is black and white"),
        Control(label: "Temperature", key: \.temperature, range: PictureGrade.percentRange, format: "%+.0f",
                help: "White balance: warmer (orange) or cooler (blue)"),
        Control(label: "Tint", key: \.tint, range: PictureGrade.percentRange, format: "%+.0f",
                help: "White balance: magenta or green"),
    ]

    var body: some View {
        let grade = adjust.grade(source)
        VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack {
                Text("Adjust").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button("Reset") { withAnimation(DS.Motion.snappy) { adjust.reset(source) } }
                    .buttonStyle(.link).font(.system(size: 11))
                    .disabled(grade.isNeutral)
                    .help(source == .game ? "Reset the game's picture adjustments" : "Reset the camera's picture adjustments")
            }
            SegmentedSwitch(selection: $source, options: [
                .init(value: .game, label: "Game", help: "Adjust the game picture"),
                .init(value: .camera, label: "Camera", help: "Adjust the camera picture"),
            ])
            ForEach(Self.controls, id: \.label) { c in
                LabeledSlider(label: c.label, value: binding(c), range: c.range, defaultValue: PictureGrade.neutral[keyPath: c.key],
                              format: { String(format: c.format, $0) }, help: c.help)
            }
            if source == .game { SdrBrightnessControl() }
        }
        #if DEBUG
        // `EHDR_PICTURE_SOURCE=camera`: the camera's controls when the section appears, for harness snapshots.
        .onAppear { if ProcessInfo.processInfo.environment["EHDR_PICTURE_SOURCE"] == "camera" { source = .camera } }
        #endif
    }

    /// Whole steps (tenths of a stop for exposure), so the read-out does not flicker between neighbours.
    private func binding(_ c: Control) -> Binding<Double> {
        let source = source, adjust = adjust
        return Binding(get: { adjust.grade(source)[keyPath: c.key] }, set: { (v: Double) in
            var g = adjust.grade(source)
            g[keyPath: c.key] = (v * c.steps).rounded() / c.steps
            adjust.set(source, g)
        })
    }
}

// MARK: - Audio

struct AudioTab: View {
    let state: StudioState
    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xl) {
            InspectorSection(title: "Game audio") {
                ToggleRow(label: "Play through speakers", isOn: !state.muted, help: "Monitor the card's audio (⌘M mutes). Recordings always include it.") {
                    state.actions.setMuted(!$0)
                }
            }
            InspectorSection(title: "Microphone") {
                DevicePicker(label: "Device", devices: state.microphones, selection: state.micID, noneLabel: "None",
                             help: "Microphone recorded as its own layer") { state.actions.selectMic($0) }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Level").font(.system(size: 12)).foregroundStyle(.secondary)
                        Spacer()
                        MicDbReadout(state: state)
                    }
                    MicLevelBar(state: state, height: 6)
                }
                Text("Your voice is saved as a separate layer, so you can change its volume and sync after recording.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct MicDbReadout: View {
    let state: StudioState
    var body: some View {
        Text(state.micOn ? String(format: "%.0f dB", StudioFormat.dbfs(state.micLevel)) : "—")
            .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
            .frame(width: 44, alignment: .trailing)
    }
}

// MARK: - Stream (UI/Studio/Stream/StreamTab.swift)

// MARK: - Rows

struct ToggleRow: View {
    let label: String
    let isOn: Bool
    var help = ""
    let set: (Bool) -> Void
    var body: some View {
        InspectorRow(label: label) {
            Toggle(label, isOn: Binding(get: { isOn }, set: set)).labelsHidden()
                .toggleStyle(.switch).controlSize(.mini)
        }
        .help(help)
    }
}

struct DevicePicker: View {
    let label: String
    let devices: [DeviceInfo]
    let selection: String?
    let noneLabel: String
    var help = ""
    let select: (String?) -> Void

    var body: some View {
        InspectorRow(label: label) {
            Picker(label, selection: Binding(get: { selection ?? "" }, set: { select($0.isEmpty ? nil : $0) })) {
                Text(noneLabel).tag("")
                if !devices.isEmpty { Divider() }
                ForEach(devices) { Text($0.name).tag($0.id) }
                if let s = selection, !devices.contains(where: { $0.id == s }) { Text("Unavailable device").tag(s) }
            }
            .labelsHidden().pickerStyle(.menu)
            .frame(maxWidth: 170)
            .help(help)
        }
    }
}
