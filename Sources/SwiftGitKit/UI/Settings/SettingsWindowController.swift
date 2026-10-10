import AppKit

/// SwiftGit › Settings… (⌘,): a single small pane.
final class SettingsWindowController: NSWindowController, NSComboBoxDelegate {
    static let shared = SettingsWindowController()

    private let fetchBox = NSButton(checkboxWithTitle: "Fetch when a repository tab gets focus", target: nil, action: nil)
    private let pullPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let autostashBox = NSButton(checkboxWithTitle: "Stash local changes automatically when pulling", target: nil, action: nil)
    private let topoBox = NSButton(checkboxWithTitle: "Group commits by branch (topological order)", target: nil, action: nil)
    private let claudeBox = NSButton(checkboxWithTitle: "Offer “Generate” with Claude in the pull request sheet", target: nil, action: nil)
    private let modelCombo = NSComboBox()
    private let claudeStatus = makeLabel("", font: .systemFont(ofSize: 11), color: .secondaryLabelColor)

    private init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 300),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "SwiftGit Settings"
        w.isReleasedWhenClosed = false
        super.init(window: w)
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func note(_ s: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: s)
        l.font = .systemFont(ofSize: 11)
        l.textColor = .secondaryLabelColor
        l.preferredMaxLayoutWidth = 400
        l.widthAnchor.constraint(equalToConstant: 400).isActive = true
        return l
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        for b in [fetchBox, autostashBox, topoBox, claudeBox] {
            b.target = self
            b.action = #selector(changed(_:))
        }
        pullPopup.addItems(withTitles: PullMode.allCases.map(\.title))
        pullPopup.target = self
        pullPopup.action = #selector(changed(_:))
        modelCombo.addItems(withObjectValues: ["haiku", "sonnet", "opus"])
        modelCombo.completes = true
        modelCombo.delegate = self
        modelCombo.target = self
        modelCombo.action = #selector(changed(_:))

        func label(_ s: String) -> NSTextField {
            let l = makeLabel(s)
            l.alignment = .right
            return l
        }
        func column(_ views: [NSView]) -> NSStackView {
            let s = NSStackView(views: views)
            s.orientation = .vertical
            s.alignment = .leading
            s.spacing = 3
            return s
        }
        let grid = NSGridView(views: [
            [label("Fetching:"), column([fetchBox, note("Quietly, at most every \(Int(Settings.focusFetchInterval)) seconds per repository. Failures (e.g. offline) are ignored.")])],
            [label("Pull:"), column([pullPopup, autostashBox, note("Without this, SwiftGit asks when local changes are in the way.")])],
            [label("History:"), topoBox],
            [label("Claude:"), column([claudeBox, NSStackView(views: [makeLabel("Model:"), modelCombo]), claudeStatus])],
        ])
        grid.rowSpacing = 14
        grid.columnSpacing = 10
        grid.rowAlignment = .firstBaseline
        grid.column(at: 0).xPlacement = .trailing
        grid.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
            grid.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20),
            grid.widthAnchor.constraint(equalToConstant: 500),
            modelCombo.widthAnchor.constraint(equalToConstant: 160),
        ])
        content.layoutSubtreeIfNeeded()
        window?.setContentSize(NSSize(width: 540, height: grid.fittingSize.height + 40))
    }

    func show() {
        load()
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func load() {
        fetchBox.state = Settings.fetchOnFocus ? .on : .off
        pullPopup.selectItem(at: PullMode.allCases.firstIndex(of: Settings.pullMode) ?? 0)
        autostashBox.state = Settings.autostash ? .on : .off
        topoBox.state = Settings.topoOrder ? .on : .off
        claudeBox.state = Settings.claudeEnabled ? .on : .off
        modelCombo.stringValue = Settings.claudeModel
        updateClaudeStatus()
    }

    private func updateClaudeStatus() {
        if let exe = ClaudeCLI.executable {
            claudeStatus.stringValue = "claude CLI: \(exe)"
        } else {
            claudeStatus.stringValue = "The claude CLI was not found, so the button is hidden."
        }
        modelCombo.isEnabled = claudeBox.state == .on
    }

    @objc private func changed(_ sender: Any?) {
        Settings.fetchOnFocus = fetchBox.state == .on
        Settings.pullMode = PullMode.allCases[max(0, pullPopup.indexOfSelectedItem)]
        Settings.autostash = autostashBox.state == .on
        Settings.claudeEnabled = claudeBox.state == .on
        Settings.claudeModel = modelCombo.stringValue
        if Settings.topoOrder != (topoBox.state == .on) {
            Settings.topoOrder = topoBox.state == .on
            NotificationCenter.default.post(name: RepoWindowController.historyOrderChanged, object: nil)
        }
        updateClaudeStatus()
    }

    func comboBoxSelectionDidChange(_ notification: Notification) {
        DispatchQueue.main.async { self.changed(nil) }
    }

    func controlTextDidEndEditing(_ obj: Notification) { changed(nil) }

    // MARK: Testing

    func testSet(fetch: Bool? = nil, pull: PullMode? = nil, autostash: Bool? = nil, model: String? = nil) {
        if let fetch { fetchBox.state = fetch ? .on : .off }
        if let pull { pullPopup.selectItem(at: PullMode.allCases.firstIndex(of: pull)!) }
        if let autostash { autostashBox.state = autostash ? .on : .off }
        if let model { modelCombo.stringValue = model }
        changed(nil)
    }
}
