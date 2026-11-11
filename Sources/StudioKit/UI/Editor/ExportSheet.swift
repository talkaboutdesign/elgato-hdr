import AppKit
import SwiftUI

// MARK: - Sheet

/// Presets as cards; several can be ticked and run as a queue in the order shown.
struct ExportSheet: View {
    let model: EditorModel
    let dismiss: () -> Void
    @State private var chosen: Set<ExportPreset> = [.youtube]
    @State private var custom = ExportPreset.Custom()

    var body: some View {
        let p = model.project
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Export").font(.system(size: 17, weight: .semibold))
                Text("\(formatTime(model.keptDuration)) after cuts · \(recordingSummary(p, duration: model.duration))")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .padding([.horizontal, .top], DS.Space.xl).padding(.bottom, DS.Space.l)

            let notices = ExportNotices(model: model)
            if notices.any {
                notices.padding(.horizontal, DS.Space.xl).padding(.bottom, DS.Space.l)
            }

            let columns = [GridItem(.flexible(), spacing: DS.Space.m), GridItem(.flexible(), spacing: DS.Space.m)]
            LazyVGrid(columns: columns, spacing: DS.Space.m) {
                ForEach(ExportPreset.allCases) { preset in
                    PresetCard(preset: preset, detail: preset.detail(for: p, custom: custom), note: note(preset, p),
                               on: chosen.contains(preset), canvas: preset == .shorts ? .vertical : preset == .custom ? nil : .wide) {
                        withAnimation(DS.Motion.snappy) { if chosen.contains(preset) { chosen.remove(preset) } else { chosen.insert(preset) } }
                    }
                }
            }
            .padding(.horizontal, DS.Space.xl)

            if chosen.contains(.custom) {
                CustomExportControls(custom: $custom, hdrSource: model.isHDRSource, sourceFps: p.fps)
                    .padding(.horizontal, DS.Space.xl).padding(.top, DS.Space.l)
                    .transition(DS.Motion.transition(.opacity.combined(with: .move(edge: .top))))
            }

            // An HDR recording exported as SDR is tone mapped with the same global setting as the stream.
            if model.isHDRSource && chosen.contains(where: { $0.jobs(for: p, custom: custom).contains { $0.range == .sdr } }) {
                SdrBrightnessControl()
                    .padding(.horizontal, DS.Space.xl).padding(.top, DS.Space.l)
                    .transition(DS.Motion.transition(.opacity))
            }

            HStack {
                Button { NSWorkspace.shared.open(model.doc.exportsDir.deletingLastPathComponent()) } label: {
                    Label("Saved in the project's Exports folder", systemImage: "folder").font(.system(size: 11))
                }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button {
                    model.startExport(Array(chosen), custom: custom)
                    dismiss()
                } label: {
                    Text(jobCount > 1 ? "Export \(jobCount) Files" : "Export").frame(minWidth: 90)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(jobCount == 0)
            }
            .padding(DS.Space.xl).padding(.top, DS.Space.s)
        }
        .frame(width: 600)
        .fixedSize(horizontal: false, vertical: true)
        .background(DS.Color.panel)
        #if DEBUG
        // `EHDR_EXPORT_CHOSEN=youtube1080,shorts`: presets ticked when the sheet opens, for harness screenshots.
        .onAppear { if let v = ProcessInfo.processInfo.environment["EHDR_EXPORT_CHOSEN"] { chosen = Set(v.split(separator: ",").compactMap { ExportPreset(rawValue: String($0)) }) } }
        #endif
    }

    private var jobCount: Int { chosen.reduce(0) { $0 + $1.jobs(for: model.project, custom: custom).count } }

    private func note(_ preset: ExportPreset, _ p: Project) -> String {
        switch preset {
        case .youtube: return p.color == .sdr ? "H.264 at the source resolution" : "HEVC 10-bit HDR, as recorded"
        case .youtube1080: return "H.264, plays everywhere"
        case .shorts: return "Vertical canvas, H.264 at 60 fps"
        case .custom: return "Pick canvas, size, frame rate and colour"
        }
    }
}

/// What the user should know before exporting: the encoder is shared with a recording or stream in progress, and
/// image layers whose file is gone are left out.
struct ExportNotices: View {
    let model: EditorModel
    private var activity: (recording: Bool, live: Bool) { ExportQueue.liveActivity }
    private var missing: [MissingAsset] { model.missingAssets }
    var any: Bool { activity.recording || activity.live || !missing.isEmpty }

