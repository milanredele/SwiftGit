import AppKit

final class SidebarNode {
    enum Kind { case section, local, remoteGroup, remote, tag, stash }
    let kind: Kind
    let title: String
    var ref: RefInfo?
    var stash: StashInfo?
    var children: [SidebarNode] = []

    init(_ kind: Kind, _ title: String, ref: RefInfo? = nil, stash: StashInfo? = nil) {
        self.kind = kind
        self.title = title
        self.ref = ref
        self.stash = stash
    }

    var key: String { "\(kind)-\(title)" }
}

/// Branches, remotes, tags and stashes.
final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    let repository: Repository
    weak var actions: RepoWindowController?
    private let outline = NSOutlineView()
    private var roots: [SidebarNode] = []
    private var expanded: Set<String> = ["section-Branches", "section-Remotes"]
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
        tags.children = repository.tags.reversed().map { SidebarNode(.tag, $0.name, ref: $0) }

        let stashes = SidebarNode(.section, "Stashes")
        stashes.children = repository.stashes.map { SidebarNode(.stash, $0.message, stash: $0) }

        let selectedKey = (outline.item(atRow: outline.selectedRow) as? SidebarNode)?.key
        roots = [local, remotes, tags, stashes]
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
                    tf.centerYAnchor.constraint(equalTo: v.centerYAnchor),
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
            let tf = NSTextField(labelWithString: "")
            tf.lineBreakMode = .byTruncatingTail
            tf.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview(iv)
            v.addSubview(tf)
            v.imageView = iv
            v.textField = tf
            NSLayoutConstraint.activate([
                iv.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 2),
                iv.centerYAnchor.constraint(equalTo: v.centerYAnchor),
                iv.widthAnchor.constraint(equalToConstant: 16),
                iv.heightAnchor.constraint(equalToConstant: 16),
                tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 5),
                tf.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor, constant: -2),
                tf.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            ])
            return v
        }()

        let symbol: String
        switch n.kind {
        case .local: symbol = n.ref?.isHead == true ? "checkmark.circle.fill" : "arrow.triangle.branch"
        case .remoteGroup: symbol = "cloud"
        case .remote: symbol = "arrow.triangle.branch"
        case .tag: symbol = "tag"
        case .stash: symbol = "tray"
        case .section: symbol = "folder"
        }
        v.imageView?.image = Theme.symbol(symbol, n.title)
        v.imageView?.contentTintColor = n.ref?.isHead == true ? .controlAccentColor : .secondaryLabelColor

        let title = NSMutableAttributedString(string: n.title, attributes: [
            .font: n.ref?.isHead == true ? NSFont.systemFont(ofSize: 12.5, weight: .semibold) : NSFont.systemFont(ofSize: 12.5),
            .foregroundColor: NSColor.labelColor,
        ])
        if let ref = n.ref, ref.kind == .local {
            var extra = ""
            if ref.ahead > 0 { extra += "  ↑\(ref.ahead)" }
            if ref.behind > 0 { extra += "  ↓\(ref.behind)" }
            if ref.upstreamGone { extra += "  (gone)" }
            if !extra.isEmpty {
                title.append(NSAttributedString(string: extra, attributes: [
                    .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
            }
        }
        v.textField?.attributedStringValue = title
        v.toolTip = n.ref?.upstream.map { "\(n.title) → \($0)" } ?? n.stash?.ref
        return v
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelection, let n = outline.item(atRow: outline.selectedRow) as? SidebarNode else { return }
        let target = n.ref?.target ?? n.stash?.hash
        if let target, let hash = Hash20(target) { actions?.reveal(commit: hash) }
    }

    @objc private func doubleClicked(_ sender: Any?) {
        guard let n = outline.item(atRow: outline.clickedRow) as? SidebarNode else { return }
        switch n.kind {
        case .local, .remote:
            if let ref = n.ref, !ref.isHead { actions?.checkout(ref) }
        case .remoteGroup, .section:
            if outline.isItemExpanded(n) { outline.collapseItem(n) } else { outline.expandItem(n) }
        case .tag, .stash:
            break
        }
    }

    // MARK: Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let n = outline.item(atRow: outline.clickedRow) as? SidebarNode else { return }
        let current = repository.currentBranch ?? "HEAD"
        func add(_ title: String, _ action: Selector) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = n
        }
        switch n.kind {
        case .local:
            guard let ref = n.ref else { return }
            if !ref.isHead { add("Checkout", #selector(menuCheckout(_:))) }
            if !ref.isHead {
                add("Merge \(ref.name) into \(current)", #selector(menuMerge(_:)))
                add("Rebase \(current) onto \(ref.name)", #selector(menuRebase(_:)))
            }
            menu.addItem(.separator())
            add("New Branch from \(ref.name)…", #selector(menuNewBranch(_:)))
            add("Rename…", #selector(menuRename(_:)))
            if !ref.isHead { add("Delete…", #selector(menuDelete(_:))) }
            menu.addItem(.separator())
            add("Push", #selector(menuPush(_:)))
            add("Create Pull Request…", #selector(menuPullRequest(_:)))
            menu.addItem(.separator())
            add("Copy Name", #selector(menuCopyName(_:)))
        case .remote:
            guard let ref = n.ref else { return }
            add("Checkout", #selector(menuCheckout(_:)))
            add("Merge \(ref.name) into \(current)", #selector(menuMerge(_:)))
            add("Rebase \(current) onto \(ref.name)", #selector(menuRebase(_:)))
            menu.addItem(.separator())
            add("New Branch from \(ref.name)…", #selector(menuNewBranch(_:)))
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
        case .remoteGroup, .section:
            break
        }
    }

    private func node(_ item: NSMenuItem) -> SidebarNode? { item.representedObject as? SidebarNode }

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

    @objc private func menuDelete(_ item: NSMenuItem) {
        if let ref = node(item)?.ref { actions?.confirmDelete(ref) }
    }

    @objc private func menuDeleteRemote(_ item: NSMenuItem) {
        if let ref = node(item)?.ref { actions?.confirmDeleteRemote(ref) }
    }

    @objc private func menuPush(_ item: NSMenuItem) {
        if let ref = node(item)?.ref { Task { await repository.push(branch: ref.name) } }
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
