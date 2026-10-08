import AppKit

enum ViewMode: Int {
    case history = 0
    case changes = 1
}

/// Per-tab UI state that survives unloading the views.
@MainActor
final class TabState {
    var mode: ViewMode = .history
    var selectedCommit: Hash20?
    var commitDraft = ""
    var amend = false
}

/// Banner shown while a merge/rebase/cherry-pick is in progress.
final class OperationBanner: NSView {
    let label = makeLabel("", font: .systemFont(ofSize: 12, weight: .medium))
    let continueButton = NSButton(title: "Continue", target: nil, action: nil)
    let skipButton = NSButton(title: "Skip", target: nil, action: nil)
    let abortButton = NSButton(title: "Abort", target: nil, action: nil)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.18).cgColor
        let icon = NSImageView(image: Theme.symbol("exclamationmark.triangle.fill", "Warning") ?? NSImage())
        icon.contentTintColor = .systemOrange
        for b in [continueButton, skipButton, abortButton] {
            b.bezelStyle = .rounded
            b.controlSize = .small
        }
        let stack = NSStackView(views: [icon, label, NSView(), continueButton, skipButton, abortButton])
        stack.orientation = .horizontal
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        addSubview(stack)
        stack.pinEdges(to: self)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 32).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.18).cgColor
    }
}

/// Spinner + progress text + cancel button at the bottom of the window.
final class ActivityBar: NSView {
    let spinner = NSProgressIndicator()
    let label = makeLabel("", font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
    let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)

    override init(frame: NSRect) {
        super.init(frame: frame)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        cancelButton.bezelStyle = .rounded
        cancelButton.controlSize = .small
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView(views: [spinner, label, NSView(), cancelButton])
        stack.orientation = .horizontal
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 10, bottom: 3, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(sep)
        addSubview(stack)
        NSLayoutConstraint.activate([
            sep.topAnchor.constraint(equalTo: topAnchor),
            sep.leadingAnchor.constraint(equalTo: leadingAnchor),
            sep.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: sep.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 28).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// Switches between the History and Changes screens, keeping only the active one alive.
final class ModeContainerViewController: NSViewController {
    let repository: Repository
    let state: TabState
    weak var actions: RepoWindowController?
    private(set) var history: HistoryViewController?
    private(set) var changes: ChangesViewController?

    init(repository: Repository, state: TabState, actions: RepoWindowController?) {
        self.repository = repository
        self.state = state
        self.actions = actions
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        show(state.mode)
    }

    func show(_ mode: ViewMode) {
        state.mode = mode
        let child: NSViewController
        switch mode {
        case .history:
            if history != nil { return }
            if let c = changes { c.view.removeFromSuperview(); c.removeFromParent(); changes = nil }
            let h = HistoryViewController(repository: repository, state: state, actions: actions)
            history = h
            child = h
        case .changes:
            if changes != nil { return }
            if let h = history { h.view.removeFromSuperview(); h.removeFromParent(); history = nil }
            let c = ChangesViewController(repository: repository, state: state, actions: actions)
            changes = c
            child = c
        }
        addChild(child)
        child.view.frame = view.bounds
        child.view.autoresizingMask = [.width, .height]
        view.addSubview(child.view)
    }

    var activeDiff: DiffViewController? {
        history?.detail.diffVC ?? changes?.diffVC
    }

    func handle(_ change: RepoChange) {
        history?.handle(change)
        changes?.handle(change)
    }
}

/// Sidebar | content split.
final class MainSplitViewController: NSSplitViewController {
    let sidebar: SidebarViewController
    let content: ModeContainerViewController

    init(repository: Repository, state: TabState, actions: RepoWindowController?) {
        sidebar = SidebarViewController(repository: repository, actions: actions)
        content = ModeContainerViewController(repository: repository, state: state, actions: actions)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        splitView.autosaveName = "MainSplit"
        let s = NSSplitViewItem(sidebarWithViewController: sidebar)
        s.minimumThickness = 170
        s.maximumThickness = 420
        s.canCollapse = true
        let c = NSSplitViewItem(viewController: content)
        addSplitViewItem(s)
        addSplitViewItem(c)
    }

    func handle(_ change: RepoChange) {
        sidebar.handle(change)
        content.handle(change)
    }
}

/// The window's permanent content view. The heavy part (split + screens) can
/// be unloaded when the tab goes to the background and rebuilt on return.
final class RootViewController: NSViewController {
    let repository: Repository
    let state: TabState
    weak var actions: RepoWindowController?
    private let stack = NSStackView()
    let banner = OperationBanner()
    let activityBar = ActivityBar()
    private(set) var main: MainSplitViewController?
    private let placeholder = NSView()

    init(repository: Repository, state: TabState, actions: RepoWindowController?) {
        self.repository = repository
        self.state = state
        self.actions = actions
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800))
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        stack.pinEdges(to: root)
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(banner)
        stack.addArrangedSubview(placeholder)
        stack.addArrangedSubview(activityBar)
        for v in [banner, placeholder, activityBar] {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        placeholder.setContentHuggingPriority(.init(1), for: .vertical)
        banner.isHidden = true
        activityBar.isHidden = true
        view = root
    }

    func loadContentIfNeeded() {
        guard main == nil else { return }
        _ = view
        let m = MainSplitViewController(repository: repository, state: state, actions: actions)
        addChild(m)
        m.view.translatesAutoresizingMaskIntoConstraints = false
        m.view.setContentHuggingPriority(.init(1), for: .vertical)
        let index = stack.arrangedSubviews.firstIndex(of: placeholder) ?? 1
        placeholder.removeFromSuperview()
        stack.insertArrangedSubview(m.view, at: index)
        m.view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        main = m
    }

    func unloadContent() {
        guard let m = main else { return }
        let index = stack.arrangedSubviews.firstIndex(of: m.view) ?? 1
        m.view.removeFromSuperview()
        m.removeFromParent()
        main = nil
        stack.insertArrangedSubview(placeholder, at: index)
        placeholder.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    func handle(_ change: RepoChange) {
        main?.handle(change)
    }
}
