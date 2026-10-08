import AppKit

/// Unstaged / staged file lists and the commit box on the left, diff on the right.
final class ChangesViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate, NSTextViewDelegate {
    let repository: Repository
    let state: TabState
    weak var actions: RepoWindowController?
    let diffVC: DiffViewController

    private let unstagedTable = KeyTableView()
    private let stagedTable = KeyTableView()
    private var unstagedItems: [FileChange] = []
    private var stagedItems: [FileChange] = []
    private let unstagedTitle = makeLabel("Unstaged", font: .systemFont(ofSize: 11, weight: .semibold), color: .secondaryLabelColor)
    private let stagedTitle = makeLabel("Staged", font: .systemFont(ofSize: 11, weight: .semibold), color: .secondaryLabelColor)
    private let stageAllButton = NSButton(title: "Stage All", target: nil, action: nil)
    private let unstageAllButton = NSButton(title: "Unstage All", target: nil, action: nil)
    private let messageScroll = NSTextView.scrollableTextView()
    private var messageView: NSTextView { messageScroll.documentView as! NSTextView }
    private let amendBox = NSButton(checkboxWithTitle: "Amend", target: nil, action: nil)
    private let commitButton = NSButton(title: "Commit", target: nil, action: nil)
    private let branchHint = makeLabel("", font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
    private var updatingSelection = false
    private let split = NSSplitView()
    private let splitRules = SplitRules(minFirst: 260, minSecond: 300, initial: { _ in 340 })

    init(repository: Repository, state: TabState, actions: RepoWindowController?) {
        self.repository = repository
        self.state = state
        self.actions = actions
        self.diffVC = DiffViewController(repository: repository)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupTable(_ t: KeyTableView) -> NSScrollView {
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        col.resizingMask = .autoresizingMask
        t.addTableColumn(col)
        t.headerView = nil
        t.style = .plain
        t.rowHeight = 20
        t.allowsMultipleSelection = true
        t.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        t.dataSource = self
        t.delegate = self
        t.target = self
        t.doubleAction = #selector(doubleClicked(_:))
        let menu = NSMenu()
        menu.delegate = self
        t.menu = menu
        t.onKey = { [weak self, weak t] key in
            guard let self, let t else { return false }
            switch key {
            case "space", "return":
                self.toggleStage(t)
                return true
            case "delete":
                if t === self.unstagedTable { self.discardSelected() }
                return true
            default:
                return false
            }
        }
        return makeScrollingTable(t)
    }

    override func loadView() {
        let left = NSView()

        let unstagedScroll = setupTable(unstagedTable)
        let stagedScroll = setupTable(stagedTable)
        for b in [stageAllButton, unstageAllButton] {
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.target = self
        }
        stageAllButton.action = #selector(stageAll(_:))
        unstageAllButton.action = #selector(unstageAll(_:))

        let unstagedHeader = NSStackView(views: [unstagedTitle, NSView(), stageAllButton])
        let stagedHeader = NSStackView(views: [stagedTitle, NSView(), unstageAllButton])
        for h in [unstagedHeader, stagedHeader] {
            h.orientation = .horizontal
            h.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 8)
            h.translatesAutoresizingMaskIntoConstraints = false
        }

        messageView.isRichText = false
        messageView.font = .systemFont(ofSize: 13)
        messageView.isAutomaticQuoteSubstitutionEnabled = false
        messageView.isAutomaticDashSubstitutionEnabled = false
        messageView.isAutomaticTextReplacementEnabled = false
        messageView.allowsUndo = true
        messageView.delegate = self
        messageView.textContainerInset = NSSize(width: 4, height: 6)
        messageView.string = state.commitDraft
        messageScroll.hasVerticalScroller = true
        messageScroll.autohidesScrollers = true
        messageScroll.borderType = .bezelBorder
        messageScroll.translatesAutoresizingMaskIntoConstraints = false

        amendBox.target = self
        amendBox.action = #selector(amendChanged(_:))
        amendBox.state = state.amend ? .on : .off
        commitButton.bezelStyle = .rounded
        commitButton.keyEquivalent = "\r"
        commitButton.keyEquivalentModifierMask = [.command]
        commitButton.target = self
        commitButton.action = #selector(commit(_:))
        commitButton.toolTip = "Commit (⌘↩)"
        let commitRow = NSStackView(views: [amendBox, branchHint, NSView(), commitButton])
        commitRow.orientation = .horizontal
        commitRow.translatesAutoresizingMaskIntoConstraints = false

        let topSep = NSBox(); topSep.boxType = .separator; topSep.translatesAutoresizingMaskIntoConstraints = false
        let midSep = NSBox(); midSep.boxType = .separator; midSep.translatesAutoresizingMaskIntoConstraints = false
        let botSep = NSBox(); botSep.boxType = .separator; botSep.translatesAutoresizingMaskIntoConstraints = false

        for v in [unstagedHeader, topSep, unstagedScroll, midSep, stagedHeader, stagedScroll, botSep, messageScroll, commitRow] as [NSView] {
            left.addSubview(v)
        }
        NSLayoutConstraint.activate([
            unstagedHeader.topAnchor.constraint(equalTo: left.topAnchor),
            unstagedHeader.leadingAnchor.constraint(equalTo: left.leadingAnchor),
            unstagedHeader.trailingAnchor.constraint(equalTo: left.trailingAnchor),
            topSep.topAnchor.constraint(equalTo: unstagedHeader.bottomAnchor),
            topSep.leadingAnchor.constraint(equalTo: left.leadingAnchor),
            topSep.trailingAnchor.constraint(equalTo: left.trailingAnchor),
            unstagedScroll.topAnchor.constraint(equalTo: topSep.bottomAnchor),
            unstagedScroll.leadingAnchor.constraint(equalTo: left.leadingAnchor),
            unstagedScroll.trailingAnchor.constraint(equalTo: left.trailingAnchor),
            midSep.topAnchor.constraint(equalTo: unstagedScroll.bottomAnchor),
            midSep.leadingAnchor.constraint(equalTo: left.leadingAnchor),
            midSep.trailingAnchor.constraint(equalTo: left.trailingAnchor),
            stagedHeader.topAnchor.constraint(equalTo: midSep.bottomAnchor),
            stagedHeader.leadingAnchor.constraint(equalTo: left.leadingAnchor),
            stagedHeader.trailingAnchor.constraint(equalTo: left.trailingAnchor),
            stagedScroll.topAnchor.constraint(equalTo: stagedHeader.bottomAnchor),
            stagedScroll.leadingAnchor.constraint(equalTo: left.leadingAnchor),
            stagedScroll.trailingAnchor.constraint(equalTo: left.trailingAnchor),
            stagedScroll.heightAnchor.constraint(equalTo: unstagedScroll.heightAnchor),
            botSep.topAnchor.constraint(equalTo: stagedScroll.bottomAnchor),
            botSep.leadingAnchor.constraint(equalTo: left.leadingAnchor),
            botSep.trailingAnchor.constraint(equalTo: left.trailingAnchor),
            messageScroll.topAnchor.constraint(equalTo: botSep.bottomAnchor, constant: 8),
            messageScroll.leadingAnchor.constraint(equalTo: left.leadingAnchor, constant: 8),
            messageScroll.trailingAnchor.constraint(equalTo: left.trailingAnchor, constant: -8),
            messageScroll.heightAnchor.constraint(equalToConstant: 96),
            commitRow.topAnchor.constraint(equalTo: messageScroll.bottomAnchor, constant: 6),
            commitRow.leadingAnchor.constraint(equalTo: left.leadingAnchor, constant: 8),
            commitRow.trailingAnchor.constraint(equalTo: left.trailingAnchor, constant: -8),
            commitRow.bottomAnchor.constraint(equalTo: left.bottomAnchor, constant: -8),
        ])

        split.isVertical = true
        split.dividerStyle = .thin
        split.autosaveName = "ChangesSplit"
        split.delegate = splitRules
        addChild(diffVC)
        split.addArrangedSubview(left)
        split.addArrangedSubview(diffVC.view)
        split.setHoldingPriority(.init(260), forSubviewAt: 0)
        view = split
        reloadLists()
        updateCommitControls()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        splitRules.enforce(split)
    }

    var testUnstaged: [FileChange] { unstagedItems }
    var testStaged: [FileChange] { stagedItems }

    // MARK: Updates

    func handle(_ change: RepoChange) {
        switch change {
        case .status:
            reloadLists()
            updateCommitControls()
        case .refs, .graph, .summaries, .activity:
            break
        }
    }

    private func reloadLists() {
        let s = repository.status
        let selUnstaged = Set(unstagedTable.selectedRowIndexes.compactMap { $0 < unstagedItems.count ? unstagedItems[$0].path : nil })
        let selStaged = Set(stagedTable.selectedRowIndexes.compactMap { $0 < stagedItems.count ? stagedItems[$0].path : nil })
        unstagedItems = s.conflicts + s.unstaged
        stagedItems = s.staged
        updatingSelection = true
        unstagedTable.reloadData()
        stagedTable.reloadData()
        unstagedTable.selectRowIndexes(IndexSet(unstagedItems.indices.filter { selUnstaged.contains(unstagedItems[$0].path) }), byExtendingSelection: false)
        stagedTable.selectRowIndexes(IndexSet(stagedItems.indices.filter { selStaged.contains(stagedItems[$0].path) }), byExtendingSelection: false)
        updatingSelection = false

        unstagedTitle.stringValue = "Unstaged (\(unstagedItems.count))"
        stagedTitle.stringValue = "Staged (\(stagedItems.count))"
        stageAllButton.isEnabled = !unstagedItems.isEmpty
        unstageAllButton.isEnabled = !stagedItems.isEmpty

        // Keep showing the same file if it is still listed, otherwise follow it or clear.
        switch diffVC.source {
        case .working(let c, let staged):
            let list = staged ? stagedItems : unstagedItems
            if let same = list.first(where: { $0.path == c.path }) {
                if same == c { diffVC.refresh() } else { diffVC.show(.working(same, staged: staged)) }
            } else if let other = (staged ? unstagedItems : stagedItems).first(where: { $0.path == c.path }) {
                diffVC.show(.working(other, staged: !staged))
                selectOnly(path: c.path, staged: !staged)
            } else {
                diffVC.show(.none)
            }
        default:
            if let first = unstagedItems.first ?? stagedItems.first {
                let staged = unstagedItems.isEmpty
                diffVC.show(.working(first, staged: staged))
                selectOnly(path: first.path, staged: staged)
            }
        }
    }

    private func selectOnly(path: String, staged: Bool) {
        updatingSelection = true
        let (table, items, other) = staged ? (stagedTable, stagedItems, unstagedTable) : (unstagedTable, unstagedItems, stagedTable)
        other.deselectAll(nil)
        if let i = items.firstIndex(where: { $0.path == path }) {
            table.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false)
        }
        updatingSelection = false
    }

