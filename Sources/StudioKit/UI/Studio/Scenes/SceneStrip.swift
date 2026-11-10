// The scene strip in the bottom bar: one card per scene with a live thumbnail, its name and shortcut. Click switches,
// drag reorders, right-click renames, duplicates, deletes or updates a scene; the plus button adds one from a template.
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SceneStrip: View {
    let state: StudioState
    @State private var dragging: UUID?

    var body: some View {
        let m = state.scenes
        HStack(spacing: DS.Space.s) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DS.Space.s) {
                        ForEach(Array(m.collection.scenes.enumerated()), id: \.element.id) { i, s in
                            SceneCard(model: m, scene: s, index: i)
                                .id(s.id)
                                .onDrag {
                                    dragging = s.id
                                    return NSItemProvider(object: s.id.uuidString as NSString)
                                }
                                .onDrop(of: [UTType.text], delegate: SceneDropDelegate(target: s.id, model: m, dragging: $dragging))
                        }
                    }
                    .padding(.vertical, 6).padding(.horizontal, 2)
                }
                .onChange(of: m.collection.activeID) { _, id in withAnimation(DS.Motion.gentle) { proxy.scrollTo(id) } }
            }
            AddSceneButton(model: m)
        }
        .onDrop(of: [UTType.text], isTargeted: nil) { _ in dragging = nil; return true }
    }
}

/// Reorders live while a card is dragged over another.
private struct SceneDropDelegate: DropDelegate {
    let target: UUID
    let model: SceneModel
    @Binding var dragging: UUID?
    func dropEntered(info: DropInfo) {
        guard let d = dragging, d != target, let to = model.collection.index(of: target) else { return }
        withAnimation(DS.Motion.snappy) { model.actions.move(d, to) }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool { dragging = nil; return true }
}

struct SceneCard: View {
    let model: SceneModel
    let scene: Scene
    let index: Int
    @State private var hover = false
    @State private var sweep: CGFloat = 1
    @State private var name = ""
    @FocusState private var nameFocused: Bool

    var active: Bool { model.collection.activeID == scene.id }
    var shortcut: String? { index < 9 ? "⌃\(index + 1)" : nil }

    var body: some View {
        let renaming = model.renamingSceneID == scene.id
        let shape = RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
        HStack(spacing: DS.Space.s) {
            SceneThumbnail(model: model, sceneID: scene.id, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                if renaming {
                    TextField("Name", text: $name)
                        .textFieldStyle(.plain).font(.system(size: 12, weight: .semibold))
                        .focused($nameFocused)
                        .onSubmit { model.actions.rename(scene.id, name) }
                        .onExitCommand { model.renamingSceneID = nil }
                        .onAppear { name = scene.name; DispatchQueue.main.async { nameFocused = true } }
                        .onChange(of: nameFocused) { _, f in if !f && model.renamingSceneID == scene.id { model.actions.rename(scene.id, name) } }
                } else {
                    Text(scene.name).font(.system(size: 12, weight: active ? .semibold : .medium)).lineLimit(1)
                        .foregroundStyle(active ? Color.primary : Color.primary.opacity(0.85))
                }
                Text(shortcut ?? " ")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(active ? Color.accentColor : Color.secondary)
            }
            .frame(minWidth: 64, maxWidth: 104, alignment: .leading)
        }
        .padding(.leading, 4).padding(.trailing, 10).frame(height: 48)
        .background(shape.fill(Color.white.opacity(active ? 0.10 : hover ? 0.075 : 0.045)))
        .overlay(shape.strokeBorder(active ? Color.accentColor.opacity(0.35) : DS.Color.stroke, lineWidth: 1))
        .overlay(shape.inset(by: 0.75).trim(from: 0, to: active ? sweep : 0).stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, lineCap: .round)))
        .contentShape(shape)
        .scaleEffect(hover && !active && !DS.Motion.reduceMotion ? 1.02 : 1)
        .onHover { hover = $0 }
        .animation(DS.Motion.snappy, value: hover)
        .animation(DS.Motion.snappy, value: active)
        .onTapGesture { model.actions.switchTo(scene.id) }
        .onChange(of: model.transition) { _, t in
            // The ring draws itself around the card being switched to, in step with the transition.
            guard let t = t, t.id == scene.id, t.duration > 0, !DS.Motion.reduceMotion else { sweep = 1; return }
            sweep = 0
            withAnimation(.timingCurve(0.2, 0.9, 0.3, 1, duration: t.duration)) { sweep = 1 }
        }
        .contextMenu {
            Button("Rename") { model.renamingSceneID = scene.id }
            Button("Duplicate") { model.actions.duplicate(scene.id) }
            Button("Update from Current Layout") { model.actions.updateFromCurrent(scene.id) }
                .disabled(active)
            Divider()
            Button("Delete", role: .destructive) { model.actions.delete(scene.id) }
                .disabled(model.collection.scenes.count < 2)
        }
        .help(active ? "\(scene.name) is showing. Drag to reorder, right-click for more." : "Switch to \(scene.name)\(shortcut.map { " (\($0))" } ?? ""). Drag to reorder, right-click for more.")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(scene.name)
        .accessibilityValue(active ? "Showing" : "")
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { model.actions.switchTo(scene.id) }
    }
}

