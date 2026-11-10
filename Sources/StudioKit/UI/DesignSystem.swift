// Shared design system: spacing, colours, motion and the small components every studio, library and editor view
// is built from. The debug-only gallery (`--design-gallery`) shows each component in its states and is the
// reference later UI work copies from.
import AppKit
import SwiftUI

enum DS {
    enum Space {
        static let xs: CGFloat = 4, s: CGFloat = 8, m: CGFloat = 12, l: CGFloat = 16, xl: CGFloat = 24, xxl: CGFloat = 32
    }
    enum Radius {
        static let control: CGFloat = 6, card: CGFloat = 10, panel: CGFloat = 14
    }

    /// Dynamic colours: the studio window is dark-only, the library and editor follow the system appearance.
    enum Palette {
        static func dynamic(_ name: String, light: NSColor, dark: NSColor) -> NSColor {
            NSColor(name: name) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light }
        }
        static func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> NSColor {
            NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
        }
        /// Behind the video: near black in both appearances, so letterboxing never flashes grey.
        static let canvas = dynamic("ds.canvas", light: rgb(12, 12, 14), dark: rgb(8, 8, 10))
        static let panel = dynamic("ds.panel", light: rgb(246, 246, 248), dark: rgb(26, 26, 30))
        static let raised = dynamic("ds.raised", light: rgb(255, 255, 255), dark: rgb(38, 38, 43))
        static let stroke = dynamic("ds.stroke", light: rgb(0, 0, 0, 0.10), dark: rgb(255, 255, 255, 0.09))
        static let textSecondary = NSColor.secondaryLabelColor
        static let record = dynamic("ds.record", light: rgb(235, 59, 48), dark: rgb(255, 69, 58))
        static let live = dynamic("ds.live", light: rgb(200, 52, 224), dark: rgb(222, 82, 245))
        static let ok = dynamic("ds.ok", light: rgb(40, 167, 69), dark: rgb(48, 209, 88))
        static let warn = dynamic("ds.warn", light: rgb(230, 140, 0), dark: rgb(255, 176, 32))
    }

    enum Color {
        static let canvas = SwiftUI.Color(nsColor: Palette.canvas)
        static let panel = SwiftUI.Color(nsColor: Palette.panel)
        static let raised = SwiftUI.Color(nsColor: Palette.raised)
        static let stroke = SwiftUI.Color(nsColor: Palette.stroke)
        static let textSecondary = SwiftUI.Color(nsColor: Palette.textSecondary)
        static let record = SwiftUI.Color(nsColor: Palette.record)
        static let live = SwiftUI.Color(nsColor: Palette.live)
        static let ok = SwiftUI.Color(nsColor: Palette.ok)
        static let warn = SwiftUI.Color(nsColor: Palette.warn)
    }

    enum Motion {
        static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
        /// Springs for state changes; with Reduce Motion on, a short cross-fade instead.
        static var snappy: Animation { reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.28, dampingFraction: 0.86) }
        static var gentle: Animation { reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.45, dampingFraction: 0.82) }
        static var fade: Animation { .easeInOut(duration: 0.25) }
        /// Moving transitions become plain opacity under Reduce Motion.
        static func transition(_ t: AnyTransition) -> AnyTransition { reduceMotion ? .opacity : t }
        /// Rolling digits and symbol swaps move content; under Reduce Motion they cross-fade.
        static var numericText: ContentTransition { reduceMotion ? .opacity : .numericText() }
        static var symbolReplace: ContentTransition { reduceMotion ? .opacity : .symbolEffect(.replace) }
        /// Press feedback scale; none under Reduce Motion.
        static func pressScale(_ pressed: Bool) -> CGFloat { pressed && !reduceMotion ? 0.97 : 1 }
    }
}

// MARK: - Buttons

/// Capsule button for primary actions (Record, Go Live). `prominent` fills it with the tint.
struct PillButton<Label: View>: View {
    var tint: SwiftUI.Color = .accentColor
    var prominent = false
    var help: String
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @Environment(\.isEnabled) private var enabled
    @State private var hover = false
    @State private var pressed = false

    var body: some View {
        Button(action: action) {
            label()
                .labelStyle(.titleAndIcon)   // inside a toolbar SwiftUI would otherwise drop the title
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, DS.Space.m).frame(height: 28)
                .foregroundStyle(prominent ? SwiftUI.Color.white : (enabled ? SwiftUI.Color.primary : SwiftUI.Color.secondary))
                .background {
                    Capsule().fill(prominent ? AnyShapeStyle(tint.opacity(hover ? 1 : 0.9)) : AnyShapeStyle(SwiftUI.Color.primary.opacity(hover ? 0.14 : 0.08)))
                }
                .overlay { Capsule().strokeBorder(SwiftUI.Color.white.opacity(prominent ? 0.18 : 0.06)) }
                .contentShape(Capsule())
                .scaleEffect(DS.Motion.pressScale(pressed))
                .opacity(enabled ? 1 : 0.5)
        }
        .buttonStyle(PressTracking(pressed: $pressed))
        .onHover { hover = $0 && enabled }
        .animation(DS.Motion.snappy, value: hover)
        .animation(DS.Motion.snappy, value: pressed)
        .help(help)
    }
}

