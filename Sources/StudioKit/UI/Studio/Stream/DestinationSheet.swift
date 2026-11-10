// Add or edit a destination: pick a service, then server URL (prefilled), stream key, canvas and name, with
// "Test connection". The typed key lives only in this view's @State and goes straight to the Keychain on save.
import AppKit
import SwiftUI

struct DestinationSheet: View {
    let streaming: StreamingState
    let close: () -> Void
    private let isNew: Bool

    @State private var service: Destination.Service?
    @State private var draft: Destination
    @State private var key = ""
    @State private var reveal = false
    @State private var nameEdited: Bool
    @State private var urlTouched = false
    @State private var test: TestState = .idle
    @State private var saving = false
    @State private var error: String?
    @State private var confirmDelete = false
    @FocusState private var focus: Field?

    enum Field { case name, url, key }
    enum TestState: Equatable { case idle, running, done(ConnectionTestResult) }

    init(streaming: StreamingState, request: DestinationEditorRequest, close: @escaping () -> Void) {
        self.streaming = streaming; self.close = close
        isNew = request.destination == nil
        let d = request.destination ?? Destination(service: request.service ?? .custom)
        _draft = State(initialValue: d)
        _service = State(initialValue: request.destination?.service ?? request.service)
        _nameEdited = State(initialValue: request.destination != nil)
    }

    var body: some View {
        Group {
            if let service { form(service) } else { chooser }
        }
        .frame(width: 520)
        .background(DS.Color.panel)
        .animation(DS.Motion.snappy, value: service)
    }

    // MARK: Service chooser

