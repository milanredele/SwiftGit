import Foundation

/// HEAD as a branch name (nil when detached) and commit.
struct HeadState: Equatable {
    var branch: String?
    var sha: String?
}

/// How to take back one git operation done in the app.
struct UndoEntry: Equatable {
    enum Kind: Equatable {
        /// commit / amend: `reset --soft` back, the changes return to staged.
        case commit
        /// merge, rebase, pull, cherry-pick, revert, reset, rewrite: `reset --keep` back.
        case moveHead
        case checkout
        /// name, the commit it was created at
        case createBranch(String, String)
        /// name, the commit it pointed to
        case deleteBranch(String, String)
        /// old name, new name
        case renameBranch(String, String)
    }

    var kind: Kind
    /// Menu text, e.g. "Commit “Fix typo”".
    var title: String
    var before: HeadState
    var after: HeadState

    /// What undoing will do, for the confirmation dialog.
    var explanation: String {
        let short = { (s: String?) in s.map { String($0.prefix(8)) } ?? "?" }
        switch kind {
        case .commit:
            return "\(after.branch ?? "HEAD") moves back to \(short(before.sha)). The committed changes stay in your working copy, staged."
        case .moveHead:
            return "\(after.branch ?? "HEAD") moves back to \(short(before.sha)), where it was before. Uncommitted changes are kept "
                + "(git refuses if they would be overwritten)."
        case .checkout:
            return "Checks out \(before.branch ?? short(before.sha)) again."
        case .createBranch(let name, _):
            return "Deletes the branch \(name)" + (after.branch == name ? " and checks out \(before.branch ?? short(before.sha)) again." : ".")
        case .deleteBranch(let name, let sha):
            return "Recreates \(name) at \(short(sha))."
        case .renameBranch(let old, let new):
            return "Renames \(new) back to \(old)."
        }
    }
}

extension Repository {
    static let maxUndo = 20

    func headState() async -> HeadState {
        async let b = git.run(["symbolic-ref", "-q", "--short", "HEAD"])
        async let h = git.run(["rev-parse", "-q", "--verify", "HEAD"])
        let (br, hr) = await (b, h)
        let branch = br.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let sha = hr.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return HeadState(branch: br.ok && !branch.isEmpty ? branch : nil, sha: hr.ok && !sha.isEmpty ? sha : nil)
    }

    /// Runs an operation and remembers how to undo it. If it stops for
    /// conflicts, the entry is completed when the operation is continued.
    @discardableResult
    func recordingUndo(_ kind: UndoEntry.Kind, _ title: String, _ op: () async -> RunResult) async -> RunResult {
        let before = await headState()
        let r = await op()
        let after = await headState()
        let entry = UndoEntry(kind: kind, title: title, before: before, after: after)
        if opState != .none {
            if pendingUndo == nil { pendingUndo = entry }
            return r
        }
        if r.ok { pushUndo(entry) }
        return r
    }

    /// Called after continue/abort/skip of a stopped operation.
    func finishPendingUndo(aborted: Bool) async {
        guard var entry = pendingUndo else { return }
        if aborted { pendingUndo = nil; return }
        guard opState == .none else { return }
        pendingUndo = nil
        entry.after = await headState()
        pushUndo(entry)
    }

    private func pushUndo(_ entry: UndoEntry) {
        switch entry.kind {
        case .commit, .moveHead, .checkout:
            guard entry.before != entry.after else { return }
        default: break
        }
        undoStack.append(entry)
        if undoStack.count > Repository.maxUndo { undoStack.removeFirst(undoStack.count - Repository.maxUndo) }
    }

    /// The most recent operation, if the repository is still in the state it left
    /// (otherwise undoing would throw away later work).
    var undoCandidate: UndoEntry? {
        guard let e = undoStack.last, opState == .none, !isBusy else { return nil }
        let now = HeadState(branch: status.branch, sha: status.headOID)
        func exists(_ name: String) -> Bool { localBranch(named: name) != nil }
        switch e.kind {
        case .commit, .moveHead, .checkout:
            return now == e.after ? e : nil
        case .createBranch(let name, let sha):
            return localBranch(named: name)?.target == sha && (e.after.branch != name || now == e.after) ? e : nil
        case .deleteBranch(let name, _):
            return exists(name) ? nil : e
        case .renameBranch(let old, let new):
            return exists(new) && !exists(old) ? e : nil
        }
    }

    @discardableResult
    func undo(_ e: UndoEntry) async -> Bool {
        guard undoStack.last == e else { return false }
        var ok = false
        switch e.kind {
        case .commit:
            guard let sha = e.before.sha else { return false }
            ok = await perform("Undo \(e.title)", ["reset", "--soft", sha]).ok
        case .moveHead:
            guard let sha = e.before.sha else { return false }
            ok = await perform("Undo \(e.title)", ["reset", "--keep", sha]).ok
        case .checkout:
            if let b = e.before.branch {
                ok = await perform("Undo \(e.title)", ["switch", b]).ok
            } else if let sha = e.before.sha {
                ok = await perform("Undo \(e.title)", ["switch", "--detach", sha]).ok
            }
        case .createBranch(let name, _):
            if e.after.branch == name {
                let back = e.before.branch.map { ["switch", $0] } ?? e.before.sha.map { ["switch", "--detach", $0] }
                guard let back, await perform("Undo \(e.title)", back).ok else { return false }
            }
            ok = await perform("Undo \(e.title)", ["branch", "-D", name]).ok
        case .deleteBranch(let name, let sha):
            ok = await perform("Undo \(e.title)", ["branch", name, sha]).ok
        case .renameBranch(let old, let new):
            ok = await perform("Undo \(e.title)", ["branch", "-m", new, old]).ok
        }
        if ok { undoStack.removeLast() }
        return ok
    }
}
