import AppKit

private extension NSToolbarItem.Identifier {
    static let fetch = Self("fetch")
    static let pull = Self("pull")
    static let push = Self("push")
    static let branch = Self("branch")
    static let merge = Self("merge")
    static let rebase = Self("rebase")
    static let stash = Self("stash")
    static let pop = Self("pop")
    static let pullRequest = Self("pullRequest")
    static let mode = Self("mode")
}

/// One repository tab: window, toolbar, actions and background unloading.
final class RepoWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate,
    NSMenuItemValidation, NSToolbarItemValidation, RepositoryObserver {
    let repository: Repository
    let state = TabState()
    var onClose: (() -> Void)?
    private var root: RootViewController!
    private let modeControl = NSSegmentedControl(labels: ["History", "Changes"], trackingMode: .selectOne, target: nil, action: nil)
    private var unloadTask: Task<Void, Never>?
    private var toolbarItems: [NSToolbarItem.Identifier: NSToolbarItem] = [:]
    private var errorQueue: [(String, String)] = []
    private var showingError = false

    init(repository: Repository) {
        self.repository = repository
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: true)
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "SwiftGitRepository"
        window.title = repository.name
        window.representedURL = repository.root
        window.minSize = NSSize(width: 820, height: 480)
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self

        root = RootViewController(repository: repository, state: state, actions: self)
        window.contentViewController = root
        window.setContentSize(NSSize(width: 1280, height: 800))
        if !window.setFrameUsingName("SwiftGitRepositoryWindow") { window.center() }
        window.setFrameAutosaveName("SwiftGitRepositoryWindow")

        let toolbar = NSToolbar(identifier: "SwiftGitToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        window.toolbar = toolbar

        modeControl.target = self
        modeControl.action = #selector(modeChanged(_:))
        modeControl.selectedSegment = state.mode.rawValue

        root.banner.continueButton.target = self
        root.banner.continueButton.action = #selector(continueOperation(_:))
        root.banner.skipButton.target = self
        root.banner.skipButton.action = #selector(skipOperation(_:))
        root.banner.abortButton.target = self
        root.banner.abortButton.action = #selector(abortOperation(_:))
        root.activityBar.cancelButton.target = self
        root.activityBar.cancelButton.action = #selector(cancelActivity(_:))

        repository.addObserver(self)
        repository.onError = { [weak self] title, message in self?.showError(title, message) }
        root.loadContentIfNeeded()

        NotificationCenter.default.addObserver(self, selector: #selector(occlusionChanged(_:)),
                                               name: NSWindow.didChangeOcclusionStateNotification, object: window)
    }

    required init?(coder: NSCoder) { fatalError() }

    var testRoot: RootViewController { root }

    // MARK: Window

    func windowWillClose(_ notification: Notification) {
        unloadTask?.cancel()
        repository.stop()
        repository.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
        onClose?()
    }

    @objc private func occlusionChanged(_ n: Notification) {
        guard let w = window else { return }
        if w.occlusionState.contains(.visible) {
            unloadTask?.cancel()
            unloadTask = nil
            if root.main == nil {
                root.loadContentIfNeeded()
                modeControl.selectedSegment = state.mode.rawValue
            }
        } else {
            unloadTask?.cancel()
            unloadTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled, let self, let w = self.window,
                      !w.occlusionState.contains(.visible) else { return }
                self.root.unloadContent()
                self.repository.dropCaches()
            }
        }
    }

    // MARK: Repository changes

    func repository(_ repo: Repository, didChange change: RepoChange) {
        root.handle(change)
        switch change {
        case .status:
            updateTitles()
            updateBanner()
        case .refs:
            updateTitles()
        case .activity:
            updateActivity()
        default:
            break
        }
    }

    private func updateTitles() {
        guard let window else { return }
        let s = repository.status
        var subtitle = s.branch ?? "detached HEAD"
        if s.ahead > 0 { subtitle += "  ↑\(s.ahead)" }
        if s.behind > 0 { subtitle += "  ↓\(s.behind)" }
        window.subtitle = subtitle
        let count = s.changeCount
        modeControl.setLabel(count > 0 ? "Changes (\(count))" : "Changes", forSegment: 1)
        modeControl.sizeToFit()
        toolbarItems[.pull]?.label = s.behind > 0 ? "Pull ↓\(s.behind)" : "Pull"
        toolbarItems[.push]?.label = s.ahead > 0 ? "Push ↑\(s.ahead)" : "Push"
        window.toolbar?.validateVisibleItems()
    }

    private func updateBanner() {
        let op = repository.opState
        root.banner.isHidden = op == .none
        guard op != .none else { return }
        let conflicts = repository.status.conflicts.count
        var text = op.title
        if conflicts > 0 { text += " — \(conflicts) conflicted file\(conflicts == 1 ? "" : "s"). Resolve and stage them, then continue." }
        root.banner.label.stringValue = text
        root.banner.skipButton.isHidden = op != .rebasing
        root.banner.continueButton.title = op == .merging ? "Commit Merge" : "Continue"
        root.banner.continueButton.isEnabled = conflicts == 0
    }

    private func updateActivity() {
        if let title = repository.activityTitle {
            root.activityBar.isHidden = false
            root.activityBar.spinner.startAnimation(nil)
            let detail = repository.activityDetail
            root.activityBar.label.stringValue = detail.isEmpty ? "\(title)…" : "\(title)… \(detail)"
        } else {
            root.activityBar.spinner.stopAnimation(nil)
            root.activityBar.isHidden = true
        }
        window?.toolbar?.validateVisibleItems()
    }

    func showError(_ title: String, _ message: String) {
        errorQueue.append((title, message))
        guard !showingError else { return }
        showingError = true
        Task {
            while !errorQueue.isEmpty {
                let (t, m) = errorQueue.removeFirst()
                await Prompt.error(window, title: "\(t) failed", message: m)
            }
            showingError = false
        }
    }

    // MARK: Toolbar

    private struct ItemSpec {
        let label: String
        let symbol: String
        let action: Selector
        let tip: String
    }

    private let specs: [NSToolbarItem.Identifier: ItemSpec] = [
        .fetch: ItemSpec(label: "Fetch", symbol: "arrow.triangle.2.circlepath", action: #selector(RepoActions.fetch(_:)), tip: "Fetch all remotes (⇧⌘F)"),
        .pull: ItemSpec(label: "Pull", symbol: "arrow.down.circle", action: #selector(RepoActions.pull(_:)), tip: "Pull (⇧⌘L)"),
        .push: ItemSpec(label: "Push", symbol: "arrow.up.circle", action: #selector(RepoActions.push(_:)), tip: "Push (⇧⌘P)"),
        .branch: ItemSpec(label: "Branch", symbol: "arrow.triangle.branch", action: #selector(RepoActions.newBranch(_:)), tip: "New branch (⇧⌘B)"),
        .merge: ItemSpec(label: "Merge", symbol: "arrow.triangle.merge", action: #selector(RepoActions.mergeBranch(_:)), tip: "Merge a branch into the current branch"),
        .rebase: ItemSpec(label: "Rebase", symbol: "arrow.up.and.down.text.horizontal", action: #selector(RepoActions.rebaseBranch(_:)), tip: "Rebase the current branch"),
        .stash: ItemSpec(label: "Stash", symbol: "tray.and.arrow.down", action: #selector(RepoActions.stashChanges(_:)), tip: "Stash changes (⇧⌘S)"),
        .pop: ItemSpec(label: "Pop", symbol: "tray.and.arrow.up", action: #selector(RepoActions.popStash(_:)), tip: "Pop the latest stash"),
        .pullRequest: ItemSpec(label: "Pull Request", symbol: "arrow.triangle.pull", action: #selector(RepoActions.createPullRequest(_:)), tip: "Create a GitHub pull request (⇧⌘R)"),
    ]

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .fetch, .pull, .push, .space, .branch, .merge, .rebase, .space, .stash, .pop, .space, .pullRequest, .flexibleSpace, .mode]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if id == .mode {
            let item = NSToolbarItem(itemIdentifier: id)
            item.view = modeControl
            item.label = "View"
            item.paletteLabel = "History / Changes"
            toolbarItems[id] = item
            return item
        }
        guard let spec = specs[id] else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = spec.label
        item.paletteLabel = spec.label
        item.toolTip = spec.tip
        item.image = Theme.symbol(spec.symbol, spec.label)
        item.target = self
        item.action = spec.action
        item.isBordered = true
        toolbarItems[id] = item
        updateTitles()
        return item
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        validate(item.action)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleUnifiedDiff(_:)):
            menuItem.state = activeDiff?.unified == true ? .on : .off
        case #selector(toggleWholeFile(_:)):
            menuItem.state = activeDiff?.wholeFile == true ? .on : .off
        case #selector(showHistory(_:)):
            menuItem.state = state.mode == .history ? .on : .off
        case #selector(showChanges(_:)):
            menuItem.state = state.mode == .changes ? .on : .off
        default:
            break
        }
        return validate(menuItem.action)
    }

    private func validate(_ action: Selector?) -> Bool {
        guard let action else { return true }
        let busy = repository.isBusy
        switch action {
        case #selector(fetch(_:)), #selector(pull(_:)), #selector(pullRebase(_:)), #selector(push(_:)),
             #selector(forcePush(_:)), #selector(newBranch(_:)), #selector(mergeBranch(_:)), #selector(rebaseBranch(_:)),
             #selector(stashChanges(_:)):
            return !busy
        case #selector(popStash(_:)):
            return !busy && !repository.stashes.isEmpty
        case #selector(createPullRequest(_:)):
            return !busy && repository.currentBranch != nil
        default:
            return true
        }
    }

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        setMode(ViewMode(rawValue: sender.selectedSegment) ?? .history)
    }

    private func setMode(_ mode: ViewMode) {
        modeControl.selectedSegment = mode.rawValue
        root.main?.content.show(mode)
        if mode == .changes { root.main?.content.changes?.focusMessage() }
    }

    private var activeDiff: DiffViewController? { root.main?.content.activeDiff }

    // MARK: RepoActions (menu + toolbar)

    @objc func fetch(_ sender: Any?) { Task { await repository.fetch() } }
    @objc func pull(_ sender: Any?) { Task { await repository.pull() } }
    @objc func pullRebase(_ sender: Any?) { Task { await repository.pull(rebase: true) } }
    @objc func push(_ sender: Any?) { Task { await repository.push() } }

    @objc func forcePush(_ sender: Any?) {
        guard let branch = repository.currentBranch else { return }
        Task {
            guard await Prompt.confirm(window, title: "Force push \(branch)?",
                                       message: "Uses --force-with-lease: the push is refused if the remote has commits you haven’t fetched.",
                                       ok: "Force Push", destructive: true) else { return }
            await repository.push(force: true)
        }
    }

    @objc func newBranch(_ sender: Any?) {
        var start: String?
        if state.mode == .history, let h = state.selectedCommit, h != repository.headHash { start = h.hex }
        promptNewBranch(from: start)
    }

    @objc func mergeBranch(_ sender: Any?) {
        let options = branchChoices()
        Task {
            guard let target = await Prompt.choose(window, title: "Merge into \(repository.currentBranch ?? "HEAD")",
                                                   message: "Choose the branch to merge.", options: options, ok: "Merge") else { return }
            await repository.merge(target)
        }
    }

    @objc func rebaseBranch(_ sender: Any?) {
        let options = branchChoices()
        let upstream = repository.status.upstream
        Task {
            guard let target = await Prompt.choose(window, title: "Rebase \(repository.currentBranch ?? "HEAD")",
                                                   message: "Choose the branch to rebase onto.", options: options,
                                                   selected: upstream, ok: "Rebase") else { return }
            await repository.rebase(onto: target)
        }
    }

    private func branchChoices() -> [String] {
        let current = repository.currentBranch
        return repository.localBranches.map(\.name).filter { $0 != current } + repository.remoteBranches.map(\.name)
    }

    @objc func stashChanges(_ sender: Any?) { Task { await repository.stash() } }
    @objc func popStash(_ sender: Any?) { Task { await repository.stashPop() } }

    @objc func createPullRequest(_ sender: Any?) {
        guard let branch = repository.currentBranch else { return }
        showPullRequestSheet(head: branch)
    }

    @objc func refresh(_ sender: Any?) {
        Task {
            await repository.refreshAll()
            await repository.reloadGraph()
        }
    }

    @objc func showHistory(_ sender: Any?) { setMode(.history) }
    @objc func showChanges(_ sender: Any?) { setMode(.changes) }
    @objc func toggleUnifiedDiff(_ sender: Any?) { activeDiff?.toggleUnified() }
    @objc func toggleWholeFile(_ sender: Any?) { activeDiff?.toggleWholeFile() }
    @objc func nextChange(_ sender: Any?) { activeDiff?.nextChange() }
    @objc func previousChange(_ sender: Any?) { activeDiff?.previousChange() }

    @objc func revealInFinder(_ sender: Any?) {
        NSWorkspace.shared.activateFileViewerSelecting([repository.root])
    }

    @objc func openInTerminal(_ sender: Any?) {
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open([repository.root], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func continueOperation(_ sender: Any?) { Task { await repository.continueOperation() } }
    @objc private func skipOperation(_ sender: Any?) { Task { await repository.skipRebaseStep() } }
    @objc private func cancelActivity(_ sender: Any?) { repository.cancelActivity() }

    @objc private func abortOperation(_ sender: Any?) {
        Task {
            guard await Prompt.confirm(window, title: "Abort?", message: "\(repository.opState.title). Aborting restores the state before it started.",
                                       ok: "Abort", destructive: true) else { return }
            await repository.abortOperation()
        }
    }

    // MARK: Shared actions (sidebar / history)

    func reveal(commit hash: Hash20) {
        state.selectedCommit = hash
        if state.mode != .history { setMode(.history) }
        root.main?.content.history?.select(hash: hash, scroll: true)
    }

    func checkout(_ ref: RefInfo) {
        Task {
            switch ref.kind {
            case .local: await repository.checkout(branch: ref.name)
            case .remote: await repository.checkout(remote: ref)
            case .tag: await repository.checkoutDetached(ref.name)
            }
        }
    }

    func promptNewBranch(from start: String?) {
        Task {
            let base = start.map { $0.count == 40 ? String($0.prefix(8)) : $0 } ?? (repository.currentBranch ?? "HEAD")
            guard let answer = await Prompt.text(window, title: "New Branch",
                                                          message: "Create a branch from \(base).",
                                                          placeholder: "feature/my-change", ok: "Create",
                                                          checkbox: "Check out the new branch", checkboxOn: true) else { return }
            await repository.createBranch(answer.text, from: start, checkout: answer.checked)
        }
    }

    func promptNewTag(at hash: String) {
        Task {
            guard let answer = await Prompt.text(window, title: "New Tag", message: "Tag commit \(hash.prefix(8)).",
                                                 placeholder: "v1.0.0", ok: "Create") else { return }
            await repository.createTag(answer.text, at: hash)
        }
    }

    func promptRename(_ ref: RefInfo) {
        Task {
            guard let answer = await Prompt.text(window, title: "Rename Branch", message: "New name for \(ref.name):",
                                                 value: ref.name, ok: "Rename"), answer.text != ref.name else { return }
            await repository.renameBranch(ref.name, to: answer.text)
        }
    }

    func confirmDelete(_ ref: RefInfo) {
        Task {
            guard await Prompt.confirm(window, title: "Delete branch \(ref.name)?", message: "The local branch will be deleted.",
                                       ok: "Delete", destructive: true) else { return }
            let r = await repository.deleteBranch(ref.name, force: false)
            if !r.ok, r.status != -2 {
                if r.errorMessage.contains("not fully merged") {
                    guard await Prompt.confirm(window, title: "\(ref.name) is not fully merged",
                                               message: "Deleting it may lose commits. Delete anyway?", ok: "Force Delete",
                                               destructive: true) else { return }
                    await repository.deleteBranch(ref.name, force: true)
                } else {
                    showError("Delete \(ref.name)", r.errorMessage)
                }
            }
        }
    }

    func confirmDeleteRemote(_ ref: RefInfo) {
        Task {
            guard await Prompt.confirm(window, title: "Delete \(ref.name) on the remote?",
                                       message: "This removes the branch from \(ref.remoteName ?? "the remote") for everyone.",
                                       ok: "Delete", destructive: true) else { return }
            await repository.deleteRemoteBranch(ref)
        }
    }

    func confirmMerge(_ target: String) {
        Task {
            let label = target.count == 40 ? String(target.prefix(8)) : target
            guard await Prompt.confirm(window, title: "Merge \(label) into \(repository.currentBranch ?? "HEAD")?",
                                       message: "", ok: "Merge") else { return }
            await repository.merge(target)
        }
    }

    func confirmRebase(onto target: String) {
        Task {
            let label = target.count == 40 ? String(target.prefix(8)) : target
            guard await Prompt.confirm(window, title: "Rebase \(repository.currentBranch ?? "HEAD") onto \(label)?",
                                       message: "Your commits will be replayed on top of \(label).", ok: "Rebase") else { return }
            await repository.rebase(onto: target)
        }
    }

    func confirmReset(to hash: String, mode: String) {
        Task {
            let destructive = mode == "hard"
            let message = destructive ? "Uncommitted changes will be lost." : "Changes after this commit are kept in the working tree."
            guard await Prompt.confirm(window, title: "Reset \(repository.currentBranch ?? "HEAD") to \(hash.prefix(8)) (\(mode))?",
                                       message: message, ok: "Reset", destructive: destructive) else { return }
            await repository.reset(to: hash, mode: mode)
        }
    }

    private var prSheet: PullRequestSheet?

    func showPullRequestSheet(head: String) {
        guard let window, window.attachedSheet == nil else { return }
        let sheet = PullRequestSheet(repository: repository, head: head)
        prSheet = sheet
        sheet.onFinish = { [weak self] in self?.prSheet = nil }
        sheet.present(on: window)
    }
}