    private func updateCommitControls() {
        let s = repository.status
        let merging = repository.opState == .merging
        commitButton.title = merging ? "Commit Merge" : (amendBox.state == .on ? "Amend" : "Commit")
        let hasMessage = !messageView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        commitButton.isEnabled = hasMessage && (!s.staged.isEmpty || amendBox.state == .on || merging) && s.conflicts.isEmpty
        branchHint.stringValue = s.branch.map { "to \($0)" } ?? "detached HEAD"
        if merging, messageView.string.isEmpty, let msg = repository.mergeMessage() {
            messageView.string = msg
            state.commitDraft = msg
            commitButton.isEnabled = s.conflicts.isEmpty
        }
    }

    func textDidChange(_ notification: Notification) {
        state.commitDraft = messageView.string
        updateCommitControls()
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === stagedTable ? stagedItems.count : unstagedItems.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let items = tableView === stagedTable ? stagedItems : unstagedItems
        guard row < items.count else { return nil }
        let id = NSUserInterfaceItemIdentifier("changeCell")
        let v = tableView.makeView(withIdentifier: id, owner: nil) as? TextCellView ?? {
            let v = TextCellView(font: .systemFont(ofSize: 12), color: .labelColor)
            v.identifier = id
            return v
        }()
        v.label.attributedStringValue = fileTitle(items[row])
        v.toolTip = items[row].path
        return v
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !updatingSelection, let table = notification.object as? NSTableView else { return }
        let staged = table === stagedTable
        let items = staged ? stagedItems : unstagedItems
        guard table.selectedRow >= 0, table.selectedRow < items.count else { return }
        updatingSelection = true
        (staged ? unstagedTable : stagedTable).deselectAll(nil)
        updatingSelection = false
        diffVC.show(.working(items[table.selectedRow], staged: staged))
    }

