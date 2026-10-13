import AppKit

/// Opens and closes repository tabs (the app delegate).
@MainActor
protocol RepositoryTabHost: AnyObject {
    func open(_ url: URL, select: Bool) async
    /// Closes the tab showing the worktree at `root`, if any.
    func closeTab(root: URL)
    func isOpen(root: URL) -> Bool
}

extension RepoWindowController {
    // MARK: Opening

    func openWorktree(_ wt: WorktreeInfo) {
        Task {
            guard !wt.isBare else { return }
            if !FileManager.default.fileExists(atPath: wt.path) {
                if wt.isLocked {
                    // Locked: probably on a drive that isn't connected. Never prune it from here.
                    await Prompt.error(window, title: "“\(wt.name)” is unavailable",
                                       message: "\(wt.path) can’t be found. The worktree is locked\(wt.lockReason.map { " (\($0))" } ?? ""), so git keeps it — connect the drive it is on and try again.")
                    return
                }
                let prune = await Prompt.confirm(window, title: "“\(wt.name)” no longer exists",
                                                 message: "The folder \(wt.path) was moved or deleted outside SwiftGit. Pruning removes git’s record of it, and of any other worktree whose folder is gone (except locked ones). Branches are kept.",
                                                 ok: "Prune")
                if prune { await repository.pruneWorktrees() }
                return
            }
            await tabHost?.open(wt.url, select: true)
        }
    }

    /// Git allows a branch in only one worktree: offers to go to the one that has it.
    func offerOpenWorktree(_ wt: WorktreeInfo, branch: String) async {
        let choice = await Prompt.buttons(window, title: "“\(branch)” is checked out in another worktree",
                                          message: "Git lets a branch be checked out in only one worktree at a time. It is checked out in “\(wt.name)” (\(wt.path)).",
                                          buttons: ["Open That Worktree", "Cancel"])
        if choice == 0 { openWorktree(wt) }
    }

    // MARK: Creating

    /// Asks for a branch and folder and adds a worktree. `branch`: preselected
    /// local or remote branch name.
    func promptNewWorktree(branch: String? = nil) {
        guard let window, window.attachedSheet == nil else { return }
        Task {
            let busy = Set(repository.worktrees.compactMap(\.branch))
            let locals = repository.localBranches.map(\.name).filter { !busy.contains($0) }
            let remotes = repository.remoteBranches.filter { r in !busy.contains(r.remoteBranch ?? "") }.map(\.name)
            let start = repository.currentBranch ?? repository.headHash.map { String($0.hex.prefix(8)) } ?? "HEAD"
            let message = "Check out a branch in a separate folder, to work on it alongside \(repository.currentBranch ?? "this worktree"). A name that isn’t a branch yet creates a new branch from \(start)."
            let repo = repository
            guard let r = await NewWorktreePrompt.run(window, message: message, branches: locals + remotes,
                                                      initial: branch ?? "",
                                                      defaultPath: { repo.defaultWorktreePath(for: repo.worktreeBranchName(for: $0)) })
            else { return }
            await addWorktree(r)
        }
    }

    func addWorktree(_ r: NewWorktreePrompt.Result) async {
        let what = repository.worktreeBranch(for: r.branch, start: nil)
        if case .existing(let b) = what {
            if b == repository.currentBranch && repository.currentWorktree?.branch == b {
                showError("Add worktree", "\(b) is checked out in this worktree. Git lets a branch be checked out in only one worktree at a time — pick another branch, or type a new branch name.")
                return
            }
            if let other = repository.worktreeUsing(branch: b) {
                await offerOpenWorktree(other, branch: b)
                return
            }
        }
        if FileManager.default.fileExists(atPath: r.path.path),
           let items = try? FileManager.default.contentsOfDirectory(atPath: r.path.path), !items.isEmpty {
            showError("Add worktree", "\(r.path.path) already exists and isn’t empty. Choose another folder.")
            return
        }
        guard await repository.addWorktree(at: r.path, what).ok else { return }
        if r.openInTab { await tabHost?.open(r.path, select: true) }
    }

    // MARK: Removing

