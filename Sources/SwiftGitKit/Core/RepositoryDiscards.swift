import Foundation

/// A saved copy of changes taken just before they were discarded.
struct DiscardedChanges: Equatable {
    /// Snapshot commit (its parent is HEAD at the time).
    var sha: String
    var summary: String
    var date: Date
    /// Position in the reflog ("refs/swiftgit/discarded@{n}").
    var index: Int
}

/// Discarded changes are kept as snapshot commits recorded in the reflog of one
/// hidden ref (not a branch, not a stash, not shown in history). Entries older
/// than `discardKeepDays` are expired when the repository is opened; once
/// nothing refers to them, git's normal garbage collection removes the data.
extension Repository {
    /// Per-worktree ref (refs/worktree/… is private to each worktree), so
    /// snapshots never mix between worktrees of one repository.
    static let discardRef = "refs/worktree/swiftgit/discarded"
    /// Where snapshots were kept before worktree support (shared by all worktrees).
    static let legacyDiscardRef = "refs/swiftgit/discarded"
    static let discardKeepDays = 14

    /// Saves the current working-tree content of `paths` (nil: every changed
    /// and untracked file) on top of HEAD. Returns false if saving failed.
    @discardableResult
    func saveDiscarded(paths: [String]?, summary: String) async -> Bool {
        // A throwaway index outside .git (so the file watcher doesn't react to it).
        let index = FileManager.default.temporaryDirectory.appendingPathComponent("swiftgit-discard-\(UUID().uuidString).index")
        let changed = paths ?? Array(Set((status.staged + status.unstaged + status.conflicts).flatMap { [$0.path] + ($0.origPath.map { [$0] } ?? []) }))
        guard !changed.isEmpty else { return true }
        defer { try? FileManager.default.removeItem(at: index) }
        let env = ["GIT_INDEX_FILE": index.path]
        let head = await git.run(["rev-parse", "-q", "--verify", "HEAD"])
        let headSha = head.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasHead = head.ok && !headSha.isEmpty

        guard await git.run(hasHead ? ["read-tree", "HEAD"] : ["read-tree", "--empty"], environment: env).ok else { return false }
        let add = await git.run(["add", "-A", "--ignore-errors", "--"] + changed, environment: env)
        guard add.ok else { return false }
        let tree = await git.run(["write-tree"], environment: env)
        let treeSha = tree.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard tree.ok, !treeSha.isEmpty else { return false }
        if hasHead {
            let headTree = await git.run(["rev-parse", "HEAD^{tree}"]).output.trimmingCharacters(in: .whitespacesAndNewlines)
            if headTree == treeSha { return true }   // nothing differs from HEAD: nothing to keep
        }
        let identity = ["GIT_AUTHOR_NAME": "SwiftGit", "GIT_AUTHOR_EMAIL": "swiftgit@localhost",
                        "GIT_COMMITTER_NAME": "SwiftGit", "GIT_COMMITTER_EMAIL": "swiftgit@localhost"]
        let commit = await git.run(["commit-tree", "--no-gpg-sign", treeSha] + (hasHead ? ["-p", headSha] : []) + ["-m", summary],
                                   environment: identity)
        let sha = commit.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard commit.ok, !sha.isEmpty else { return false }
        let oneLine = summary.replacingOccurrences(of: "\n", with: " ")
        return await git.run(["update-ref", "--create-reflog", "-m", oneLine, Repository.discardRef, sha]).ok
    }

    /// Newest first.
    func discardedChanges() async -> [DiscardedChanges] {
        let r = await git.run(["reflog", "show", "--format=%H%x1f%gs%x1f%ct", Repository.discardRef, "--"])
        guard r.ok else { return [] }
        return r.output.split(separator: "\n").enumerated().compactMap { i, line in
            let f = line.split(separator: "\u{1f}", omittingEmptySubsequences: false)
            guard f.count == 3, let t = TimeInterval(f[2]) else { return nil }
            return DiscardedChanges(sha: String(f[0]), summary: String(f[1]), date: Date(timeIntervalSince1970: t), index: i)
        }
    }

    /// Files that differ between the snapshot and the commit it was taken on.
    func discardedFiles(_ d: DiscardedChanges) async -> [String] {
        let r = await git.run(["diff", "--name-only", "-z", "--no-renames", "\(d.sha)^", d.sha])
        guard r.ok else {
            // Snapshot of an unborn branch: every file in it.
            let all = await git.run(["ls-tree", "-r", "-z", "--name-only", d.sha])
            return all.output.split(separator: "\0").map(String.init)
        }
        return r.output.split(separator: "\0").map(String.init)
    }

    /// Puts the saved content of those files back into the working copy. Their
    /// current content is saved first, so restoring can be undone the same way.
    @discardableResult
    func restoreDiscarded(_ d: DiscardedChanges) async -> Bool {
        let files = await discardedFiles(d)
        guard !files.isEmpty else { return true }
        await saveDiscarded(paths: files, summary: "Before restoring “\(d.summary)”")
        // Files the snapshot deleted are removed again; the others get its content.
        let present = await git.run(["ls-tree", "-r", "-z", "--name-only", d.sha, "--"] + files)
        let inSnapshot = Set(present.output.split(separator: "\0").map(String.init))
        let restore = files.filter { inSnapshot.contains($0) }
        if !restore.isEmpty {
            guard await perform("Restore discarded changes", ["restore", "--source", d.sha, "--worktree", "--"] + restore).ok else {
                return false
            }
        }
        for f in files where !inSnapshot.contains(f) {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(f))
        }
        await refreshStatus()
        return true
    }

    func deleteDiscarded(_ d: DiscardedChanges) async {
        let count = await discardedChanges().count
        if count <= 1 {
            _ = await git.run(["update-ref", "-d", Repository.discardRef])
        } else {
            _ = await git.run(["reflog", "delete", "--updateref", "\(Repository.discardRef)@{\(d.index)}"])
        }
    }

    /// Drops snapshots older than `discardKeepDays` (and the ref once empty).
    /// Moves snapshots from the old shared ref into this worktree's own (once,
    /// in the main worktree, where they were taken). Dates restart at the move.
    func migrateLegacyDiscards() async {
        guard !isLinkedWorktree,
              await git.run(["rev-parse", "-q", "--verify", Repository.legacyDiscardRef]).ok else { return }
        let r = await git.run(["reflog", "show", "--format=%H%x1f%gs", Repository.legacyDiscardRef, "--"])
        let entries = r.output.split(separator: "\n").compactMap { line -> (String, String)? in
            let f = line.split(separator: "\u{1f}", maxSplits: 1, omittingEmptySubsequences: false)
            return f.count == 2 ? (String(f[0]), String(f[1])) : nil
        }
        for (sha, message) in entries.reversed() {
            _ = await git.run(["update-ref", "--create-reflog", "-m", message, Repository.discardRef, sha])
        }
        _ = await git.run(["update-ref", "-d", Repository.legacyDiscardRef])
    }

    func expireDiscarded(now: Date = Date()) async {
        guard await git.run(["rev-parse", "-q", "--verify", Repository.discardRef]).ok else { return }
        let cutoff = now.addingTimeInterval(-Double(Repository.discardKeepDays) * 86_400)
        let entries = await discardedChanges()
        if entries.allSatisfy({ $0.date < cutoff }) {
            _ = await git.run(["update-ref", "-d", Repository.discardRef])
            return
        }
        // Oldest first so the indexes of newer entries stay valid.
        for e in entries.reversed() where e.date < cutoff {
            _ = await git.run(["reflog", "delete", "\(Repository.discardRef)@{\(e.index)}"])
        }
    }
}
