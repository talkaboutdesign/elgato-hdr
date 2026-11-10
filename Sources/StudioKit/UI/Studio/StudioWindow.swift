// The studio window: live picture in the middle, bottom bar, inspector sidebar and a unified toolbar.
// Built in AppKit so the MetalView is a plain subview: SwiftUI never re-lays-out its CAMetalLayer.
import AppKit
import SwiftUI
import Observation

/// AppKit's bridge to `@Observable`: `apply` runs with the value `read` returns, again whenever a property `read`
/// touched changes. Only `read` is tracked, so `apply` may change other observable state without looping.
func trackChanges<T>(_ read: @escaping () -> T, _ apply: @escaping (T) -> Void) {
    let v = withObservationTracking(read) { DispatchQueue.main.async { trackChanges(read, apply) } }
    apply(v)
}

final class StudioWindowController: NSWindowController, NSToolbarDelegate {
    let state: StudioState
    let stage: StageViewController
    let split = StudioSplitViewController()
    let sidebarItem: NSSplitViewItem
    private var collapseObservation: NSKeyValueObservation?

    init(state: StudioState, metalView: MetalView) {
        self.state = state
        stage = StageViewController(state: state, metalView: metalView)
        let sidebar = NSHostingController(rootView: StudioSidebar(state: state))
        sidebar.sizingOptions = []
        sidebarItem = NSSplitViewItem(inspectorWithViewController: sidebar)
        sidebarItem.minimumThickness = 300
        sidebarItem.maximumThickness = 380
        sidebarItem.canCollapse = true
        sidebarItem.isCollapsed = UserDefaults.standard.bool(forKey: "sidebarHidden")
        let stageItem = NSSplitViewItem(viewController: stage)
        stageItem.minimumThickness = 560
        stageItem.holdingPriority = .defaultLow
        split.splitViewItems = [stageItem, sidebarItem]

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 860),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.title = AppInfo.name
        w.appearance = NSAppearance(named: .darkAqua)          // the studio is dark-only, whatever the system uses
        w.backgroundColor = DS.Palette.canvas
        w.toolbarStyle = .unified
        w.titlebarSeparatorStyle = .automatic
        w.collectionBehavior = [.fullScreenPrimary]
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 960, height: 600)
        w.contentViewController = split
        w.setContentSize(NSSize(width: 1440, height: 860))
        w.center()
        w.setFrameAutosaveName("StudioWindow")
        super.init(window: w)

        let tb = NSToolbar(identifier: "StudioToolbar")
        tb.delegate = self
        tb.displayMode = .iconOnly
        tb.allowsUserCustomization = false
        tb.centeredItemIdentifiers = [.canvas]
        w.toolbar = tb

        split.onToggleInspector = { [weak state] in state?.actions.toggleSidebar() }
        state.sidebarVisible = !sidebarItem.isCollapsed
        collapseObservation = sidebarItem.observe(\.isCollapsed, options: [.new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.state.sidebarVisible = !item.isCollapsed
                if !self.state.focusMode { UserDefaults.standard.set(item.isCollapsed, forKey: "sidebarHidden") }
            }
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    func setSidebar(visible: Bool, animated: Bool) {
        guard sidebarItem.isCollapsed == visible else { return }
        if animated { sidebarItem.animator().isCollapsed = !visible } else { sidebarItem.isCollapsed = !visible }
    }

    // MARK: Toolbar

    func toolbarDefaultItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, .canvas, .flexibleSpace, .record, .goLive, .inspectorTrackingSeparator, .flexibleSpace, .toggleInspector]
    }
    func toolbarAllowedItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(t) + [.space] }

    func toolbar(_ t: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar: Bool) -> NSToolbarItem? {
        func hosted<V: View>(_ v: V, label: String, tip: String) -> NSToolbarItem {
            let item = NSToolbarItem(itemIdentifier: id)
            let host = NSHostingView(rootView: v.environment(\.colorScheme, .dark))
            host.sizingOptions = [.intrinsicContentSize]
            item.view = host
            item.label = label; item.paletteLabel = label; item.toolTip = tip
            item.visibilityPriority = .high
            return item
        }
        switch id {
        case .canvas: return hosted(CanvasSwitch(), label: "Canvas", tip: "Live 16:9 and 9:16 canvases are coming with scenes")
        case .record: return hosted(RecordButton(state: state), label: "Record", tip: "Start or stop recording (⌘R)")
        case .goLive: return hosted(GoLiveButton(state: state), label: "Go Live", tip: "Streaming arrives in a later update")
        default: return nil
        }
    }
}

/// The toolbar's system inspector button sends `toggleInspector(_:)` here; it takes the same path as ⌥⌘S so focus
/// mode is handled in one place.
final class StudioSplitViewController: NSSplitViewController {
    var onToggleInspector: (() -> Void)?
    override func toggleInspector(_ sender: Any?) {
        if let h = onToggleInspector { h() } else { super.toggleInspector(sender) }
    }
}

extension NSToolbarItem.Identifier {
    static let canvas = NSToolbarItem.Identifier("studio.canvas")
    static let record = NSToolbarItem.Identifier("studio.record")
    static let goLive = NSToolbarItem.Identifier("studio.goLive")
}

