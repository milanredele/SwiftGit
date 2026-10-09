import Foundation
import Testing
@testable import SwiftGitKit

@MainActor
@Suite("Core")
struct CoreTests {
    @Test func statusParsing() throws {
        let raw = "# branch.oid abc\0# branch.head main\0# branch.upstream origin/main\0# branch.ab +2 -1\0"
            + "1 .M N... 100644 100644 100644 aaa bbb a.txt\0"
            + "1 M. N... 100644 100644 100644 aaa bbb src/b c.swift\0"
            + "2 R. N... 100644 100644 100644 aaa bbb R100 new name.txt\0old name.txt\0"
            + "u UU N... 100644 100644 100644 100644 a b c conflict.txt\0"
            + "? untracked.txt\0"
        let s = WorkingStatus.parse(Data(raw.utf8))
        #expect(s.branch == "main")
        #expect(s.upstream == "origin/main")
        #expect(s.ahead == 2 && s.behind == 1)
        #expect(s.unstaged.map(\.path) == ["a.txt", "untracked.txt"])
        #expect(s.staged.map(\.path) == ["src/b c.swift", "new name.txt"])
        #expect(s.staged.last?.origPath == "old name.txt")
        #expect(s.conflicts.map(\.path) == ["conflict.txt"])
    }

    @Test func graphFromFixture() async throws {
        let dir = try Fixture.makeRepo()
        let repo = try await Repository.open(dir)
        await repo.refreshAll()
        let g = await repo.graph
        #expect(g.count == 6)
        #expect(g.maxLanes == 2)
        // The merge commit is first and has two parents leaving its node.
        #expect(g.bottomOut[0].nonzeroBitCount == 2)
        let refs = await repo.refs
        #expect(refs.contains { $0.name == "feature" && $0.kind == .local })
        #expect(refs.contains { $0.name == "v1.0" && $0.kind == .tag })
        let status = await repo.status
        #expect(status.unstaged.map(\.path).sorted() == ["a.txt", "new.txt"])
        #expect(status.staged.map(\.path) == ["src/b.swift"])
    }

    @Test func branchOrderingAndStaleness() async throws {
        let dir = try Fixture.makeRepo()
        let remote = dir.deletingLastPathComponent().appendingPathComponent(dir.lastPathComponent + "-remote.git")
        try Fixture.git(["init", "-q", "--bare", remote.path], in: dir)
        try Fixture.git(["remote", "add", "origin", remote.path], in: dir)
        try Fixture.git(["push", "-q", "-u", "origin", "main", "feature"], in: dir)
        // A newer, unmerged branch (created without touching the working tree).
        let later = ["GIT_COMMITTER_DATE": "2026-02-01T12:00:00", "GIT_AUTHOR_DATE": "2026-02-01T12:00:00"]
        let wip = try Fixture.git(["commit-tree", "HEAD^{tree}", "-p", "HEAD", "-m", "WIP"], in: dir, env: later)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try Fixture.git(["branch", "wip", wip], in: dir)
        // feature was merged into main and deleted on the remote → "gone".
        try Fixture.git(["push", "-q", "origin", "--delete", "feature"], in: dir)
        try Fixture.git(["fetch", "-q", "--prune", "origin"], in: dir)

        let repo = try await Repository.open(dir)
        await repo.refreshAll()
        let locals = repo.localBranches
        #expect(locals.map(\.name) == ["wip", "main", "feature"])
        let feature = try #require(locals.first { $0.name == "feature" })
        #expect(feature.upstreamGone)
        #expect(feature.isMerged)
        #expect(feature.isStale)
        #expect(locals.first { $0.name == "wip" }?.isStale == false)
        #expect(locals.first { $0.name == "main" }?.isStale == false)
    }

