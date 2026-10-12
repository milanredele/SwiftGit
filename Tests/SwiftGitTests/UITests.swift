import AppKit
import Testing
@testable import SwiftGitKit

/// Drives the real window controllers in an offscreen window (no screen
/// access needed), asserts on the view state and writes PNG snapshots.
@MainActor
@Suite("UI", .serialized, .disabled(if: MemoryTests.measuring, "memory measurement run"))
struct UITests {
    private func openWindow() async throws -> (Repository, RepoWindowController, NSWindow) {
        UI.setUpApp()
        let dir = try Fixture.makeRepo()
        let repo = try await Repository.open(dir)
        let wc = RepoWindowController(repository: repo)
        let window = try #require(wc.window)
        window.setContentSize(NSSize(width: 1280, height: 800))
        await repo.refreshAll()
        await UI.settle(window)
        return (repo, wc, window)
    }

    @Test func historyShowsCommitDetailsAndDiff() async throws {
        let (repo, wc, window) = try await openWindow()
        let history = try #require(wc.testRoot.main?.content.history)
        #expect(history.testRowCount == repo.graph.count)

        history.select(hash: repo.graph.hashes[0], scroll: true)
        let detail = history.detail
        await UI.wait("commit files") { detail.testFileCount > 0 }
        await UI.wait("diff rows") { detail.diffVC.testRowCount > 0 }
        await UI.wait("summaries") { repo.summary(row: 0) != nil }
        await UI.settle(window)
        UI.snapshot(window, "history")

        // The diff must actually be visible when the whole window is rendered
        // (catches views painting over each other, not just model state).
        let diffColors = UI.sampleColors(detail.diffVC.view)
        #expect(diffColors.count > 3, "diff area renders only \(diffColors.sorted())")
        if let cv = window.contentView {
            let r = detail.diffVC.testBody.rightScroll.convert(detail.diffVC.testBody.rightScroll.bounds, to: cv)
            let hit = cv.hitTest(NSPoint(x: r.midX, y: r.midY))
            #expect(hit is DiffPaneView, "hit test in right pane finds \(hit.map { "\(type(of: $0))" } ?? "nil")")
        }
        #expect(detail.testHeader.contains("Merge feature"))
        let leftColumn = try #require((detail.view as? NSSplitView)?.arrangedSubviews.first)
        #expect(leftColumn.frame.width > 150, "commit info column width \(leftColumn.frame.width)")
        let body = detail.diffVC.testBody
        #expect(!body.isHidden)
        #expect(body.leftScroll.frame.width > 100, "left pane width \(body.leftScroll.frame.width)")
        #expect(body.rightScroll.frame.height > 50, "right pane height \(body.rightScroll.frame.height)")
        #expect(detail.diffVC.testPlaceholder == nil)

        // When HEAD moves (checkout/pull), the selection follows it.
        #expect(history.testSelectedHash == repo.headHash)
        let featureTip = try #require(repo.localBranches.first { $0.name == "feature" }.flatMap { Hash20($0.target) })
        await repo.checkout(branch: "feature")
        await UI.wait("selection follows HEAD") { history.testSelectedHash == featureTip }
        #expect(repo.currentBranch == "feature")
        window.close()
    }

    @Test func selectingACommitHighlightsItsBranch() async throws {
        let (repo, wc, window) = try await openWindow()
        let history = try #require(wc.testRoot.main?.content.history)
        let sidebar = try #require(wc.testRoot.main?.sidebar)
        let featureTip = try #require(repo.localBranches.first { $0.name == "feature" }.flatMap { Hash20($0.target) })
        history.select(hash: featureTip, scroll: true)
        #expect(sidebar.testSelectedTitle == "feature")
        let head = try #require(repo.headHash)
        history.select(hash: head, scroll: true)
        #expect(sidebar.testSelectedTitle == "main")
        // A commit without branches clears the sidebar selection.
        let plain = try #require(repo.graph.hashes.first { (repo.decorations[$0] ?? []).isEmpty })
        history.select(hash: plain, scroll: true)
        #expect(sidebar.testSelectedTitle == nil)

        // Open pull request badge next to the branch.
        repo.testSetPullRequests(["feature": PullRequestBadge(number: 42, url: "https://github.com/acme/w/pull/42",
                                                              isDraft: true, review: .approved, checks: .failing)])
        await UI.settle(window)
        #expect(sidebar.testRowText(named: "feature")?.contains("#42 draft ● ✓") == true, "\(sidebar.testRowText(named: "feature") ?? "nil")")
        UI.snapshot(window, "sidebar-pr-badge")
        window.close()
    }