extension PillButton where Label == SwiftUI.Label<Text, Image> {
    init(_ title: String, systemImage: String, tint: SwiftUI.Color = .accentColor, prominent: Bool = false, help: String, action: @escaping () -> Void) {
        self.init(tint: tint, prominent: prominent, help: help, action: action) { SwiftUI.Label(title, systemImage: systemImage) }
    }
}

/// Lets a custom-drawn button react to presses without the default bezel.
struct PressTracking: ButtonStyle {
    @Binding var pressed: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.onChange(of: configuration.isPressed) { _, v in pressed = v }
    }
}

/// Square icon button with hover highlight; `isOn` shows it latched.
struct IconButton: View {
    let systemImage: String
    let help: String
    var isOn = false
    var size: CGFloat = 28
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.48, weight: .medium))
                .frame(width: size, height: size)
                .foregroundStyle(isOn ? SwiftUI.Color.accentColor : SwiftUI.Color.primary.opacity(enabled ? 0.85 : 0.35))
                .background(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                    .fill(SwiftUI.Color.primary.opacity(isOn ? 0.14 : hover ? 0.09 : 0)))
                .contentShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 && enabled }
        .animation(DS.Motion.snappy, value: hover)
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Meter

/// Horizontal level meter in dBFS (-60...0) with a held peak. Green to -12 dB, yellow to -3 dB, red above.
struct MeterBar: View {
    var level: Float                 // linear peak 0...1
    var active = true
    var height: CGFloat = 6
    @State private var peak: Double = 0
    @State private var peakAt = Date.distantPast

    static let gradient = Gradient(stops: [
        .init(color: DS.Color.ok, location: 0), .init(color: DS.Color.ok, location: 0.76),
        .init(color: DS.Color.warn, location: 0.84), .init(color: DS.Color.warn, location: 0.93),
        .init(color: DS.Color.record, location: 0.97),
    ])

    var body: some View {
        let f = active ? StudioFormat.meterFraction(level) : 0
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(SwiftUI.Color.primary.opacity(0.10))
                LinearGradient(gradient: Self.gradient, startPoint: .leading, endPoint: .trailing)
                    .mask(alignment: .leading) { Capsule().frame(width: max(0, g.size.width * f)) }
                    .animation(.linear(duration: 0.06), value: f)
                if active && peak > 0.02 {
                    Capsule().fill(peak > 0.95 ? DS.Color.record : SwiftUI.Color.primary.opacity(0.8))
                        .frame(width: 2).offset(x: max(0, g.size.width * peak - 2))
                }
            }
        }
        .frame(height: height)
        .onChange(of: f) { _, v in
            let now = Date()
            if v >= peak || now.timeIntervalSince(peakAt) > 1.5 { peak = v; peakAt = now }
        }
        .accessibilityElement()
        .accessibilityLabel("Level")
        .accessibilityValue(active ? "\(Int(StudioFormat.dbfs(level))) decibels" : "off")
    }
}

// MARK: - Status and messages

/// Small capsule over the video: a status dot and a line of text on a material background.
struct StatusPill: View {
    let text: String
    var dot: SwiftUI.Color? = nil
    var pulsing = false
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 7) {
            if let dot = dot {
                Circle().fill(dot).frame(width: 7, height: 7)
                    .opacity(pulsing && pulse ? 0.35 : 1)
                    .animation(pulsing && !DS.Motion.reduceMotion ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default, value: pulse)
                    .onAppear { pulse = true }
            }
            Text(text).font(.system(size: 12, weight: .medium).monospacedDigit())
                .contentTransition(DS.Motion.numericText)
                .lineLimit(1)
        }
        .padding(.horizontal, 10).frame(height: 26)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(SwiftUI.Color.white.opacity(0.10)))
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .combine)
    }
}

struct ToastView: View {
    let toast: Toast
    var tint: SwiftUI.Color {
        switch toast.style { case .info: .accentColor; case .success: DS.Color.ok; case .warning: DS.Color.warn; case .error: DS.Color.record }
    }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
            Image(systemName: toast.symbol).foregroundStyle(tint).font(.system(size: 13, weight: .semibold))
            VStack(alignment: .leading, spacing: 2) {
                Text(toast.text).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                if let d = toast.detail { Text(d).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2) }
            }
        }
        .padding(.horizontal, DS.Space.l).padding(.vertical, 10)
        .frame(maxWidth: 420, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous).strokeBorder(SwiftUI.Color.white.opacity(0.10)))
        .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
        .accessibilityElement(children: .combine)
    }
}