    @Test func squashAndRebaseMergesAreDetected() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gitui-squash-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func g(_ args: String...) throws { try Fixture.git(args, in: dir) }
        try g("init", "-q")
        try Fixture.write(dir, "a.txt", Fixture.lines(20))
        try g("add", "-A"); try g("commit", "-q", "-m", "init")
        // topic: two commits, squash-merged into main
        try g("switch", "-q", "-c", "topic")
        try Fixture.write(dir, "b.txt", "one\n"); try g("add", "-A"); try g("commit", "-q", "-m", "t1")
        try Fixture.write(dir, "b.txt", "one\ntwo\n"); try g("commit", "-q", "-am", "t2")
        // rebased: one commit, cherry-picked (rebase merge) into main
        try g("switch", "-q", "-c", "rebased", "main")
        try Fixture.write(dir, "c.txt", "c\n"); try g("add", "-A"); try g("commit", "-q", "-m", "r1")
        // open: unmerged work
        try g("switch", "-q", "-c", "open", "main")
        try Fixture.write(dir, "d.txt", "d\n"); try g("add", "-A"); try g("commit", "-q", "-m", "o1")
        // nearby: edits line 10 of a.txt; main edits line 12 before the squash
        // (different diff context → plain patch-ids differ)
        var a = (1...20).map { "line \($0)" }
        try g("switch", "-q", "-c", "nearby", "main")
        a[9] = "line 10 (nearby)"
        try Fixture.write(dir, "a.txt", a.joined(separator: "\n") + "\n"); try g("commit", "-q", "-am", "n1")
        // later: edits line 3; after the squash main edits the same line again
        try g("switch", "-q", "-c", "later", "main")
        var l = (1...20).map { "line \($0)" }
        l[2] = "line three"
        try Fixture.write(dir, "a.txt", l.joined(separator: "\n") + "\n"); try g("commit", "-q", "-am", "l1")
        try g("switch", "-q", "main")
        try Fixture.write(dir, "e.txt", "main moved on\n"); try g("add", "-A"); try g("commit", "-q", "-m", "main work")
        try g("merge", "-q", "--squash", "topic"); try g("commit", "-q", "-m", "Topic (squashed)")
        try g("cherry-pick", "rebased")
        a = (1...20).map { "line \($0)" }
        a[11] = "line 12 (main)"
        try Fixture.write(dir, "a.txt", a.joined(separator: "\n") + "\n"); try g("commit", "-q", "-am", "main edits line 12")
        try g("merge", "-q", "--squash", "nearby"); try g("commit", "-q", "-m", "Nearby (squashed)")
        try g("merge", "-q", "--squash", "later"); try g("commit", "-q", "-m", "Later (squashed)")
        a = try String(contentsOf: dir.appendingPathComponent("a.txt"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        a[2] = "line THREE (main again)"
        try Fixture.write(dir, "a.txt", a.joined(separator: "\n") + "\n"); try g("commit", "-q", "-am", "main edits line 3")

        let repo = try await Repository.open(dir)
        await repo.refreshAll()
        // Lazy: nothing is checked until branches are shown / selected.
        #expect(repo.localBranches.first { $0.name == "topic" }?.isMerged == false)
        repo.checkMergeStatus(repo.localBranches)
        let expected = ["topic", "rebased", "nearby", "later"]
        await UI.wait("content merge detection", timeout: 20) {
            expected.allSatisfy { name in repo.localBranches.first { $0.name == name }?.isMerged == true }
        }
        let byName = Dictionary(uniqueKeysWithValues: repo.localBranches.map { ($0.name, $0) })
        for name in expected {
            #expect(byName[name]?.mergedByContent == true, "\(name) not detected as merged")
        }
        #expect(byName["open"]?.isMerged == false)
        let openReport = await repo.mergeReport(for: try #require(byName["open"]))
        #expect(!openReport.merged)
        #expect(openReport.steps.contains { $0.hasPrefix("✗ Merging it now would still change 1 file") })
        let laterReport = await repo.mergeReport(for: try #require(byName["later"]))
        #expect(laterReport.merged)
        #expect(laterReport.steps.last?.hasPrefix("✓") == true)
        #expect(repo.localBranches.last?.isStale == true)
        #expect(repo.localBranches.first?.name == "main")
    }

    @Test func historyIsInDateOrder() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gitui-order-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func commit(_ msg: String, day: Int, file: String) throws {
            try Fixture.write(dir, file, msg + "\n")
            try Fixture.git(["add", "-A"], in: dir)
            let d = String(format: "2026-03-%02dT12:00:00", day)
            try Fixture.git(["commit", "-q", "-m", msg], in: dir, env: ["GIT_AUTHOR_DATE": d, "GIT_COMMITTER_DATE": d])
        }
        try Fixture.git(["init", "-q"], in: dir)
        try commit("c1", day: 1, file: "main.txt")
        try Fixture.git(["switch", "-q", "-c", "side"], in: dir)
        try commit("b1", day: 2, file: "side.txt")
        try Fixture.git(["switch", "-q", "main"], in: dir)
        try commit("c2", day: 3, file: "main.txt")
        try Fixture.git(["switch", "-q", "side"], in: dir)
        try commit("b2", day: 4, file: "side.txt")
        try Fixture.git(["switch", "-q", "main"], in: dir)
        try Fixture.git(["merge", "-q", "--no-ff", "side", "-m", "merge"], in: dir,
                        env: ["GIT_AUTHOR_DATE": "2026-03-05T12:00:00", "GIT_COMMITTER_DATE": "2026-03-05T12:00:00"])

        UserDefaults.standard.removeObject(forKey: Repository.topoOrderKey)
        let repo = try await Repository.open(dir)
        await repo.refreshAll()
        await UI.wait("summaries") { (0..<repo.graph.count).allSatisfy { repo.summary(row: $0) != nil } }
        let subjects = (0..<repo.graph.count).compactMap { repo.summary(row: $0)?.subject }
        #expect(subjects == ["merge", "b2", "c2", "b1", "c1"])
    }

    @Test func deletionInfoCountsCommitsThatWouldBeLost() async throws {
        let dir = try Fixture.makeRepo()
        let wip = try Fixture.git(["commit-tree", "HEAD^{tree}", "-p", "HEAD", "-m", "WIP"], in: dir)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try Fixture.git(["branch", "wip", wip], in: dir)
        let repo = try await Repository.open(dir)
        await repo.refreshAll()
        let feature = try #require(repo.localBranches.first { $0.name == "feature" })
        let featureInfo = await repo.deletionInfo(for: feature)
        #expect(featureInfo.uniqueCommits == 0)
        #expect(featureInfo.lastSubject == "Feature: notes")
        #expect(featureInfo.mainBranch == "main")
        let wipRef = try #require(repo.localBranches.first { $0.name == "wip" })
        let wipInfo = await repo.deletionInfo(for: wipRef)
        #expect(wipInfo.uniqueCommits == 1)
        #expect(!wipRef.isMerged)
    }

    @Test func sideBySideRows() async throws {
        let dir = try Fixture.makeRepo()
        let repo = try await Repository.open(dir)
        await repo.refreshAll()
        let change = await repo.status.unstaged.first { $0.path == "a.txt" }!
        let diff = try #require(await repo.workingDiff(change, staged: false, context: 3))
        #expect(diff.hunks.count == 3)
        let rows = diff.sideBySideRows()
        #expect(rows.contains { $0.kind == .changed })
        #expect(rows.contains { $0.kind == .added })
        #expect(rows.contains { $0.kind == .gap })
        // Both panes always have identical row counts by construction; every
        // changed row pairs a deletion with an addition.
        for r in rows where r.kind == .changed {
            #expect(diff.lines[Int(r.left)].kind == .deleted)
            #expect(diff.lines[Int(r.right)].kind == .added)
        }
        let unified = diff.unifiedRows()
        #expect(unified.count > rows.count)
    }

    @Test func stagePartialLines() async throws {
        let dir = try Fixture.makeRepo()
        let repo = try await Repository.open(dir)
        await repo.refreshAll()
        let change = await repo.status.unstaged.first { $0.path == "a.txt" }!
        let diff = try #require(await repo.workingDiff(change, staged: false, context: 3))
        // Select only the lines of the first hunk.
        let first = diff.hunks[0]
        let selected = Set(first.lines.filter { diff.lines[$0].kind != .context })
        let patch = try #require(diff.patch(lines: selected, reverse: false))
        let ok = await repo.apply(patch: patch, cached: true, reverse: false, title: "Stage lines")
        #expect(ok)
        let cached = try Fixture.git(["diff", "--cached", "--", "a.txt"], in: dir)
        #expect(cached.contains("+line 3 modified in working tree"))
        #expect(!cached.contains("inserted line"))
        let remaining = try Fixture.git(["diff", "--", "a.txt"], in: dir)
        #expect(remaining.contains("+inserted line"))
        #expect(!remaining.contains("line 3 modified"))

        // Unstage it again with a reverse partial patch.
        let staged = try #require(await repo.workingDiff(change, staged: true, context: 3))
        let all = Set(staged.lines.indices.filter { staged.lines[$0].kind != .context })
        let back = try #require(staged.patch(lines: all, reverse: true))
        #expect(await repo.apply(patch: back, cached: true, reverse: true, title: "Unstage lines"))
        let after = try Fixture.git(["diff", "--cached", "--", "a.txt"], in: dir)
        #expect(after.isEmpty)
    }

    @Test func syntaxHighlightingSwift() throws {
        let source = "struct B {\n    let value = 1 // note\n\tfunc run() { print(\"hi\") }\n}\n"
        let spans = try #require(SyntaxHighlighter.shared.highlight(source, path: "x.swift", lines: [1, 2, 3, 4]))
        let line1 = try #require(spans[1])
        #expect(line1.contains { $0.style == .keyword && $0.start == 0 && $0.length == 6 })
        let line2 = try #require(spans[2])
        #expect(line2.contains { $0.style == .number })
        #expect(line2.contains { $0.style == .comment })
        // Tab expanded to 4 spaces: "func" starts at column 4 in the drawn text.
        let line3 = try #require(spans[3])
        #expect(line3.contains { $0.style == .keyword && $0.start == 4 && $0.length == 4 })
        #expect(line3.contains { $0.style == .string })
    }

    @Test func syntaxHighlightingAda() throws {
        let source = "procedure Hello is\nbegin\n   Put_Line (\"Hi\"); -- greet\nend Hello;\n"
        let spans = try #require(SyntaxHighlighter.shared.highlight(source, path: "hello.adb", lines: [1, 2, 3, 4]))
        #expect(spans[1]?.contains { $0.style == .keyword && $0.start == 0 } == true)
        #expect(spans[3]?.contains { $0.style == .string } == true)
        #expect(spans[3]?.contains { $0.style == .comment } == true)
    }

    @Test func syntaxLanguagesLoad() {
        let h = SyntaxHighlighter.shared
        for path in ["a.swift", "a.js", "a.ts", "a.tsx", "a.py", "a.go", "a.rs", "a.c", "a.cpp",
                     "a.java", "a.json", "a.sh", "a.rb", "a.css", "a.html", "a.cs", "a.ads", "a.adb"] {
            #expect(h.isSupported(path: path), "no highlighting for \(path)")
        }
        #expect(!h.isSupported(path: "README"))
    }

    @Test func intralineHighlightsChangedWord() {
        let (old, new) = Intraline.compute("    let value = 1", "    let value = 2")
        #expect(old == [NSRange(location: 16, length: 1)])
        #expect(new == [NSRange(location: 16, length: 1)])
    }

    @Test func gitHubAuthStatusParsing() {
        let multi = """
        github.com
          ✓ Logged in to github.com account milanredele (keyring)
          - Active account: true
          - Git operations protocol: https
          - Token: gho_************************************
          - Token scopes: 'gist', 'read:org', 'repo', 'workflow'

          ✓ Logged in to github.com account mredele (keyring)
          - Active account: false
          - Git operations protocol: https

        ghe.example.com
          X Failed to log in to ghe.example.com account worker (keyring)
          - Active account: true
        """
        let accounts = GitHub.parseAuthStatus(multi)
        #expect(accounts.map(\.login) == ["milanredele", "mredele", "worker"])
        #expect(accounts.map(\.isActive) == [true, false, true])
        #expect(accounts.map(\.isValid) == [true, true, false])
        #expect(accounts[2].host == "ghe.example.com")

        let old = """
        github.com
          ✓ Logged in to github.com as octocat (oauth_token)
          ✓ Git operations for github.com configured to use https protocol.
        """
        let single = GitHub.parseAuthStatus(old)
        #expect(single.count == 1)
        #expect(single.first?.login == "octocat")
        #expect(single.first?.isActive == true)
        #expect(GitHub.parseAuthStatus("You are not logged into any GitHub hosts.").isEmpty)
    }

    /// Runs against the real gh on this machine (no assertions on accounts).
    @Test func gitHubAccountsFromInstalledGh() async {
        let accounts = await GitHub.accounts()
        print("DIAG gh accounts:", accounts.map { "\($0.login)@\($0.host) active=\($0.isActive) valid=\($0.isValid)" })
    }

    @Test func gitHubRemoteParsing() {
        #expect(GitHubRepo.parse(remoteURL: "git@github.com:acme/widgets.git") == GitHubRepo(owner: "acme", name: "widgets"))
        #expect(GitHubRepo.parse(remoteURL: "https://github.com/acme/widgets") == GitHubRepo(owner: "acme", name: "widgets"))
        #expect(GitHubRepo.parse(remoteURL: "ssh://git@github.com/acme/widgets.git/") == GitHubRepo(owner: "acme", name: "widgets"))
        #expect(GitHubRepo.parse(remoteURL: "git@gitlab.com:acme/widgets.git") == nil)
    }

    @Test func repositoryOrganizationMatchesOwner() {
        let orgs = ["Acme-Corp", "tools"]
        #expect(GitHubAccountToolbarItem.repositoryOrganization(owner: "acme-corp", orgs: orgs) == "Acme-Corp")
        #expect(GitHubAccountToolbarItem.repositoryOrganization(owner: "someone", orgs: orgs) == nil)
        #expect(GitHubAccountToolbarItem.repositoryOrganization(owner: nil, orgs: orgs) == nil)
        #expect(GitHub.parseLines("acme\n tools \n\n") == ["acme", "tools"])
    }

    /// Runs against the real gh on this machine (no assertions on the result).
    @Test func organizationsFromInstalledGh() async {
        let orgs = await GitHub.organizations()
        print("DIAG gh orgs:", orgs.map { $0.joined(separator: ", ") } ?? "request failed")
    }

    @Test func branchCommitsAreOldestFirst() async throws {
        let dir = try Fixture.makeRepo()
        try Fixture.git(["switch", "-q", "-c", "topic/pr"], in: dir)
        try Fixture.write(dir, "one.txt", "1\n")
        try Fixture.git(["add", "one.txt"], in: dir)
        try Fixture.git(["commit", "-q", "-m", "First change", "-m", "Why it matters.\n\nMore detail.", "--", "one.txt"], in: dir)
        try Fixture.write(dir, "two.txt", "2\n")
        try Fixture.git(["add", "two.txt"], in: dir)
        try Fixture.git(["commit", "-q", "-m", "Second change", "--", "two.txt"], in: dir)
        let repo = try await Repository.open(dir)

        let found = try #require(await repo.branchCommits(head: "topic/pr", bases: ["refs/remotes/origin/main", "refs/heads/main"]))
        #expect(found.base == "refs/heads/main")
        #expect(found.commits.map(\.subject) == ["First change", "Second change"])
        #expect(found.commits[0].body == "Why it matters.\n\nMore detail.")
        #expect(found.commits[0].message == "First change\n\nWhy it matters.\n\nMore detail.")
        #expect(found.commits[1].body == "")
        #expect(await repo.branchCommits(head: "topic/pr", bases: ["refs/heads/nope"]) == nil)
        let stat = await repo.diffStat(base: found.base, head: "topic/pr")
        #expect(stat.contains("one.txt") && stat.contains("two.txt"))
    }

    @Test func claudeReplyParsing() {
        let reply = """
        TITLE: Add CSV export to reports
        BODY:
        Adds a **CSV** export.

        - New button
        - Tests
        """
        #expect(ClaudeCLI.parse(reply) == ClaudeCLI.Draft(title: "Add CSV export to reports",
                                                          body: "Adds a **CSV** export.\n\n- New button\n- Tests"))
        let fenced = "```\nTitle: Fix crash\nBody: One line body.\n```"
        #expect(ClaudeCLI.parse(fenced) == ClaudeCLI.Draft(title: "Fix crash", body: "One line body."))
        let plain = "**Fix login redirect**\n\nRedirects back after login."
        #expect(ClaudeCLI.parse(plain) == ClaudeCLI.Draft(title: "Fix login redirect", body: "Redirects back after login."))
        #expect(ClaudeCLI.parse("   ") == nil)

        let commits = [BranchCommit(hash: "aaaaaaa", subject: "First", body: "Because."),
                       BranchCommit(hash: "bbbbbbb", subject: "Second", body: "")]
        let input = ClaudeCLI.input(head: "topic", base: "main", commits: commits, diffStat: " a.txt | 2 +-", template: "## Summary\n")
        #expect(input.contains("Branch topic into main."))
        #expect(input.range(of: "First\n\nBecause.")!.lowerBound < input.range(of: "Second")!.lowerBound)
        #expect(input.contains("Changed files:\n a.txt | 2 +-"))
        #expect(input.contains("Pull request template:\n## Summary"))
        #expect(ClaudeCLI.arguments(minimal: false).contains("--model"))
    }

    /// Checks the claude CLI on this machine accepts our flags. Only runs a real
    /// (tiny, Haiku) request when .dev/claude-live-test exists.
    @Test func claudeCLIOnThisMachine() async throws {
        guard let exe = ClaudeCLI.executable else { print("DIAG claude: not installed"); return }
        let v = await ProcessRunner.run(executable: exe, arguments: ["--version"], cwd: nil)
        print("DIAG claude:", exe, v.output.trimmingCharacters(in: .whitespacesAndNewlines))
        let marker = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".dev/claude-live-test")
        guard FileManager.default.fileExists(atPath: marker.path) else { return }
        let commits = [BranchCommit(hash: "aaaaaaa", subject: "Add a greeting to the README", body: "New users asked how to start."),
                       BranchCommit(hash: "bbbbbbb", subject: "Fix typo in greeting", body: "")]
        let started = Date()
        let draft = try await ClaudeCLI.generatePullRequest(head: "readme-greeting", base: "main", commits: commits,
                                                            diffStat: " README.md | 4 ++++", template: nil, cancel: CancelToken())
        print("DIAG claude draft (\(Int(Date().timeIntervalSince(started)))s):", draft.title, "|", draft.body)
        #expect(!draft.title.isEmpty)
    }
}