    @Test func changesShowsFilesAndDiff() async throws {
        let (_, wc, window) = try await openWindow()
        wc.showChanges(nil)
        await UI.settle(window)
        let changes = try #require(wc.testRoot.main?.content.changes)
        #expect(changes.testUnstaged.map(\.path).sorted() == ["a.txt", "new.txt"])
        #expect(changes.testStaged.map(\.path) == ["src/b.swift"])
        await UI.wait("diff rows") { changes.diffVC.testRowCount > 0 }
        await UI.settle(window)
        UI.snapshot(window, "changes")

        let body = changes.diffVC.testBody
        #expect(!body.isHidden)
        // The commit button must be fully inside the left column.
        let button = changes.testCommitButton
        let column = try #require((changes.view as? NSSplitView)?.arrangedSubviews.first)
        #expect(column.frame.width >= 360, "left column \(column.frame.width)")
        let inColumn = button.convert(button.bounds, to: column)
        #expect(column.bounds.contains(inColumn), "commit button \(inColumn) outside \(column.bounds)")
        let diffColors = UI.sampleColors(changes.diffVC.view)
        #expect(diffColors.count > 3, "diff area renders only \(diffColors.sorted())")
        // Text must start right of the line-number gutter, not underneath it.
        for scroll in [body.leftScroll, body.rightScroll] {
            let clip = scroll.contentView
            #expect(abs(clip.bounds.origin.x + clip.contentInsets.left) < 1,
                    "clip x \(clip.bounds.origin.x), gutter inset \(clip.contentInsets.left)")
        }
        #expect(body.rightScroll.frame.width > 100, "right pane width \(body.rightScroll.frame.width)")

        changes.diffVC.toggleUnified()
        await UI.settle(window)
        UI.snapshot(window, "changes-unified")
        changes.diffVC.toggleUnified()