    private func selected(_ table: NSTableView) -> [FileChange] {
        let items = table === stagedTable ? stagedItems : unstagedItems
        var rows = table.selectedRowIndexes
        if table.clickedRow >= 0 && !rows.contains(table.clickedRow) { rows = IndexSet(integer: table.clickedRow) }
        return rows.compactMap { $0 < items.count ? items[$0] : nil }
    }

    private func toggleStage(_ table: NSTableView) {
        let files = selected(table)
        guard !files.isEmpty else { return }
        Task {
            if table === stagedTable { await repository.unstage(files) } else { await repository.stage(files) }
        }
    }

    @objc private func doubleClicked(_ sender: NSTableView) {
        guard sender.clickedRow >= 0 else { return }
        toggleStage(sender)
    }

    @objc private func stageAll(_ sender: Any?) {
        Task { await repository.stageAll() }
    }

    @objc private func unstageAll(_ sender: Any?) {
        Task { await repository.unstageAll() }
    }

    private func discardSelected() {
        let files = selected(unstagedTable).filter { !$0.isConflict }
        guard !files.isEmpty else { return }
        Task {
            let names = files.prefix(5).map(\.path).joined(separator: "\n") + (files.count > 5 ? "\n…" : "")
            guard await Prompt.confirm(view.window, title: "Discard changes in \(files.count) file\(files.count == 1 ? "" : "s")?",
                                       message: names + "\n\nUntracked files are moved to the Trash.", ok: "Discard", destructive: true) else { return }
            await repository.discard(files)
        }
    }