    func confirmRemoveWorktree(_ wt: WorktreeInfo) {
        guard !wt.isMain else {
            showError("Remove worktree", "“\(wt.name)” is the main worktree: it contains the repository itself, so it can’t be removed.")
            return
        }
        Task {
            let state = await repository.worktreeState(wt)
            let isSelf = samePath(wt.path, repository.root.path)
            if state.invalid {
                showError("Remove worktree", "\(wt.path) doesn’t look like that worktree any more (its .git file may be missing). Check the folder in the Finder; if it is no longer needed, delete it there and prune.")
                return
            }
            var lines = [wt.path, ""]
            var losing = 0
            if let op = state.operation {
                lines.append("⚠︎ It is in the middle of \(op); that is abandoned.")
            }
            if state.detachedCommits > 0 {
                losing = state.detachedCommits
                lines.append("⚠︎ It is detached and has \(Self.commits(losing)) on no branch. They will be lost — create a branch for them first to keep them.")
            }
            if state.missing {
                lines.append("Its folder no longer exists. This removes git’s record of it (and of any other worktree whose folder is gone).")
            } else {
                if state.changedFiles.isEmpty {
                    lines.append("✓ No uncommitted changes.")
                } else {
                    let n = state.changedFiles.count
                    var list = state.changedFiles.prefix(5).map { "   " + $0 }.joined(separator: "\n")
                    if n > 5 { list += "\n   … and \(n - 5) more" }
                    lines.append("⚠︎ \(n) changed file\(n == 1 ? "" : "s"):\n\(list)\nThey are saved as a stash first; stashes are shared by all worktrees, so you can apply it anywhere later.")
                }
                lines.append("The folder is deleted, including ignored files such as build output, and so are its recoverable discarded changes.")
            }
            if wt.isLocked { lines.append("🔒 It is locked" + (wt.lockReason.map { ": \($0)" } ?? "") + "; removing it lifts the lock.") }
            var option: String?
            var optionOn = false
            if let b = wt.branch {
                let ref = repository.localBranch(named: b)
                if state.unpushedCommits > 0 {
                    lines.append("⚠︎ \(b) has \(Self.commits(state.unpushedCommits)) that \(state.unpushedCommits == 1 ? "is" : "are") on no remote and no other branch. Keep the branch to keep them.")
                    // From its own tab there is no Undo afterwards (the tab closes).
                    option = isSelf ? nil : "Also delete the branch \(b) (its commits would only be reachable through Undo)"
                } else {
                    lines.append("✓ The branch \(b) is kept unless you delete it; all its commits are also on a remote or another branch.")
                    option = "Also delete the branch \(b)"
                    optionOn = ref?.isMerged == true || ref?.upstreamGone == true
                }
            }
            guard let deleteBranch = await Prompt.confirm(window, title: "Remove worktree “\(wt.name)”?",
                                                          message: lines.joined(separator: "\n"),
                                                          ok: losing > 0 ? "Remove and Lose \(Self.commits(losing))" : "Remove Worktree",
                                                          destructive: losing > 0,
                                                          option: option, optionOn: optionOn) else { return }
            await removeWorktree(wt, state: state, deleteBranch: deleteBranch)
        }
    }

    func removeWorktree(_ wt: WorktreeInfo, state: Repository.WorktreeState, deleteBranch: Bool) async {
        guard !wt.isMain && !wt.isBare else { return }
        let isSelf = samePath(wt.path, repository.root.path)
        if !state.changedFiles.isEmpty {
            guard await repository.stashChanges(in: wt, message: "SwiftGit: changes from worktree \(wt.name)") else { return }
        }
        // Changes were stashed, so no force: if anything new appeared meanwhile, git refuses.
        guard await repository.removeWorktree(wt, force: false) else { return }
        if !isSelf { tabHost?.closeTab(root: wt.url) }
        if deleteBranch, let b = wt.branch {
            if isSelf {
                await repository.perform("Delete \(b)", ["branch", "-D", b], in: repository.commonDir)
            } else {
                await repository.deleteBranch(b, force: true)
            }
        }
        if isSelf {
            // This tab's folder is gone: show the main worktree (or another one) instead.
            let next = repository.openableWorktrees.first { $0.isMain }
                ?? repository.openableWorktrees.first { !samePath($0.path, wt.path) }
            if let next, FileManager.default.fileExists(atPath: next.path) { await tabHost?.open(next.url, select: true) }
            window?.close()
        }
    }

    // MARK: Lock, move, prune

    func promptLockWorktree(_ wt: WorktreeInfo) {
        Task {
            guard let answer = await Prompt.text(window, title: "Lock worktree “\(wt.name)”?",
                                                 message: "A locked worktree isn’t pruned when its folder is unavailable (for example on a removable or network drive), and removing it asks for confirmation.",
                                                 placeholder: "Reason (optional)", ok: "Lock", allowEmpty: true) else { return }
            await repository.lockWorktree(wt, reason: answer.text)
        }
    }

    func unlockWorktree(_ wt: WorktreeInfo) {
        Task { await repository.unlockWorktree(wt) }
    }

    func promptMoveWorktree(_ wt: WorktreeInfo) {
        guard !wt.isMain else {
            showError("Move worktree", "“\(wt.name)” is the main worktree; move it in the Finder instead (and reopen it).")
            return
        }
        guard !wt.isLocked else {
            showError("Move worktree", "“\(wt.name)” is locked. Unlock it first.")
            return
        }
        Task {
            guard let answer = await Prompt.text(window, title: "Move worktree “\(wt.name)”",
                                                 message: "New folder (it must not exist yet):", value: wt.path, ok: "Move") else { return }
            let target = URL(fileURLWithPath: (answer.text as NSString).expandingTildeInPath, isDirectory: true)
            guard !samePath(target.path, wt.path) else { return }
            let isSelf = samePath(wt.path, repository.root.path)
            let wasOpen = !isSelf && tabHost?.isOpen(root: wt.url) == true
            if wasOpen { tabHost?.closeTab(root: wt.url) }
            let ok = await repository.moveWorktree(wt, to: target)
            if ok && (isSelf || wasOpen) { await tabHost?.open(target, select: true) }
            else if wasOpen { await tabHost?.open(wt.url, select: false) }
            if ok && isSelf { window?.close() }
        }
    }

    func confirmPruneWorktrees() {
        Task {
            let missing = repository.worktrees.filter { $0.isPrunable }
            guard !missing.isEmpty else {
                await Prompt.error(window, title: "Nothing to prune", message: "Every worktree’s folder still exists.")
                return
            }
            let list = missing.map { "• \($0.name) — \($0.path)" + ($0.isLocked ? " (locked, kept)" : "") }.joined(separator: "\n")
            guard await Prompt.confirm(window, title: "Prune missing worktrees?",
                                       message: "These folders no longer exist:\n\(list)\n\nPruning removes git’s records of them. Their branches are kept.",
                                       ok: "Prune") else { return }
            await repository.pruneWorktrees()
        }
    }

    @objc func newWorktree(_ sender: Any?) { promptNewWorktree() }
}