/// A scene's live picture; a quiet placeholder until the first one is rendered.
struct SceneThumbnail: View {
    let model: SceneModel
    let sceneID: UUID
    let height: CGFloat

    var body: some View {
        let th = model.thumbnails, vertical = th.canvas == .vertical
        let w = vertical ? height * 9 / 16 : height * 16 / 9
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        ZStack {
            shape.fill(LinearGradient(colors: [Color(white: 0.2), Color(white: 0.12)], startPoint: .top, endPoint: .bottom))
            if let img = th.images[sceneID] {
                Image(decorative: img, scale: 1).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            }
        }
        .frame(width: w, height: height)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.white.opacity(0.08)))
        .frame(width: height * 16 / 9)   // cards keep their width when the canvas turns vertical
    }
}

struct AddSceneButton: View {
    let model: SceneModel
    @State private var hover = false

    var body: some View {
        Button { model.galleryOpen.toggle() } label: {
            Image(systemName: "plus").font(.system(size: 13, weight: .medium))
                .foregroundStyle(hover ? Color.primary : Color.secondary)
                .frame(width: 40, height: 48)
                .background(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .fill(Color.white.opacity(hover ? 0.06 : 0)))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 3])).foregroundStyle(DS.Color.stroke))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("Add a scene")
        .accessibilityLabel("Add scene")
        // While the gallery is open its templates get live thumbnails too.
        .popover(isPresented: Binding(get: { model.galleryOpen }, set: { model.galleryOpen = $0 }), arrowEdge: .top) {
            SceneTemplateGallery(model: model) { model.galleryOpen = false }
        }
    }
}

struct SceneTemplateGallery: View {
    let model: SceneModel
    let done: () -> Void

    var body: some View {
        let columns = Array(repeating: GridItem(.fixed(150), spacing: DS.Space.m, alignment: .top), count: 3)
        VStack(alignment: .leading, spacing: DS.Space.m) {
            Text("Add a Scene").font(.system(size: 13, weight: .semibold))
            section("Layouts")
            LazyVGrid(columns: columns, alignment: .leading, spacing: DS.Space.l) {
                ForEach(model.templates.filter { !$0.template.isScreen }, id: \.template) { t in
                    TemplateCard(model: model, template: t.template, previewID: t.scene.id) { model.actions.add(t.template); done() }
                }
                TemplateCard(model: model, template: nil, previewID: model.active.id) { model.actions.duplicate(model.active.id); done() }
            }
            section("Screens")
            LazyVGrid(columns: columns, alignment: .leading, spacing: DS.Space.l) {
                ForEach(model.templates.filter { $0.template.isScreen }, id: \.template) { t in
                    TemplateCard(model: model, template: t.template, previewID: t.scene.id) { model.actions.add(t.template); done() }
                }
            }
        }
        .padding(DS.Space.l)
        .environment(\.colorScheme, .dark)
    }

    private func section(_ title: String) -> some View {
        Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).kerning(0.6).foregroundStyle(.secondary).padding(.top, 2)
    }
}

private struct TemplateCard: View {
    let model: SceneModel
    let template: SceneTemplate?     // nil: duplicate the active scene
    let previewID: UUID
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                SceneThumbnail(model: model, sceneID: previewID, height: 150 * 9 / 16)
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.accentColor, lineWidth: hover ? 2 : 0))
                Text(template?.name ?? "Copy of \(model.active.name)").font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(template?.summary ?? "The scene showing now, to change from there").font(.system(size: 10)).foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
            }
            .frame(width: 150, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(DS.Motion.snappy, value: hover)
    }
}
