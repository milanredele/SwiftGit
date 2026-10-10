import Foundation

enum RepoChange {
    case status
    case refs
    case graph
    case activity
    case summaries(Int)
    case pullRequests
}

@MainActor
protocol RepositoryObserver: AnyObject {
    func repository(_ repo: Repository, didChange change: RepoChange)
}

private struct WeakObserver {
    weak var value: RepositoryObserver?
}

/// The per-tab model. Everything here is compact; views are rebuilt from it.
@MainActor
final class Repository {
    let root: URL
    let gitDir: URL
    let git: Git
    var name: String { root.lastPathComponent }

    private(set) var status = WorkingStatus()
    private(set) var refs: [RefInfo] = []
    private(set) var stashes: [StashInfo] = []
    private(set) var remotes: [RemoteInfo] = []
    private(set) var opState: OperationState = .none
    private(set) var graph = CommitGraph()
    private(set) var decorations: [Hash20: [RefInfo]] = [:]
    private(set) var headHash: Hash20?
    private let summaries = SummaryCache()

    private(set) var activityTitle: String?
    private(set) var activityDetail = ""
    private var activityToken: CancelToken?
    private var lastActivityNotify = Date.distantPast

    /// Called with (title, message) when an operation fails.
    var onError: ((String, String) -> Void)?

    private var observers: [WeakObserver] = []
    private var watcher: RepoWatcher?
    private var refreshTask: Task<Void, Never>?
    private var pendingStatus = false
    private var pendingRefs = false
    private var statusGeneration = 0
    private var refsGeneration = 0
    private var refsSignature = ""
    private var graphLoading = false
    /// "branchTip|mainTip" → content already in main (squash / rebase merge).
    private var contentMergeCache: [String: Bool] = [:]
    private var contentMergeTask: Task<Void, Never>?
    private var contentQueue: [(key: String, ref: RefInfo, base: String, baseTarget: String)] = []
    private var patchIDCache: (target: String, ids: Set<String>)?
    /// Main branch used for merge checks: (name, tip, local name).
    private var mergeBaseInfo: (name: String, target: String, local: String?)?
    private var graphReloadAgain = false
    /// Undo history of operations done in this tab (see RepositoryUndo.swift).
    var undoStack: [UndoEntry] = []
    var pendingUndo: UndoEntry?
    /// Quiet fetch started when the tab gets focus (user operations wait for it).
    private var backgroundFetchTask: Task<Void, Never>?
    private var lastBackgroundFetch = Date.distantPast
    private(set) var lastBackgroundFetchError: String?
    /// Open pull requests by head branch name (GitHub remotes only).
    private(set) var pullRequests: [String: PullRequestBadge] = [:]
    private var pullRequestTask: Task<Void, Never>?
    private var lastPullRequestLoad = Date.distantPast

    /// Most recently updated first; merged / upstream-deleted branches last.
    var localBranches: [RefInfo] {
        refs.filter { $0.kind == .local }.sorted { a, b in
            if a.isStale != b.isStale { return !a.isStale }
            if a.date != b.date { return a.date > b.date }
            return a.name < b.name
        }
    }
    var remoteBranches: [RefInfo] { refs.filter { $0.kind == .remote }.sorted(by: Repository.newestFirst) }
    var tags: [RefInfo] { refs.filter { $0.kind == .tag }.sorted(by: Repository.newestFirst) }
    /// The branch others are merged into, e.g. "origin/main" or "main".
    private(set) var mainBranch: String?

    private static func newestFirst(_ a: RefInfo, _ b: RefInfo) -> Bool {
        a.date != b.date ? a.date > b.date : a.name < b.name
    }
    var currentBranch: String? { status.branch }
    var isBusy: Bool { activityTitle != nil }

    private init(root: URL, gitDir: URL) {
        self.root = root
        self.gitDir = gitDir
        self.git = Git(root: root)
    }

    /// Validates that `url` is inside a git work tree and opens its top level.
    static func open(_ url: URL) async throws -> Repository {
        let r = await ProcessRunner.run(executable: Git.executable,
                                        arguments: ["rev-parse", "--show-toplevel", "--absolute-git-dir"],
                                        cwd: url)
        let lines = r.output.split(separator: "\n").map(String.init)
        guard r.ok, lines.count >= 2 else {
            throw GitHubError(message: "“\(url.lastPathComponent)” is not a git repository.\n\n\(r.errorMessage)")
        }
        let root = URL(fileURLWithPath: lines[0]).resolvingSymlinksInPath()
        let gitDir = URL(fileURLWithPath: lines[1]).resolvingSymlinksInPath()
        return Repository(root: root, gitDir: gitDir)
    }

    func start() {
        Task { await expireDiscarded() }
        var paths = [root.path]
        if !gitDir.path.hasPrefix(root.path + "/") { paths.append(gitDir.path) }
        watcher = RepoWatcher(paths: paths) { [weak self] events in
            self?.handleFileEvents(events)
        }
        Task {
            await refreshAll()
            loadPullRequests()
        }
    }

    func stop() {
        watcher?.stop()
        watcher = nil
        refreshTask?.cancel()
        activityToken?.cancel()
    }

    // MARK: Observers

    func addObserver(_ o: RepositoryObserver) {
        observers.removeAll { $0.value == nil }
        observers.append(WeakObserver(value: o))
    }

    func removeObserver(_ o: RepositoryObserver) {
        observers.removeAll { $0.value == nil || $0.value === o }
    }

    private func notify(_ change: RepoChange) {
        for o in observers { o.value?.repository(self, didChange: change) }
    }

    // MARK: Refresh

