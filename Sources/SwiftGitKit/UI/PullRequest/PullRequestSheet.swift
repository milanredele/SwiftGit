import AppKit

/// Sheet for creating a GitHub pull request with reviewers, via `gh pr create`.
final class PullRequestSheet: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    let repository: Repository
    var onFinish: (() -> Void)?
    private let initialHead: String
    private var ghRepo: GitHubRepo?
    private var remoteName: String?
    private var reviewers: [Reviewer] = []
    private var filtered: [Reviewer] = []
    private var selected = Set<String>()
    private var viewer: String?
    /// PR template from the repository, if any (it then stays the default description).
    private var template: String?
    /// Last automatically filled title/description; a field still holding it is replaced on branch changes.
    private var autoTitle = ""
    private var autoBody = ""
    private var defaultsTask: Task<Void, Never>?
    private var aiCancel: CancelToken?
    /// Tests turn this off to skip the gh network calls.
    var loadsGitHubData = true

    private let basePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let headPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let titleField = NSTextField()
    private let bodyScroll = NSTextView.scrollableTextView()
    private var bodyView: NSTextView { bodyScroll.documentView as! NSTextView }
    private let searchField = NSSearchField()
    private let reviewerTable = NSTableView()
    private let selectedLabel = makeLabel("No reviewers selected", font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
    private let draftBox = NSButton(checkboxWithTitle: "Create as draft", target: nil, action: nil)
    private let pushBox = NSButton(checkboxWithTitle: "Push branch first", target: nil, action: nil)
    private let statusLabel = makeLabel("", font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
    private let spinner = NSProgressIndicator()
    private let createButton = NSButton(title: "Create Pull Request", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let generateButton = NSButton(title: "Generate", target: nil, action: nil)

    init(repository: Repository, head: String) {
        self.repository = repository
        self.initialHead = head
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 640),
                         styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        w.title = "Create Pull Request"
        w.minSize = NSSize(width: 520, height: 560)
        super.init(window: w)
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        headPopup.target = self
        headPopup.action = #selector(headChanged(_:))
        basePopup.target = self
        basePopup.action = #selector(baseChanged(_:))
        titleField.placeholderString = "Title"
        titleField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        generateButton.bezelStyle = .rounded
        generateButton.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Generate")
        generateButton.imagePosition = .imageLeading
        generateButton.target = self
        generateButton.action = #selector(generate(_:))
        generateButton.toolTip = "Write the title and description from this branch’s commit messages with Claude "
            + "(uses the claude CLI with the \(ClaudeCLI.model) model)"
        generateButton.isHidden = !ClaudeCLI.isAvailable
        generateButton.setContentHuggingPriority(.required, for: .horizontal)
        bodyView.isRichText = false
        bodyView.font = .systemFont(ofSize: 13)
        bodyView.isAutomaticQuoteSubstitutionEnabled = false
        bodyView.isAutomaticDashSubstitutionEnabled = false
        bodyView.allowsUndo = true
        bodyView.textContainerInset = NSSize(width: 4, height: 6)
        bodyScroll.hasVerticalScroller = true
        bodyScroll.borderType = .bezelBorder
        bodyScroll.translatesAutoresizingMaskIntoConstraints = false

        searchField.placeholderString = "Filter people and teams"
        searchField.delegate = self
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("reviewer"))
        col.resizingMask = .autoresizingMask
        reviewerTable.addTableColumn(col)
        reviewerTable.headerView = nil
        reviewerTable.rowHeight = 22
        reviewerTable.style = .plain
        reviewerTable.dataSource = self
        reviewerTable.delegate = self
        reviewerTable.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        let reviewerScroll = makeScrollingTable(reviewerTable)
        reviewerScroll.borderType = .bezelBorder

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        createButton.bezelStyle = .rounded
        createButton.keyEquivalent = "\r"
        createButton.target = self
        createButton.action = #selector(create(_:))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.target = self
        cancelButton.action = #selector(cancel(_:))

        func rowLabel(_ s: String) -> NSTextField {
            let l = makeLabel(s, font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
            l.alignment = .right
            return l
        }

        let titleRow = NSStackView(views: [titleField, generateButton])
        titleRow.orientation = .horizontal
        titleRow.spacing = 8
        let branchRow = NSStackView(views: [headPopup, makeLabel("→", color: .secondaryLabelColor), basePopup])
        branchRow.orientation = .horizontal
        let reviewerBox = NSStackView(views: [searchField, reviewerScroll, selectedLabel])
        reviewerBox.orientation = .vertical
        reviewerBox.alignment = .leading
        reviewerBox.spacing = 4
        let options = NSStackView(views: [pushBox, draftBox])
        options.orientation = .horizontal
        options.spacing = 16

        let grid = NSGridView(views: [
            [rowLabel("Branches"), branchRow],
            [rowLabel("Title"), titleRow],
            [rowLabel("Description"), bodyScroll],
            [rowLabel("Reviewers"), reviewerBox],
            [NSGridCell.emptyContentView, options],
        ])
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 10
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 80
        grid.rowAlignment = .firstBaseline
        grid.row(at: 2).yPlacement = .top
        grid.row(at: 3).yPlacement = .top
        grid.cell(for: bodyScroll)?.yPlacement = .fill
        grid.cell(for: reviewerBox)?.yPlacement = .fill

        let footer = NSStackView(views: [spinner, statusLabel, NSView(), cancelButton, createButton])
        footer.orientation = .horizontal
        footer.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        content.addSubview(grid)
        content.addSubview(footer)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            footer.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 16),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            titleRow.widthAnchor.constraint(greaterThanOrEqualToConstant: 380),
            titleField.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
            bodyScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 140),
            bodyScroll.widthAnchor.constraint(equalTo: titleRow.widthAnchor),
            reviewerScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 150),
            reviewerScroll.widthAnchor.constraint(equalTo: titleRow.widthAnchor),
            searchField.widthAnchor.constraint(equalTo: titleRow.widthAnchor),
            basePopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
            headPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
        ])
    }

    func present(on parent: NSWindow) {
        guard let window else { return }
        parent.beginSheet(window) { [weak self] _ in self?.onFinish?() }
        load()
    }

    private func finish() {
        aiCancel?.cancel()
        defaultsTask?.cancel()
        guard let window, let parent = window.sheetParent else { return }
        parent.endSheet(window)
    }

    // MARK: Data

    func load() {
        // GitHub repository from the preferred remote
        if let found = repository.gitHubRemote {
            ghRepo = found.repo
            remoteName = found.remote
        }

        let locals = repository.localBranches.map(\.name)
        headPopup.removeAllItems()
        headPopup.addItems(withTitles: locals)
        headPopup.selectItem(withTitle: initialHead)

        guard let gh = ghRepo, let remote = remoteName else {
            setStatus("No GitHub remote found for this repository.")
            createButton.isEnabled = false
            return
        }
        window?.title = "Create Pull Request — \(gh.slug)"

        let bases = repository.remoteBranches.filter { $0.remoteName == remote }.compactMap(\.remoteBranch).filter { $0 != "HEAD" }
        basePopup.removeAllItems()
        basePopup.addItems(withTitles: bases.isEmpty ? ["main"] : bases)
        if let guess = ["main", "master", "develop"].first(where: { bases.contains($0) }) { basePopup.selectItem(withTitle: guess) }

        loadTemplate()
        updateDefaults()

        reviewers = GitHub.cachedReviewers(gh)
        applyFilter()

        guard loadsGitHubData else { return }

        if GitHub.executable == nil {
            setStatus(GitHub.missingMessage)
            createButton.isEnabled = false
            return
        }
        setStatus("Loading reviewers…", busy: true)
        Task {
            async let def = GitHub.defaultBranch(gh)
            async let me = GitHub.viewerLogin()
            let (defaultBranch, login) = await (def, me)
            viewer = login
            if let defaultBranch, basePopup.itemTitles.contains(defaultBranch),
               basePopup.titleOfSelectedItem != defaultBranch {
                basePopup.selectItem(withTitle: defaultBranch)
                updateDefaults()
            }
            do {
                let fresh = try await GitHub.reviewers(gh)
                GitHub.storeReviewers(fresh, for: gh)
                reviewers = fresh
                applyFilter()
                setStatus("")
            } catch {
                setStatus("Couldn’t load reviewers: \(error.localizedDescription)")
                applyFilter()
            }
        }
    }

    private func loadTemplate() {
        let candidates = [".github/pull_request_template.md", ".github/PULL_REQUEST_TEMPLATE.md",
                          "pull_request_template.md", "PULL_REQUEST_TEMPLATE.md",
                          "docs/pull_request_template.md", ".github/PULL_REQUEST_TEMPLATE/pull_request_template.md"]
        for c in candidates {
            if let text = try? String(contentsOf: repository.root.appendingPathComponent(c), encoding: .utf8) {
                template = text
                bodyView.string = text
                return
            }
        }
    }

    @objc private func headChanged(_ sender: Any?) { updateDefaults() }

    @objc private func baseChanged(_ sender: Any?) { updateDefaults() }

    /// Refs to compare the head against: the remote's base branch, else a local one.
    private func baseRefs() -> [String] {
        guard let base = basePopup.titleOfSelectedItem else { return [] }
        var refs: [String] = []
        if let remote = remoteName { refs.append("refs/remotes/\(remote)/\(base)") }
        refs.append("refs/heads/\(base)")
        return refs
    }

    /// Default title and description: the earliest commit of the branch (its
    /// subject and body). The description keeps the PR template if there is one.
    /// Fields the user has edited are left alone.
    private func updateDefaults() {
        guard let head = headPopup.titleOfSelectedItem else { return }
        let ref = repository.localBranch(named: head)
        pushBox.state = (ref?.upstream == nil || (ref?.ahead ?? 0) > 0) ? .on : .off
        let bases = baseRefs()
        defaultsTask?.cancel()
        defaultsTask = Task {
            let found = await repository.branchCommits(head: head, bases: bases)
            var title = found?.commits.first?.subject ?? ""
            let body = found?.commits.first?.body ?? ""
            if title.isEmpty { title = await repository.lastCommitSubject(of: head) }
            guard !Task.isCancelled else { return }
            if titleField.stringValue.isEmpty || titleField.stringValue == autoTitle { titleField.stringValue = title }
            autoTitle = title
            if template == nil {
                if bodyView.string.isEmpty || bodyView.string == autoBody { setBody(body) }
                autoBody = body
            }
            defaultsTask = nil
        }
    }

    /// Replaces the description as one undoable edit.
    private func setBody(_ text: String) {
        let range = NSRange(location: 0, length: (bodyView.string as NSString).length)
        if bodyView.shouldChangeText(in: range, replacementString: text) {
            bodyView.replaceCharacters(in: range, with: text)
            bodyView.didChangeText()
        } else {
            bodyView.string = text
        }
    }

    // MARK: AI

    @objc private func generate(_ sender: Any?) {
        if let running = aiCancel { running.cancel(); return }
        guard let head = headPopup.titleOfSelectedItem, let base = basePopup.titleOfSelectedItem else { return }
        let bases = baseRefs()
        let cancel = CancelToken()
        aiCancel = cancel
        generateButton.title = "Stop"
        generateButton.image = NSImage(systemSymbolName: "stop.circle", accessibilityDescription: "Stop")
        setStatus("Writing the title and description with Claude (\(ClaudeCLI.model))…", busy: true)
        Task {
            defer {
                aiCancel = nil
                generateButton.title = "Generate"
                generateButton.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Generate")
            }
            guard let found = await repository.branchCommits(head: head, bases: bases), !found.commits.isEmpty else {
                setStatus("\(head) has no commits that aren’t on \(base).")
                return
            }
            let stat = await repository.diffStat(base: found.base, head: head)
            do {
                let draft = try await ClaudeCLI.generatePullRequest(head: head, base: base, commits: found.commits,
                                                                    diffStat: stat, template: template, cancel: cancel)
                titleField.stringValue = draft.title
                autoTitle = draft.title
                if !draft.body.isEmpty {
                    setBody(draft.body)
                    autoBody = draft.body
                }
                setStatus("")
            } catch is CancellationError {
                setStatus("")
            } catch {
                setStatus(error.localizedDescription)
            }
        }
    }

    private func setStatus(_ text: String, busy: Bool = false) {
        statusLabel.stringValue = text
        statusLabel.toolTip = text
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    private func applyFilter() {
        let q = searchField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        filtered = reviewers.filter { r in
            r.id != viewer && (q.isEmpty || r.id.lowercased().contains(q) || r.name.lowercased().contains(q))
        }
        // selected first
        filtered.sort { (selected.contains($0.id) ? 0 : 1) < (selected.contains($1.id) ? 0 : 1) }
        reviewerTable.reloadData()
        updateSelectedLabel()
    }

    private func updateSelectedLabel() {
        selectedLabel.stringValue = selected.isEmpty ? "No reviewers selected" : "Reviewers: " + selected.sorted().joined(separator: ", ")
    }

    func controlTextDidChange(_ obj: Notification) {
        if (obj.object as? NSSearchField) === searchField { applyFilter() }
    }

    // MARK: Reviewer table

    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < filtered.count else { return nil }
        let r = filtered[row]
        let id = NSUserInterfaceItemIdentifier("reviewerCell")
        let box = tableView.makeView(withIdentifier: id, owner: nil) as? NSButton ?? {
            let b = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleReviewer(_:)))
            b.identifier = id
            return b
        }()
        box.title = r.title
        box.state = selected.contains(r.id) ? .on : .off
        box.tag = row
        return box
    }

    @objc private func toggleReviewer(_ sender: NSButton) {
        guard sender.tag < filtered.count else { return }
        let id = filtered[sender.tag].id
        if sender.state == .on { selected.insert(id) } else { selected.remove(id) }
        updateSelectedLabel()
    }

    // MARK: Actions

    @objc private func cancel(_ sender: Any?) { finish() }

    @objc private func create(_ sender: Any?) {
        guard let gh = ghRepo, let head = headPopup.titleOfSelectedItem, let base = basePopup.titleOfSelectedItem else { return }
        let title = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            window?.makeFirstResponder(titleField)
            NSSound.beep()
            return
        }
        guard head != base else {
            setStatus("The head and base branches are the same.")
            return
        }
        let request = GitHub.PullRequestRequest(repo: gh, base: base, head: head, title: title, body: bodyView.string,
                                                reviewers: selected.sorted(), draft: draftBox.state == .on)
        let shouldPush = pushBox.state == .on
        setEnabled(false)
        Task {
            if shouldPush {
                setStatus("Pushing \(head)…", busy: true)
                guard await repository.push(branch: head) else {
                    setStatus("Push failed.")
                    setEnabled(true)
                    return
                }
            }
            setStatus("Creating pull request…", busy: true)
            do {
                let url = try await GitHub.createPullRequest(request, cwd: repository.root)
                setStatus("")
                let parent = window?.sheetParent
                finish()
                try? await Task.sleep(nanoseconds: 350_000_000)
                let alert = NSAlert()
                alert.messageText = "Pull request created"
                alert.informativeText = url
                alert.addButton(withTitle: "Open in Browser")
                alert.addButton(withTitle: "Copy Link")
                alert.addButton(withTitle: "Close")
                let handle: (NSApplication.ModalResponse) -> Void = { resp in
                    if resp == .alertFirstButtonReturn, let u = URL(string: url) { NSWorkspace.shared.open(u) }
                    if resp == .alertSecondButtonReturn {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url, forType: .string)
                    }
                }
                if let parent { alert.beginSheetModal(for: parent, completionHandler: handle) } else { handle(alert.runModal()) }
            } catch {
                setStatus(error.localizedDescription)
                setEnabled(true)
            }
        }
    }

    private func setEnabled(_ on: Bool) {
        for c in [basePopup, headPopup, titleField, searchField, draftBox, pushBox, createButton, generateButton] as [NSControl] {
            c.isEnabled = on
        }
        bodyView.isEditable = on
    }

    // MARK: Testing

    var testTitle: String { titleField.stringValue }
    var testBody: String { bodyView.string }
    var testIsUpdating: Bool { defaultsTask != nil }
    func testSetTitle(_ s: String) { titleField.stringValue = s }
    func testSelect(head: String? = nil, base: String? = nil) {
        if let head { headPopup.selectItem(withTitle: head); headChanged(headPopup) }
        if let base { basePopup.selectItem(withTitle: base); baseChanged(basePopup) }
    }
}