// MARK: - Stage

/// Pill visibility lives here, not in StudioState: it is window chrome and changes on every mouse move.
@Observable final class StageChrome {
    var pillVisible = true
}

/// The left side of the split: MetalView, the bottom bar, and small overlays (pill, toast, placeholder) that are
/// hidden, not just transparent, when not shown so nothing sits over the picture.
final class StageViewController: NSViewController {
    let state: StudioState
    let metalView: MetalView
    let chrome = StageChrome()
    private var bottomBar: NSView!
    private var pillHost: NSView!, toastHost: NSView!, placeholderHost: NSView!
    private var videoTopToSafeArea: NSLayoutConstraint!, videoTopToEdge: NSLayoutConstraint!
    private var videoBottomToBar: NSLayoutConstraint!, videoBottomToEdge: NSLayoutConstraint!
    private var hidePill: DispatchWorkItem?
    static let barHeight: CGFloat = 64

    init(state: StudioState, metalView: MetalView) {
        self.state = state; self.metalView = metalView
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1140, height: 800))
        root.wantsLayer = true
        root.layer?.backgroundColor = DS.Palette.canvas.cgColor
        view = root

        metalView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(metalView)

        let bar = NSHostingView(rootView: BottomBar(state: state).environment(\.colorScheme, .dark))
        bar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(bar)
        bottomBar = bar

        let pill = NSHostingView(rootView: PillOverlay(state: state, chrome: chrome))
        pill.sizingOptions = [.intrinsicContentSize]
        pill.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(pill)
        pillHost = pill

        let toast = NSHostingView(rootView: ToastOverlay(state: state).environment(\.colorScheme, .dark))
        toast.sizingOptions = [.intrinsicContentSize]
        toast.translatesAutoresizingMaskIntoConstraints = false
        toast.isHidden = true
        root.addSubview(toast)
        toastHost = toast

        let placeholder = NSHostingView(rootView: StagePlaceholder(state: state).environment(\.colorScheme, .dark))
        placeholder.sizingOptions = [.intrinsicContentSize]
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(placeholder)
        placeholderHost = placeholder

        let safe = root.safeAreaLayoutGuide
        videoTopToSafeArea = metalView.topAnchor.constraint(equalTo: safe.topAnchor)
        videoTopToEdge = metalView.topAnchor.constraint(equalTo: root.topAnchor)
        videoBottomToBar = metalView.bottomAnchor.constraint(equalTo: bar.topAnchor)
        videoBottomToEdge = metalView.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        NSLayoutConstraint.activate([
            videoTopToSafeArea, videoBottomToBar,
            metalView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            metalView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: Self.barHeight),
            pill.leadingAnchor.constraint(equalTo: metalView.leadingAnchor, constant: DS.Space.l),
            pill.bottomAnchor.constraint(equalTo: metalView.bottomAnchor, constant: -DS.Space.l),
            toast.centerXAnchor.constraint(equalTo: metalView.centerXAnchor),
            toast.topAnchor.constraint(equalTo: metalView.topAnchor, constant: DS.Space.l),
            toast.widthAnchor.constraint(lessThanOrEqualTo: metalView.widthAnchor, constant: -2 * DS.Space.l),
            placeholder.centerXAnchor.constraint(equalTo: metalView.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: metalView.centerYAnchor),
        ])

        metalView.onMouseActivity = { [weak self] in self?.showPill() }
        observeOverlays()
    }

    private func observeOverlays() {
        let state = state
        trackChanges({ state.connection == .live || state.connection == .demo }) { [weak self] live in
            guard let self = self else { return }
            self.placeholderHost.isHidden = live
            self.showPill(autoHide: live)
        }
        trackChanges({ state.toast != nil }) { [weak self] shown in
            guard let self = self else { return }
            if shown { self.toastHost.isHidden = false }
            else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { if self.state.toast == nil { self.toastHost.isHidden = true } } }
        }
    }

    /// Shows the status pill; while the picture is live it fades out after 3 s without mouse movement.
    func showPill(autoHide: Bool = true) {
        hidePill?.cancel()
        if pillHost.isHidden { pillHost.isHidden = false }
        if !chrome.pillVisible { withAnimation(DS.Motion.fade) { chrome.pillVisible = true } }
        guard autoHide else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.state.connection == .live || self.state.connection == .demo else { return }
            withAnimation(.easeOut(duration: 0.4)) { self.chrome.pillVisible = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { if !self.chrome.pillVisible { self.pillHost.isHidden = true } }
        }
        hidePill = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    /// Focus mode: the picture takes the whole window (the toolbar overlays it only when revealed).
    func setFocus(_ on: Bool) {
        bottomBar.isHidden = on
        NSLayoutConstraint.deactivate(on ? [videoTopToSafeArea, videoBottomToBar] : [videoTopToEdge, videoBottomToEdge])
        NSLayoutConstraint.activate(on ? [videoTopToEdge, videoBottomToEdge] : [videoTopToSafeArea, videoBottomToBar])
    }
}