    // MARK: Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let table = [unstagedTable, stagedTable].first(where: { $0.menu === menu }) else { return }
        let files = selected(table)
        guard !files.isEmpty else { return }
        func add(_ title: String, _ action: Selector) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = table
        }
        if table === stagedTable {
            add("Unstage", #selector(menuUnstage(_:)))
        } else {
            add(files.contains(where: \.isConflict) ? "Mark Resolved (Stage)" : "Stage", #selector(menuStage(_:)))
            if files.count == 1, files[0].isConflict {
                add("Open in Merge Tool", #selector(menuMergetool(_:)))
            }
            menu.addItem(.separator())
            add("Discard Changes…", #selector(menuDiscard(_:)))
        }
        menu.addItem(.separator())
        if files.count == 1 && !files[0].isConflict {
            add("Open in Diff Tool", #selector(menuDifftool(_:)))
        }
        add("Open File", #selector(menuOpenFile(_:)))
        add("Show in Finder", #selector(menuReveal(_:)))
        add("Copy Path", #selector(menuCopyPath(_:)))
    }

    private func files(from item: NSMenuItem) -> [FileChange] {
        guard let t = item.representedObject as? NSTableView else { return [] }
        return selected(t)
    }

    @objc private func menuStage(_ item: NSMenuItem) {
        let f = files(from: item)
        Task { await repository.stage(f) }
    }

    @objc private func menuUnstage(_ item: NSMenuItem) {
        let f = files(from: item)
        Task { await repository.unstage(f) }
    }

    @objc private func menuDiscard(_ item: NSMenuItem) {
        discardSelected()
    }

    @objc private func menuMergetool(_ item: NSMenuItem) {
        guard let first = files(from: item).first else { return }
        repository.openMergetool(first.path)
    }

    @objc private func menuDifftool(_ item: NSMenuItem) {
        guard let t = item.representedObject as? NSTableView, let first = files(from: item).first else { return }
        repository.openDifftool(first, staged: t === stagedTable, commit: nil, parent: nil)
    }

    @objc private func menuOpenFile(_ item: NSMenuItem) {
        let f = files(from: item)
        for c in f { NSWorkspace.shared.open(repository.root.appendingPathComponent(c.path)) }
    }

    @objc private func menuReveal(_ item: NSMenuItem) {
        let f = files(from: item)
        NSWorkspace.shared.activateFileViewerSelecting(f.map { repository.root.appendingPathComponent($0.path) })
    }

    @objc private func menuCopyPath(_ item: NSMenuItem) {
        let f = files(from: item)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(f.map(\.path).joined(separator: "\n"), forType: .string)
    }

    // MARK: Commit

    @objc private func amendChanged(_ sender: NSButton) {
        state.amend = sender.state == .on
        if state.amend && messageView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Task {
                let msg = await repository.lastCommitMessage()
                if messageView.string.isEmpty {
                    messageView.string = msg
                    state.commitDraft = msg
                }
                updateCommitControls()
            }
        }
        updateCommitControls()
    }

    @objc private func commit(_ sender: Any?) {
        let message = messageView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { NSSound.beep(); return }
        let amend = amendBox.state == .on
        Task {
            if await repository.commit(message: message, amend: amend) {
                messageView.string = ""
                state.commitDraft = ""
                state.amend = false
                amendBox.state = .off
                updateCommitControls()
            }
        }
    }

    func focusMessage() {
        view.window?.makeFirstResponder(messageView)
    }
}
