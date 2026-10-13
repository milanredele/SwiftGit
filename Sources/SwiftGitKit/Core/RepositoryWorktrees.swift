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
    static func parse(_ data: Data) -> [WorktreeInfo] {
        var out: [WorktreeInfo] = []
        var current: WorktreeInfo?
        for field in data.split(separator: 0, omittingEmptySubsequences: false) {
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
        for marker in ["is already checked out at '", "is already used by worktree at '"] {
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

    func defaultWorktreePath(for branch: String) -> URL {
        let main = worktrees.first.flatMap { $0.isMain && !$0.isBare ? $0.url : nil }
            ?? (isLinkedWorktree ? nil : root)
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
        var missing = false
    }

    func worktreeState(_ wt: WorktreeInfo) async -> WorktreeState {
        var s = WorktreeState()
        guard FileManager.default.fileExists(atPath: wt.path) else { s.missing = true; return s }
        let status = await Git(root: wt.url).run(["status", "--porcelain", "-z", "--untracked-files=all"])
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
        let r = await perform("Stash changes of \(wt.name)", ["stash", "push", "--include-untracked", "-m", message], in: wt.url)
        return r.ok
    }

    /// Removes a worktree (its folder and git's record of it). `force` also
    /// removes one with changes, or a locked one. A worktree whose folder is
    /// already gone is pruned instead.
    @discardableResult
    func removeWorktree(_ wt: WorktreeInfo, force: Bool) async -> Bool {
        if !FileManager.default.fileExists(atPath: wt.path) {
            if wt.isLocked { await perform("Unlock worktree", ["worktree", "unlock", wt.path], in: commonDir) }
            await perform("Prune worktrees", ["worktree", "prune"], in: commonDir)
            await refreshRefs()
            return !worktrees.contains { samePath($0.path, wt.path) }
        }
        let forceArgs = force ? (wt.isLocked ? ["--force", "--force"] : ["--force"]) : []
        return await perform("Remove worktree", ["worktree", "remove"] + forceArgs + [wt.path], in: commonDir).ok
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
        let r = await Git(root: commonDir).run(["worktree", "list", "--porcelain", "-z"])
        return WorktreeInfo.parse(r.stdout).filter { !$0.isBare }
    }

    /// Local branches, most recently committed first, and remote branches.
    static func branches(of commonDir: URL) async -> [String] {
        let r = await Git(root: commonDir).run(["for-each-ref", "--format=%(refname:short)", "--sort=-committerdate",
                                                "refs/heads", "refs/remotes"])
        return r.output.split(separator: "\n").map(String.init).filter { !$0.hasSuffix("/HEAD") }
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
            return await git.run(["worktree", "add", "--track", "-b", local, path.path, branch])
        }
        return await git.run(["worktree", "add", path.path, branch])
    }
}
