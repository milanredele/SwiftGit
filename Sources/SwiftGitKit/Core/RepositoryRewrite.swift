import Foundation

/// One commit in a simple interactive rebase.
struct RebaseStep: Equatable {
    enum Action: String, CaseIterable {
        case pick, reword, squash, fixup, drop

        var title: String {
            switch self {
            case .pick: return "Keep"
            case .reword: return "Reword"
            case .squash: return "Squash into previous"
            case .fixup: return "Fixup into previous (drop message)"
            case .drop: return "Drop"
            }
        }
    }

    var commit: BranchCommit
    var action: Action = .pick
    /// New message for `.reword`.
    var message: String?
}

struct RewritePlan: Equatable {
    /// Rebase base (exclusive); nil means from the root commit.
    var base: String?
    var commits: [BranchCommit]
    /// Commits of the range that are already on the upstream branch (rewriting them needs a force push).
    var pushedCount: Int
}

extension Repository {
    /// The commits from `first` (inclusive) to HEAD, oldest first, for editing.
    /// Fails with an explanation when the range can't be rewritten simply.
    func rewritePlan(from first: String) async -> Result<RewritePlan, GitHubError> {
        guard opState == .none else { return .failure(GitHubError(message: "Finish the current \(opState) first.")) }
        guard await git.run(["merge-base", "--is-ancestor", first, "HEAD"]).ok else {
            return .failure(GitHubError(message: "That commit isn’t part of the checked-out branch."))
        }
        let parent = await git.run(["rev-parse", "-q", "--verify", "\(first)^"])
        let base: String? = parent.ok ? parent.output.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        let range = base.map { "\($0)..HEAD" } ?? "HEAD"
        let merges = await git.run(["rev-list", "--count", "--merges", range])
        if (Int(merges.output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) > 0 {
            return .failure(GitHubError(message: "The range contains merge commits, which this simple editor can’t rewrite. Use git rebase -i --rebase-merges in a terminal."))
        }
        let log = await git.run(["log", "--reverse", "--format=%H%x1f%s%x1f%b%x1e", range, "--"])
        guard log.ok else { return .failure(GitHubError(message: log.errorMessage)) }
        let commits = BranchCommit.parse(log.output)
        guard !commits.isEmpty else { return .failure(GitHubError(message: "No commits to edit.")) }
        guard commits.count <= 200 else { return .failure(GitHubError(message: "That is \(commits.count) commits; pick a more recent one (up to 200).")) }
        var pushed = 0
        if status.upstream != nil {
            // Commits of the range that are not on the upstream yet; the rest are pushed.
            let notPushed = await git.run(["rev-list", "--count", range, "^@{upstream}"])
            if notPushed.ok, let n = Int(notPushed.output.trimmingCharacters(in: .whitespacesAndNewlines)) {
                pushed = max(0, commits.count - n)
            }
        }
        return .success(RewritePlan(base: base, commits: commits, pushedCount: pushed))
    }

    /// The todo list git rebase -i runs for `steps` (rewords become pick + amend).
    static func rebaseTodo(_ steps: [RebaseStep], messageFiles: [String: String]) -> String {
        var lines: [String] = []
        for s in steps {
            switch s.action {
            case .reword:
                lines.append("pick \(s.commit.hash)")
                if let file = messageFiles[s.commit.hash] {
                    lines.append("exec git commit --amend --only --allow-empty --cleanup=strip -F \(shellQuote(file))")
                }
            default:
                lines.append("\(s.action.rawValue) \(s.commit.hash)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Checks the steps before running: something must change and squash/fixup need a commit before them.
    static func validate(_ steps: [RebaseStep], original: [BranchCommit]) -> String? {
        guard let firstKept = steps.firstIndex(where: { $0.action != .drop }) else {
            return "All commits would be dropped. Use Reset instead."
        }
        if [.squash, .fixup].contains(steps[firstKept].action) {
            return "“\(steps[firstKept].commit.subject)” can’t be squashed: there is no earlier commit in the list to squash it into."
        }
        let unchanged = steps.map(\.commit) == original && steps.allSatisfy { $0.action == .pick }
        return unchanged ? "Nothing changed." : nil
    }

    /// Rewrites the commits with `git rebase -i`, letting git do the work.
    /// Stops like any rebase when a step conflicts (the banner offers continue/abort).
    @discardableResult
    func rewrite(_ plan: RewritePlan, steps: [RebaseStep]) async -> RunResult {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("swiftgit-rebase-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var files: [String: String] = [:]
        for s in steps where s.action == .reword {
            let url = dir.appendingPathComponent("msg-\(s.commit.hash.prefix(12))")
            try? (s.message ?? s.commit.message).write(to: url, atomically: true, encoding: .utf8)
            files[s.commit.hash] = url.path
        }
        let todo = dir.appendingPathComponent("todo")
        try? Repository.rebaseTodo(steps, messageFiles: files).write(to: todo, atomically: true, encoding: .utf8)
        // git appends the todo file's path to this command.
        let env = ["GIT_SEQUENCE_EDITOR": "cp \(Repository.shellQuote(todo.path))"]
        let args = ["rebase", "-i", "--autostash"] + (plan.base.map { [$0] } ?? ["--root"])
        let r = await recordingUndo(.moveHead, "Edit \(plan.commits.count) Commit\(plan.commits.count == 1 ? "" : "s")") {
            await perform("Edit commits", args, environment: env)
        }
        // Message files are needed until a stopped rebase is continued; leave them in the temp dir then.
        if opState == .none { try? FileManager.default.removeItem(at: dir) }
        return r
    }
}
