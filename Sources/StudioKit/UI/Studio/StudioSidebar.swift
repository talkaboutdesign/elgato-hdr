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
        }
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