    private func handleFileEvents(_ paths: [String]) {
        let gd = gitDir.path
        for p in paths {
            guard p.hasPrefix(gd) else { pendingStatus = true; continue }
            let rel = p.dropFirst(gd.count)
            if rel.hasPrefix("/objects") || rel.hasPrefix("/logs") || rel.hasPrefix("/lfs") { continue }
            // Index writes (e.g. an IDE running git status) only affect status.
            if rel.hasPrefix("/index") || rel == "/" || rel.isEmpty {
                pendingStatus = true
                continue
            }
            pendingRefs = true
            pendingStatus = true
        }
        guard pendingRefs || pendingStatus else { return }
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled, let self else { return }
            let refs = self.pendingRefs, status = self.pendingStatus
            self.pendingRefs = false
            self.pendingStatus = false
            if status { await self.refreshStatus() }
            if refs { await self.refreshRefs() }
        }
    }

    func refreshAll() async {
        await refreshStatus()
        await refreshRefs()
    }

    func refreshStatus() async {
        statusGeneration += 1
        let gen = statusGeneration
        let r = await git.run(["status", "--porcelain=v2", "-z", "--branch"])
        guard gen == statusGeneration, r.ok else { return }
        status = WorkingStatus.parse(r.stdout)
        headHash = status.headOID.flatMap { Hash20($0) }
        opState = detectOperationState()
        notify(.status)
    }

    func refreshRefs() async {
        refsGeneration += 1
        let gen = refsGeneration
        async let refsResult = git.run(["for-each-ref", "--format=" + RefInfo.format, "refs/heads", "refs/remotes", "refs/tags"])
        async let stashResult = git.run(["stash", "list", "--format=%gd%x09%H%x09%s"])
        async let remoteResult = git.run(["remote", "-v"])
        let (r1, r2, r3) = await (refsResult, stashResult, remoteResult)
        guard gen == refsGeneration else { return }
        var newRefs = r1.ok ? RefInfo.parse(r1.output) : []
        stashes = r2.ok ? StashInfo.parse(r2.output) : []
        remotes = r3.ok ? RemoteInfo.parse(r3.output) : []

        // Which local branches are already merged into the main branch?
        let remoteHeads = r1.ok ? RefInfo.parseRemoteHeads(r1.output) : [:]
        let preferred = remotes.contains { $0.name == "origin" } ? "origin" : remotes.first?.name
        var base = preferred.flatMap { remoteHeads[$0] }
        if base == nil, let preferred {
            // No origin/HEAD (e.g. remote added by hand): the remote's main is
            // more up to date than a local main that may not have been pulled.
            base = ["main", "master", "develop", "trunk"].map { "\(preferred)/\($0)" }.first { name in
                newRefs.contains { $0.kind == .remote && $0.name == name }
            }
        }
        if base == nil {
            base = ["main", "master", "develop", "trunk"].first { name in
                newRefs.contains { $0.kind == .local && $0.name == name }
            }
        }
        mainBranch = base
        if let base, let baseRef = newRefs.first(where: { $0.name == base && $0.kind != .tag }) {
            let merged = await git.run(["for-each-ref", "--merged=\(base)", "--format=%(refname)", "refs/heads"])
            guard gen == refsGeneration else { return }
            let mergedNames = Set(merged.output.split(separator: "\n").map(String.init))
            let baseLocal = baseRef.kind == .remote ? baseRef.remoteBranch : baseRef.name
            mergeBaseInfo = (base, baseRef.target, baseLocal)
            for i in newRefs.indices where newRefs[i].kind == .local {
                let r = newRefs[i]
                // A branch pointing exactly at main (e.g. just created) is not "done".
                guard r.name != baseLocal, r.target != baseRef.target else { continue }
                if mergedNames.contains(r.fullName) {
                    newRefs[i].isMerged = true
                } else if let hit = contentMergeCache[r.target + "|" + baseRef.target] {
                    // Squash/rebase checks run lazily (checkMergeStatus); reuse earlier results.
                    newRefs[i].isMerged = hit
                    newRefs[i].mergedByContent = hit
                }
            }
        } else {
            mergeBaseInfo = nil
        }
        refs = newRefs

        var deco: [Hash20: [RefInfo]] = [:]
        for ref in refs {
            guard let h = Hash20(ref.target) else { continue }
            deco[h, default: []].append(ref)
        }
        if status.branch == nil, let oid = status.headOID, let h = Hash20(oid) {
            deco[h, default: []].insert(RefInfo(fullName: "HEAD", name: "HEAD", kind: .local, target: oid, isHead: true), at: 0)
        }
        decorations = deco
        notify(.refs)

        let signature = (status.headOID ?? "") + "|" + refs.map { $0.fullName + "=" + $0.target }.joined(separator: ",")
        if signature != refsSignature {
            refsSignature = signature
            await reloadGraph()
        }
    }

    /// Checks (lazily) whether these branches were squash- or rebase-merged.
    /// Called for branches visible in the history, selected, or about to be
    /// deleted, so big repos never scan every branch.
    func checkMergeStatus(_ candidates: [RefInfo]) {
        guard let base = mergeBaseInfo else { return }
        let todo = candidates.filter { r in
            r.kind == .local && !r.isHead && !r.isMerged && r.name != base.local && r.target != base.target
                && contentMergeCache[r.target + "|" + base.target] == nil
        }
        if !todo.isEmpty { detectContentMerges(todo, base: base.name, baseTarget: base.target) }
    }

    /// Runs the checks in the background, one branch at a time. A running
    /// check is never cancelled by refreshes; new branches are queued.
    private func detectContentMerges(_ branches: [RefInfo], base: String, baseTarget: String) {
        for b in branches {
            let key = b.target + "|" + baseTarget
            guard contentMergeCache[key] == nil, !contentQueue.contains(where: { $0.key == key }) else { continue }
            contentQueue.append((key: key, ref: b, base: base, baseTarget: baseTarget))
        }
        guard contentMergeTask == nil, !contentQueue.isEmpty else { return }
        contentMergeTask = Task { [weak self] in
            while let self, !self.contentQueue.isEmpty {
                let item = self.contentQueue.removeFirst()
                let report = await self.contentCheck(item.ref.target, base: item.base, baseTarget: item.baseTarget)
                self.recordContentMerge(item.ref, baseTarget: item.baseTarget, merged: report.merged)
            }
            self?.contentMergeTask = nil
        }
    }

    private func recordContentMerge(_ ref: RefInfo, baseTarget: String, merged: Bool) {
        contentMergeCache[ref.target + "|" + baseTarget] = merged
        guard merged else { return }
        var changed = false
        for i in refs.indices where refs[i].fullName == ref.fullName && refs[i].target == ref.target && !refs[i].isMerged {
            refs[i].isMerged = true
            refs[i].mergedByContent = true
            changed = true
        }
        if changed { notify(.refs) }
    }

    struct MergeReport {
        var merged = false
        var steps: [String] = []
    }

    /// Runs all checks now (no cache) and explains each step. Used by the
    /// delete dialog and "Check Merge Status…".
    func mergeReport(for ref: RefInfo) async -> MergeReport {
        guard let base = mergeBaseInfo else {
            return MergeReport(merged: false, steps: ["No main branch found (no origin/HEAD, origin/main or main)."])
        }
        var report = MergeReport()
        report.steps.append("Main branch: \(base.name) (\(base.target.prefix(8)))")
        if ref.target == base.target {
            report.steps.append("Points at the same commit as \(base.name).")
            return report
        }
        let ancestor = await git.run(["merge-base", "--is-ancestor", ref.fullName, base.name])
        if ancestor.status == 0 {
            report.merged = true
            report.steps.append("✓ All its commits are in \(base.name) (normal merge or fast-forward).")
            return report
        }
        report.steps.append("✗ Not an ancestor of \(base.name) (no normal merge).")
        let content = await contentCheck(ref.target, base: base.name, baseTarget: base.target, explain: true)
        report.steps += content.steps
        report.merged = content.merged
        if ref.kind == .local { recordContentMerge(ref, baseTarget: base.target, merged: content.merged) }
        return report
    }

    /// Is everything on `tip` already contained in `base`?
    ///  1. `git cherry`: every commit has an equivalent patch in base (rebase merge).
    ///  2. `git merge-tree`: merging tip into base would not change base's tree
    ///     (squash merge, also when base changed nearby or later).
    ///  3. patch-id of the whole branch diff (zero context) equals one recent
    ///     commit on base (squash merge where base later edited the same lines).
    private func contentCheck(_ tip: String, base: String, baseTarget: String, explain: Bool = false) async -> MergeReport {
        var r = MergeReport()
        func note(_ s: String) { if explain { r.steps.append(s) } }

        let cherry = await git.run(["cherry", base, tip])
        guard cherry.ok else { note("git cherry failed: \(cherry.errorMessage)"); return r }
        let lines = cherry.output.split(separator: "\n")
        let equivalent = lines.filter { $0.hasPrefix("-") }.count
        note("Commits with an equivalent change in \(base): \(equivalent) of \(lines.count).")
        if !lines.isEmpty && equivalent == lines.count {
            r.merged = true
            note("✓ Rebase- or squash-merged: every commit has an equivalent change in \(base).")
            return r
        }

        let mb = await git.run(["merge-base", base, tip])
        let mergeBase = mb.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard mb.ok, !mergeBase.isEmpty else { note("No common ancestor with \(base)."); return r }
        let stat = await git.run(["diff", "--shortstat", "--no-ext-diff", mergeBase, tip])
        let own = stat.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !own.isEmpty else { note("The branch has no changes of its own since \(mergeBase.prefix(8))."); return r }
        note("Branch changes since it split off (\(mergeBase.prefix(8))): \(own).")

        let merge = await git.run(["merge-tree", "--write-tree", "--no-messages", base, tip])
        let mergedTree = merge.output.split(separator: "\n").first.map(String.init) ?? ""
        if merge.ok && !mergedTree.isEmpty {
            let baseTree = await git.run(["rev-parse", "\(base)^{tree}"]).output.trimmingCharacters(in: .whitespacesAndNewlines)
            if mergedTree == baseTree {
                r.merged = true
                note("✓ Squash-merged: merging it into \(base) now would change nothing.")
                return r
            }
            if explain {
                let changed = await git.run(["diff", "--name-only", "--no-ext-diff", baseTree, mergedTree])
                let files = changed.output.split(separator: "\n")
                note("✗ Merging it now would still change \(files.count) file\(files.count == 1 ? "" : "s"): "
                     + files.prefix(5).joined(separator: ", ") + (files.count > 5 ? ", …" : ""))
            }
        } else if merge.status == 1 {
            note("✗ Merging it now would conflict with \(base).")
        } else {
            note("merge-tree unavailable: \(merge.errorMessage)")
        }

        // Pipe inside sh so large diffs never pass through this process.
        let branchPatch = await ProcessRunner.run(
            executable: "/bin/sh",
            arguments: ["-c", "git diff -U0 --no-color --no-ext-diff \"$1\" \"$2\" | git patch-id --stable", "sh", mergeBase, tip],
            cwd: root)
        guard let branchID = branchPatch.output.split(separator: " ").first.map(String.init), !branchID.isEmpty else {
            note("Could not compute the branch's patch-id.")
            return r
        }
        if await recentPatchIDs(base: base, baseTarget: baseTarget).contains(branchID) {
            r.merged = true
            note("✓ Squash-merged: one commit in \(base) has exactly the branch's changes.")
        } else {
            note("✗ No single commit among the last 1000 in \(base) has exactly the branch's changes.")
        }
        return r
    }

    /// Patch-ids (zero context) of the last 1000 non-merge commits on base,
    /// computed once per base tip.
    private func recentPatchIDs(base: String, baseTarget: String) async -> Set<String> {
        if let cached = patchIDCache, cached.target == baseTarget { return cached.ids }
        let r = await ProcessRunner.run(
            executable: "/bin/sh",
            arguments: ["-c", "git log -p -U0 --no-merges --no-color --no-ext-diff -n 1000 \"$1\" | git patch-id --stable", "sh", base],
            cwd: root)
        let ids = Set(r.output.split(separator: "\n").compactMap { $0.split(separator: " ").first.map(String.init) })
        patchIDCache = (baseTarget, ids)
        return ids
    }

    struct BranchDeletionInfo {
        var ref: RefInfo
        /// Commits reachable only from this branch (not from any other branch,
        /// remote branch or tag): these are what deleting it would drop.
        var uniqueCommits: Int
        var lastSubject: String
        var lastDate: Date?
        var mainBranch: String?
        /// For remote branches: the local branch tracking it, if any.
        var trackingLocal: String?
    }

    func deletionInfo(for ref: RefInfo) async -> BranchDeletionInfo {
        // --exclude takes the short name and only applies to the next --branches/--remotes.
        let others: [String] = ref.kind == .remote
            ? ["--branches", "--tags", "--exclude=\(ref.name)", "--remotes"]
            : ["--remotes", "--tags", "--exclude=\(ref.name)", "--branches"]
        async let unique = git.run(["rev-list", "--count", ref.fullName, "--not"] + others)
        async let last = git.run(["log", "-1", "--format=%s%x00%ct", ref.fullName])
        let (u, l) = await (unique, last)
        let parts = l.output.trimmingCharacters(in: .newlines).split(separator: "\0", omittingEmptySubsequences: false)
        let tracking = ref.kind == .remote ? refs.first { $0.kind == .local && $0.upstream == ref.name }?.name : nil
        return BranchDeletionInfo(
            ref: ref,
            uniqueCommits: Int(u.output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0,
            lastSubject: parts.first.map(String.init) ?? "",
            lastDate: parts.count > 1 ? Double(parts[1]).map { Date(timeIntervalSince1970: $0) } : nil,
            mainBranch: mainBranch,
            trackingLocal: tracking)
    }

    static let topoOrderKey = "history.topoOrder"

    func reloadGraph() async {
        if graphLoading { graphReloadAgain = true; return }
        graphLoading = true
        defer { graphLoading = false }
        repeat {
            graphReloadAgain = false
            // Date order by default (children still always above parents);
            // topological order groups each branch's commits together.
            let order = UserDefaults.standard.bool(forKey: Repository.topoOrderKey) ? "--topo-order" : "--date-order"
            let args = ["log"] + graphRevisions + [order, "--format=%H %P"]
            let builder = GraphBuilder()
            let r = await git.run(args, onStdout: { data in builder.feed(data) })
            let newGraph: CommitGraph = await Task.detached { builder.finish() }.value
            if r.ok || newGraph.count > 0 || refs.isEmpty {
                graph = newGraph
                summaries.clear()
                notify(.graph)
            }
        } while graphReloadAgain
    }

    /// The commits the history shows: all branches, remote branches, tags and HEAD.
    var graphRevisions: [String] {
        ["--branches", "--remotes", "--tags"] + (status.headOID != nil ? ["HEAD"] : [])
    }

    /// What a history search looks for.
    enum HistoryQuery: Equatable {
        /// Message or author text (case-insensitive), or a commit hash prefix.
        case text(String)
        /// Commits that changed this path (following renames).
        case file(String)

        static let filePrefix = "file:"

        init?(_ input: String) {
            let s = input.trimmingCharacters(in: .whitespaces)
            if s.lowercased().hasPrefix(HistoryQuery.filePrefix) {
                let path = s.dropFirst(HistoryQuery.filePrefix.count).trimmingCharacters(in: .whitespaces)
                guard !path.isEmpty else { return nil }
                self = .file(path)
            } else {
                guard !s.isEmpty else { return nil }
                self = .text(s)
            }
        }

        var filePath: String? { if case .file(let p) = self { return p } else { return nil } }
    }

    /// Commits of the history that match `query`.
    func searchHistory(_ query: HistoryQuery) async -> Set<Hash20> {
        var result = Set<Hash20>()
        func collect(_ r: RunResult) {
            guard r.ok else { return }
            for line in r.output.split(separator: "\n") {
                if let h = Hash20(String(line)) { result.insert(h) }
            }
        }
        switch query {
        case .text(let text):
            async let messages = git.run(["log"] + graphRevisions + ["--format=%H", "-i", "-F", "--grep=\(text)"])
            async let authors = git.run(["log"] + graphRevisions + ["--format=%H", "-i", "-F", "--author=\(text)"])
            let (m, a) = await (messages, authors)
            collect(m)
            collect(a)
            let lower = text.lowercased()
            if lower.count >= 4, lower.count <= 40, lower.allSatisfy({ $0.isHexDigit }) {
                for h in graph.hashes where h.hex.hasPrefix(lower) { result.insert(h) }
            }
        case .file(let path):
            // --follow tracks renames but only works for a single file, not a directory.
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path, isDirectory: &isDir)
            let follow = !(exists && isDir.boolValue) && !path.hasSuffix("/")
            collect(await git.run(["log"] + graphRevisions + ["--format=%H"] + (follow ? ["--follow"] : []) + ["--", path]))
        }
        return result
    }

    private func detectOperationState() -> OperationState {
        let fm = FileManager.default
        func has(_ name: String) -> Bool { fm.fileExists(atPath: gitDir.appendingPathComponent(name).path) }
        if has("rebase-merge") || has("rebase-apply") { return .rebasing }
        if has("MERGE_HEAD") { return .merging }
        if has("CHERRY_PICK_HEAD") { return .cherryPicking }
        if has("REVERT_HEAD") { return .reverting }
        return .none
    }

    // MARK: History rows

    func summary(row: Int) -> CommitSummary? {
        if let s = summaries.summary(row: row) { return s }
        let block = row / SummaryCache.blockSize
        if summaries.needsLoad(block: block) { loadSummaries(block: block) }
        return nil
    }

    private func loadSummaries(block: Int) {
        let size = SummaryCache.blockSize
        let start = block * size
        let end = min(graph.count, start + size)
        guard start < end else { return }
        summaries.markPending(block)
        let g = graph
        let hexes = (start..<end).map { g.hashes[$0].hex }
        Task { [weak self] in
            guard let self else { return }
            let input = Data((hexes.joined(separator: "\n") + "\n").utf8)
            let r = await self.git.run(["log", "--no-walk=unsorted", "--stdin", "--format=%H%x1f%an%x1f%at%x1f%s%x1e"], stdin: input)
            guard g === self.graph else { return }
            var map: [String: CommitSummary] = [:]
            for rec in r.stdout.split(separator: 0x1e) {
                let f = rec.split(separator: 0x1f, omittingEmptySubsequences: false)
                    .map { String(decoding: $0, as: UTF8.self) }
                guard f.count == 4 else { continue }
                let h = f[0].trimmingCharacters(in: .whitespacesAndNewlines)
                map[String(h.prefix(40))] = CommitSummary(subject: f[3], author: f[1], time: Int64(f[2]) ?? 0)
            }
            let items = hexes.map { map[$0] ?? CommitSummary(subject: "", author: "", time: 0) }
            self.summaries.store(block: block, items)
            self.notify(.summaries(block))
        }
    }

    /// Frees caches that can be rebuilt (used when the tab goes to the background).
    func dropCaches() {
        summaries.clear()
    }

    // MARK: Operations

    @discardableResult
    func perform(_ title: String, _ args: [String], stdin: Data? = nil, environment: [String: String] = [:],
                 reportErrors: Bool = true) async -> RunResult {
        // Don't race a quiet background fetch for git's locks.
        if let fetch = backgroundFetchTask { await fetch.value }
        if let busy = activityTitle {
            onError?(title, "Please wait until “\(busy)” has finished.")
            return RunResult(status: -2, stdout: Data(), stderr: "busy")
        }
        let token = CancelToken()
        activityToken = token
        activityTitle = title
        activityDetail = ""
        notify(.activity)
        let r = await git.run(args, stdin: stdin, environment: environment, cancel: token, onStderrLine: { [weak self] line in
            Task { @MainActor in self?.setActivityDetail(line) }
        })
        activityToken = nil
        activityTitle = nil
        notify(.activity)
        let stateBefore = opState, headBefore = status.headOID
        await refreshStatus()
        await refreshRefs()
        // A merge/rebase/cherry-pick that (newly) stopped for conflicts is not an error:
        // the banner and the conflicted files explain what to do next.
        let stoppedForConflicts = opState != .none && (stateBefore == .none || status.headOID != headBefore)
        if !r.ok && reportErrors && !token.isCancelled && !stoppedForConflicts { onError?(title, r.errorMessage) }
        return r
    }

    private func setActivityDetail(_ line: String) {
        guard activityTitle != nil else { return }
        activityDetail = line
        let now = Date()
        if now.timeIntervalSince(lastActivityNotify) > 0.08 {
            lastActivityNotify = now
            notify(.activity)
        }
    }

    func cancelActivity() { activityToken?.cancel() }

    var preferredRemote: String? {
        if remotes.contains(where: { $0.name == "origin" }) { return "origin" }
        return remotes.first?.name
    }

    /// The GitHub repository behind the preferred remote (or the first GitHub remote).
    var gitHubRemote: (repo: GitHubRepo, remote: String)? {
        let preferred = preferredRemote
        let ordered = remotes.filter { $0.name == preferred } + remotes.filter { $0.name != preferred }
        for r in ordered {
            if let gh = GitHubRepo.parse(remoteURL: r.url) { return (gh, r.name) }
        }
        return nil
    }

    func localBranch(named name: String) -> RefInfo? { refs.first { $0.kind == .local && $0.name == name } }

    func checkout(branch: String) async {
        await recordingUndo(.checkout, "Checkout \(branch)") {
            await perform("Checkout \(branch)", ["switch", branch])
        }
    }

    func checkout(remote ref: RefInfo) async {
        guard let local = ref.remoteBranch else { return }
        if localBranch(named: local) != nil {
            await checkout(branch: local)
        } else {
            let before = await headState()
            let r = await perform("Checkout \(ref.name)", ["switch", "--track", ref.name])
            if r.ok, let sha = await headState().sha {
                undoStack.append(UndoEntry(kind: .createBranch(local, sha), title: "Checkout \(ref.name)",
                                           before: before, after: HeadState(branch: local, sha: sha)))
            }
        }
    }

    func checkoutDetached(_ target: String) async {
        await recordingUndo(.checkout, "Checkout \(String(target.prefix(8)))") {
            await perform("Checkout \(target)", ["switch", "--detach", target])
        }
    }

    func createBranch(_ name: String, from start: String?, checkout: Bool) async {
        let before = await headState()
        let r: RunResult
        if checkout {
            r = await perform("Create branch \(name)", ["switch", "-c", name] + (start.map { [$0] } ?? []))
        } else {
            r = await perform("Create branch \(name)", ["branch", name] + (start.map { [$0] } ?? []))
        }
        guard r.ok else { return }
        let target = await git.run(["rev-parse", "-q", "--verify", "refs/heads/\(name)"]).output
            .trimmingCharacters(in: .whitespacesAndNewlines)
        undoStack.append(UndoEntry(kind: .createBranch(name, target), title: "Create Branch \(name)",
                                   before: before, after: await headState()))
    }

    func renameBranch(_ old: String, to new: String) async {
        let before = await headState()
        if await perform("Rename \(old)", ["branch", "-m", old, new]).ok {
            undoStack.append(UndoEntry(kind: .renameBranch(old, new), title: "Rename \(old) to \(new)",
                                       before: before, after: await headState()))
        }
    }

    @discardableResult
    func deleteBranch(_ name: String, force: Bool) async -> RunResult {
        let sha = localBranch(named: name)?.target
        let before = await headState()
        let r = await perform("Delete \(name)", ["branch", force ? "-D" : "-d", name], reportErrors: force)
        if r.ok, let sha {
            undoStack.append(UndoEntry(kind: .deleteBranch(name, sha), title: "Delete Branch \(name)", before: before, after: before))
        }
        return r
    }

    func deleteRemoteBranch(_ ref: RefInfo) async {
        guard let remote = ref.remoteName, let branch = ref.remoteBranch else { return }
        await perform("Delete \(ref.name)", ["push", "--progress", remote, "--delete", branch])
    }

    func createTag(_ name: String, at target: String) async {
        await perform("Create tag \(name)", ["tag", name, target])
    }

    func merge(_ ref: String) async {
        await recordingUndo(.moveHead, "Merge \(ref)") { await perform("Merge \(ref)", ["merge", "--no-edit", ref]) }
    }

    func rebase(onto ref: String) async {
        await recordingUndo(.moveHead, "Rebase onto \(ref)") { await perform("Rebase onto \(ref)", ["rebase", ref]) }
    }

    func cherryPick(_ hash: String) async {
        await recordingUndo(.moveHead, "Cherry-pick \(String(hash.prefix(8)))") { await perform("Cherry-pick", ["cherry-pick", hash]) }
    }

    func revert(_ hash: String) async {
        await recordingUndo(.moveHead, "Revert \(String(hash.prefix(8)))") { await perform("Revert", ["revert", "--no-edit", hash]) }
    }

    func reset(to hash: String, mode: String) async {
        if mode == "hard", status.changeCount > 0 {
            _ = await saveDiscarded(paths: nil, summary: "Reset (hard) to \(String(hash.prefix(8)))")
        }
        await recordingUndo(.moveHead, "Reset (\(mode)) to \(String(hash.prefix(8)))") {
            await perform("Reset (\(mode))", ["reset", "--\(mode)", hash])
        }
    }

    func continueOperation() async {
        switch opState {
        case .rebasing: await perform("Continue rebase", ["rebase", "--continue"])
        case .merging: await perform("Commit merge", ["commit", "--no-edit"])
        case .cherryPicking: await perform("Continue cherry-pick", ["cherry-pick", "--continue"])
        case .reverting: await perform("Continue revert", ["revert", "--continue"])
        case .none: break
        }
        await finishPendingUndo(aborted: false)
    }

    func abortOperation() async {
        switch opState {
        case .rebasing: await perform("Abort rebase", ["rebase", "--abort"])
        case .merging: await perform("Abort merge", ["merge", "--abort"])
        case .cherryPicking: await perform("Abort cherry-pick", ["cherry-pick", "--abort"])
        case .reverting: await perform("Abort revert", ["revert", "--abort"])
        case .none: break
        }
        if opState == .none { await finishPendingUndo(aborted: true) }
    }

    func skipRebaseStep() async {
        await perform("Skip commit", ["rebase", "--skip"])
        await finishPendingUndo(aborted: false)
    }

    func fetch() async {
        await perform("Fetch", ["fetch", "--all", "--prune", "--progress"])
    }

    /// Fetches all remotes quietly (no activity bar, no error dialogs), at most
    /// once per `minInterval`. Used when the tab gets focus.
    func fetchInBackground(minInterval: TimeInterval = Settings.focusFetchInterval) {
        guard !remotes.isEmpty, backgroundFetchTask == nil, !isBusy, opState == .none,
              Date().timeIntervalSince(lastBackgroundFetch) >= minInterval else { return }
        lastBackgroundFetch = Date()
        backgroundFetchTask = Task {
            let r = await git.run(["fetch", "--all", "--prune", "--quiet"])
            lastBackgroundFetchError = r.ok ? nil : r.errorMessage
            backgroundFetchTask = nil
            await refreshRefs()
        }
    }

    var isFetchingInBackground: Bool { backgroundFetchTask != nil }

    /// Reloads the open pull requests (one gh call), at most once per `minInterval`.
    func loadPullRequests(minInterval: TimeInterval = Settings.focusFetchInterval) {
        guard pullRequestTask == nil, GitHub.executable != nil, let gh = gitHubRemote?.repo,
              Date().timeIntervalSince(lastPullRequestLoad) >= minInterval else { return }
        lastPullRequestLoad = Date()
        pullRequestTask = Task {
            let badges = try? await GitHub.openPullRequestBadges(gh)
            pullRequestTask = nil
            guard let badges, badges != pullRequests else { return }
            pullRequests = badges
            notify(.pullRequests)
        }
    }

    var isLoadingPullRequests: Bool { pullRequestTask != nil }

    func testSetPullRequests(_ badges: [String: PullRequestBadge]) {
        pullRequests = badges
        notify(.pullRequests)
    }

    func pull(rebase: Bool? = nil) async {
        let mode: PullMode = rebase == true ? .rebase : rebase == false ? .merge : Settings.pullMode
        _ = await pullResult(mode: mode, autostash: Settings.autostash, reportErrors: true)
    }

    /// Pulls with `mode`; `autostash` stashes local changes first and re-applies them.
    func pullResult(mode: PullMode, autostash: Bool, reportErrors: Bool) async -> RunResult {
        var args = ["pull", "--progress"] + mode.arguments
        if autostash { args.append("--autostash") }
        return await recordingUndo(.moveHead, "Pull") { await perform("Pull", args, reportErrors: reportErrors) }
    }

    /// Pushes `branch` (default: current). Sets the upstream when there is none.
    @discardableResult
    func push(branch: String? = nil, force: Bool = false) async -> Bool {
        await pushResult(branch: branch, force: force, reportErrors: true).ok
    }

    /// Like `push`, but returns the git result; with `reportErrors: false` the
    /// caller explains failures (see `PushProblem`).
    func pushResult(branch: String? = nil, force: Bool = false, reportErrors: Bool) async -> RunResult {
        guard let name = branch ?? status.branch else {
            onError?("Push", "HEAD is detached. Check out a branch first.")
            return RunResult(status: -2, stdout: Data(), stderr: "detached")
        }
        let upstream = name == status.branch ? status.upstream : localBranch(named: name)?.upstream
        var args = ["push", "--progress"]
        if force { args.append("--force-with-lease") }
        if upstream == nil {
            guard let remote = preferredRemote else {
                onError?("Push", "This repository has no remote.")
                return RunResult(status: -2, stdout: Data(), stderr: "no remote")
            }
            args += ["--set-upstream", remote, name]
        } else if name != status.branch {
            let parts = upstream!.split(separator: "/", maxSplits: 1).map(String.init)
            if parts.count == 2 { args += [parts[0], "\(name):\(parts[1])"] }
        }
        return await perform(force ? "Force push \(name)" : "Push \(name)", args, reportErrors: reportErrors)
    }

    /// Pushes `branch` to the branch of the same name on `remote` (what a pull
    /// request needs, whatever upstream is configured). Sets the upstream if
    /// there is none. `force` uses --force-with-lease against remote/branch.
    func pushForPullRequest(branch: String, remote: String, force: Bool) async -> RunResult {
        var args = ["push", "--progress"]
        if force { args.append("--force-with-lease=refs/heads/\(branch)") }
        if localBranch(named: branch)?.upstream == nil { args.append("--set-upstream") }
        args += [remote, "refs/heads/\(branch):refs/heads/\(branch)"]
        return await perform(force ? "Force push \(branch)" : "Push \(branch)", args, reportErrors: false)
    }

    /// Commits only in `local` / only in `remoteRef` (nil if either can't be resolved).
    func divergence(local: String, remoteRef: String) async -> (ahead: Int, behind: Int)? {
        let r = await git.run(["rev-list", "--left-right", "--count", "refs/heads/\(local)...\(remoteRef)", "--"])
        guard r.ok else { return nil }
        let n = r.output.split(whereSeparator: { $0 == "\t" || $0 == " " || $0 == "\n" }).compactMap { Int($0) }
        return n.count == 2 ? (n[0], n[1]) : nil
    }

    /// Fetches one branch from `remote` quietly (updates refs/remotes/remote/branch).
    func fetchBranch(_ branch: String, remote: String) async -> Bool {
        let r = await git.run(["fetch", "--quiet", remote, "+refs/heads/\(branch):refs/remotes/\(remote)/\(branch)"])
        await refreshRefs()
        return r.ok
    }

    func stash() async {
        await perform("Stash", ["stash", "push", "--include-untracked"])
    }

    func stashPop(_ ref: String = "stash@{0}") async {
        await perform("Pop stash", ["stash", "pop", ref])
    }

    func stashApply(_ ref: String) async {
        await perform("Apply stash", ["stash", "apply", ref])
    }

    func stashDrop(_ ref: String) async {
        await perform("Drop stash", ["stash", "drop", ref])
    }

    func stage(_ files: [FileChange]) async {
        guard !files.isEmpty else { return }
        await perform("Stage", ["add", "-A", "--"] + files.map(\.path))
    }

    func stageAll() async {
        await perform("Stage all", ["add", "-A"])
    }

    func unstage(_ files: [FileChange]) async {
        guard !files.isEmpty else { return }
        let paths = files.flatMap { [$0.path] + ($0.origPath.map { [$0] } ?? []) }
        if status.headOID == nil {
            await perform("Unstage", ["rm", "--cached", "-r", "-q", "--"] + paths)
        } else {
            await perform("Unstage", ["restore", "--staged", "--"] + paths)
        }
    }

    func unstageAll() async {
        if status.headOID == nil {
            await perform("Unstage all", ["rm", "--cached", "-r", "-q", "."])
        } else {
            await perform("Unstage all", ["reset", "-q"])
        }
    }

    /// Restores tracked files; untracked files are moved to the Trash.
    func discard(_ files: [FileChange]) async {
        let names = files.map(\.path)
        await saveDiscarded(paths: names, summary: "Discard " + (names.count == 1 ? names[0] : "\(names.count) files"))
        let untracked = files.filter(\.isUntracked)
        let tracked = files.filter { !$0.isUntracked && !$0.isConflict }
        for f in untracked {
            try? FileManager.default.trashItem(at: root.appendingPathComponent(f.path), resultingItemURL: nil)
        }
        if !tracked.isEmpty {
            await perform("Discard changes", ["restore", "--worktree", "--"] + tracked.map(\.path))
        } else {
            await refreshStatus()
        }
    }

    @discardableResult
    func commit(message: String, amend: Bool) async -> Bool {
        var args = ["commit", "-F", "-"]
        if amend { args.append("--amend") }
        let subject = message.split(separator: "\n").first.map { String($0.prefix(50)) } ?? ""
        return await recordingUndo(.commit, (amend ? "Amend “" : "Commit “") + subject + "”") {
            await perform(amend ? "Amend commit" : "Commit", args, stdin: Data(message.utf8))
        }.ok
    }

    static let discardRecoveryNote = "A copy is kept for \(Repository.discardKeepDays) days: Repository › Recover Discarded Changes…"

    /// Reverse-applies `patch` to the working copy after saving the file's content.
    @discardableResult
    func discardPatch(_ patch: Data, path: String, title: String) async -> Bool {
        await saveDiscarded(paths: [path], summary: "\(title) in \(path)")
        return await apply(patch: patch, cached: false, reverse: true, title: title)
    }

    @discardableResult
    func apply(patch: Data, cached: Bool, reverse: Bool, title: String) async -> Bool {
        var args = ["apply", "--recount", "--whitespace=nowarn"]
        if cached { args.append("--cached") }
        if reverse { args.append("-R") }
        args.append("-")
        return await perform(title, args, stdin: patch).ok
    }

    // MARK: Queries

    enum FileVersion: Equatable {
        case none
        case worktree(String)
        case index(String)
        case commit(String, String)
    }

    /// Full text of one version of a file (for syntax highlighting), or nil if
    /// missing, binary or too large.
    func fileText(_ version: FileVersion) async -> String? {
        let data: Data
        switch version {
        case .none:
            return nil
        case .worktree(let path):
            let url = root.appendingPathComponent(path)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attrs[.size] as? Int, size <= SyntaxHighlighter.maxBytes,
                  let d = try? Data(contentsOf: url) else { return nil }
            data = d
        case .index(let path):
            let r = await git.run(["show", ":\(path)"])
            guard r.ok else { return nil }
            data = r.stdout
        case .commit(let rev, let path):
            let r = await git.run(["show", "\(rev):\(path)"])
            guard r.ok else { return nil }
            data = r.stdout
        }
        guard data.count <= SyntaxHighlighter.maxBytes, !data.prefix(8000).contains(0) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    func lastCommitMessage() async -> String {
        let r = await git.run(["log", "-1", "--format=%B"])
        return r.ok ? r.output.trimmingCharacters(in: .whitespacesAndNewlines) : ""
    }

    /// Commits on `head` that are not on the first resolvable base ref, oldest
    /// first (merge commits skipped), with the base ref that was used.
    /// nil when none of the bases could be resolved.
    func branchCommits(head: String, bases: [String], limit: Int = 300) async -> (base: String, commits: [BranchCommit])? {
        for base in bases {
            let r = await git.run(["log", "--no-merges", "--reverse", "--format=%H%x1f%s%x1f%b%x1e",
                                   "\(base)..\(head)", "--"])
            guard r.ok else { continue }
            return (base, Array(BranchCommit.parse(r.output).prefix(limit)))
        }
        return nil
    }

    /// `git diff --stat` of what `head` changes since it split off `base`.
    func diffStat(base: String, head: String) async -> String {
        let r = await git.run(["diff", "--stat=100", "--stat-count=60", "\(base)...\(head)", "--"])
        return r.ok ? r.output.trimmingCharacters(in: .whitespacesAndNewlines) : ""
    }

    func lastCommitSubject(of ref: String) async -> String {
        let r = await git.run(["log", "-1", "--format=%s", ref])
        return r.ok ? r.output.trimmingCharacters(in: .whitespacesAndNewlines) : ""
    }

    func mergeMessage() -> String? {
        guard let text = try? String(contentsOf: gitDir.appendingPathComponent("MERGE_MSG"), encoding: .utf8) else { return nil }
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("#") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func commitDetail(_ hash: String) async -> CommitDetail? {
        async let header = git.run(["show", "-s", "--format=" + CommitDetail.format, hash])
        async let files = git.run(["show", "--format=", "--name-status", "-z", "-M", "--diff-merges=first-parent", hash])
        let (h, f) = await (header, files)
        guard h.ok, var detail = CommitDetail.parseHeader(h.stdout) else { return nil }
        detail.files = f.ok ? CommitDetail.parseNameStatus(f.stdout) : []
        return detail
    }

    private func diffBaseArgs(context: Int) -> [String] {
        ["diff", "--no-ext-diff", "--no-color", "--histogram", "-M", "-U\(context)"]
    }

    private func pathArgs(_ change: FileChange) -> [String] {
        ["--"] + (change.origPath.map { [$0] } ?? []) + [change.path]
    }

    func workingDiff(_ change: FileChange, staged: Bool, context: Int) async -> FileDiff? {
        var args: [String]
        if change.isUntracked {
            if change.path.hasSuffix("/") { return nil }
            args = ["diff", "--no-index", "--no-ext-diff", "--no-color", "--histogram", "-U\(context)", "--", "/dev/null", change.path]
        } else {
            args = diffBaseArgs(context: context) + (staged ? ["--cached"] : []) + pathArgs(change)
        }
        let r = await git.run(args)
        guard r.ok || (change.isUntracked && r.status == 1) else { return nil }
        let data = r.stdout
        return await Task.detached { FileDiff(data: data) }.value
    }

    func commitDiff(_ change: FileChange, commit: String, parent: String?, context: Int) async -> FileDiff? {
        let args = diffBaseArgs(context: context) + [parent ?? emptyTreeHash, commit] + pathArgs(change)
        let r = await git.run(args)
        guard r.ok else { return nil }
        let data = r.stdout
        return await Task.detached { FileDiff(data: data) }.value
    }

    /// Opens the user's configured difftool for a file (non-blocking).
    func openDifftool(_ change: FileChange, staged: Bool, commit: String?, parent: String?) {
        var args = ["difftool", "-y", "--no-prompt"]
        if let commit { args += [parent ?? emptyTreeHash, commit] }
        else if staged { args.append("--cached") }
        args += pathArgs(change)
        Task { _ = await git.run(args) }
    }

    func openMergetool(_ path: String) {
        Task {
            _ = await git.run(["mergetool", "-y", "--", path])
            await refreshStatus()
        }
    }
}
