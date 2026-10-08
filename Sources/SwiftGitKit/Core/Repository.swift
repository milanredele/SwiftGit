import Foundation

enum RepoChange {
    case status
    case refs
    case graph
    case activity
    case summaries(Int)
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
    private var graphReloadAgain = false

    var localBranches: [RefInfo] { refs.filter { $0.kind == .local } }
    var remoteBranches: [RefInfo] { refs.filter { $0.kind == .remote } }
    var tags: [RefInfo] { refs.filter { $0.kind == .tag } }
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
        var paths = [root.path]
        if !gitDir.path.hasPrefix(root.path + "/") { paths.append(gitDir.path) }
        watcher = RepoWatcher(paths: paths) { [weak self] events in
            self?.handleFileEvents(events)
        }
        Task { await refreshAll() }
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
            if p.hasPrefix(gd) {
                let rel = p.dropFirst(gd.count)
                if rel.hasPrefix("/objects") || rel.hasPrefix("/logs") || rel.hasPrefix("/lfs") { continue }
                pendingRefs = true
                pendingStatus = true
            } else {
                pendingStatus = true
            }
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
        refs = r1.ok ? RefInfo.parse(r1.output) : []
        stashes = r2.ok ? StashInfo.parse(r2.output) : []
        remotes = r3.ok ? RemoteInfo.parse(r3.output) : []

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

    func reloadGraph() async {
        if graphLoading { graphReloadAgain = true; return }
        graphLoading = true
        defer { graphLoading = false }
        repeat {
            graphReloadAgain = false
            var args = ["log", "--branches", "--remotes", "--tags", "--topo-order", "--format=%H %P"]
            if status.headOID != nil { args.append("HEAD") }
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
    func perform(_ title: String, _ args: [String], stdin: Data? = nil, reportErrors: Bool = true) async -> RunResult {
        if let busy = activityTitle {
            onError?(title, "Please wait until “\(busy)” has finished.")
            return RunResult(status: -2, stdout: Data(), stderr: "busy")
        }
        let token = CancelToken()
        activityToken = token
        activityTitle = title
        activityDetail = ""
        notify(.activity)
        let r = await git.run(args, stdin: stdin, cancel: token, onStderrLine: { [weak self] line in
            Task { @MainActor in self?.setActivityDetail(line) }
        })
        activityToken = nil
        activityTitle = nil
        notify(.activity)
        if !r.ok && reportErrors && !token.isCancelled { onError?(title, r.errorMessage) }
        await refreshStatus()
        await refreshRefs()
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

    func localBranch(named name: String) -> RefInfo? { refs.first { $0.kind == .local && $0.name == name } }

    func checkout(branch: String) async {
        await perform("Checkout \(branch)", ["switch", branch])
    }

    func checkout(remote ref: RefInfo) async {
        guard let local = ref.remoteBranch else { return }
        if localBranch(named: local) != nil {
            await perform("Checkout \(local)", ["switch", local])
        } else {
            await perform("Checkout \(ref.name)", ["switch", "--track", ref.name])
        }
    }

    func checkoutDetached(_ target: String) async {
        await perform("Checkout \(target)", ["switch", "--detach", target])
    }

    func createBranch(_ name: String, from start: String?, checkout: Bool) async {
        if checkout {
            await perform("Create branch \(name)", ["switch", "-c", name] + (start.map { [$0] } ?? []))
        } else {
            await perform("Create branch \(name)", ["branch", name] + (start.map { [$0] } ?? []))
        }
    }

    func renameBranch(_ old: String, to new: String) async {
        await perform("Rename \(old)", ["branch", "-m", old, new])
    }

    @discardableResult
    func deleteBranch(_ name: String, force: Bool) async -> RunResult {
        await perform("Delete \(name)", ["branch", force ? "-D" : "-d", name], reportErrors: force)
    }

    func deleteRemoteBranch(_ ref: RefInfo) async {
        guard let remote = ref.remoteName, let branch = ref.remoteBranch else { return }
        await perform("Delete \(ref.name)", ["push", "--progress", remote, "--delete", branch])
    }

    func createTag(_ name: String, at target: String) async {
        await perform("Create tag \(name)", ["tag", name, target])
    }

    func merge(_ ref: String) async {
        await perform("Merge \(ref)", ["merge", "--no-edit", ref])
    }

    func rebase(onto ref: String) async {
        await perform("Rebase onto \(ref)", ["rebase", ref])
    }

    func cherryPick(_ hash: String) async {
        await perform("Cherry-pick", ["cherry-pick", hash])
    }

    func revert(_ hash: String) async {
        await perform("Revert", ["revert", "--no-edit", hash])
    }

    func reset(to hash: String, mode: String) async {
        await perform("Reset (\(mode))", ["reset", "--\(mode)", hash])
    }

    func continueOperation() async {
        switch opState {
        case .rebasing: await perform("Continue rebase", ["rebase", "--continue"])
        case .merging: await perform("Commit merge", ["commit", "--no-edit"])
        case .cherryPicking: await perform("Continue cherry-pick", ["cherry-pick", "--continue"])
        case .reverting: await perform("Continue revert", ["revert", "--continue"])
        case .none: break
        }
    }

    func abortOperation() async {
        switch opState {
        case .rebasing: await perform("Abort rebase", ["rebase", "--abort"])
        case .merging: await perform("Abort merge", ["merge", "--abort"])
        case .cherryPicking: await perform("Abort cherry-pick", ["cherry-pick", "--abort"])
        case .reverting: await perform("Abort revert", ["revert", "--abort"])
        case .none: break
        }
    }

    func skipRebaseStep() async {
        await perform("Skip commit", ["rebase", "--skip"])
    }

    func fetch() async {
        await perform("Fetch", ["fetch", "--all", "--prune", "--progress"])
    }

    func pull(rebase: Bool? = nil) async {
        var args = ["pull", "--progress"]
        if rebase == true { args.append("--rebase") }
        if rebase == false { args.append("--no-rebase") }
        await perform("Pull", args)
    }

    /// Pushes `branch` (default: current). Sets the upstream when there is none.
    @discardableResult
    func push(branch: String? = nil, force: Bool = false) async -> Bool {
        guard let name = branch ?? status.branch else {
            onError?("Push", "HEAD is detached. Check out a branch first.")
            return false
        }
        let upstream = name == status.branch ? status.upstream : localBranch(named: name)?.upstream
        var args = ["push", "--progress"]
        if force { args.append("--force-with-lease") }
        if upstream == nil {
            guard let remote = preferredRemote else {
                onError?("Push", "This repository has no remote.")
                return false
            }
            args += ["--set-upstream", remote, name]
        } else if name != status.branch {
            let parts = upstream!.split(separator: "/", maxSplits: 1).map(String.init)
            if parts.count == 2 { args += [parts[0], "\(name):\(parts[1])"] }
        }
        return await perform(force ? "Force push \(name)" : "Push \(name)", args).ok
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
        return await perform(amend ? "Amend commit" : "Commit", args, stdin: Data(message.utf8)).ok
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
