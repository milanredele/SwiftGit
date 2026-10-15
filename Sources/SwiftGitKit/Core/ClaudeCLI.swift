import Foundation

/// Optional AI help through the Claude Code CLI (`claude`), if it is installed
/// and logged in. Used to write pull request titles and descriptions from a
/// branch's commit messages with a small, inexpensive model.
enum ClaudeCLI {
    /// Model alias passed to `claude --model` (default: haiku, the cheapest; see Settings).
    static var model: String { Settings.claudeModel }
    static let timeout: TimeInterval = 120

    static var executable: String? {
        if let p = Tooling.find("claude") { return p }
        // GUI apps may not see the PATH entry the installer added to the shell profile.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude",
                          "\(home)/.npm-global/bin/claude", "\(home)/.bun/bin/claude",
                          "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var isAvailable: Bool { Settings.claudeEnabled && executable != nil }

    struct Draft: Equatable {
        var title: String
        var body: String
    }

    static let systemPrompt = """
    You write GitHub pull request titles and descriptions from git commit messages.
    Reply in exactly this format and nothing else:
    TITLE: <one line, imperative mood, at most 72 characters, no trailing period>
    BODY:
    <a concise Markdown description: what changes and why, as a short paragraph and/or a bullet list>

    Follow the conventions of the commit messages: if their subjects start with a prefix such as feat:, fix:,
    chore: or fix(scope): (Conventional Commits), start the title the same way; reuse ticket keys, language,
    capitalization and tone the commits use, and write the description in the style of the commit bodies.
    Base everything on the commits and the file list; do not invent details, ticket numbers or test results.
    If a pull request template is given, fill in its sections and keep its headings; leave checkboxes unticked.
    No preamble, no closing remarks, no code fences around the whole reply.
    """

    /// The text sent on stdin: branch, commits (oldest first), changed files and template.
    static func input(head: String, base: String, commits: [BranchCommit], diffStat: String, template: String?) -> String {
        var s = "Branch \(head) into \(base).\n"
        if let release = CommitStyle.releaseTitle(head: head, base: base) {
            s += "This is a release to production; start the title with \"\(release): \" followed by a short summary of what is released (no Conventional Commits prefix).\n"
        } else if let p = CommitStyle.pullRequestPrefix(commits.map(\.subject)) {
            s += "The commits use Conventional Commits prefixes; start the title with \"\(p.text) \".\n"
        }
        s += "\nCommits, oldest first:\n"
        var budget = 24_000
        for c in commits {
            let entry = "\n---\n" + c.message + "\n"
            if entry.count > budget { s += "\n(… \(commits.count) commits in total, the rest omitted)\n"; break }
            s += entry
            budget -= entry.count
        }
        if !diffStat.isEmpty { s += "\nChanged files:\n" + String(diffStat.prefix(6_000)) + "\n" }
        if let template, !template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            s += "\nPull request template:\n" + String(template.prefix(6_000)) + "\n"
        }
        return s
    }

    /// Parses the "TITLE: … / BODY: …" reply, tolerating minor deviations.
    static func parse(_ output: String) -> Draft? {
        var text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            var lines = text.components(separatedBy: "\n")
            lines.removeFirst()
            if lines.last?.trimmingCharacters(in: .whitespaces).hasPrefix("```") == true { lines.removeLast() }
            text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let lines = text.components(separatedBy: "\n")
        var title: String?
        var bodyLines: [String] = []
        var inBody = false
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if !inBody, title == nil, let r = t.range(of: "TITLE:", options: [.anchored, .caseInsensitive]) {
                title = String(t[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            } else if !inBody, let r = t.range(of: "BODY:", options: [.anchored, .caseInsensitive]) {
                inBody = true
                let rest = String(t[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !rest.isEmpty { bodyLines.append(rest) }
            } else if inBody {
                bodyLines.append(line)
            } else if title == nil, !t.isEmpty {
                title = t   // no markers: first line is the title, the rest the body
                inBody = true
            }
        }
        guard var title, !title.isEmpty else { return nil }
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: "*#`\"").union(.whitespaces))
        let body = bodyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return Draft(title: title, body: body)
    }

    static func arguments(minimal: Bool) -> [String] {
        let prompt = "Write the pull request title and description for the branch described on stdin."
        if minimal { return ["-p", "--model", model, "--system-prompt", systemPrompt, prompt] }
        return ["-p", "--model", model,
                "--system-prompt", systemPrompt,
                "--tools", "",                     // text only: no file, shell or web access
                "--disable-slash-commands",
                "--no-session-persistence",
                "--output-format", "text",
                prompt]
    }

    static func generatePullRequest(head: String, base: String, commits: [BranchCommit], diffStat: String,
                                    template: String?, cancel: CancelToken) async throws -> Draft {
        guard let exe = executable else { throw GitHubError(message: "The claude CLI was not found.") }
        let stdin = Data(input(head: head, base: base, commits: commits, diffStat: diffStat, template: template).utf8)
        // Run outside the repository so no project settings or CLAUDE.md are picked up.
        let cwd = FileManager.default.temporaryDirectory
        let started = Date()
        let timer = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            if !Task.isCancelled { cancel.cancel() }
        }
        defer { timer.cancel() }
        var r = await ProcessRunner.run(executable: exe, arguments: arguments(minimal: false), cwd: cwd, stdin: stdin, cancel: cancel)
        if !r.ok, !cancel.isCancelled, r.stderr.lowercased().contains("unknown option") {
            // Older CLI without some of the flags.
            r = await ProcessRunner.run(executable: exe, arguments: arguments(minimal: true), cwd: cwd, stdin: stdin, cancel: cancel)
        }
        if cancel.isCancelled {
            if Date().timeIntervalSince(started) >= timeout - 1 {
                throw GitHubError(message: "claude didn’t answer within \(Int(timeout)) seconds.")
            }
            throw CancellationError()
        }
        guard r.ok else {
            var message = r.errorMessage
            if message.lowercased().contains("login") || message.lowercased().contains("auth") {
                message += "\nRun `claude` in Terminal once to log in."
            }
            throw GitHubError(message: "claude: " + message)
        }
        guard var draft = parse(r.output) else {
            throw GitHubError(message: "claude returned no usable text.")
        }
        if CommitStyle.releaseTitle(head: head, base: base) != nil {
            draft.title = CommitStyle.applyRelease(head: head, base: base, to: draft.title)
        } else {
            draft.title = CommitStyle.apply(CommitStyle.pullRequestPrefix(commits.map(\.subject)), to: draft.title)
        }
        return draft
    }
}