        // Syntax highlighting on the staged Swift file
        let swiftFile = try #require(changes.testStaged.first { $0.path == "src/b.swift" })
        changes.diffVC.show(.working(swiftFile, staged: true))
        await UI.wait("syntax spans") { changes.diffVC.testSyntaxLineCount > 0 }
        await UI.settle(window)
        UI.snapshot(window, "changes-syntax")
        window.close()
    }

    @Test func longNamesWrapAndRowsGrow() async throws {
        UI.setUpApp()
        let dir = try Fixture.makeRepo()
        let longBranch = "topic/a-really-long-branch-name-that-cannot-possibly-fit-into-the-sidebar-width"
        try Fixture.git(["branch", longBranch, "main"], in: dir)
        let longPath = "src/a-very-long-file-name-that-will-definitely-need-to-wrap-onto-a-second-line-in-the-list.txt"
        try Fixture.write(dir, longPath, "x\n")
        let repo = try await Repository.open(dir)
        let wc = RepoWindowController(repository: repo)
        let window = try #require(wc.window)
        window.setContentSize(NSSize(width: 1280, height: 800))
        await repo.refreshAll()
        wc.showChanges(nil)
        await UI.settle(window)
        UI.snapshot(window, "wrapping")

        // Sidebar: the long branch row must be taller than a single line and contain its text.
        let outline = try #require(UI.find(NSOutlineView.self, in: window.contentView!))
        let row = try #require((0..<outline.numberOfRows).first {
            (outline.item(atRow: $0) as? SidebarNode)?.title == longBranch })
        let rect = outline.rect(ofRow: row)
        #expect(rect.height > 30, "branch row height \(rect.height)")
        if let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView,
           let tf = cell.textField {
            #expect(tf.frame.height <= rect.height + 0.5, "label \(tf.frame.height) taller than row \(rect.height)")
            #expect(tf.frame.height > 20)
        }

        // Changes list: the long untracked file name wraps too.
        let changes = try #require(wc.testRoot.main?.content.changes)
        let table = try #require(changes.testUnstagedTable)
        let fileRow = try #require(changes.testUnstaged.firstIndex { $0.path.hasPrefix("src/") })
        let fileRect = table.rect(ofRow: fileRow)
        #expect(fileRect.height > 25, "file row height \(fileRect.height)")
        window.close()
    }

    @Test func openTabsSurviveQuit() async throws {
        UI.setUpApp()
        let defaults = try #require(UserDefaults(suiteName: "SwiftGitTests-\(UUID().uuidString)"))
        let a = try Fixture.makeRepo(), b = try Fixture.makeRepo()

        let first = AppDelegate(defaults: defaults, presentsWindows: false)
        await first.open(a, select: true)
        await first.open(b, select: true)
        #expect(defaults.stringArray(forKey: "openRepositories") == [a.path, b.path])

        // Quit: AppKit asks, then closes every tab window before exiting.
        _ = first.applicationShouldTerminate(NSApplication.shared)
        for c in first.controllers { c.window?.close() }
        first.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        #expect(defaults.stringArray(forKey: "openRepositories") == [a.path, b.path])

        // Relaunch
        let second = AppDelegate(defaults: defaults, presentsWindows: false)
        await second.restoreOpenRepositories()
        #expect(second.controllers.map(\.repository.root.path) == [a.path, b.path])

        // Closing a tab normally (not quitting) forgets it.
        second.controllers.last?.window?.close()
        #expect(defaults.stringArray(forKey: "openRepositories") == [a.path])
        second.controllers.first?.window?.close()
    }

    @Test func backgroundTabUnloadsViews() async throws {
        let (repo, wc, window) = try await openWindow()
        #expect(wc.testRoot.main != nil)
        wc.testRoot.unloadContent()
        repo.dropCaches()
        #expect(wc.testRoot.main == nil)
        wc.testRoot.loadContentIfNeeded()
        await UI.settle(window)
        #expect(wc.testRoot.main?.content.history != nil)
        let bytes = repo.graph.approximateBytes
        #expect(bytes < 5_000_000)
        window.close()
    }

    @Test func pullRequestDefaultsToEarliestCommit() async throws {
        UI.setUpApp()
        let dir = try Fixture.makeRepo()
        try Fixture.git(["remote", "add", "origin", "https://github.com/acme/widgets.git"], in: dir)
        try Fixture.git(["update-ref", "refs/remotes/origin/main", "main"], in: dir)
        try Fixture.git(["switch", "-q", "-c", "topic/pr"], in: dir)
        try Fixture.write(dir, "one.txt", "1\n")
        try Fixture.git(["add", "one.txt"], in: dir)
        try Fixture.git(["commit", "-q", "-m", "First change", "-m", "Why it matters.", "--", "one.txt"], in: dir)
        try Fixture.write(dir, "two.txt", "2\n")
        try Fixture.git(["add", "two.txt"], in: dir)
        try Fixture.git(["commit", "-q", "-m", "Second change", "--", "two.txt"], in: dir)
        try Fixture.git(["switch", "-q", "main"], in: dir)
        let repo = try await Repository.open(dir)
        await repo.refreshAll()
        #expect(repo.gitHubRemote?.repo == GitHubRepo(owner: "acme", name: "widgets"))

        let sheet = PullRequestSheet(repository: repo, head: "topic/pr")
        sheet.loadsGitHubData = false
        sheet.load()
        await UI.wait("default title") { !sheet.testIsUpdating && !sheet.testTitle.isEmpty }
        #expect(sheet.testTitle == "First change")
        #expect(sheet.testBody == "Why it matters.")

        // Switching branches replaces untouched defaults…
        sheet.testSelect(head: "feature")
        await UI.wait("feature defaults") { !sheet.testIsUpdating }
        #expect(sheet.testTitle == "Feature: notes")  // merged branch: falls back to its last commit
        // …but not a title the user typed.
        sheet.testSetTitle("My own title")
        sheet.testSelect(head: "topic/pr")
        await UI.wait("topic defaults") { !sheet.testIsUpdating }
        #expect(sheet.testTitle == "My own title")
        #expect(sheet.testBody == "Why it matters.")
        if let w = sheet.window {
            w.setContentSize(NSSize(width: 620, height: 640))
            await UI.settle(w)
            UI.snapshot(w, "pull-request")
        }
        sheet.window?.close()
    }

    @Test func pullRequestForRewrittenBranchOffersForcePush() async throws {
        UI.setUpApp()
        let dir = try Fixture.makeRepo()
        try Fixture.git(["remote", "add", "origin", "https://github.com/acme/widgets.git"], in: dir)
        try Fixture.git(["update-ref", "refs/remotes/origin/main", "main"], in: dir)
        try Fixture.git(["switch", "-q", "-c", "topic/rebased"], in: dir)
        try Fixture.write(dir, "r.txt", "1\n")
        try Fixture.git(["add", "r.txt"], in: dir)
        try Fixture.git(["commit", "-q", "-m", "feat: draft work", "--", "r.txt"], in: dir)
        // "Pushed" earlier, then rewritten locally.
        try Fixture.git(["update-ref", "refs/remotes/origin/topic/rebased", "HEAD"], in: dir)
        try Fixture.git(["config", "branch.topic/rebased.remote", "origin"], in: dir)
        try Fixture.git(["config", "branch.topic/rebased.merge", "refs/heads/topic/rebased"], in: dir)
        try Fixture.git(["commit", "-q", "--amend", "--only", "-m", "feat: draft work (rebased)"], in: dir)
        try Fixture.git(["switch", "-q", "main"], in: dir)
        let repo = try await Repository.open(dir)
        await repo.refreshAll()

        let sheet = PullRequestSheet(repository: repo, head: "topic/rebased")
        sheet.loadsGitHubData = false
        sheet.load()
        await UI.wait("defaults") { !sheet.testIsUpdating && !sheet.testTitle.isEmpty }
        #expect(sheet.testPushTitle == "Force push branch first")
        #expect(sheet.testPushOn)
        #expect(sheet.testNote.contains("rewritten"), "\(sheet.testNote)")
        #expect(sheet.testCreateTitle == "Create Pull Request")

        // An already open draft PR switches the sheet to updating it.
        let pr = GitHub.ExistingPullRequest(number: 42, url: "https://github.com/acme/widgets/pull/42",
                                            title: "feat: the draft PR", body: "Existing description", isDraft: true,
                                            base: "main", reviewers: ["alice"])
        sheet.setExisting(pr)
        #expect(sheet.testCreateTitle == "Update Pull Request")
        #expect(sheet.testTitle == "feat: the draft PR")
        #expect(sheet.testBody == "Existing description")
        #expect(sheet.testSelectedReviewers == ["alice"])
        #expect(sheet.testNote.contains("#42"))
        if let w = sheet.window {
            await UI.settle(w)
            UI.snapshot(w, "pull-request-update")
        }
        sheet.setExisting(nil)
        await UI.wait("defaults again") { !sheet.testIsUpdating }
        #expect(sheet.testCreateTitle == "Create Pull Request")
        #expect(sheet.testTitle == "feat: draft work (rebased)")
        sheet.window?.close()
    }

    @Test func settingsWindowAndRecoverSheetRender() async throws {
        UI.setUpApp()
        let saved = Settings.defaults
        defer { Settings.defaults = saved }
        Settings.defaults = try #require(UserDefaults(suiteName: "SwiftGitSettingsUI-\(UUID().uuidString)"))
        let settings = SettingsWindowController.shared
        settings.load()
        settings.testSet(pull: .rebase, autostash: true, model: "sonnet")
        #expect(Settings.pullMode == .rebase && Settings.autostash && Settings.claudeModel == "sonnet")
        if let w = settings.window {
            await UI.settle(w)
            UI.snapshot(w, "settings")
        }

        let (repo, wc, window) = try await openWindow()
        let a = try #require(repo.status.unstaged.first { $0.path == "a.txt" })
        await repo.discard([a])
        #expect(repo.undoCandidate == nil)
        let sheet = DiscardedChangesSheet(repository: repo)
        sheet.reload()
        await UI.wait("entries") { sheet.testEntries.count == 1 }
        if let w = sheet.window {
            w.setContentSize(NSSize(width: 560, height: 420))
            await UI.settle(w)
            UI.snapshot(w, "recover-discarded")
        }
        _ = wc
        window.close()
    }

    @Test func historySearchAndFileHistory() async throws {
        let (repo, wc, window) = try await openWindow()
        let history = try #require(wc.testRoot.main?.content.history)

        wc.findInHistory(nil)
        #expect(history.testSearchVisible)
        history.showSearch("feature")
        await UI.wait("matches") { history.testMatchCount == 3 }   // 2 feature commits + "Merge feature"
        #expect(history.testMatchLabel.hasSuffix("of 3") || history.testMatchLabel == "3 matches")
        let head = try #require(repo.headHash)
        let initial = try #require(repo.graph.row(of: head))
        #expect(!history.testIsDimmed(row: initial))   // "Merge feature" (HEAD) matches
        let secondHash = try #require(Hash20(try Fixture.git(["rev-parse", "main~2"], in: repo.root).trimmingCharacters(in: .whitespacesAndNewlines)))
        let secondRow = try #require(repo.graph.row(of: secondHash))
        #expect(history.testIsDimmed(row: secondRow))
        history.moveToMatch(forward: true)
        #expect(history.testMatchLabel.contains(" of 3"))
        UI.snapshot(window, "history-search")

        // Hash prefix
        let second = repo.graph.hashes[secondRow]
        history.showSearch(String(second.hex.prefix(7)))
        await UI.wait("hash match") { history.testMatchCount == 1 }
        #expect(history.testSelectedHash == second)

        // File history: commits that touched docs/notes.md, with that file selected.
        let notes = try #require(repo.localBranches.first { $0.name == "feature" }.flatMap { Hash20($0.target) })
        wc.showFileHistory("docs/notes.md")
        await UI.wait("file history") { history.testSelectedHash == notes }
        #expect(history.testMatchCount == 1)
        await UI.wait("file preselected") { history.detail.testSelectedFile == "docs/notes.md" }
        history.showSearch("file:a.txt")
        await UI.wait("a.txt history") { history.testMatchCount == 2 }
        UI.snapshot(window, "file-history")

        history.closeSearch(nil)
        #expect(!history.testSearchVisible)
        #expect(!history.testIsDimmed(row: secondRow))
        #expect(wc.state.historySearch == nil)
        window.close()
    }

    @Test func conflictedFileShowsResolutionButtons() async throws {
        UI.setUpApp()
        let dir = try Fixture.makeRepo()
        try Fixture.git(["stash", "-q", "--include-untracked"], in: dir)
        try Fixture.git(["switch", "-q", "-c", "topic/c"], in: dir)
        try Fixture.write(dir, "c.md", "topic\n")
        try Fixture.git(["commit", "-q", "-am", "topic change"], in: dir)
        try Fixture.git(["switch", "-q", "main"], in: dir)
        try Fixture.write(dir, "c.md", "main\n")
        try Fixture.git(["commit", "-q", "-am", "main change"], in: dir)
        let repo = try await Repository.open(dir)
        let wc = RepoWindowController(repository: repo)
        let window = try #require(wc.window)
        await repo.refreshAll()
        await repo.merge("topic/c")
        let c = try #require(repo.status.conflicts.first)
        let diff = DiffViewController(repository: repo)
        window.contentViewController = diff
        window.setContentSize(NSSize(width: 900, height: 500))
        diff.show(.working(c, staged: false))
        await UI.wait("conflict buttons") { diff.testConflictButtons != nil }
        #expect(diff.testConflictButtons == ["Keep main", "Take topic/c", "Open Merge Tool", "Edit File", "Mark Resolved"])
        #expect(diff.testPlaceholder?.contains("Both sides changed the same lines.") == true)
        await UI.settle(window)
        UI.snapshot(window, "conflict")
        window.close()
    }

    @Test func rewriteCommitsSheetRenders() async throws {
        let (repo, wc, window) = try await openWindow()
        _ = wc
        let first = try Fixture.git(["rev-parse", "main~1"], in: repo.root).trimmingCharacters(in: .whitespacesAndNewlines)
        try Fixture.git(["switch", "-q", "-c", "topic/s"], in: repo.root)
        try Fixture.write(repo.root, "s.txt", "1\n")
        try Fixture.git(["add", "s.txt"], in: repo.root)
        try Fixture.git(["commit", "-q", "-m", "fix: s", "--", "s.txt"], in: repo.root)
        await repo.refreshAll()
        // From the merge commit: refused (merges in range).
        if case .success = await repo.rewritePlan(from: first) { Issue.record("expected refusal") }
        let tip = try Fixture.git(["rev-parse", "HEAD"], in: repo.root).trimmingCharacters(in: .whitespacesAndNewlines)
        let plan = try await repo.rewritePlan(from: tip).get()
        let sheet = RewriteCommitsSheet(repository: repo, plan: plan)
        sheet.testSet(0, .reword, message: "fix: better message")
        if let w = sheet.window {
            await UI.settle(w)
            UI.snapshot(w, "edit-commits")
        }
        #expect(sheet.steps.first?.action == .reword)
        window.close()
    }

    @Test func pullAfterBranchWasMergedAndDeletedOffersDefaultBranch() async throws {
        UI.setUpApp()
        let dir = try Fixture.makeRepo()
        try Fixture.git(["stash", "-q", "--include-untracked"], in: dir)
        let parent = dir.deletingLastPathComponent()
        let bare = parent.appendingPathComponent(dir.lastPathComponent + "-gone.git")
        let other = parent.appendingPathComponent(dir.lastPathComponent + "-gone-other")
        try Fixture.git(["init", "-q", "--bare", bare.path], in: parent)
        try Fixture.git(["remote", "add", "origin", bare.path], in: dir)
        try Fixture.git(["push", "-q", "-u", "origin", "main"], in: dir)
        try Fixture.git(["remote", "set-head", "origin", "main"], in: dir)
        try Fixture.git(["switch", "-q", "-c", "topic/pr"], in: dir)
        try Fixture.write(dir, "pr.txt", "pr\n")
        try Fixture.git(["add", "pr.txt"], in: dir)
        try Fixture.git(["commit", "-q", "-m", "feat: pr work"], in: dir)
        try Fixture.git(["push", "-q", "-u", "origin", "topic/pr"], in: dir)
        // Elsewhere: squash-merge the PR into main and delete its branch.
        try Fixture.git(["clone", "-q", bare.path, other.path], in: parent)
        try Fixture.git(["merge", "-q", "--squash", "origin/topic/pr"], in: other)
        try Fixture.git(["commit", "-q", "-m", "feat: pr work (#1)"], in: other)
        try Fixture.git(["push", "-q", "origin", "main", ":topic/pr"], in: other)

        let repo = try await Repository.open(dir)
        let wc = RepoWindowController(repository: repo)
        await repo.refreshAll()
        #expect(repo.currentBranch == "topic/pr")
        #expect(repo.defaultBranch?.local == "main")

        // Without a pruning fetch git doesn't know yet: pull fails and is explained.
        Prompt.headlessLog = []
        Prompt.headlessAnswers = [0]   // "Switch to main and Pull", delete option at its default (on: merged)
        await wc.pullInteractively(mode: .merge)
        #expect(Prompt.headlessLog.first?.hasPrefix("topic/pr was deleted on the remote") == true, "\(Prompt.headlessLog)")
        #expect(Prompt.headlessLog.first?.contains("squash") == true, "\(Prompt.headlessLog)")
        #expect(repo.currentBranch == "main")
        #expect(repo.localBranch(named: "topic/pr") == nil)
        #expect(repo.status.behind == 0)
        #expect(try Fixture.git(["log", "-1", "--format=%s"], in: dir).trimmingCharacters(in: .whitespacesAndNewlines) == "feat: pr work (#1)")
        // Deleting the branch can be undone.
        #expect(repo.undoStack.contains { if case .deleteBranch("topic/pr", _) = $0.kind { return true } else { return false } })
        Prompt.headlessAnswers = []
        wc.window?.close()
    }

    @Test func veryLongLinesDrawQuickly() async throws {
        UI.setUpApp()
        let dir = try Fixture.makeRepo()
        let item = #"{"id":1,"name":"item","tags":["a","b"]},"#
        let before = "[" + String(repeating: item, count: 30_000) + "{}]\n"   // 1.2 MB line, under the 3 MB diff limit
        try Fixture.write(dir, "data.json", before)
        try Fixture.git(["add", "data.json"], in: dir)
        try Fixture.git(["commit", "-q", "-m", "data", "--", "data.json"], in: dir)
        try Fixture.write(dir, "data.json", before.replacingOccurrences(of: "{}]", with: #"{"id":2}]"#))
        let repo = try await Repository.open(dir)
        await repo.refreshAll()
        let change = try #require(repo.status.unstaged.first { $0.path == "data.json" })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        let diff = DiffViewController(repository: repo)
        window.contentViewController = diff
        diff.show(.working(change, staged: false))
        await UI.wait("rows", timeout: 20) { diff.testRowCount > 0 }
        await UI.settle(window)
        await UI.wait("syntax", timeout: 20) { diff.testSyntaxLineCount > 0 }
        let pane = diff.testBody.rightScroll.documentView!
        var times: [TimeInterval] = []
        for _ in 0..<5 {
            let start = Date()
            pane.display()
            times.append(Date().timeIntervalSince(start))
        }
        // Scroll far right and draw again.
        diff.testBody.rightScroll.contentView.scroll(to: NSPoint(x: 50_000, y: 0))
        let start = Date()
        pane.display()
        times.append(Date().timeIntervalSince(start))
        print("DIAG long line draw times:", times.map { String(format: "%.1f ms", $0 * 1000) })
        #expect(times.max()! < 0.1, "\(times)")
        UI.snapshot(window, "long-line")
        window.close()
    }
}

