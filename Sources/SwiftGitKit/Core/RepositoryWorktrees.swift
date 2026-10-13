import Foundation

/// One entry of `git worktree list`.
struct WorktreeInfo: Hashable {
    var path: String
    var head: String?
    /// Short branch name; nil when detached (or bare).
    var branch: String?
    var isBare = false
    var isDetached = false
    var isLocked = false
    var lockReason: String?
    /// Its folder is gone (`git worktree prune` would remove the entry).
    var isPrunable = false
    var prunableReason: String?
    /// The first entry: the main worktree (or the bare repository itself).
    var isMain = false

    var name: String { (path as NSString).lastPathComponent }
    var url: URL { URL(fileURLWithPath: path) }

    /// Parses `git worktree list --porcelain -z`: NUL-separated attributes,
    /// an empty attribute ends each worktree.
    /// Without -z (git before 2.36) attributes are separated by newlines.
    static func parse(_ data: Data) -> [WorktreeInfo] {
        var out: [WorktreeInfo] = []
        var current: WorktreeInfo?
        let separator: UInt8 = data.contains(0) ? 0 : 10
        for field in data.split(separator: separator, omittingEmptySubsequences: false) {
            let s = String(decoding: field, as: UTF8.self)
            if s.isEmpty {
                if let c = current { out.append(c) }
                current = nil
                continue
            }
            let (key, value): (String, String?) = {
                guard let space = s.firstIndex(of: " ") else { return (s, nil) }
                return (String(s[..<space]), String(s[s.index(after: space)...]))
            }()
            switch key {
            case "worktree": current = WorktreeInfo(path: value ?? "", isMain: out.isEmpty)
            case "HEAD": current?.head = value
            case "branch": current?.branch = value.map { $0.hasPrefix("refs/heads/") ? String($0.dropFirst(11)) : $0 }
            case "detached": current?.isDetached = true
            case "bare": current?.isBare = true
            case "locked": current?.isLocked = true; current?.lockReason = value
            case "prunable": current?.isPrunable = true; current?.prunableReason = value
            default: break
            }
        }
        if let c = current { out.append(c) }
        return out
    }

    /// `-z` needs git 2.36; older versions fall back to newline-separated output.
    nonisolated(unsafe) private static var supportsZ = true

    /// `git worktree list` run in `dir`; nil if it failed.
    static func list(in dir: URL) async -> [WorktreeInfo]? {
        let git = Git(root: dir)
        if supportsZ {
            let r = await git.run(["worktree", "list", "--porcelain", "-z"])
            if r.ok { return parse(r.stdout) }
            guard r.stderr.contains("unknown switch") else { return nil }
            supportsZ = false
        }
        let r = await git.run(["worktree", "list", "--porcelain"])
        return r.ok ? parse(r.stdout) : nil
    }
}

/// Paths reported by FSEvents/git may carry the /private prefix that
/// URL.resolvingSymlinksInPath strips; compare without it.
func samePath(_ a: String, _ b: String) -> Bool {
    func norm(_ s: String) -> String {
        var p = s.hasPrefix("/private/") ? String(s.dropFirst(8)) : s
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }
    return norm(a) == norm(b)
}

/// Where new worktrees go by default.
enum WorktreeLocation {
    /// Main worktree `~/dev/app` → `~/dev/app.worktrees/<branch>`. Bare repository
    /// `~/dev/app/.bare` → `~/dev/app/<branch>` (worktrees next to it, the usual
    /// layout); `~/dev/app.git` → `~/dev/app.worktrees/<branch>`.
    static func folder(for branch: String, commonDir: URL, mainWorktree: URL?, repositoryName: String) -> URL {
        let safe = branch.replacingOccurrences(of: "/", with: "-")
        let base: URL
        if let main = mainWorktree {
            base = main.deletingLastPathComponent().appendingPathComponent("\(repositoryName).worktrees", isDirectory: true)
        } else if [".bare", ".git"].contains(commonDir.lastPathComponent) {
            base = commonDir.deletingLastPathComponent()
        } else {
            base = commonDir.deletingLastPathComponent().appendingPathComponent("\(repositoryName).worktrees", isDirectory: true)
        }
        return base.appendingPathComponent(safe, isDirectory: true)
    }