    private var chooser: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Add a destination").font(.system(size: 17, weight: .semibold))
                Text("Where do you want to stream? You can add as many as you like and turn each on or off.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: DS.Space.m), GridItem(.flexible())], spacing: DS.Space.m) {
                ForEach(Destination.Service.allCases) { s in
                    Button { choose(s) } label: { ServiceChoice(service: s) }
                        .buttonStyle(ChoiceButtonStyle())
                }
            }
            HStack {
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
            }
        }
        .padding(DS.Space.xl)
    }

    private func choose(_ s: Destination.Service) {
        draft.service = s
        draft.url = s.preset.defaultURL
        if !nameEdited { draft.name = s.preset.defaultName(draft.canvas) }
        withAnimation(DS.Motion.snappy) { service = s }
        DispatchQueue.main.async { focus = s.preset.defaultURL.isEmpty ? .url : .key }
    }

    // MARK: Form

    private func form(_ s: Destination.Service) -> some View {
        let p = s.preset
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: DS.Space.m) {
                ServiceTile(service: s, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(isNew ? "Add \(p.title)" : "Edit \(draft.name.isEmpty ? p.title : draft.name)")
                        .font(.system(size: 17, weight: .semibold)).lineLimit(1)
                    Text(subtitle(s)).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                if isNew {
                    Button { withAnimation(DS.Motion.snappy) { service = nil } } label: { Label("Services", systemImage: "chevron.left") }
                        .buttonStyle(.borderless).controlSize(.small).help("Choose another service")
                }
            }
            .padding([.horizontal, .top], DS.Space.xl).padding(.bottom, DS.Space.l)

            Divider().opacity(0.6)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: DS.Space.m, verticalSpacing: DS.Space.m) {
                GridRow {
                    label("Name")
                    TextField("Name", text: $draft.name, prompt: Text(p.defaultName(draft.canvas)))
                        .textFieldStyle(.roundedBorder).focused($focus, equals: .name)
                        .onChange(of: draft.name) { _, _ in if focus == .name { nameEdited = true } }
                }
                GridRow {
                    label("Server URL")
                    VStack(alignment: .leading, spacing: 5) {
                        TextField("Server URL", text: $draft.url, prompt: Text(s == .kick ? "rtmps://…global-contribute.live-video.net/app" : "rtmp://server/app"))
                            .textFieldStyle(.roundedBorder).font(.system(size: 11, design: .monospaced))
                            .focused($focus, equals: .url)
                            .onChange(of: draft.url) { _, _ in if focus == .url { urlTouched = true }; test = .idle }
                        urlFootnote(s)
                    }
                }
                GridRow {
                    label("Stream key")
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            Group {
                                if reveal {
                                    TextField("Stream key", text: $key, prompt: Text(keyPrompt(s)))
                                } else {
                                    SecureField("Stream key", text: $key, prompt: Text(keyPrompt(s)))
                                }
                            }
                            .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                            .focused($focus, equals: .key)
                            .onChange(of: key) { _, _ in test = .idle }
                            Button { reveal.toggle() } label: { Image(systemName: reveal ? "eye.slash" : "eye").frame(width: 16) }
                                .buttonStyle(.borderless).help(reveal ? "Hide the key" : "Show the key")
                                .accessibilityLabel(reveal ? "Hide stream key" : "Show stream key")
                            Button("Paste", action: pasteKey).controlSize(.small).help("Paste the stream key from the clipboard")
                        }
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(p.keyHint).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        if let url = p.helpURL {
                            Link(destination: url) { Label("Where do I find this?", systemImage: "arrow.up.right.square") }
                                .font(.system(size: 11, weight: .medium))
                                .help("Opens \(url.host ?? "the platform's stream settings") in your browser")
                        }
                    }
                }
                GridRow {
                    label("Canvas")
                    VStack(alignment: .leading, spacing: 5) {
                        Picker("Canvas", selection: Binding(get: { draft.canvas }, set: { c in
                            draft.canvas = c
                            if !nameEdited { draft.name = p.defaultName(c) }
                        })) {
                            Label("Widescreen 16:9", systemImage: "rectangle").tag(Canvas.wide)
                            Label("Vertical 9:16", systemImage: "rectangle.portrait").tag(Canvas.vertical)
                        }
                        .pickerStyle(.segmented).labelsHidden()
                        .help("Which program this destination receives: the 16:9 one, or the 9:16 one for vertical lives and Shorts")
                        if let note = p.note {
                            Text(note).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(.horizontal, DS.Space.xl).padding(.vertical, DS.Space.l)

            Divider().opacity(0.6)

            HStack(spacing: DS.Space.m) {
                Button(action: runTest) {
                    if test == .running { ProgressView().controlSize(.small).frame(width: 96) } else { Text("Test Connection").frame(minWidth: 96) }
                }
                .disabled(test == .running || Destination.urlProblem(draft.url, service: s) != nil || (!hasKey && s != .custom))
                .help("Connects and starts publishing without sending video, then disconnects")
                testResult
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.Space.xl).padding(.vertical, DS.Space.m)
            .frame(minHeight: 52)
            .background(Color.primary.opacity(0.03))

            Divider().opacity(0.6)

            HStack(spacing: DS.Space.s) {
                if !isNew {
                    Button("Delete…", role: .destructive) { confirmDelete = true }
                        .disabled(streaming.isActive && streaming.health(draft.id).status.isActive)
                        .help(streaming.isActive && streaming.health(draft.id).status.isActive ? "Turn this destination off before deleting it" : "Delete this destination and its stream key")
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.circle.fill").font(.system(size: 11)).foregroundStyle(DS.Color.record)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: DS.Space.s)
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button(isNew ? "Add Destination" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving || !canSave(s))
            }
            .padding(DS.Space.l).padding(.horizontal, DS.Space.xs)
        }
        .alert("Delete \(draft.name)?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { streaming.actions.delete(draft.id); close() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its stream key is removed from your Keychain.")
        }
        .onAppear { if focus == nil { focus = draft.url.isEmpty ? .url : isNew ? .key : .name } }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(.secondary).gridColumnAlignment(.trailing).frame(minWidth: 72, alignment: .trailing)
    }

    private func subtitle(_ s: Destination.Service) -> String {
        switch s {
        case .twitch: "Stream to your Twitch channel."
        case .youtube: "Stream to YouTube Live, widescreen or vertical."
        case .kick: "Stream to your Kick channel."
        case .custom: "Any RTMP or RTMPS server: a restream service, your own server, a local recorder."
        }
    }

    @ViewBuilder private func urlFootnote(_ s: Destination.Service) -> some View {
        if let split = Destination.splitKey(from: draft.url, service: s) {
            HStack(spacing: 6) {
                Image(systemName: "key.fill").foregroundStyle(DS.Color.warn)
                Text("This URL seems to end with your stream key.").font(.system(size: 11))
                Button("Move It to the Key Field") { draft.url = split.url; key = split.key; reveal = false; test = .idle }
                    .buttonStyle(.link).font(.system(size: 11, weight: .semibold))
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).fill(DS.Color.warn.opacity(0.12)))
        } else if (urlTouched || error != nil), !draft.url.isEmpty || error != nil, let problem = Destination.urlProblem(draft.url, service: s) {
            Text(problem).font(.system(size: 11)).foregroundStyle(DS.Color.record)
        } else if !s.preset.defaultURL.isEmpty {
            if draft.url.trimmingCharacters(in: .whitespaces) == s.preset.defaultURL {
                Text("Default \(s.preset.title) ingest, routed to the nearest server.").font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 4) {
                    Text("Custom ingest server.").font(.system(size: 11)).foregroundStyle(.secondary)
                    Button("Use Default") { draft.url = s.preset.defaultURL; urlTouched = false }.buttonStyle(.link).font(.system(size: 11))
                }
            }
        }
    }

    private var hasKey: Bool { !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (!isNew && streaming.keyStored.contains(draft.id)) }

    private func keyPrompt(_ s: Destination.Service) -> String {
        if !isNew && streaming.keyStored.contains(draft.id) { return "Saved in Keychain · type to replace" }
        return s == .custom ? "Optional" : "Paste your stream key"
    }

    private func canSave(_ s: Destination.Service) -> Bool {
        guard Destination.urlProblem(draft.url, service: s) == nil else { return false }
        return s == .custom || hasKey
    }

    private func pasteKey() {
        guard let text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
        // A pasted URL belongs in the URL field; if it carries the key, split it right away.
        if text.lowercased().hasPrefix("rtmp") {
            if let s = service, let split = Destination.splitKey(from: text, service: s) { draft.url = split.url; key = split.key }
            else { draft.url = text }
            urlTouched = true
        } else {
            key = text
        }
        reveal = false; test = .idle
    }

    private func runTest() {
        error = nil
        test = .running
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        streaming.actions.testConnection(draft, k.isEmpty ? nil : k) { result in
            withAnimation(DS.Motion.snappy) { test = .done(result) }
        }
    }

    @ViewBuilder private var testResult: some View {
        switch test {
        case .idle:
            Text("Checks the URL and key without going live.").font(.system(size: 11)).foregroundStyle(.secondary)
        case .running:
            Text("Connecting…").font(.system(size: 11)).foregroundStyle(.secondary)
        case .done(.connected):
            Label("Connected. The server accepted the stream key.", systemImage: "checkmark.circle.fill")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(DS.Color.ok)
        case .done(.failed(let stage, let message)):
            VStack(alignment: .leading, spacing: 1) {
                Label("Failed at \(stage)", systemImage: "xmark.octagon.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.Color.record)
                Text(message).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func save() {
        guard let s = service, canSave(s) else { error = Destination.urlProblem(draft.url, service: service ?? .custom); return }
        saving = true; error = nil
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        var d = draft
        if d.name.trimmingCharacters(in: .whitespaces).isEmpty { d.name = s.preset.defaultName(d.canvas) }
        streaming.actions.save(d, k.isEmpty ? nil : k) { message in
            saving = false
            if let message { error = message } else { key = ""; close() }
        }
    }
}

private struct ServiceChoice: View {
    let service: Destination.Service
    var body: some View {
        HStack(spacing: DS.Space.m) {
            ServiceTile(service: service, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(service.preset.title).font(.system(size: 13, weight: .semibold))
                Text(blurb).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(DS.Space.m)
        .frame(maxWidth: .infinity, minHeight: 64, maxHeight: 64, alignment: .leading)
    }
    private var blurb: String {
        switch service {
        case .twitch: "Key from your dashboard"
        case .youtube: "Widescreen or vertical live"
        case .kick: "Your personal URL and key"
        case .custom: "Any RTMP or RTMPS server"
        }
    }
}

private struct ChoiceButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { ChoiceBody(configuration: configuration) }
    private struct ChoiceBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var hover = false
        var body: some View {
            configuration.label
                .background(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : hover ? 0.085 : 0.05)))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .strokeBorder(hover ? Color.accentColor.opacity(0.6) : DS.Color.stroke))
                .contentShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                .scaleEffect(configuration.isPressed && !DS.Motion.reduceMotion ? 0.98 : 1)
                .onHover { hover = $0 }
                .animation(DS.Motion.snappy, value: hover)
        }
    }
}
