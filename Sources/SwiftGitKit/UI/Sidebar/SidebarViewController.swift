import AppKit

final class SidebarNode {
    enum Kind { case section, local, remoteGroup, remote, tag, stash, worktree }
    let kind: Kind
    let title: String
    var ref: RefInfo?
    var stash: StashInfo?
    var worktree: WorktreeInfo?
    var children: [SidebarNode] = []

    init(_ kind: Kind, _ title: String, ref: RefInfo? = nil, stash: StashInfo? = nil, worktree: WorktreeInfo? = nil) {
        self.kind = kind
        self.title = title
        self.ref = ref
        self.stash = stash
        self.worktree = worktree
    }

    var key: String { kind == .worktree ? "worktree-\(worktree?.path ?? title)" : "\(kind)-\(title)" }
}

/// Branches, worktrees, remotes, tags and stashes.
final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    let repository: Repository
    weak var actions: RepoWindowController?
    private let outline = NSOutlineView()
    private var roots: [SidebarNode] = []
    private var expanded: Set<String> = ["section-Branches", "section-Worktrees", "section-Remotes"]
    private var suppressSelection = false

    init(repository: Repository, actions: RepoWindowController?) {
        self.repository = repository
        self.actions = actions
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        col.resizingMask = .autoresizingMask
        outline.addTableColumn(col)
        outline.outlineTableColumn = col
        outline.headerView = nil
        outline.style = .sourceList
        outline.rowHeight = 22
        outline.usesAutomaticRowHeights = true
        outline.floatsGroupRows = false
        outline.indentationPerLevel = 12
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(doubleClicked(_:))
        outline.autosaveExpandedItems = false
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        view = scroll
        rebuild()
    }

    func handle(_ change: RepoChange) {
        switch change {
        case .refs, .status: rebuild()
        case .pullRequests: outline.reloadData()
        default: break
        }
    }

    private func rebuild() {
        let local = SidebarNode(.section, "Branches")
        local.children = repository.localBranches.map { SidebarNode(.local, $0.name, ref: $0) }

        let remotes = SidebarNode(.section, "Remotes")
        var groups: [String: SidebarNode] = [:]
        var order: [String] = repository.remotes.map(\.name)
        for ref in repository.remoteBranches {
            guard let rn = ref.remoteName, let branch = ref.remoteBranch else { continue }
            if groups[rn] == nil {
                groups[rn] = SidebarNode(.remoteGroup, rn)
                if !order.contains(rn) { order.append(rn) }
            }
            groups[rn]!.children.append(SidebarNode(.remote, branch, ref: ref))
        }
        for name in order {
            remotes.children.append(groups[name] ?? SidebarNode(.remoteGroup, name))
        }

        let tags = SidebarNode(.section, "Tags")
        tags.children = repository.tags.map { SidebarNode(.tag, $0.name, ref: $0) }

        let stashes = SidebarNode(.section, "Stashes")
        stashes.children = repository.stashes.map { SidebarNode(.stash, $0.message, stash: $0) }

        // Worktrees: shown once there is more than one (or a missing one to prune).
        let openable = repository.openableWorktrees
        var sections = [local]
        if openable.count > 1 || openable.contains(where: \.isPrunable) {
            let wts = SidebarNode(.section, "Worktrees")
            wts.children = openable.map { SidebarNode(.worktree, $0.name, worktree: $0) }
            sections.append(wts)
        }

        let selectedKey = (outline.item(atRow: outline.selectedRow) as? SidebarNode)?.key
        roots = sections + [remotes, tags, stashes]
        suppressSelection = true
        outline.reloadData()
        restoreExpansion(roots)
        if let selectedKey {
            for row in 0..<outline.numberOfRows {
                if let n = outline.item(atRow: row) as? SidebarNode, n.key == selectedKey {
                    outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    break
                }
            }
        }
        suppressSelection = false
    }

    private func restoreExpansion(_ nodes: [SidebarNode]) {
        for n in nodes where expanded.contains(n.key) {
            outline.expandItem(n)
            restoreExpansion(n.children)
        }
    }

    // MARK: Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let n = item as? SidebarNode else { return roots.count }
        return n.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let n = item as? SidebarNode else { return roots[index] }
        return n.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let n = item as? SidebarNode else { return false }
        return n.kind == .section || n.kind == .remoteGroup
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        (item as? SidebarNode)?.kind == .section
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let n = item as? SidebarNode else { return false }
        return n.kind != .section
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        if let n = notification.userInfo?["NSObject"] as? SidebarNode { expanded.insert(n.key) }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        if let n = notification.userInfo?["NSObject"] as? SidebarNode { expanded.remove(n.key) }
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let n = item as? SidebarNode else { return nil }
        if n.kind == .section {
            let id = NSUserInterfaceItemIdentifier("header")
            let v = outlineView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? {
                let v = NSTableCellView()
                v.identifier = id
                let tf = NSTextField(labelWithString: "")
                tf.translatesAutoresizingMaskIntoConstraints = false
                v.addSubview(tf)
                v.textField = tf
                NSLayoutConstraint.activate([
                    tf.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 2),
                    tf.topAnchor.constraint(equalTo: v.topAnchor, constant: 5),
                    tf.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -3),
                ])
                return v
            }()
            let count = n.kind == .section && n.title != "Remotes" ? "  \(n.children.count)" : ""
            v.textField?.stringValue = n.title + count
            return v
        }

        let id = NSUserInterfaceItemIdentifier("item")
        let v = outlineView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? {
            let v = NSTableCellView()
            v.identifier = id
            let iv = NSImageView()
            iv.translatesAutoresizingMaskIntoConstraints = false
            // Long names wrap and the row grows (automatic row heights).
            let tf = NSTextField(wrappingLabelWithString: "")
            tf.lineBreakMode = .byWordWrapping
            tf.maximumNumberOfLines = 0
            tf.setContentCompressionResistancePriority(.required, for: .vertical)
            tf.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview(iv)
            v.addSubview(tf)
            v.imageView = iv
            v.textField = tf
            NSLayoutConstraint.activate([
                iv.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 2),
                iv.topAnchor.constraint(equalTo: v.topAnchor, constant: 3),
                iv.widthAnchor.constraint(equalToConstant: 16),
                iv.heightAnchor.constraint(equalToConstant: 16),
                tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 5),
                tf.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -2),
                tf.topAnchor.constraint(equalTo: v.topAnchor, constant: 3),
                tf.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -3),
            ])
            return v
        }()

        if n.kind == .worktree, let wt = n.worktree {
            configureWorktree(v, wt)
            return v
        }

        let symbol: String
        switch n.kind {
        case .local: symbol = n.ref?.isHead == true ? "checkmark.circle.fill" : "arrow.triangle.branch"
        case .remoteGroup: symbol = "cloud"
        case .remote: symbol = "arrow.triangle.branch"
        case .tag: symbol = "tag"
        case .stash: symbol = "tray"
        case .section, .worktree: symbol = "folder"
        }
        v.imageView?.image = Theme.symbol(symbol, n.title)
        v.imageView?.contentTintColor = n.ref?.isHead == true ? .controlAccentColor : .secondaryLabelColor

        let stale = n.ref?.isStale == true
        let title = NSMutableAttributedString(string: n.title, attributes: [
            .font: n.ref?.isHead == true ? NSFont.systemFont(ofSize: 12.5, weight: .semibold) : NSFont.systemFont(ofSize: 12.5),
            .foregroundColor: stale ? NSColor.secondaryLabelColor : NSColor.labelColor,
        ])
        var tip = n.ref?.upstream.map { "\(n.title) → \($0)" } ?? n.stash?.ref
        if let ref = n.ref, ref.kind == .local {
            var extra = ""
            if ref.ahead > 0 { extra += "  ↑\(ref.ahead)" }
            if ref.behind > 0 { extra += "  ↓\(ref.behind)" }
            if ref.upstreamGone {
                extra += "  remote deleted"
                tip = "\(ref.name): its remote branch \(ref.upstream ?? "") no longer exists (usually merged and deleted on GitHub)."
            } else if ref.isMerged && !ref.isHead {
                extra += "  merged"
                let how = ref.mergedByContent ? "squash- or rebase-merged" : "fully merged"
                tip = "\(ref.name) is \(how) into \(repository.mainBranch ?? "the main branch")."
            }
            if let wt = repository.worktreeUsing(branch: ref.name) {
                extra += "  ⎇ \(wt.name)"
                tip = "\(ref.name) is checked out in the worktree “\(wt.name)”\n\(wt.path)\nDouble-click to open it." + (tip.map { "\n" + $0 } ?? "")
            }
            if !extra.isEmpty {
                title.append(NSAttributedString(string: extra, attributes: [
                    .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.tertiaryLabelColor]))
            }
            if let pr = repository.pullRequests[ref.name] {
                title.append(Self.badge(pr))
                tip = pr.summary + (tip.map { "\n" + $0 } ?? "") + "\nRight-click › Open Pull Request"
            }
        }
        v.textField?.attributedStringValue = title
        v.toolTip = tip
        return v
    }

    private func configureWorktree(_ v: NSTableCellView, _ wt: WorktreeInfo) {
        let isCurrent = samePath(wt.path, repository.root.path)
        let symbol = wt.isPrunable ? "exclamationmark.triangle" : isCurrent ? "checkmark.circle.fill" : wt.isLocked ? "lock" : wt.isMain ? "house" : "folder"
        v.imageView?.image = Theme.symbol(symbol, wt.name)
        v.imageView?.contentTintColor = isCurrent ? .controlAccentColor : wt.isPrunable ? .systemOrange : .secondaryLabelColor
        let title = NSMutableAttributedString(string: wt.name, attributes: [
            .font: isCurrent ? NSFont.systemFont(ofSize: 12.5, weight: .semibold) : NSFont.systemFont(ofSize: 12.5),
            .foregroundColor: wt.isPrunable ? NSColor.secondaryLabelColor : NSColor.labelColor,
        ])
        var extra = ""
        if let b = wt.branch { extra += "  ⎇ \(b)" } else if let h = wt.head { extra += "  detached \(h.prefix(7))" }
        if wt.isLocked { extra += "  locked" }
        if wt.isPrunable { extra += "  missing" }
        title.append(NSAttributedString(string: extra, attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.tertiaryLabelColor]))
        v.textField?.attributedStringValue = title
        var tip = wt.path
        if wt.isMain { tip += "\nThe main worktree (contains the repository)." }
        if wt.isLocked { tip += "\nLocked" + (wt.lockReason.map { ": \($0)" } ?? "") }
        if wt.isPrunable { tip += "\nThe folder no longer exists. Right-click › Prune." }
        else if !isCurrent { tip += "\nDouble-click to open it in a tab." }
        v.toolTip = tip
    }

    /// Text shown for the row of a worktree (tests).
    func testWorktreeRowText(named name: String) -> String? {
        for row in 0..<outline.numberOfRows {
            guard let n = outline.item(atRow: row) as? SidebarNode, n.kind == .worktree, n.title == name,
                  let v = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView else { continue }
            return v.textField?.stringValue
        }
        return nil
    }

    /// Context menu titles for a row (tests).
    func testMenuTitles(row: Int) -> [String] {
        let menu = NSMenu()
        clickedRowOverride = row
        defer { clickedRowOverride = nil }
        menuNeedsUpdate(menu)
        return menu.items.map(\.title)
    }

    func testRow(where match: (SidebarNode) -> Bool) -> Int? {
        (0..<outline.numberOfRows).first { (outline.item(atRow: $0) as? SidebarNode).map(match) ?? false }
    }

    private var clickedRowOverride: Int?
    private var clickedRow: Int { clickedRowOverride ?? outline.clickedRow }

    /// Text shown for the row of a branch (tests).
    func testRowText(named name: String) -> String? {
        for row in 0..<outline.numberOfRows {
            guard let n = outline.item(atRow: row) as? SidebarNode, n.ref?.name == name,
                  let v = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView else { continue }
            return v.textField?.stringValue
        }
        return nil
    }

    /// "  #42 draft ● ✓" — number, draft flag, check result dot, review state.
    static func badge(_ pr: PullRequestBadge) -> NSAttributedString {
        let small = NSFont.systemFont(ofSize: 11, weight: .medium)
        let s = NSMutableAttributedString(string: "  #\(pr.number)", attributes: [.font: small, .foregroundColor: NSColor.systemBlue])
        if pr.isDraft {
            s.append(NSAttributedString(string: " draft", attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.tertiaryLabelColor]))
        }
        let dot: NSColor? = {
            switch pr.checks {
            case .none: return nil
            case .pending: return .systemOrange
            case .passing: return .systemGreen
            case .failing: return .systemRed
            }
        }()
        if let dot { s.append(NSAttributedString(string: " ●", attributes: [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: dot])) }
        switch pr.review {
        case .approved: s.append(NSAttributedString(string: " ✓", attributes: [.font: small, .foregroundColor: NSColor.systemGreen]))
        case .changesRequested: s.append(NSAttributedString(string: " ✎", attributes: [.font: small, .foregroundColor: NSColor.systemOrange]))
        default: break
        }
        return s
    }

    /// Selects the sidebar entry for one of `refs` without moving the history.
    /// Keeps the current selection if it is already one of them.
    func highlight(_ refs: [RefInfo]) {
        let names = Set(refs.map(\.fullName))
        if let current = outline.item(atRow: outline.selectedRow) as? SidebarNode,
           let ref = current.ref, names.contains(ref.fullName) { return }
        let preferred = refs.first { $0.kind == .local && $0.isHead }
            ?? refs.first { $0.kind == .local }
            ?? refs.first { $0.kind == .remote }
            ?? refs.first
        suppressSelection = true
        defer { suppressSelection = false }
        guard let preferred else { outline.deselectAll(nil); return }
        // Expand the section / remote group that contains it.
        for top in roots {
            for child in top.children {
                if child.ref?.fullName == preferred.fullName {
                    outline.expandItem(top)
                } else if child.children.contains(where: { $0.ref?.fullName == preferred.fullName }) {
                    outline.expandItem(top)
                    outline.expandItem(child)
                }
            }
        }
        for row in 0..<outline.numberOfRows {
            if let n = outline.item(atRow: row) as? SidebarNode, n.ref?.fullName == preferred.fullName {
                outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                outline.scrollRowToVisible(row)
                return
            }
        }
        outline.deselectAll(nil)
    }

    var testSelectedTitle: String? { (outline.item(atRow: outline.selectedRow) as? SidebarNode)?.title }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelection, let n = outline.item(atRow: outline.selectedRow) as? SidebarNode else { return }
        if let ref = n.ref { repository.checkMergeStatus([ref]) }
        let target = n.ref?.target ?? n.stash?.hash ?? n.worktree?.head
        if let target, let hash = Hash20(target) { actions?.reveal(commit: hash) }
    }

    @objc private func doubleClicked(_ sender: Any?) {
        guard let n = outline.item(atRow: outline.clickedRow) as? SidebarNode else { return }
        switch n.kind {
        case .local, .remote:
            if let ref = n.ref, !ref.isHead { actions?.checkout(ref) }
        case .worktree:
            if let wt = n.worktree, !samePath(wt.path, repository.root.path) { actions?.openWorktree(wt) }
        case .remoteGroup, .section:
            if outline.isItemExpanded(n) { outline.collapseItem(n) } else { outline.expandItem(n) }
        case .tag, .stash:
            break
        }
    }

    // MARK: Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let n = outline.item(atRow: clickedRow) as? SidebarNode else { return }
        let current = repository.currentBranch ?? "HEAD"
        func add(_ title: String, _ action: Selector) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = n
        }
        switch n.kind {
        case .local:
            guard let ref = n.ref else { return }
            let elsewhere = repository.worktreeUsing(branch: ref.name)
            if let elsewhere {
                add("Open Worktree “\(elsewhere.name)”", #selector(menuOpenBranchWorktree(_:)))
            } else if !ref.isHead {
                add("Checkout", #selector(menuCheckout(_:)))
                add("New Worktree for \(ref.name)…", #selector(menuNewWorktreeForBranch(_:)))
            }
            if !ref.isHead {
                add("Merge \(ref.name) into \(current)", #selector(menuMerge(_:)))
                add("Rebase \(current) onto \(ref.name)", #selector(menuRebase(_:)))
            }
            menu.addItem(.separator())
            add("New Branch from \(ref.name)…", #selector(menuNewBranch(_:)))
            add("Rename…", #selector(menuRename(_:)))
            if !ref.isHead { add("Check Merge Status…", #selector(menuMergeStatus(_:))) }
            if !ref.isHead { add("Delete…", #selector(menuDelete(_:))) }
            menu.addItem(.separator())
            add("Push", #selector(menuPush(_:)))
            if let pr = repository.pullRequests[n.ref?.name ?? ""] {
                add("Open Pull Request #\(pr.number)", #selector(menuOpenPullRequest(_:)))
                add("Update Pull Request #\(pr.number)…", #selector(menuPullRequest(_:)))
            } else {
                add("Create Pull Request…", #selector(menuPullRequest(_:)))
            }
            menu.addItem(.separator())
            add("Copy Name", #selector(menuCopyName(_:)))
        case .remote:
            guard let ref = n.ref else { return }
            add("Checkout", #selector(menuCheckout(_:)))
            add("Merge \(ref.name) into \(current)", #selector(menuMerge(_:)))
            add("Rebase \(current) onto \(ref.name)", #selector(menuRebase(_:)))
            menu.addItem(.separator())
            add("New Branch from \(ref.name)…", #selector(menuNewBranch(_:)))
            if repository.worktreeUsing(branch: ref.remoteBranch ?? "") == nil && ref.remoteBranch != repository.currentBranch {
                add("New Worktree for \(ref.name)…", #selector(menuNewWorktreeForBranch(_:)))
            }
            add("Delete \(ref.name) on Remote…", #selector(menuDeleteRemote(_:)))
            menu.addItem(.separator())
            add("Copy Name", #selector(menuCopyName(_:)))
        case .tag:
            add("Checkout (Detached)", #selector(menuCheckoutTag(_:)))
            add("Merge into \(current)", #selector(menuMerge(_:)))
            add("Copy Name", #selector(menuCopyName(_:)))
        case .stash:
            add("Apply", #selector(menuStashApply(_:)))
            add("Pop", #selector(menuStashPop(_:)))
            menu.addItem(.separator())
            add("Drop…", #selector(menuStashDrop(_:)))
        case .worktree:
            guard let wt = n.worktree else { return }
            let isCurrent = samePath(wt.path, repository.root.path)
            if !isCurrent && !wt.isPrunable { add("Open in Tab", #selector(menuOpenWorktree(_:))) }
            if !wt.isPrunable {
                add("Show in Finder", #selector(menuRevealWorktree(_:)))
                add("Open in Terminal", #selector(menuTerminalWorktree(_:)))
            }
            add("Copy Path", #selector(menuCopyWorktreePath(_:)))
            if !wt.isMain {
                menu.addItem(.separator())
                if wt.isLocked { add("Unlock", #selector(menuUnlockWorktree(_:))) } else { add("Lock…", #selector(menuLockWorktree(_:))) }
                if !wt.isPrunable && !wt.isLocked { add("Move…", #selector(menuMoveWorktree(_:))) }
                add(wt.isPrunable ? "Prune…" : "Remove…", #selector(menuRemoveWorktree(_:)))
            }
            menu.addItem(.separator())
            add("New Worktree…", #selector(menuNewWorktree(_:)))
            if repository.worktrees.contains(where: { $0.isPrunable && !$0.isLocked }) {
                add("Prune Missing Worktrees…", #selector(menuPruneWorktrees(_:)))
            }
        case .section where n.title == "Worktrees" || n.title == "Branches":
            add("New Worktree…", #selector(menuNewWorktree(_:)))
            if n.title == "Worktrees", repository.worktrees.contains(where: { $0.isPrunable && !$0.isLocked }) {
                add("Prune Missing Worktrees…", #selector(menuPruneWorktrees(_:)))
            }
        case .remoteGroup, .section:
            break
        }
    }

    // MARK: Worktree menu actions

    @objc private func menuOpenBranchWorktree(_ item: NSMenuItem) {
        if let name = node(item)?.ref?.name, let wt = repository.worktreeUsing(branch: name) { actions?.openWorktree(wt) }
    }

    @objc private func menuNewWorktreeForBranch(_ item: NSMenuItem) {
        if let ref = node(item)?.ref { actions?.promptNewWorktree(branch: ref.name) }
    }

    @objc private func menuNewWorktree(_ item: NSMenuItem) { actions?.promptNewWorktree() }

    @objc private func menuOpenWorktree(_ item: NSMenuItem) {
        if let wt = node(item)?.worktree { actions?.openWorktree(wt) }
    }

    @objc private func menuRevealWorktree(_ item: NSMenuItem) {
        if let wt = node(item)?.worktree { NSWorkspace.shared.activateFileViewerSelecting([wt.url]) }
    }

    @objc private func menuTerminalWorktree(_ item: NSMenuItem) {
        guard let wt = node(item)?.worktree else { return }
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open([wt.url], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func menuCopyWorktreePath(_ item: NSMenuItem) {
        guard let wt = node(item)?.worktree else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(wt.path, forType: .string)
    }

    @objc private func menuLockWorktree(_ item: NSMenuItem) {
        if let wt = node(item)?.worktree { actions?.promptLockWorktree(wt) }
    }

    @objc private func menuUnlockWorktree(_ item: NSMenuItem) {
        if let wt = node(item)?.worktree { actions?.unlockWorktree(wt) }
    }

    @objc private func menuMoveWorktree(_ item: NSMenuItem) {
        if let wt = node(item)?.worktree { actions?.promptMoveWorktree(wt) }
    }

    @objc private func menuRemoveWorktree(_ item: NSMenuItem) {
        if let wt = node(item)?.worktree { actions?.confirmRemoveWorktree(wt) }
    }

    @objc private func menuPruneWorktrees(_ item: NSMenuItem) { actions?.confirmPruneWorktrees() }

    private func node(_ item: NSMenuItem) -> SidebarNode? { item.representedObject as? SidebarNode }

    @objc private func menuOpenPullRequest(_ item: NSMenuItem) {
        guard let name = node(item)?.ref?.name, let s = repository.pullRequests[name]?.url, let url = URL(string: s) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func menuCheckout(_ item: NSMenuItem) {
        if let ref = node(item)?.ref { actions?.checkout(ref) }
    }

    @objc private func menuCheckoutTag(_ item: NSMenuItem) {
        if let ref = node(item)?.ref { Task { await repository.checkoutDetached(ref.name) } }
    }

    @objc private func menuMerge(_ item: NSMenuItem) {
        if let ref = node(item)?.ref { actions?.confirmMerge(ref.name) }
    }

    @objc private func menuRebase(_ item: NSMenuItem) {
        if let ref = node(item)?.ref { actions?.confirmRebase(onto: ref.name) }
    }

    @objc private func menuNewBranch(_ item: NSMenuItem) {
        if let ref = node(item)?.ref { actions?.promptNewBranch(from: ref.name) }
    }

    @objc private func menuRename(_ item: NSMenuItem) {
        if let ref = node(item)?.ref { actions?.promptRename(ref) }
    }

    @objc private func menuMergeStatus(_ item: NSMenuItem) {
        if let ref = node(item)?.ref { actions?.showMergeStatus(ref) }
    }

    @objc private func menuDelete(_ item: NSMenuItem) {
        if let ref = node(item)?.ref { actions?.confirmDelete(ref) }
    }

    @objc private func menuDeleteRemote(_ item: NSMenuItem) {
        if let ref = node(item)?.ref { actions?.confirmDeleteRemote(ref) }
    }

    @objc private func menuPush(_ item: NSMenuItem) {
        if let ref = node(item)?.ref { actions?.pushExplainingRejection(branch: ref.name) }
    }

    @objc private func menuPullRequest(_ item: NSMenuItem) {
        if let ref = node(item)?.ref { actions?.showPullRequestSheet(head: ref.name) }
    }

    @objc private func menuCopyName(_ item: NSMenuItem) {
        guard let n = node(item) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(n.ref?.name ?? n.title, forType: .string)
    }

    @objc private func menuStashApply(_ item: NSMenuItem) {
        if let s = node(item)?.stash { Task { await repository.stashApply(s.ref) } }
    }

    @objc private func menuStashPop(_ item: NSMenuItem) {
        if let s = node(item)?.stash { Task { await repository.stashPop(s.ref) } }
    }

    @objc private func menuStashDrop(_ item: NSMenuItem) {
        guard let s = node(item)?.stash else { return }
        Task {
            guard await Prompt.confirm(view.window, title: "Drop \(s.ref)?", message: s.message, ok: "Drop", destructive: true) else { return }
            await repository.stashDrop(s.ref)
        }
    }
}
