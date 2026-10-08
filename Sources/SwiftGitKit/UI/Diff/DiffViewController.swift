import AppKit

enum DiffSource: Equatable {
    case none
    case working(FileChange, staged: Bool)
    case commit(FileChange, hash: String, parent: String?)

    var change: FileChange? {
        switch self {
        case .none: return nil
        case .working(let c, _): return c
        case .commit(let c, _, _): return c
        }
    }
}

/// Lays out the two panes (or one in unified mode) plus the overview strip.
final class DiffBodyView: NSView {
    var unified = false { didSet { needsLayout = true } }
    let leftScroll = NSScrollView()
    let rightScroll = NSScrollView()
    let overview = OverviewRuler()
    let overviewWidth: CGFloat = 12

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let b = bounds
        let ov = overviewWidth
        overview.frame = NSRect(x: b.maxX - ov, y: 0, width: ov, height: b.height)
        if unified {
            leftScroll.isHidden = true
            rightScroll.frame = NSRect(x: 0, y: 0, width: b.width - ov, height: b.height)
        } else {
            leftScroll.isHidden = false
            let half = floor((b.width - ov - 1) / 2)
            leftScroll.frame = NSRect(x: 0, y: 0, width: half, height: b.height)
            rightScroll.frame = NSRect(x: half + 1, y: 0, width: b.width - ov - half - 1, height: b.height)
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: NSRect) {
        NSColor.separatorColor.setFill()
        rect.intersection(bounds).fill()
    }
}

/// Side-by-side diff with locked vertical scrolling (and linked horizontal
/// scrolling unless ⌥ is held), hunk/line staging and an overview strip.
final class DiffViewController: NSViewController {
    let repository: Repository
    private(set) var source: DiffSource = .none
    private var diff: FileDiff?
    private var rows: [DiffRow] = []
    private var intralineCache: [Int: (old: [NSRange], new: [NSRange])] = [:]
    private var loadTask: Task<Void, Never>?
    private var syntaxTask: Task<Void, Never>?
    private var syntaxOld: [Int: [SyntaxSpan]] = [:]
    private var syntaxNew: [Int: [SyntaxSpan]] = [:]
    private var contextLines = 3
    private var allowLarge = false
    private let largeLimit = 3_000_000

    private(set) var unified = UserDefaults.standard.bool(forKey: "diff.unified")
    private(set) var wholeFile = false
    private var linkHorizontal: Bool {
        UserDefaults.standard.object(forKey: "diff.linkHorizontal") as? Bool ?? true
    }

    // Selection (rows), shared by both panes
    private var selAnchor: Int?
    private var selHead: Int?
    private var selSide: PaneSide = .right

    // Views
    private let body = DiffBodyView()
    private let leftPane = DiffPaneView(side: .left)
    private let rightPane = DiffPaneView(side: .right)
    private let unifiedPane = DiffPaneView(side: .unified)
    private var leftRuler: LineNumberRuler!
    private var rightRuler: LineNumberRuler!
    private var unifiedRuler: LineNumberRuler!
    private let pathLabel = makeLabel("", font: .systemFont(ofSize: 12, weight: .medium))
    private let modeControl = NSSegmentedControl(labels: ["Split", "Unified"], trackingMode: .selectOne, target: nil, action: nil)
    private let wholeFileBox = NSButton(checkboxWithTitle: "Whole file", target: nil, action: nil)
    private let primaryButton = NSButton(title: "Stage Hunk", target: nil, action: nil)
    private let linesButton = NSButton(title: "Stage Lines", target: nil, action: nil)
    private let discardButton = NSButton(title: "Discard Hunk", target: nil, action: nil)
    private let externalButton = NSButton(title: "", target: nil, action: nil)
    private let placeholder = makeLabel("", font: .systemFont(ofSize: 13), color: .secondaryLabelColor)
    private let placeholderButton = NSButton(title: "Load Anyway", target: nil, action: nil)
    private var syncing = false