struct EmptyState: View {
    let systemImage: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: DS.Space.m) {
            Image(systemName: systemImage)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.secondary)
                .frame(width: 64, height: 64)
                .background(Circle().fill(SwiftUI.Color.primary.opacity(0.06)))
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(message).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let t = actionTitle, let a = action {
                Button(t, action: a).controlSize(.regular).padding(.top, DS.Space.xs)
            }
        }
        .frame(maxWidth: 260)
        .padding(DS.Space.xl)
    }
}

// MARK: - Containers

/// Rounded panel with the library's hover lift.
struct Card<Content: View>: View {
    var selected = false
    var hoverLift = true
    @ViewBuilder let content: () -> Content
    @State private var hover = false

    var body: some View {
        content()
            .background(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).fill(DS.Color.raised))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .strokeBorder(selected ? SwiftUI.Color.accentColor : DS.Color.stroke, lineWidth: selected ? 2 : 1))
            .shadow(color: .black.opacity(hover && hoverLift ? 0.25 : 0.10), radius: hover && hoverLift ? 10 : 3, y: hover && hoverLift ? 4 : 1)
            .scaleEffect(hover && hoverLift && !DS.Motion.reduceMotion ? 1.012 : 1)
            .animation(DS.Motion.snappy, value: hover)
            .onHover { hover = $0 }
    }
}

/// Titled group in the inspector sidebar.
struct InspectorSection<Content: View>: View {
    let title: String
    var trailing: AnyView? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack {
                Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).kerning(0.6).foregroundStyle(.secondary)
                Spacer()
                trailing
            }
            .padding(.horizontal, DS.Space.xs)
            VStack(alignment: .leading, spacing: DS.Space.m) { content() }
                .padding(DS.Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).fill(SwiftUI.Color.primary.opacity(0.045)))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).strokeBorder(DS.Color.stroke))
        }
    }
}

/// A row label on the left, a control on the right, as in System Settings.
struct InspectorRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content
    var body: some View {
        HStack(spacing: DS.Space.m) {
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).layoutPriority(1)
            Spacer(minLength: 0)
            content()
        }
        .frame(minHeight: 22)
    }
}

// MARK: - Inputs

/// Segmented control with a sliding selection; options may carry an SF Symbol.
struct SegmentedSwitch<T: Hashable>: View {
    struct Option { let value: T; let label: String; var systemImage: String? = nil; var help: String? = nil }
    @Binding var selection: T
    let options: [Option]
    var iconOnly = false
    var height: CGFloat = 24
    @Namespace private var ns
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { o in
                let on = o.value == selection
                Button { withAnimation(DS.Motion.snappy) { selection = o.value } } label: {
                    Group {
                        if iconOnly, let s = o.systemImage { Image(systemName: s).font(.system(size: 12, weight: .medium)) }
                        else if let s = o.systemImage { SwiftUI.Label(o.label, systemImage: s).labelStyle(.titleAndIcon) }
                        else { Text(o.label) }
                    }
                    .font(.system(size: 12, weight: on ? .semibold : .regular))
                    .padding(.horizontal, iconOnly ? 0 : DS.Space.m)
                    .frame(maxWidth: .infinity, minHeight: height - 4, maxHeight: height - 4)
                    .foregroundStyle(on ? SwiftUI.Color.primary : SwiftUI.Color.secondary)
                    .background {
                        if on {
                            RoundedRectangle(cornerRadius: DS.Radius.control - 1, style: .continuous)
                                .fill(DS.Color.raised)
                                .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
                                .modifier(SlidingSelection(ns: ns))
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(o.help ?? o.label)
                .accessibilityLabel(o.label)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .frame(height: height)
        .background(RoundedRectangle(cornerRadius: DS.Radius.control + 1, style: .continuous).fill(SwiftUI.Color.primary.opacity(0.08)))
        .opacity(enabled ? 1 : 0.45)
    }
}

/// Slider with a monospaced read-out; double-click the label or value to reset to the default.
struct LabeledSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let defaultValue: Double
    var format: (Double) -> String = { String(format: "%.0f%%", $0 * 100) }
    var onEditingChanged: (Bool) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Text(format(value)).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                    .contentTransition(DS.Motion.numericText)
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { withAnimation(DS.Motion.snappy) { value = defaultValue } }
            Slider(value: $value, in: range, onEditingChanged: onEditingChanged).controlSize(.small)
        }
        .help("\(label): double-click to reset")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityValue(format(value))
    }
}

/// The segmented switch's highlight slides between options; under Reduce Motion it cross-fades in place.
private struct SlidingSelection: ViewModifier {
    let ns: Namespace.ID
    @ViewBuilder func body(content: Content) -> some View {
        if DS.Motion.reduceMotion { content.transition(.opacity) } else { content.matchedGeometryEffect(id: "sel", in: ns) }
    }
}
