import AppKit

/// Commit graph + log on top, commit details and diff below.
final class HistoryViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    let repository: Repository
    let state: TabState
    weak var actions: RepoWindowController?

    private let table = NSTableView()
    private var scroll: NSScrollView!
    private let split = NSSplitView()
    let detail: CommitDetailViewController
    private var selectTask: Task<Void, Never>?
    private var suppressSelection = false
    private let splitRules = SplitRules(minFirst: 120, minSecond: 200, initial: { $0 * 0.45 })
    private var graphColumn: NSTableColumn!

    init(repository: Repository, state: TabState, actions: RepoWindowController?) {
        self.repository = repository
        self.state = state
        self.actions = actions
        self.detail = CommitDetailViewController(repository: repository)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        func column(_ id: String, _ title: String, width: CGFloat, min: CGFloat, flexible: Bool = false) -> NSTableColumn {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.title = title
            c.width = width
            c.minWidth = min
            c.resizingMask = flexible ? [.autoresizingMask, .userResizingMask] : .userResizingMask
            table.addTableColumn(c)
            return c
        }
        graphColumn = column("graph", "Graph", width: 60, min: 30)
        _ = column("subject", "Description", width: 520, min: 200, flexible: true)
        _ = column("author", "Author", width: 150, min: 60)
        _ = column("date", "Date", width: 140, min: 60)
        _ = column("sha", "Commit", width: 76, min: 50)

        table.style = .plain
        table.rowHeight = 22
        table.intercellSpacing = .zero
        table.gridStyleMask = []
        table.usesAlternatingRowBackgroundColors = false
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.allowsMultipleSelection = false
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked(_:))
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
        table.autosaveName = "HistoryTable"
        table.autosaveTableColumns = true

        scroll = makeScrollingTable(table)
        scroll.translatesAutoresizingMaskIntoConstraints = true

        split.isVertical = false
        split.dividerStyle = .thin
        split.autosaveName = "HistorySplit"
        split.delegate = splitRules
        addChild(detail)
        split.addArrangedSubview(scroll)
        split.addArrangedSubview(detail.view)
        split.setHoldingPriority(.init(260), forSubviewAt: 0)
        split.setHoldingPriority(.init(250), forSubviewAt: 1)
        view = split
        updateGraphColumn()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        splitRules.enforce(split)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if let hash = state.selectedCommit { select(hash: hash, scroll: true) }
    }

    // MARK: Updates

    func handle(_ change: RepoChange) {
        switch change {
        case .graph:
            suppressSelection = true
            table.reloadData()
            updateGraphColumn()
            if let hash = state.selectedCommit, let row = repository.graph.row(of: hash) {
                table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            } else {
                table.deselectAll(nil)
                detail.show(nil)
            }
            suppressSelection = false
        case .summaries(let block):
            let start = block * SummaryCache.blockSize
            let range = start..<min(repository.graph.count, start + SummaryCache.blockSize)
            let visible = table.rows(in: table.visibleRect)
            let lo = max(range.lowerBound, visible.location)
            let hi = min(range.upperBound, visible.location + visible.length)
            if lo < hi {
                table.reloadData(forRowIndexes: IndexSet(integersIn: lo..<hi),
                                 columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
            }
        case .refs, .status:
            reloadVisible()
        case .activity:
            break
        }
    }

    private func reloadVisible() {
        let visible = table.rows(in: table.visibleRect)
        guard visible.length > 0 else { return }
        table.reloadData(forRowIndexes: IndexSet(integersIn: visible.location..<(visible.location + visible.length)),
                         columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
    }

    private func updateGraphColumn() {
        let lanes = CGFloat(max(1, min(repository.graph.maxLanes, 24)))
        let w = graphLeftInset * 2 + lanes * graphLaneWidth
        graphColumn.width = max(30, w)
    }

    func select(hash: Hash20, scroll: Bool) {
        guard let row = repository.graph.row(of: hash) else { return }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        if scroll {
            let visible = table.rows(in: table.visibleRect)
            if row < visible.location || row >= visible.location + visible.length {
                let target = max(0, row - visible.length / 2)
                table.scrollRowToVisible(min(repository.graph.count - 1, target + visible.length - 1))
                table.scrollRowToVisible(target)
            }
        }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { repository.graph.count }

    var testRowCount: Int { table.numberOfRows }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn else { return nil }
        let g = repository.graph
        guard row < g.count else { return nil }
        let id = tableColumn.identifier
        switch id.rawValue {
        case "graph":
            let v = tableView.makeView(withIdentifier: id, owner: nil) as? GraphCellView ?? {
                let v = GraphCellView()
                v.identifier = id
                return v
            }()
            v.node = Int(g.nodeLane[row])
            v.through = g.through[row]
            v.topIn = g.topIn[row]
            v.bottomOut = g.bottomOut[row]
            v.isHead = g.hashes[row] == repository.headHash
            v.isMerge = g.bottomOut[row].nonzeroBitCount > 1
            v.needsDisplay = true
            return v
        case "subject":
            let v = tableView.makeView(withIdentifier: id, owner: nil) as? SubjectCellView ?? {
                let v = SubjectCellView()
                v.identifier = id
                return v
            }()
            v.refs = repository.decorations[g.hashes[row]] ?? []
            v.subject = repository.summary(row: row)?.subject ?? ""
            v.currentBranch = repository.currentBranch
            v.needsDisplay = true
            return v
        default:
            let v = tableView.makeView(withIdentifier: id, owner: nil) as? TextCellView ?? {
                let v = TextCellView(font: id.rawValue == "sha" ? Theme.monoSmall : .systemFont(ofSize: 12))
                v.identifier = id
                return v
            }()
            let s = repository.summary(row: row)
            switch id.rawValue {
            case "author": v.label.stringValue = s?.author ?? ""
            case "date":
                if let t = s?.time, t > 0 {
                    v.label.stringValue = relativeDateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(t)))
                } else {
                    v.label.stringValue = ""
                }
            case "sha": v.label.stringValue = g.hashes[row].short
            default: v.label.stringValue = ""
            }
            return v
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelection else { return }
        let row = table.selectedRow
        guard row >= 0, row < repository.graph.count else {
            state.selectedCommit = nil
            detail.show(nil)
            return
        }
        let hash = repository.graph.hashes[row]
        state.selectedCommit = hash
        selectTask?.cancel()
        selectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard !Task.isCancelled else { return }
            self?.detail.show(hash.hex)
        }
    }

    @objc private func doubleClicked(_ sender: Any?) {
        let row = table.clickedRow
        guard row >= 0, row < repository.graph.count else { return }
        let refs = repository.decorations[repository.graph.hashes[row]] ?? []
        if let local = refs.first(where: { $0.kind == .local && $0.name != "HEAD" && $0.name != repository.currentBranch }) {
            actions?.checkout(local)
        }
    }

    // MARK: Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = table.clickedRow
        guard row >= 0, row < repository.graph.count else { return }
        let hash = repository.graph.hashes[row].hex
        let refs = repository.decorations[repository.graph.hashes[row]] ?? []
        let current = repository.currentBranch ?? "HEAD"

        func add(_ title: String, _ action: Selector, _ object: Any? = nil) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = object ?? hash
        }

        for ref in refs where ref.kind == .local && ref.name != "HEAD" && ref.name != repository.currentBranch {
            add("Checkout \(ref.name)", #selector(checkoutRef(_:)), ref.name)
        }
        add("Checkout This Commit (Detached)", #selector(checkoutDetached(_:)))
        add("New Branch Here…", #selector(newBranchHere(_:)))
        add("New Tag Here…", #selector(newTagHere(_:)))
        menu.addItem(.separator())
        add("Merge into \(current)", #selector(mergeHere(_:)), refs.first(where: { $0.kind != .tag && $0.name != "HEAD" })?.name ?? hash)
        add("Rebase \(current) onto This", #selector(rebaseHere(_:)))
        add("Cherry-pick", #selector(cherryPick(_:)))
        add("Revert", #selector(revert(_:)))
        menu.addItem(.separator())
        let reset = NSMenuItem(title: "Reset \(current) to Here", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for mode in ["soft", "mixed", "hard"] {
            let item = sub.addItem(withTitle: mode.capitalized + (mode == "hard" ? " (discard changes)…" : ""), action: #selector(resetHere(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = [hash, mode]
        }
        reset.submenu = sub
        menu.addItem(reset)
        menu.addItem(.separator())
        add("Copy Commit Hash", #selector(copyHash(_:)))
        add("Copy Subject", #selector(copySubject(_:)), row)
    }

    @objc private func checkoutRef(_ item: NSMenuItem) {
        guard let name = item.representedObject as? String, let ref = repository.localBranch(named: name) else { return }
        actions?.checkout(ref)
    }

    @objc private func checkoutDetached(_ item: NSMenuItem) {
        guard let hash = item.representedObject as? String else { return }
        Task { await repository.checkoutDetached(hash) }
    }

    @objc private func newBranchHere(_ item: NSMenuItem) {
        actions?.promptNewBranch(from: item.representedObject as? String)
    }

    @objc private func newTagHere(_ item: NSMenuItem) {
        guard let hash = item.representedObject as? String else { return }
        actions?.promptNewTag(at: hash)
    }

    @objc private func mergeHere(_ item: NSMenuItem) {
        guard let target = item.representedObject as? String else { return }
        actions?.confirmMerge(target)
    }

    @objc private func rebaseHere(_ item: NSMenuItem) {
        guard let hash = item.representedObject as? String else { return }
        actions?.confirmRebase(onto: hash)
    }

    @objc private func cherryPick(_ item: NSMenuItem) {
        guard let hash = item.representedObject as? String else { return }
        Task { await repository.cherryPick(hash) }
    }

    @objc private func revert(_ item: NSMenuItem) {
        guard let hash = item.representedObject as? String else { return }
        Task { await repository.revert(hash) }
    }

    @objc private func resetHere(_ item: NSMenuItem) {
        guard let pair = item.representedObject as? [String], pair.count == 2 else { return }
        actions?.confirmReset(to: pair[0], mode: pair[1])
    }

    @objc private func copyHash(_ item: NSMenuItem) {
        guard let hash = item.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(hash, forType: .string)
    }

    @objc private func copySubject(_ item: NSMenuItem) {
        guard let row = item.representedObject as? Int, let s = repository.summary(row: row) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s.subject, forType: .string)
    }
}

/// Commit message/metadata and changed files on the left, diff on the right.
final class CommitDetailViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    let repository: Repository
    let diffVC: DiffViewController
    private var detail: CommitDetail?
    private let headerScroll = NSTextView.scrollableTextView()
    private var headerText: NSTextView { headerScroll.documentView as! NSTextView }
    private let files = NSTableView()
    private var loadTask: Task<Void, Never>?
    private var currentHash: String?
    private let split = NSSplitView()
    private let left = NSSplitView()
    private let splitRules = SplitRules(minFirst: 220, minSecond: 300, initial: { _ in 320 })
    private let leftRules = SplitRules(minFirst: 60, minSecond: 80, initial: { _ in 130 })

    init(repository: Repository) {
        self.repository = repository
        self.diffVC = DiffViewController(repository: repository)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        headerText.isEditable = false
        headerText.isSelectable = true
        headerText.drawsBackground = false
        headerText.textContainerInset = NSSize(width: 8, height: 8)
        headerScroll.hasVerticalScroller = true
        headerScroll.autohidesScrollers = true
        headerScroll.drawsBackground = false

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        col.resizingMask = .autoresizingMask
        files.addTableColumn(col)
        files.headerView = nil
        files.style = .plain
        files.rowHeight = 20
        files.dataSource = self
        files.delegate = self
        files.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        let filesScroll = makeScrollingTable(files)
        filesScroll.translatesAutoresizingMaskIntoConstraints = true

        left.isVertical = false
        left.dividerStyle = .thin
        left.delegate = leftRules
        left.addArrangedSubview(headerScroll)
        left.addArrangedSubview(filesScroll)
        left.setHoldingPriority(.init(260), forSubviewAt: 0)

        split.isVertical = true
        split.dividerStyle = .thin
        split.autosaveName = "CommitDetailSplit2"
        split.delegate = splitRules
        addChild(diffVC)
        split.addArrangedSubview(left)
        split.addArrangedSubview(diffVC.view)
        split.setHoldingPriority(.init(260), forSubviewAt: 0)
        view = split
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        splitRules.enforce(split)
        leftRules.enforce(left)
    }

    func show(_ hash: String?) {
        guard hash != currentHash else { return }
        currentHash = hash
        loadTask?.cancel()
        guard let hash else {
            detail = nil
            headerText.string = ""
            files.reloadData()
            diffVC.show(.none)
            return
        }
        loadTask = Task { [weak self] in
            guard let self else { return }
            let d = await self.repository.commitDetail(hash)
            guard !Task.isCancelled, self.currentHash == hash else { return }
            self.detail = d
            self.renderHeader()
            self.files.reloadData()
            if let d, !d.files.isEmpty {
                self.files.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            } else {
                self.diffVC.show(.none)
            }
        }
    }

    private func renderHeader() {
        guard let d = detail else { headerText.string = ""; return }
        let out = NSMutableAttributedString()
        let lines = d.message.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let subject = lines.first.map(String.init) ?? ""
        out.append(NSAttributedString(string: subject + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.labelColor]))
        if lines.count > 1 {
            let body = String(lines[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty {
                out.append(NSAttributedString(string: "\n" + body + "\n", attributes: [
                    .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor]))
            }
        }
        let meta: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
        out.append(NSAttributedString(string: "\n", attributes: meta))
        out.append(NSAttributedString(string: d.hash + "\n", attributes: [.font: Theme.monoSmall, .foregroundColor: NSColor.secondaryLabelColor]))
        out.append(NSAttributedString(string: "\(d.author) <\(d.authorEmail)>\n", attributes: meta))
        out.append(NSAttributedString(string: relativeDateFormatter.string(from: d.authorTime) + "\n", attributes: meta))
        if d.committer != d.author {
            out.append(NSAttributedString(string: "Committed by \(d.committer)\n", attributes: meta))
        }
        if !d.parents.isEmpty {
            out.append(NSAttributedString(string: "Parents: " + d.parents.map { String($0.prefix(8)) }.joined(separator: ", "), attributes: meta))
        }
        headerText.textStorage?.setAttributedString(out)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { detail?.files.count ?? 0 }

    var testFileCount: Int { files.numberOfRows }
    var testHeader: String { headerText.string }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let d = detail, row < d.files.count else { return nil }
        let id = NSUserInterfaceItemIdentifier("fileCell")
        let v = tableView.makeView(withIdentifier: id, owner: nil) as? TextCellView ?? {
            let v = TextCellView(font: .systemFont(ofSize: 12), color: .labelColor)
            v.identifier = id
            return v
        }()
        v.label.attributedStringValue = fileTitle(d.files[row])
        return v
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let d = detail else { return }
        let row = files.selectedRow
        guard row >= 0, row < d.files.count else { diffVC.show(.none); return }
        diffVC.show(.commit(d.files[row], hash: d.hash, parent: d.parents.first))
    }
}

func fileTitle(_ c: FileChange) -> NSAttributedString {
    let out = NSMutableAttributedString(string: String(c.code) + "  ", attributes: [
        .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold), .foregroundColor: Theme.statusColor(c.code)])
    let isDir = c.path.hasSuffix("/")
    let trimmed = isDir ? String(c.path.dropLast()) : c.path
    var name = trimmed
    var dir = ""
    if let slash = trimmed.lastIndex(of: "/") {
        name = String(trimmed[trimmed.index(after: slash)...])
        dir = String(trimmed[..<slash])
    }
    if isDir { name += "/" }
    out.append(NSAttributedString(string: name, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor]))
    if !dir.isEmpty {
        out.append(NSAttributedString(string: "  " + dir, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
    }
    if let orig = c.origPath {
        out.append(NSAttributedString(string: "  ← " + orig, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.tertiaryLabelColor]))
    }
    return out
}