    /// One line per missing file: "Logo in “Gameplay” and “Camera Focus”".
    static func byFile(_ missing: [MissingAsset]) -> [String] {
        var order: [String] = [], scenes: [String: [String]] = [:], names: [String: String] = [:]
        for m in missing {
            if scenes[m.file] == nil { order.append(m.file); names[m.file] = m.layer }
            if !(scenes[m.file] ?? []).contains(m.scene) { scenes[m.file, default: []].append(m.scene) }
        }
        return order.map { f in
            let s = (scenes[f] ?? []).map { "“\($0)”" }
            let list = s.count > 1 ? s.dropLast().joined(separator: ", ") + " and " + s.last! : s.first ?? ""
            return "\(names[f] ?? f) in \(list)"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            let a = activity
            if a.recording || a.live {
                Callout(style: .info, title: "Exports wait for the video encoder while you are live or recording",
                        detail: "\(a.live && a.recording ? "Streaming and recording use" : a.live ? "The stream uses" : "The recording uses") the Mac's video encoder first, so exports run slower until \(a.live ? "you end the stream" : "the recording stops"). Nothing is lost.",
                        systemImage: a.live ? "dot.radiowaves.left.and.right" : "record.circle")
            }
            let files = ExportNotices.byFile(missing)
            if !files.isEmpty {
                Callout(style: .warning, title: files.count == 1 ? "1 image is missing and will be left out" : "\(files.count) images are missing and will be left out",
                        detail: files.prefix(3).joined(separator: "; ") + (files.count > 3 ? "; and \(files.count - 3) more" : "")
                            + ". Put the file back in the recording's Assets folder to include it.")
            }
        }
    }
}

struct PresetCard: View {
    let preset: ExportPreset
    let detail: String
    let note: String
    let on: Bool
    let canvas: Canvas?
    let toggle: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: toggle) {
            HStack(alignment: .top, spacing: DS.Space.m) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.07)).frame(width: 52, height: 52)
                    if let c = canvas {
                        RoundedRectangle(cornerRadius: 3).strokeBorder(Color.primary.opacity(0.55), lineWidth: 1.5)
                            .frame(width: c == .wide ? 34 : 19, height: c == .wide ? 19 : 34)
                        Image(systemName: preset == .shorts ? "play.fill" : "play.fill").font(.system(size: 8)).foregroundStyle(.secondary)
                    } else {
                        Image(systemName: preset.symbol).font(.system(size: 18)).foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(preset.title).font(.system(size: 13, weight: .semibold))
                    Text(detail).font(.system(size: 11).monospacedDigit()).foregroundStyle(.primary.opacity(0.8)).lineLimit(2)
                    Text(note).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17))
                    .foregroundStyle(on ? Color.accentColor : Color.secondary.opacity(0.5))
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(DS.Space.m)
            .frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).fill(on ? Color.accentColor.opacity(0.08) : DS.Color.raised))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .strokeBorder(on ? Color.accentColor : DS.Color.stroke, lineWidth: on ? 2 : 1))
            .shadow(color: .black.opacity(hover ? 0.12 : 0.04), radius: hover ? 6 : 2, y: 1)
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(DS.Motion.snappy, value: hover)
        .accessibilityLabel(preset.title)
        .accessibilityValue(on ? "selected" : "not selected")
        .accessibilityHint(detail)
    }
}

struct CustomExportControls: View {
    @Binding var custom: ExportPreset.Custom
    let hdrSource: Bool
    let sourceFps: Double
    var body: some View {
        InspectorSection(title: "Custom") {
            InspectorRow(label: "Canvas") {
                HStack(spacing: DS.Space.m) {
                    ForEach(Canvas.allCases) { c in
                        Toggle(c.title, isOn: Binding(get: { custom.canvases.contains(c) }, set: { if $0 { custom.canvases.insert(c) } else { custom.canvases.remove(c) } }))
                            .toggleStyle(.checkbox)
                    }
                }
            }
            InspectorRow(label: "Resolution") {
                SegmentedSwitch(selection: $custom.resolution, options: [.init(value: .hd, label: "1080p"), .init(value: .uhd, label: "4K")]).frame(width: 160)
            }
            InspectorRow(label: "Frame rate") {
                SegmentedSwitch(selection: $custom.fps, options: [
                    .init(value: .source, label: "Source (\(Int(sourceFps.rounded())))"), .init(value: .sixty, label: "60"), .init(value: .thirty, label: "30"),
                ]).frame(width: 220)
            }
            if hdrSource {
                InspectorRow(label: "Colour") {
                    SegmentedSwitch(selection: $custom.range, options: [.init(value: .hdr, label: "HDR · HEVC"), .init(value: .sdr, label: "SDR · H.264")]).frame(width: 220)
                }
            }
        }
        .font(.system(size: 12))
    }
}