    static func repositoryName(commonDir: URL) -> String {
        let parent = [".git", ".bare"].contains(commonDir.lastPathComponent) ? commonDir.deletingLastPathComponent() : commonDir
        let n = parent.lastPathComponent
        return n.hasSuffix(".git") ? String(n.dropLast(4)) : n
    }
}

/// Git's messages about a branch that is checked out in another worktree,
/// rewritten to say what to do.
enum WorktreeProblem {
    /// The worktree path from "is already checked out at '…'" / "is already used by worktree at '…'".
    static func busyWorktreePath(_ message: String) -> String? {
        for marker in ["is already checked out at '", "is already used by worktree at '", "used by worktree at '"] {
            guard let r = message.range(of: marker) else { continue }
            let rest = message[r.upperBound...]
            guard let end = rest.firstIndex(of: "'") else { continue }
            return String(rest[..<end])
        }
        return nil
    }

    static func explain(_ message: String) -> String? {
        guard let path = busyWorktreePath(message) else { return nil }
        let name = (path as NSString).lastPathComponent
        return """
        That branch is checked out in the worktree “\(name)” (\(path)). Git lets a branch be checked out in only one worktree at a time.

        Work on it in that worktree (double-click it under Worktrees in the sidebar), or switch that worktree to another branch first.
        """
    }
}

extension Repository {
    /// This worktree's own entry.
    var currentWorktree: WorktreeInfo? { worktrees.first { samePath($0.path, root.path) } }

    /// Worktrees that can be opened (not the bare repository itself).
    var openableWorktrees: [WorktreeInfo] { worktrees.filter { !$0.isBare } }

    /// The other worktree that has `branch` checked out, if any.
    func worktreeUsing(branch: String) -> WorktreeInfo? {
        worktrees.first { $0.branch == branch && !samePath($0.path, root.path) }
    }

    /// What to check out in a new worktree for what the user typed or picked:
    /// a local branch, a remote branch (as a new local branch tracking it, or
    /// the existing local branch of that name), or else a new branch from `start`.
    func worktreeBranch(for text: String, start: String?) -> WorktreeBranch {
        if localBranch(named: text) != nil { return .existing(text) }
        if let remote = refs.first(where: { $0.kind == .remote && $0.name == text }), let local = remote.remoteBranch {
            return localBranch(named: local) != nil ? .existing(local) : .new(name: local, start: text, track: true)
        }
        // Not "HEAD": worktree commands run in the common git dir, where HEAD is the main worktree's.
        return .new(name: text, start: start ?? currentBranch ?? headHash?.hex ?? "HEAD", track: false)
    }

    /// The local branch name a new worktree for `text` would have.
    func worktreeBranchName(for text: String) -> String {
        switch worktreeBranch(for: text, start: nil) {
        case .existing(let b): return b
        case .new(let name, _, _): return name
        case .detached(let c): return String(c.prefix(8))
        }
    }

    func defaultWorktreePath(for branch: String) -> URL {
        let main: URL?
        if let first = worktrees.first {
            main = first.isBare ? nil : first.url
        } else if !isLinkedWorktree {
            main = root
        } else {
            // Not listed yet: a ".git" common dir belongs to a normal main worktree.
            main = commonDir.lastPathComponent == ".git" ? commonDir.deletingLastPathComponent() : nil
        }
        return WorktreeLocation.folder(for: branch, commonDir: commonDir, mainWorktree: main, repositoryName: repositoryName)
    }

    enum WorktreeBranch: Equatable {
        /// Check out an existing local branch.
        case existing(String)
        /// Create `name` starting at `start` (a commit or branch); `track` sets
        /// a remote branch start as its upstream.
        case new(name: String, start: String, track: Bool)
        /// Detached at a commit.
        case detached(String)
    }

    /// `git worktree add`. Worktree commands run in the common git directory,
    /// so they also work when this tab's own worktree is the one affected.
    @discardableResult
    func addWorktree(at path: URL, _ branch: WorktreeBranch) async -> RunResult {
        try? FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        var args = ["worktree", "add"]
        switch branch {
        case .existing(let b): args += [path.path, b]
        case .new(let name, let start, let track): args += [track ? "--track" : "--no-track", "-b", name, path.path, start]
        case .detached(let c): args += ["--detach", path.path, c]
        }
        return await perform("Add worktree", args, in: commonDir)
    }

