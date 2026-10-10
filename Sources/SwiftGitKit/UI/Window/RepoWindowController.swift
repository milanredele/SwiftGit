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
    static let account = Self("githubAccount")
    static let undo = Self("undo")
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

        let toolbar = NSToolbar(identifier: "SwiftGitToolbar3")
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
        NotificationCenter.default.addObserver(self, selector: #selector(historyOrderChanged(_:)),
                                               name: RepoWindowController.historyOrderChanged, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    var testRoot: RootViewController { root }

    // MARK: Window

    func windowDidBecomeKey(_ notification: Notification) {
        GitHubAccounts.shared.refresh()
        if Settings.fetchOnFocus { repository.fetchInBackground() }
        repository.loadPullRequests()
    }

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
            (toolbarItems[.account] as? GitHubAccountToolbarItem)?.repositoryChanged()
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
        .undo: ItemSpec(label: "Undo", symbol: "arrow.uturn.backward", action: #selector(RepoActions.undoGitOperation(_:)), tip: "Undo the last git operation (⌥⌘Z)"),
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
        [.toggleSidebar, .undo, .space, .fetch, .pull, .push, .space, .branch, .merge, .rebase, .space, .stash, .pop, .space, .pullRequest, .flexibleSpace, .account, .mode]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if id == .account {
            let item = GitHubAccountToolbarItem(identifier: id, repository: repository)
            toolbarItems[id] = item
            return item
        }
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
        if item.action == #selector(undoGitOperation(_:)) {
            item.toolTip = repository.undoCandidate.map { "Undo \($0.title) (⌥⌘Z)" } ?? "Nothing to undo"
        }
        return validate(item.action)
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
        case #selector(undoGitOperation(_:)):
            menuItem.title = repository.undoCandidate.map { "Undo \($0.title)" } ?? "Undo Git Operation"
        case #selector(toggleTopoOrder(_:)):
            menuItem.state = UserDefaults.standard.bool(forKey: Repository.topoOrderKey) ? .on : .off
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
        case #selector(undoGitOperation(_:)):
            return !busy && repository.undoCandidate != nil
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
    @objc func pull(_ sender: Any?) { pullHandlingLocalChanges(mode: Settings.pullMode) }
    @objc func pullRebase(_ sender: Any?) { pullHandlingLocalChanges(mode: .rebase) }

    /// Pulls; if uncommitted changes are in the way, offers to stash them,
    /// pull and re-apply them (git's --autostash).
    func pullHandlingLocalChanges(mode: PullMode) {
        Task {
            let autostash = Settings.autostash
            let r = await repository.pullResult(mode: mode, autostash: autostash, reportErrors: false)
            if r.ok {
                await explainAutostash(r)
                return
            }
            guard r.status != -2 else { return }
            let output = r.stderr + "\n" + r.output
            switch PullProblem.classify(output) {
            case .localChanges where !autostash:
                let files = Self.overwrittenFiles(output)
                var which = "Your uncommitted changes"
                if !files.isEmpty {
                    which += " to " + files.prefix(6).joined(separator: ", ")
                    if files.count > 6 { which += " and \(files.count - 6) more" }
                }
                let message = which + " are in the way of the pull.\n\nSwiftGit can stash them, pull, and put them back afterwards. "
                    + "If putting them back conflicts, they stay safe in the stash list."
                guard let always = await Prompt.confirm(window, title: "Stash changes and pull?", message: message,
                                                        ok: "Stash and Pull", destructive: false,
                                                        option: "Always do this (Settings › Pull)") else { return }
                if always { Settings.autostash = true }
                let again = await repository.pullResult(mode: mode, autostash: true, reportErrors: true)
                if again.ok { await explainAutostash(again) }
            case .notFastForward:
                showError("Pull", "Your branch and its upstream have diverged, so it can’t be fast-forwarded. "
                          + "Use Pull (Rebase), or change the pull mode in Settings.\n\n" + r.errorMessage)
            default:
                showError("Pull", r.errorMessage)
            }
        }
    }

    private func explainAutostash(_ r: RunResult) async {
        guard PullProblem.autostashConflicted(r.stderr + r.output) else { return }
        await Prompt.error(window, title: "Your stashed changes conflict with the pulled commits",
                           message: "The pull worked, but putting your local changes back caused conflicts. Resolve them in Changes; "
                            + "your changes are also still in the stash list (Pop or Drop it afterwards).")
    }

    /// File names from git's "would be overwritten by merge:" list.
    static func overwrittenFiles(_ output: String) -> [String] {
        var files: [String] = []
        var inList = false
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.contains("would be overwritten by") { inList = true; continue }
            guard inList else { continue }
            if line.hasPrefix("\t") || line.hasPrefix("        ") {
                files.append(line.trimmingCharacters(in: .whitespaces))
            } else { inList = false }
        }
        return files
    }
    @objc func push(_ sender: Any?) { pushExplainingRejection(branch: nil) }

    /// Pushes; when git refuses because the remote branch has other commits
    /// (typically after a rebase or amend), explains why and offers a force
    /// push or a pull instead of showing git's raw error.
    func pushExplainingRejection(branch: String?) {
        Task {
            guard let name = branch ?? repository.currentBranch else {
                await repository.push()   // reports the detached-HEAD error
                return
            }
            let r = await repository.pushResult(branch: name, force: false, reportErrors: false)
            guard !r.ok, r.status != -2 else { return }
            guard PushProblem.classify(r.stderr) == .diverged,
                  let upstream = repository.localBranch(named: name)?.upstream,
                  let slash = upstream.firstIndex(of: "/") else {
                showError("Push \(name)", r.errorMessage)
                return
            }
            // git push doesn't update the remote-tracking branch on rejection: fetch it to count.
            let remote = String(upstream[..<slash]), remoteBranch = String(upstream[upstream.index(after: slash)...])
            _ = await repository.fetchBranch(remoteBranch, remote: remote)
            let d = await repository.divergence(local: name, remoteRef: "refs/remotes/\(upstream)")
            let ahead = d?.ahead ?? 0, behind = d?.behind ?? 0
            let isCurrent = name == repository.currentBranch
            if ahead == 0 && behind > 0 {
                let choice = await Prompt.buttons(window, title: "\(upstream) has \(Self.commits(behind)) you don’t have",
                    message: "Your \(name) has nothing new to push." + (isCurrent ? " Pull to bring it up to date." : ""),
                    buttons: isCurrent ? ["Pull", "Cancel"] : ["OK"])
                if isCurrent && choice == 0 { await repository.pull() }
                return
            }
            let message = """
            Push was rejected because \(name) and \(upstream) have diverged: \(Self.commits(ahead)) only here, \(Self.commits(behind)) only on \(remote).

            This is expected after a rebase or amend: the remote still has the old commits. Force push replaces \(upstream) with your version (with lease, so it is refused if the remote changes again in the meantime). Only do this if nobody else is working on the branch.

            If someone else pushed to it, \(isCurrent ? "pull (rebase)" : "check out the branch and pull") instead.
            """
            let choice = await Prompt.buttons(window, title: "Push rejected: \(name) was rewritten", message: message,
                                              buttons: isCurrent ? ["Force Push", "Pull (Rebase)", "Cancel"] : ["Force Push", "Cancel"],
                                              destructive: 0)
            if choice == 0 { await repository.push(branch: name, force: true) }
            if choice == 1, isCurrent { await repository.pull(rebase: true) }
        }
    }

    static func commits(_ n: Int) -> String { n == 1 ? "1 commit" : "\(n) commits" }

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

    @objc func undoGitOperation(_ sender: Any?) {
        guard let e = repository.undoCandidate else { NSSound.beep(); return }
        Task {
            guard await Prompt.confirm(window, title: "Undo \(e.title)?", message: e.explanation, ok: "Undo") else { return }
            await repository.undo(e)
        }
    }

    @objc func recoverDiscarded(_ sender: Any?) {
        guard let window else { return }
        let sheet = DiscardedChangesSheet(repository: repository)
        sheets.append(sheet)
        sheet.onFinish = { [weak self, weak sheet] in self?.sheets.removeAll { $0 === sheet } }
        sheet.present(on: window)
    }

    /// Keeps sheet controllers alive while they are shown.
    private var sheets: [NSWindowController] = []

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

    static let historyOrderChanged = Notification.Name("SwiftGitHistoryOrderChanged")

    @objc func toggleTopoOrder(_ sender: Any?) {
        Settings.topoOrder.toggle()
        NotificationCenter.default.post(name: RepoWindowController.historyOrderChanged, object: nil)
    }

    @objc private func historyOrderChanged(_ n: Notification) {
        Task { await repository.reloadGraph() }
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

    /// Explains what deleting a branch means for this particular branch before doing it.
    func confirmDelete(_ ref: RefInfo) {
        guard ref.kind == .local else { confirmDeleteRemote(ref); return }
        guard !ref.isHead else {
            showError("Delete \(ref.name)", "\(ref.name) is the checked-out branch. Check out another branch first.")
            return
        }
        Task {
            let info = await repository.deletionInfo(for: ref)
            let report = await repository.mergeReport(for: ref)
            var lines: [String] = []
            let main = info.mainBranch ?? "the main branch"
            let isMerged = report.merged || ref.isMerged
            if isMerged {
                lines.append(report.steps.last(where: { $0.hasPrefix("✓") }) ?? "✓ Merged into \(main).")
            } else {
                lines.append("✗ Not merged into \(main) (normal, squash or rebase).")
            }
            if let upstream = ref.upstream {
                if ref.upstreamGone {
                    lines.append("✓ Its remote branch \(upstream) was already deleted (usually after the PR was merged).")
                } else if ref.ahead > 0 {
                    lines.append("⚠︎ \(ref.ahead) commit\(ref.ahead == 1 ? "" : "s") not pushed to \(upstream).")
                } else {
                    lines.append("✓ Pushed: \(upstream) has all its commits\(ref.behind > 0 ? " (and \(ref.behind) more)" : "").")
                }
            } else {
                lines.append("⚠︎ Never pushed: no remote branch.")
            }
            if !info.lastSubject.isEmpty {
                let when = info.lastDate.map { relativeDateFormatter.string(from: $0) } ?? ""
                lines.append("Last commit: “\(info.lastSubject)” \(when)")
            }
            let losing = info.uniqueCommits > 0 && !isMerged
            if losing {
                lines.append("")
                lines.append("⚠︎ \(info.uniqueCommits) commit\(info.uniqueCommits == 1 ? " exists" : "s exist") only on this branch and will no longer be reachable. Git keeps them for a while (git reflog), but they will eventually be removed.")
            } else {
                lines.append("")
                lines.append("No work will be lost: every commit is also on another branch, a remote branch or in \(main).")
            }
            let remoteOption: String? = (ref.upstream != nil && !ref.upstreamGone) ? "Also delete \(ref.upstream!) on the remote" : nil
            guard let alsoRemote = await Prompt.confirm(window, title: "Delete branch “\(ref.name)”?",
                                                        message: lines.joined(separator: "\n"),
                                                        ok: losing ? "Delete and Lose Commits" : "Delete",
                                                        destructive: losing, option: remoteOption) else { return }
            // The user has seen the consequences, so force (-D) to also cover squash merges.
            let r = await repository.deleteBranch(ref.name, force: true)
            guard r.ok else { return }
            if alsoRemote, let upstream = ref.upstream,
               let remoteRef = repository.remoteBranches.first(where: { $0.name == upstream }) {
                await repository.deleteRemoteBranch(remoteRef)
            }
        }
    }

    func confirmDeleteRemote(_ ref: RefInfo) {
        Task {
            let info = await repository.deletionInfo(for: ref)
            let remote = ref.remoteName ?? "the remote"
            var lines = ["This removes \(ref.remoteBranch ?? ref.name) from \(remote) for everyone who uses it."]
            if let local = info.trackingLocal {
                lines.append("Your local branch \(local) is kept; it will show as “remote deleted”.")
            }
            if info.uniqueCommits > 0 {
                lines.append("⚠︎ \(info.uniqueCommits) commit\(info.uniqueCommits == 1 ? " is" : "s are") on no other branch or tag and will be lost from \(remote).")
            } else {
                lines.append("No work will be lost: every commit is also on another branch or tag.")
            }
            guard await Prompt.confirm(window, title: "Delete “\(ref.name)” on \(remote)?",
                                       message: lines.joined(separator: "\n"),
                                       ok: "Delete on Remote", destructive: true) else { return }
            await repository.deleteRemoteBranch(ref)
        }
    }

    /// Explains step by step whether (and how) a branch is merged into main.
    func showMergeStatus(_ ref: RefInfo) {
        Task {
            let report = await repository.mergeReport(for: ref)
            let alert = NSAlert()
            alert.messageText = report.merged ? "“\(ref.name)” is merged" : "“\(ref.name)” is not merged"
            alert.informativeText = report.steps.joined(separator: "\n")
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Copy Details")
            let response: NSApplication.ModalResponse
            if let window, window.attachedSheet == nil {
                response = await withCheckedContinuation { c in alert.beginSheetModal(for: window) { c.resume(returning: $0) } }
            } else {
                response = alert.runModal()
            }
            if response == .alertSecondButtonReturn {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("\(ref.name) @ \(ref.target)\n" + report.steps.joined(separator: "\n"), forType: .string)
            }
        }
    }

    /// Highlights the branch(es) of the commit selected in the history.
    func highlightBranch(of refs: [RefInfo]) {
        root.main?.sidebar.highlight(refs.filter { $0.name != "HEAD" })
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
        sheet.onFinish = { [weak self] in
            self?.prSheet = nil
            self?.repository.loadPullRequests(minInterval: 0)
        }
        sheet.present(on: window)
    }
}