    init(repository: Repository) {
        self.repository = repository
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))

        // Header bar
        modeControl.selectedSegment = unified ? 1 : 0
        modeControl.target = self
        modeControl.action = #selector(modeChanged(_:))
        modeControl.controlSize = .small
        wholeFileBox.target = self
        wholeFileBox.action = #selector(wholeFileChanged(_:))
        wholeFileBox.controlSize = .small
        for b in [primaryButton, linesButton, discardButton] {
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.target = self
        }
        primaryButton.action = #selector(primaryHunkAction(_:))
        linesButton.action = #selector(linesAction(_:))
        discardButton.action = #selector(discardHunkAction(_:))
        externalButton.image = Theme.symbol("arrow.up.forward.app", "Open in diff tool")
        externalButton.bezelStyle = .rounded
        externalButton.controlSize = .small
        externalButton.toolTip = "Open in external diff tool (git difftool)"
        externalButton.target = self
        externalButton.action = #selector(openExternal(_:))
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let bar = NSStackView(views: [pathLabel, spacer, primaryButton, linesButton, discardButton, wholeFileBox, modeControl, externalButton])
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 8)
        bar.translatesAutoresizingMaskIntoConstraints = false

        let barSeparator = NSBox()
        barSeparator.boxType = .separator
        barSeparator.translatesAutoresizingMaskIntoConstraints = false

        // Panes
        setupScroll(body.leftScroll, pane: leftPane, showVertical: false)
        setupScroll(body.rightScroll, pane: rightPane, showVertical: true)
        leftRuler = LineNumberRuler(scrollView: body.leftScroll, pane: leftPane)
        rightRuler = LineNumberRuler(scrollView: body.rightScroll, pane: rightPane)
        unifiedRuler = LineNumberRuler(scrollView: body.rightScroll, pane: unifiedPane)
        body.leftScroll.verticalRulerView = leftRuler
        body.leftScroll.hasVerticalRuler = true
        body.leftScroll.rulersVisible = true
        body.leftScroll.tile()
        body.rightScroll.verticalRulerView = unified ? unifiedRuler : rightRuler
        body.rightScroll.hasVerticalRuler = true
        body.rightScroll.rulersVisible = true
        if unified { body.rightScroll.documentView = unifiedPane }
        body.rightScroll.tile()
        body.overview.controller = self
        body.unified = unified
        body.addSubview(body.leftScroll)
        body.addSubview(body.rightScroll)
        body.addSubview(body.overview)
        body.translatesAutoresizingMaskIntoConstraints = false
        for p in [leftPane, rightPane, unifiedPane] { p.controller = self }

        placeholder.alignment = .center
        placeholder.lineBreakMode = .byWordWrapping
        placeholder.maximumNumberOfLines = 4
        placeholderButton.target = self
        placeholderButton.action = #selector(loadAnyway(_:))
        placeholderButton.translatesAutoresizingMaskIntoConstraints = false
        placeholderButton.isHidden = true

        root.addSubview(bar)
        root.addSubview(barSeparator)
        root.addSubview(body)
        root.addSubview(placeholder)
        root.addSubview(placeholderButton)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: root.topAnchor),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 30),
            barSeparator.topAnchor.constraint(equalTo: bar.bottomAnchor),
            barSeparator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            barSeparator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            body.topAnchor.constraint(equalTo: barSeparator.bottomAnchor),
            body.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            body.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            placeholder.centerXAnchor.constraint(equalTo: body.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: body.centerYAnchor, constant: -10),
            placeholder.widthAnchor.constraint(lessThanOrEqualTo: body.widthAnchor, constant: -40),
            placeholderButton.centerXAnchor.constraint(equalTo: body.centerXAnchor),
            placeholderButton.topAnchor.constraint(equalTo: placeholder.bottomAnchor, constant: 10),
        ])
        view = root
        updateHeader()
        showPlaceholder("Select a file to see its changes")
    }

    private func setupScroll(_ scroll: NSScrollView, pane: DiffPaneView, showVertical: Bool) {
        scroll.documentView = pane
        scroll.hasVerticalScroller = showVertical
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        scroll.horizontalScrollElasticity = .allowed
        scroll.verticalScrollElasticity = .allowed
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipBoundsChanged(_:)),
                                               name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(clipFrameChanged(_:)),
                                               name: NSView.frameDidChangeNotification, object: scroll.contentView)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    var testRowCount: Int { rows.count }
    var testPlaceholder: String? { placeholder.isHidden ? nil : placeholder.stringValue }
    var testBody: DiffBodyView { body }
    var testRightPane: DiffPaneView { rightPane }

    // MARK: Loading

    func show(_ newSource: DiffSource) {
        let sameFile = newSource == source
        source = newSource
        if !sameFile {
            contextLines = wholeFile ? 1_000_000 : 3
            allowLarge = false
            clearSelectionSilently()
        }
        reload(resetScroll: !sameFile)
    }

    /// Re-runs the diff for the current source (after staging or file changes).
    func refresh() {
        reload(resetScroll: false)
    }

    private func reload(resetScroll: Bool) {
        loadTask?.cancel()
        updateHeader()
        let src = source
        let context = contextLines
        loadTask = Task { [weak self] in
            guard let self else { return }
            var result: FileDiff?
            switch src {
            case .none:
                result = nil
            case .working(let c, let staged):
                if c.isConflict {
                    self.showPlaceholder("“\(c.path)” has conflicts.\nResolve them in your editor or a merge tool, then stage the file.", button: "Open Merge Tool")
                    return
                }
                result = await self.repository.workingDiff(c, staged: staged, context: context)
            case .commit(let c, let hash, let parent):
                result = await self.repository.commitDiff(c, commit: hash, parent: parent, context: context)
            }
            if Task.isCancelled || src != self.source { return }
            self.apply(result, resetScroll: resetScroll)
        }
    }

    private func apply(_ d: FileDiff?, resetScroll: Bool) {
        intralineCache.removeAll()
        defer { startSyntaxHighlighting() }
        guard case .none = source else {
            guard let d else {
                diff = nil; rows = []
                pushRows()
                showPlaceholder(source.change?.path.hasSuffix("/") == true ? "Untracked folder" : "No changes")
                return
            }
            if d.isBinary {
                diff = nil; rows = []
                pushRows()
                showPlaceholder("Binary file")
                return
            }
            if d.byteSize > largeLimit && !allowLarge {
                diff = nil; rows = []
                pushRows()
                showPlaceholder("Large diff (\(d.byteSize / 1_000_000) MB)", button: "Load Anyway")
                return
            }
            if d.isEmpty {
                diff = nil; rows = []
                pushRows()
                showPlaceholder(d.headerBytes.isEmpty ? "No changes" : "No content changes (mode or rename only)")
                return
            }
            diff = d
            rows = unified ? d.unifiedRows() : d.sideBySideRows()
            hidePlaceholder()
            if let head = selHead, head >= rows.count { clearSelectionSilently() }
            pushRows()
            if resetScroll { scrollToRow(0, margin: 0) }
            return
        }
        diff = nil
        rows = []
        pushRows()
        showPlaceholder("Select a file to see its changes")
    }

    private func pushRows() {
        for p in [leftPane, rightPane, unifiedPane] {
            p.diff = diff
            p.rows = rows
            p.reload()
        }
        for r in [leftRuler, rightRuler, unifiedRuler] {
            r?.updateThickness()
            r?.needsDisplay = true
        }
        body.overview.setRows(rows)
        updateHeader()
    }

    private func showPlaceholder(_ text: String, button: String? = nil) {
        placeholder.stringValue = text
        placeholder.isHidden = false
        placeholderButton.isHidden = button == nil
        if let button { placeholderButton.title = button }
        body.isHidden = true
    }

    private func hidePlaceholder() {
        placeholder.isHidden = true
        placeholderButton.isHidden = true
        body.isHidden = false
    }

    @objc private func loadAnyway(_ sender: Any?) {
        if let c = source.change, c.isConflict {
            repository.openMergetool(c.path)
            return
        }
        allowLarge = true
        reload(resetScroll: true)
    }

    // MARK: Header

    private func updateHeader() {
        guard isViewLoaded else { return }
        let c = source.change
        if let c {
            pathLabel.stringValue = c.origPath.map { "\($0) → \(c.path)" } ?? c.path
        } else {
            pathLabel.stringValue = ""
        }
        let hasSelection = selHead != nil && diff != nil
        switch source {
        case .working(let c, let staged):
            primaryButton.isHidden = false
            linesButton.isHidden = c.isUntracked
            discardButton.isHidden = staged
            primaryButton.title = staged ? "Unstage Hunk" : "Stage Hunk"
            linesButton.title = staged ? "Unstage Lines" : "Stage Lines"
            discardButton.title = "Discard Hunk"
            primaryButton.isEnabled = hasSelection || c.isUntracked
            linesButton.isEnabled = hasSelection
            discardButton.isEnabled = hasSelection
        default:
            primaryButton.isHidden = true
            linesButton.isHidden = true
            discardButton.isHidden = true
        }
        externalButton.isEnabled = c != nil
        wholeFileBox.state = wholeFile ? .on : .off
        modeControl.selectedSegment = unified ? 1 : 0
    }

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        setUnified(sender.selectedSegment == 1)
    }

    @objc private func wholeFileChanged(_ sender: NSButton) {
        setWholeFile(sender.state == .on)
    }

    func toggleUnified() { setUnified(!unified) }
    func toggleWholeFile() { setWholeFile(!wholeFile) }

    private func setUnified(_ on: Bool) {
        guard on != unified else { return }
        unified = on
        UserDefaults.standard.set(on, forKey: "diff.unified")
        body.unified = on
        body.rightScroll.documentView = on ? unifiedPane : rightPane
        body.rightScroll.verticalRulerView = on ? unifiedRuler : rightRuler
        body.rightScroll.tile()
        clearSelectionSilently()
        if let d = diff {
            rows = on ? d.unifiedRows() : d.sideBySideRows()
            intralineCache.removeAll()
        }
        pushRows()
        scrollToRow(0, margin: 0)
    }

    private func setWholeFile(_ on: Bool) {
        wholeFile = on
        contextLines = on ? 1_000_000 : 3
        clearSelectionSilently()
        reload(resetScroll: false)
    }

    func expandContext() {
        guard let d = diff else { return }
        var maxGap = 0
        var prevEnd = 1
        for h in d.hunks {
            maxGap = max(maxGap, h.oldStart - prevEnd)
            prevEnd = h.oldStart + h.oldCount
        }
        contextLines = contextLines + maxGap + 1
        clearSelectionSilently()
        reload(resetScroll: false)
    }

    // MARK: Scrolling

    private var activeScroll: NSScrollView { body.rightScroll }

    @objc private func clipBoundsChanged(_ n: Notification) {
        guard !syncing, let clip = n.object as? NSClipView else { return }
        syncing = true
        defer { syncing = false }
        if !unified {
            let other = clip === body.leftScroll.contentView ? body.rightScroll : body.leftScroll
            var o = other.contentView.bounds.origin
            o.y = clip.bounds.origin.y
            if linkHorizontal && !NSEvent.modifierFlags.contains(.option) {
                let docW = other.documentView?.frame.width ?? 0
                let minX = -other.contentView.contentInsets.left
                o.x = max(minX, min(clip.bounds.origin.x, max(minX, docW - other.contentView.bounds.width)))
            }
            if o != other.contentView.bounds.origin {
                other.contentView.setBoundsOrigin(o)
                other.reflectScrolledClipView(other.contentView)
            }
        }
        leftRuler.needsDisplay = true
        rightRuler.needsDisplay = true
        unifiedRuler.needsDisplay = true
        body.overview.needsDisplay = true
    }

    @objc private func clipFrameChanged(_ n: Notification) {
        for p in [leftPane, rightPane, unifiedPane] { p.updateSize() }
        body.overview.needsDisplay = true
    }

    func visibleFraction() -> (CGFloat, CGFloat)? {
        let docH = activeScroll.documentView?.frame.height ?? 0
        guard docH > 0, !rows.isEmpty else { return nil }
        let b = activeScroll.contentView.bounds
        return (max(0, b.origin.y) / docH, b.height / docH)
    }

    func scrollToFraction(_ f: CGFloat) {
        guard let pane = activeScroll.documentView else { return }
        let b = activeScroll.contentView.bounds
        let minY = -activeScroll.contentView.contentInsets.top
        let y = max(minY, min(pane.frame.height - b.height, f * pane.frame.height - b.height / 2))
        activeScroll.contentView.setBoundsOrigin(NSPoint(x: b.origin.x, y: y))
        activeScroll.reflectScrolledClipView(activeScroll.contentView)
    }

    private func scrollToRow(_ row: Int, margin: Int = 3) {
        let rh = rightPane.rowHeight
        guard let pane = activeScroll.documentView else { return }
        let b = activeScroll.contentView.bounds
        let insets = activeScroll.contentView.contentInsets
        let maxY = max(-insets.top, pane.frame.height - b.height)
        let y = max(-insets.top, min(maxY, CGFloat(row - margin) * rh))
        let x = row == 0 && margin == 0 ? -insets.left : b.origin.x
        activeScroll.contentView.setBoundsOrigin(NSPoint(x: x, y: y))
        activeScroll.reflectScrolledClipView(activeScroll.contentView)
    }

    private func ensureVisible(_ row: Int) {
        let rh = rightPane.rowHeight
        let b = activeScroll.contentView.bounds
        let y = CGFloat(row) * rh
        if y < b.minY + rh { scrollToRow(row, margin: 1) }
        else if y + rh > b.maxY - rh {
            let target = y + 2 * rh - b.height
            activeScroll.contentView.setBoundsOrigin(NSPoint(x: b.origin.x, y: max(0, target)))
            activeScroll.reflectScrolledClipView(activeScroll.contentView)
        }
    }

    private var changeStarts: [Int] {
        var starts: [Int] = []
        var prevChange = false
        for (i, r) in rows.enumerated() {
            let isChange = r.kind != .context && r.kind != .gap
            if isChange && !prevChange { starts.append(i) }
            prevChange = isChange
        }
        return starts
    }

    func nextChange() {
        let top = Int(activeScroll.contentView.bounds.origin.y / rightPane.rowHeight) + 3
        if let next = changeStarts.first(where: { $0 > top }) { scrollToRow(next) }
    }

    func previousChange() {
        let top = Int(activeScroll.contentView.bounds.origin.y / rightPane.rowHeight) + 3
        if let prev = changeStarts.last(where: { $0 < top }) { scrollToRow(prev) }
    }

    // MARK: Intraline / syntax

    func intraline(row r: Int) -> (old: [NSRange], new: [NSRange])? {
        if let cached = intralineCache[r] { return cached }
        guard let d = diff, r < rows.count else { return nil }
        let row = rows[r]
        guard row.kind == .changed, row.left >= 0, row.right >= 0 else { return nil }
        let a = DiffPaneView.expandTabs(d.text(Int(row.left)))
        let b = DiffPaneView.expandTabs(d.text(Int(row.right)))
        let result = (a.utf16.count + b.utf16.count) > 4000 ? ([], []) : Intraline.compute(a, b)
        intralineCache[r] = result
        return result
    }

    /// Hook for syntax highlighting (foreground colors per UTF-16 range).
    func syntaxColors(lineIndex: Int) -> [(NSRange, NSColor)]? {
        guard let d = diff, lineIndex < d.lines.count else { return nil }
        let line = d.lines[lineIndex]
        let spans = line.kind == .deleted ? syntaxOld[Int(line.oldNo)] : syntaxNew[Int(line.newNo)]
        guard let spans, !spans.isEmpty else { return nil }
        return spans.map { (NSRange(location: Int($0.start), length: Int($0.length)), Theme.syntaxColor($0.style)) }
    }

    var testSyntaxLineCount: Int { syntaxOld.count + syntaxNew.count }

    /// Loads both full versions of the file, highlights them off the main
    /// thread and keeps only the spans of the lines shown in the diff.
    private func startSyntaxHighlighting() {
        syntaxTask?.cancel()
        syntaxOld = [:]
        syntaxNew = [:]
        guard let d = diff, let change = source.change,
              SyntaxHighlighter.shared.languageID(forPath: change.path) != nil else { return }
        var oldLines = Set<Int>(), newLines = Set<Int>()
        for l in d.lines {
            if l.kind != .added && l.oldNo > 0 { oldLines.insert(Int(l.oldNo)) }
            if l.kind != .deleted && l.newNo > 0 { newLines.insert(Int(l.newNo)) }
        }
        let oldPath = change.origPath ?? change.path
        let oldVersion: Repository.FileVersion
        let newVersion: Repository.FileVersion
        switch source {
        case .none:
            return
        case .working(let c, let staged):
            if staged {
                oldVersion = repository.status.headOID == nil || c.code == "A" ? .none : .commit("HEAD", oldPath)
                newVersion = c.code == "D" ? .none : .index(c.path)
            } else {
                oldVersion = c.isUntracked ? .none : .index(oldPath)
                newVersion = c.code == "D" ? .none : .worktree(c.path)
            }
        case .commit(let c, let hash, let parent):
            oldVersion = (parent == nil || c.code == "A") ? .none : .commit(parent!, oldPath)
            newVersion = c.code == "D" ? .none : .commit(hash, c.path)
        }
        let src = source
        let repo = repository
        let path = change.path
        syntaxTask = Task { [weak self] in
            async let oldText = repo.fileText(oldVersion)
            async let newText = repo.fileText(newVersion)
            let (ot, nt) = await (oldText, newText)
            guard !Task.isCancelled else { return }
            let result = await Task.detached(priority: .userInitiated) { () -> ([Int: [SyntaxSpan]], [Int: [SyntaxSpan]]) in
                let h = SyntaxHighlighter.shared
                let o = ot.flatMap { h.highlight($0, path: path, lines: oldLines) } ?? [:]
                let n = nt.flatMap { h.highlight($0, path: path, lines: newLines) } ?? [:]
                return (o, n)
            }.value
            guard let self, !Task.isCancelled, self.source == src else { return }
            self.syntaxOld = result.0
            self.syntaxNew = result.1
            for p in [self.leftPane, self.rightPane, self.unifiedPane] { p.needsDisplay = true }
        }
    }

    // MARK: Selection

    func isSelected(row: Int) -> Bool {
        guard let a = selAnchor, let h = selHead else { return false }
        return row >= min(a, h) && row <= max(a, h)
    }

    private var selectedRange: ClosedRange<Int>? {
        guard let a = selAnchor, let h = selHead else { return nil }
        return min(a, h)...max(a, h)
    }

    private func redrawPanes() {
        for p in [leftPane, rightPane, unifiedPane] { p.needsDisplay = true }
        updateHeader()
    }

    func beginSelection(at row: Int, side: PaneSide) {
        selAnchor = row
        selHead = row
        selSide = side
        redrawPanes()
    }

    func extendSelection(to row: Int, side: PaneSide) {
        if selAnchor == nil { selAnchor = row }
        selHead = row
        selSide = side
        redrawPanes()
    }

    func moveSelection(by delta: Int, extend: Bool, side: PaneSide) {
        guard !rows.isEmpty else { return }
        var r = (selHead ?? -1) + delta
        r = max(0, min(rows.count - 1, r))
        while r > 0, r < rows.count - 1, rows[r].kind == .gap { r += delta }
        if extend { extendSelection(to: r, side: side) } else { beginSelection(at: r, side: side) }
        ensureVisible(r)
    }

    func selectAll(side: PaneSide) {
        guard !rows.isEmpty else { return }
        selAnchor = 0
        selHead = rows.count - 1
        selSide = side
        redrawPanes()
    }

    func clearSelection() {
        clearSelectionSilently()
        redrawPanes()
    }

    private func clearSelectionSilently() {
        selAnchor = nil
        selHead = nil
    }

    func copySelection(side: PaneSide) {
        guard let d = diff, let range = selectedRange else { return }
        var out: [String] = []
        for r in range where r < rows.count {
            let row = rows[r]
            let li: Int32
            switch side {
            case .left: li = row.left
            case .right: li = row.right
            case .unified: li = row.left >= 0 ? row.left : row.right
            }
            if li >= 0 { out.append(d.text(Int(li))) }
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(out.joined(separator: "\n"), forType: .string)
    }

    private var selectedHunks: Set<Int> {
        guard let range = selectedRange else { return [] }
        var s = Set<Int>()
        for r in range where r < rows.count && rows[r].kind != .gap { s.insert(Int(rows[r].hunk)) }
        return s
    }

    private var selectedLines: Set<Int> {
        guard let range = selectedRange else { return [] }
        var s = Set<Int>()
        for r in range where r < rows.count {
            let row = rows[r]
            if row.left >= 0 { s.insert(Int(row.left)) }
            if row.right >= 0 { s.insert(Int(row.right)) }
        }
        return s
    }

    // MARK: Staging actions

    func contextMenu() -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy", action: #selector(copyFromMenu(_:)), keyEquivalent: "").target = self
        if case .working(let c, let staged) = source, diff != nil {
            menu.addItem(.separator())
            if staged {
                menu.addItem(withTitle: "Unstage Hunk", action: #selector(primaryHunkAction(_:)), keyEquivalent: "").target = self
                menu.addItem(withTitle: "Unstage Selected Lines", action: #selector(linesAction(_:)), keyEquivalent: "").target = self
            } else {
                menu.addItem(withTitle: "Stage Hunk", action: #selector(primaryHunkAction(_:)), keyEquivalent: "").target = self
                if !c.isUntracked {
                    menu.addItem(withTitle: "Stage Selected Lines", action: #selector(linesAction(_:)), keyEquivalent: "").target = self
                    menu.addItem(.separator())
                    menu.addItem(withTitle: "Discard Hunk…", action: #selector(discardHunkAction(_:)), keyEquivalent: "").target = self
                    menu.addItem(withTitle: "Discard Selected Lines…", action: #selector(discardLinesAction(_:)), keyEquivalent: "").target = self
                }
            }
        }
        return menu
    }

    @objc private func copyFromMenu(_ sender: Any?) {
        copySelection(side: selSide)
    }

    @objc private func primaryHunkAction(_ sender: Any?) {
        guard case .working(let c, let staged) = source else { return }
        if c.isUntracked && !staged {
            Task { await repository.stage([c]) }
            return
        }
        guard let d = diff, let patch = d.patch(hunks: selectedHunks) else { NSSound.beep(); return }
        Task {
            await repository.apply(patch: patch, cached: true, reverse: staged, title: staged ? "Unstage hunk" : "Stage hunk")
            clearSelection()
        }
    }

    @objc private func linesAction(_ sender: Any?) {
        guard case .working(let c, let staged) = source, !c.isUntracked else { return }
        guard let d = diff, let patch = d.patch(lines: selectedLines, reverse: staged) else { NSSound.beep(); return }
        Task {
            await repository.apply(patch: patch, cached: true, reverse: staged, title: staged ? "Unstage lines" : "Stage lines")
            clearSelection()
        }
    }

    @objc private func discardHunkAction(_ sender: Any?) {
        guard case .working(_, let staged) = source, !staged else { return }
        guard let d = diff, let patch = d.patch(hunks: selectedHunks) else { NSSound.beep(); return }
        Task {
            guard await Prompt.confirm(view.window, title: "Discard the selected hunk?",
                                       message: "This change will be lost.", ok: "Discard", destructive: true) else { return }
            await repository.apply(patch: patch, cached: false, reverse: true, title: "Discard hunk")
            clearSelection()
        }
    }

    @objc private func discardLinesAction(_ sender: Any?) {
        guard case .working(_, let staged) = source, !staged else { return }
        guard let d = diff, let patch = d.patch(lines: selectedLines, reverse: true) else { NSSound.beep(); return }
        Task {
            guard await Prompt.confirm(view.window, title: "Discard the selected lines?",
                                       message: "These changes will be lost.", ok: "Discard", destructive: true) else { return }
            await repository.apply(patch: patch, cached: false, reverse: true, title: "Discard lines")
            clearSelection()
        }
    }

    @objc private func openExternal(_ sender: Any?) {
        switch source {
        case .working(let c, let staged):
            if c.isConflict { repository.openMergetool(c.path) }
            else { repository.openDifftool(c, staged: staged, commit: nil, parent: nil) }
        case .commit(let c, let hash, let parent):
            repository.openDifftool(c, staged: false, commit: hash, parent: parent)
        case .none:
            break
        }
    }
}