    /// What removing a worktree would affect.
    struct WorktreeState {
        var changedFiles: [String] = []
        /// Commits on its branch that are on no remote branch and no other local branch.
        var unpushedCommits = 0
        /// Detached: commits at its HEAD that are on no branch (lost when it is removed).
        var detachedCommits = 0
        /// A merge, rebase, cherry-pick or revert in progress.
        var operation: String?
        var missing = false
        /// The folder exists but isn't that worktree (e.g. its .git file is gone).
        var invalid = false
    }

    /// True if git, run in `wt`'s folder, really finds that worktree (and not
    /// e.g. an enclosing repository).
    func isIntact(_ wt: WorktreeInfo) async -> Bool {
        let r = await Git(root: wt.url).run(["rev-parse", "--show-toplevel"])
        guard r.ok else { return false }
        let top = r.output.trimmingCharacters(in: .newlines)
        return samePath(top, wt.path) || samePath(top, URL(fileURLWithPath: wt.path).resolvingSymlinksInPath().path)
    }

    func worktreeState(_ wt: WorktreeInfo) async -> WorktreeState {
        var s = WorktreeState()
        guard FileManager.default.fileExists(atPath: wt.path) else { s.missing = true; return s }
        guard await isIntact(wt) else { s.invalid = true; return s }
        let wgit = Git(root: wt.url)
        let gitDirResult = await wgit.run(["rev-parse", "--absolute-git-dir"])
        if gitDirResult.ok {
            let gd = gitDirResult.output.trimmingCharacters(in: .newlines)
            let fm = FileManager.default
            for (file, what) in [("rebase-merge", "a rebase"), ("rebase-apply", "a rebase"), ("MERGE_HEAD", "a merge"),
                                 ("CHERRY_PICK_HEAD", "a cherry-pick"), ("REVERT_HEAD", "a revert")]
            where fm.fileExists(atPath: gd + "/" + file) {
                s.operation = what
                break
            }
        }
        if wt.branch == nil {
            let r = await wgit.run(["rev-list", "--count", "HEAD", "--not", "--branches", "--remotes", "--tags"])
            s.detachedCommits = Int(r.output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        }
        let status = await wgit.run(["status", "--porcelain", "-z", "--untracked-files=all"])
        var entries = status.stdout.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        // Renames are followed by their old path as a separate entry.
        var files: [String] = []
        while !entries.isEmpty {
            let e = entries.removeFirst()
            guard e.count > 3 else { continue }
            files.append(String(e.dropFirst(3)))
            if e.hasPrefix("R") || e.hasPrefix("C"), !entries.isEmpty { entries.removeFirst() }
        }
        s.changedFiles = files
        if let branch = wt.branch {
            let r = await git.run(["rev-list", "--count", "refs/heads/\(branch)", "--not", "--remotes",
                                   "--exclude=\(branch)", "--branches"])
            s.unpushedCommits = Int(r.output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        }
        return s
    }

    /// Stashes a worktree's changes, including untracked files. Stashes are
    /// shared by all worktrees, so they survive removing it.
    func stashChanges(in wt: WorktreeInfo, message: String) async -> Bool {
        guard await isIntact(wt) else { return false }
        let r = await perform("Stash changes of \(wt.name)", ["stash", "push", "--include-untracked", "-m", message], in: wt.url)
        return r.ok
    }

    /// Removes a worktree (its folder and git's record of it). `force` also
    /// discards uncommitted changes. A lock is lifted first (and restored if
    /// removing fails), so it never turns into discarding changes. A worktree
    /// whose folder is already gone is pruned instead.
    @discardableResult
    func removeWorktree(_ wt: WorktreeInfo, force: Bool) async -> Bool {
        if wt.isLocked {
            guard await perform("Unlock worktree", ["worktree", "unlock", wt.path], in: commonDir).ok else { return false }
        }
        let ok: Bool
        if !FileManager.default.fileExists(atPath: wt.path) {
            await perform("Prune worktrees", ["worktree", "prune"], in: commonDir)
            await refreshRefs()
            ok = !worktrees.contains { samePath($0.path, wt.path) }
        } else {
            ok = await perform("Remove worktree", ["worktree", "remove"] + (force ? ["--force"] : []) + [wt.path], in: commonDir).ok
        }
        if !ok && wt.isLocked {
            await perform("Lock worktree", ["worktree", "lock"] + (wt.lockReason.map { ["--reason", $0] } ?? []) + [wt.path],
                          reportErrors: false, in: commonDir)
        }
        return ok
    }

    @discardableResult
    func lockWorktree(_ wt: WorktreeInfo, reason: String?) async -> Bool {
        let r = reason.flatMap { $0.isEmpty ? nil : ["--reason", $0] } ?? []
        return await perform("Lock worktree", ["worktree", "lock"] + r + [wt.path], in: commonDir).ok
    }

    @discardableResult
    func unlockWorktree(_ wt: WorktreeInfo) async -> Bool {
        await perform("Unlock worktree", ["worktree", "unlock", wt.path], in: commonDir).ok
    }

    @discardableResult
    func moveWorktree(_ wt: WorktreeInfo, to path: URL) async -> Bool {
        try? FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        return await perform("Move worktree", ["worktree", "move", wt.path, path.path], in: commonDir).ok
    }

    /// `git worktree prune`: forgets worktrees whose folder was deleted.
    @discardableResult
    func pruneWorktrees() async -> Bool {
        await perform("Prune worktrees", ["worktree", "prune"], in: commonDir).ok
    }
}

/// Worktrees of a bare repository (which can't be opened as a tab itself).
enum BareRepositoryWorktrees {
    static func worktrees(of commonDir: URL) async -> [WorktreeInfo] {
        (await WorktreeInfo.list(in: commonDir) ?? []).filter { !$0.isBare }
    }

    /// Local branches, most recently committed first, and remote branches.
    static func branches(of commonDir: URL) async -> (local: [String], remote: [String]) {
        let r = await Git(root: commonDir).run(["for-each-ref", "--format=%(refname)", "--sort=-committerdate",
                                                "refs/heads", "refs/remotes"])
        var local: [String] = [], remote: [String] = []
        for line in r.output.split(separator: "\n") {
            if line.hasPrefix("refs/heads/") { local.append(String(line.dropFirst(11))) }
            else if line.hasPrefix("refs/remotes/"), !line.hasSuffix("/HEAD") { remote.append(String(line.dropFirst(13))) }
        }
        return (local, remote)
    }

    static func defaultFolder(_ commonDir: URL, branch: String) -> URL {
        WorktreeLocation.folder(for: branch, commonDir: commonDir, mainWorktree: nil,
                                repositoryName: WorktreeLocation.repositoryName(commonDir: commonDir))
    }

    /// Adds a worktree for a local branch, or for a remote branch (as a new
    /// local branch tracking it).
    static func addWorktree(_ commonDir: URL, path: URL, branch: String) async -> RunResult {
        try? FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let git = Git(root: commonDir)
        let isLocal = await git.run(["show-ref", "--verify", "--quiet", "refs/heads/\(branch)"]).ok
        if !isLocal, await git.run(["show-ref", "--verify", "--quiet", "refs/remotes/\(branch)"]).ok,
           let slash = branch.firstIndex(of: "/") {
            let local = String(branch[branch.index(after: slash)...])
            if await git.run(["show-ref", "--verify", "--quiet", "refs/heads/\(local)"]).ok {
                return await git.run(["worktree", "add", path.path, local])
            }
            return await git.run(["worktree", "add", "--track", "-b", local, path.path, branch])
        }
        if isLocal { return await git.run(["worktree", "add", path.path, branch]) }
        // A new branch from the repository's HEAD (its default branch).
        return await git.run(["worktree", "add", "-b", branch, path.path, "HEAD"])
    }

    /// The local branch name a worktree for `branch` (local or remote) gets.
    static func localName(_ branch: String, remoteBranches: Set<String>) -> String {
        guard remoteBranches.contains(branch), let slash = branch.firstIndex(of: "/") else { return branch }
        return String(branch[branch.index(after: slash)...])
    }
}
