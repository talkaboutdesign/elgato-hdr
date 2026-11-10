// Toolbar controls, the overlays drawn over the picture (status pill, toast, no-signal placeholder) and the
// bottom bar. Each view reads only the StudioState properties it shows, so a 20 Hz meter update re-renders the
// meter and nothing else.
import AppKit
import SwiftUI

// MARK: - Toolbar

struct CanvasSwitch: View {
    @State private var canvas = Canvas.wide
    var body: some View {
        SegmentedSwitch(selection: $canvas, options: [
            .init(value: .wide, label: "16:9", help: "Widescreen canvas"),
            .init(value: .vertical, label: "9:16", help: "Vertical canvas"),
        ], height: 26)
        .frame(width: 120)
        .disabled(true)
        .help("Live 16:9 and 9:16 canvases are coming with scenes")
        .accessibilityLabel("Canvas, coming with scenes")
    }
}

struct RecordButton: View {
    let state: StudioState
    @State private var hover = false

    var body: some View {
        let rec = state.recording
        Button { state.actions.toggleRecording() } label: {
            HStack(spacing: 7) {
                Image(systemName: rec ? "square.fill" : "circle.fill")
                    .font(.system(size: rec ? 9 : 11, weight: .bold))
                    .foregroundStyle(DS.Color.record)
                    .frame(width: 12, height: 12)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.pulse, options: .repeating, isActive: rec && !DS.Motion.reduceMotion)
                Text(rec ? StudioFormat.elapsed(state.recordingElapsed) : "Record")
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .contentTransition(.numericText())
                    .frame(minWidth: 46, alignment: .leading)
            }
            .padding(.leading, 10).padding(.trailing, 12).frame(height: 28)
            .background(Capsule().fill(rec ? DS.Color.record.opacity(hover ? 0.28 : 0.2) : Color.white.opacity(hover ? 0.14 : 0.08)))
            .overlay(Capsule().strokeBorder(rec ? DS.Color.record.opacity(0.55) : Color.white.opacity(0.08)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(DS.Motion.snappy, value: rec)
        .animation(DS.Motion.snappy, value: hover)
        .help(rec ? "Stop Recording (⌘R)" : "Start Recording (⌘R)")
        .accessibilityLabel(rec ? "Stop recording" : "Start recording")
        .accessibilityValue(rec ? StudioFormat.elapsed(state.recordingElapsed) : "")
    }
}

/// Idle, connecting and live states and both popovers are in `UI/Studio/Stream/GoLiveControl.swift`.
struct GoLiveButton: View {
    let state: StudioState
    var body: some View { GoLiveControl(state: state) }
}

// MARK: - Overlays

struct PillOverlay: View {
    let state: StudioState
    let chrome: StageChrome
    var body: some View {
        let (dot, pulsing): (Color, Bool) = {
            switch state.connection {
            case .live: return (DS.Color.ok, false)
            case .demo: return (Color.accentColor, false)
            case .connecting: return (DS.Color.warn, true)
            case .noSignal: return (DS.Color.record, false)
            }
        }()
        StatusPill(text: state.pillText, dot: dot, pulsing: pulsing)
            .opacity(chrome.pillVisible ? 1 : 0)
            .animation(DS.Motion.snappy, value: state.pillText)
            .help(state.signal.isEmpty ? state.pillText : state.signal)
    }
}

struct ToastOverlay: View {
    let state: StudioState
    var body: some View {
        ZStack {
            if let t = state.toast {
                ToastView(toast: t).id(t.id)
                    .transition(DS.Motion.transition(.move(edge: .top).combined(with: .opacity)))
            }
        }
        .padding(DS.Space.xs)
        .animation(DS.Motion.gentle, value: state.toast?.id)
    }
}

struct StagePlaceholder: View {
    let state: StudioState
    var body: some View {
        switch state.connection {
        case .connecting:
            VStack(spacing: DS.Space.m) {
                ProgressView().controlSize(.regular)
                Text("Connecting to the capture card…").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            .padding(DS.Space.xl)
        case .noSignal(let why):
            EmptyState(systemImage: "video.slash", title: "No signal",
                       message: why.isEmpty ? "Check that the capture card is connected and the console is on." : why,
                       actionTitle: "Reconnect") { state.actions.reconnect() }
        case .live, .demo:
            EmptyView()
        }
    }
}

// MARK: - Bottom bar

struct BottomBar: View {
    let state: StudioState
    var body: some View {
        HStack(spacing: DS.Space.l) {
            SceneStrip(state: state)
            Spacer(minLength: DS.Space.l)
            GameAudioControl(state: state)
            Divider().frame(height: 28)
            MicMeter(state: state)
        }
        .padding(.horizontal, DS.Space.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.Color.panel)
        .overlay(alignment: .top) { Rectangle().fill(DS.Color.stroke).frame(height: 1) }
    }
}

/// Placeholder until scenes (plan 22): the one live layout, and a disabled slot for more.
struct SceneStrip: View {
    let state: StudioState
    var body: some View {
        HStack(spacing: DS.Space.s) {
            SceneChip(title: state.cameraOn ? "Game + Camera" : "Game", camera: state.cameraOn, selected: true)
                .help("The live layout. Move the camera by dragging it on the picture.")
            Button {} label: {
                Image(systemName: "plus").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    .frame(width: 40, height: 36)
                    .background(RoundedRectangle(cornerRadius: DS.Radius.control + 2, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 3])).foregroundStyle(DS.Color.stroke))
            }
            .buttonStyle(.plain)
            .disabled(true)
            .help("More scenes are coming in a later update")
            .accessibilityLabel("Add scene, coming later")
        }
    }
}

struct SceneChip: View {
    let title: String
    let camera: Bool
    var selected = false
    var body: some View {
        HStack(spacing: DS.Space.s) {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(LinearGradient(colors: [Color(white: 0.28), Color(white: 0.16)], startPoint: .top, endPoint: .bottom))
                    .frame(width: 40, height: 24)
                    .overlay(Image(systemName: "gamecontroller.fill").font(.system(size: 9)).foregroundStyle(.white.opacity(0.55)))
                if camera {
                    RoundedRectangle(cornerRadius: 2, style: .continuous).fill(Color.white.opacity(0.85))
                        .frame(width: 11, height: 11).padding(2)
                }
            }
            Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
        }
        .padding(.leading, 6).padding(.trailing, 10).frame(height: 36)
        .background(RoundedRectangle(cornerRadius: DS.Radius.control + 2, style: .continuous).fill(Color.white.opacity(selected ? 0.10 : 0.05)))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.control + 2, style: .continuous)
            .strokeBorder(selected ? Color.accentColor.opacity(0.9) : DS.Color.stroke, lineWidth: selected ? 1.5 : 1))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct GameAudioControl: View {
    let state: StudioState
    var body: some View {
        HStack(spacing: DS.Space.s) {
            IconButton(systemImage: state.muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                       help: state.muted ? "Unmute game audio (⌘M)" : "Mute game audio (⌘M)", isOn: state.muted) {
                state.actions.setMuted(!state.muted)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("Game").font(.system(size: 11, weight: .semibold))
                Text(state.muted ? "Muted" : "Monitoring").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .frame(width: 66, alignment: .leading)
        }
    }
}

struct MicMeter: View {
    let state: StudioState
    var body: some View {
        let name = state.microphones.first { $0.id == state.micID }?.name
        HStack(spacing: DS.Space.s) {
            Image(systemName: state.micOn ? "mic.fill" : "mic.slash")
                .font(.system(size: 13)).foregroundStyle(state.micOn ? Color.primary : Color.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 5) {
                Text(name ?? "No microphone").font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    .foregroundStyle(state.micOn ? Color.primary : Color.secondary)
                MicLevelBar(state: state)
            }
            .frame(width: 160, alignment: .leading)
        }
        .help(state.micOn ? "Microphone level. The mic is recorded as its own layer." : "Choose a microphone in the sidebar's Audio tab")
    }
}

/// The only view that reads `micLevel`, so the 20 Hz updates stay in this leaf.
struct MicLevelBar: View {
    let state: StudioState
    var height: CGFloat = 5
    var body: some View { MeterBar(level: state.micLevel, active: state.micOn, height: height) }
}