// MARK: - Progress capsule

/// In the toolbar while the queue has work: overall progress; click for each job, time left and cancel.
struct ExportProgressCapsule: View {
    let model: EditorModel
    @State private var showList = false

    var body: some View {
        let q = model.exportQueue!
        let running = q.isRunning
        let items = q.items
        if !items.isEmpty {
            Button { showList.toggle() } label: {
                HStack(spacing: 7) {
                    if running {
                        ProgressView(value: q.overallProgress).progressViewStyle(.circular).controlSize(.mini)
                        Text(items.contains { $0.state == .running && $0.encoderWaiting } ? q.encoderWaitMessage : String(format: "Exporting %d of %d · %.0f%%", min(q.runningIndex, items.count), items.count, q.overallProgress * 100))
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                            .contentTransition(.numericText())
                    } else {
                        let failed = items.contains { if case .failed = $0.state { return true }; return false }
                        Image(systemName: failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(failed ? DS.Color.warn : DS.Color.ok)
                        Text(failed ? "Export finished with errors" : "Exported \(items.filter { if case .done = $0.state { return true }; return false }.count)")
                            .font(.system(size: 12, weight: .medium))
                    }
                }
                .padding(.horizontal, 10).frame(height: 26)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Export queue")
            .accessibilityLabel(running ? "Export progress" : "Export results")
            .accessibilityValue(String(format: "%.0f percent", q.overallProgress * 100))
            .popover(isPresented: $showList, arrowEdge: .bottom) { ExportQueueList(model: model) }
            #if DEBUG
            .onReceive(NotificationCenter.default.publisher(for: .harnessShowQueue)) { _ in showList = true }
            #endif
        }
    }
}

struct ExportQueueList: View {
    let model: EditorModel
    var body: some View {
        let q = model.exportQueue!
        VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack {
                Text("Exports").font(.system(size: 13, weight: .semibold))
                Spacer()
                if q.isRunning { Button("Cancel All") { q.cancelAll() }.controlSize(.small) }
            }
            ForEach(q.items) { item in ExportQueueRow(queue: q, item: item) }
        }
        .padding(DS.Space.l)
        .frame(width: 380)
    }
}

struct ExportQueueRow: View {
    let queue: ExportQueue
    let item: ExportQueue.Item
    var body: some View {
        HStack(alignment: .center, spacing: DS.Space.m) {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(item.title).font(.system(size: 12, weight: .semibold))
                    Text(ExportPreset.describe(item.job)).font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
                }
                switch item.state {
                case .waiting: Text("Waiting").font(.system(size: 11)).foregroundStyle(.secondary)
                case .running:
                    ProgressView(value: item.progress).progressViewStyle(.linear).controlSize(.small)
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text(item.encoderWaiting ? queue.encoderWaitMessage : remainingText(queue.remaining(item, now: ctx.date), item.progress)).font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
                    }
                case .done(let url):
                    HStack(spacing: 6) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 16, height: 16)
                            .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
                        Text(url.lastPathComponent).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                    }
                case .failed(let why): Text(why).font(.system(size: 11)).foregroundStyle(DS.Color.record).lineLimit(2)
                case .cancelled: Text("Cancelled").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if item.isActive {
                Button { queue.cancel(item.id) } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 15)) }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).help("Cancel this export").accessibilityLabel("Cancel \(item.title)")
            } else if case .done(let url) = item.state {
                Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Image(systemName: "magnifyingglass.circle.fill").font(.system(size: 15)) }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).help("Show in Finder").accessibilityLabel("Show \(item.title) in Finder")
            }
        }
    }
    private func remainingText(_ s: Double?, _ p: Double) -> String {
        let pct = String(format: "%.0f%%", p * 100)
        guard let s = s else { return pct }
        return s < 60 ? "\(pct) · about \(Int(s.rounded())) s left" : "\(pct) · about \(Int((s / 60).rounded())) min left"
    }
}
