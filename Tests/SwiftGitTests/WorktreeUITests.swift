import AppKit
import Testing
@testable import SwiftGitKit

/// Worktree UI flows; part of the serialized UI suite because they answer
/// the headless prompts (global state).
extension UITests {
    private func app() throws -> AppDelegate {
        UI.setUpApp()
        let defaults = try #require(UserDefaults(suiteName: "SwiftGitTests-\(UUID().uuidString)"))
        return AppDelegate(defaults: defaults, presentsWindows: false)
    }

    private func closeAll(_ app: AppDelegate) {
        for c in app.controllers { c.window?.close() }
        Prompt.headlessAnswers = []
    }

    @Test func sidebarShowsWorktreesAndBranchBadges() async throws {
        let (main, linked) = try WorktreeFixture.make()
        let app = try app()
        defer { closeAll(app) }
        await app.open(main, select: true)
        let wc = try #require(app.controllers.first)
        let window = try #require(wc.window)
        window.setContentSize(NSSize(width: 1280, height: 800))
        await UI.wait("worktrees") { wc.repository.worktrees.count == 2 && wc.repository.localBranch(named: "wt-branch") != nil }
        await UI.settle(window)
        let sidebar = try #require(wc.testRoot.main?.sidebar)
        let row = try #require(sidebar.testWorktreeRowText(named: linked.lastPathComponent))
        #expect(row.contains("⎇ wt-branch"), "\(row)")
        #expect(sidebar.testWorktreeRowText(named: main.lastPathComponent)?.contains("main") == true)
        #expect(sidebar.testRowText(named: "wt-branch")?.contains("⎇ \(linked.lastPathComponent)") == true,
                "\(sidebar.testRowText(named: "wt-branch") ?? "nil")")
        UI.snapshot(window, "sidebar-worktrees")

        // Context menus.
        let wtRow = try #require(sidebar.testRow { $0.kind == .worktree && $0.title == linked.lastPathComponent })
        let items = sidebar.testMenuTitles(row: wtRow)
        #expect(items.contains("Open in Tab") && items.contains("Remove…") && items.contains("Lock…") && items.contains("Move…"), "\(items)")
        let mainRow = try #require(sidebar.testRow { $0.kind == .worktree && $0.title == main.lastPathComponent })
        #expect(!sidebar.testMenuTitles(row: mainRow).contains("Remove…"))
        let branchRow = try #require(sidebar.testRow { $0.ref?.name == "wt-branch" })
        let branchItems = sidebar.testMenuTitles(row: branchRow)
        #expect(branchItems.contains("Open Worktree “\(linked.lastPathComponent)”") && !branchItems.contains("Checkout"), "\(branchItems)")
        let featureRow = try #require(sidebar.testRow { $0.ref?.name == "feature" })
        #expect(sidebar.testMenuTitles(row: featureRow).contains("New Worktree for feature…"))

        // Checking out a branch that another worktree has offers to open it instead.
        Prompt.headlessLog = []
        Prompt.headlessAnswers = [0]
        let ref = try #require(wc.repository.localBranch(named: "wt-branch"))
        wc.checkout(ref)
        await UI.wait("opened the other worktree") { app.controllers.count == 2 }
        #expect(Prompt.headlessLog.first?.hasPrefix("“wt-branch” is checked out in another worktree") == true, "\(Prompt.headlessLog)")
        #expect(wc.repository.currentBranch == "main")
        #expect(app.controllers.last?.repository.isLinkedWorktree == true)
        // Opening it again switches to the tab instead of adding one.
        await app.open(linked, select: true)
        #expect(app.controllers.count == 2)

        // Deleting it explains why that's blocked.
        Prompt.headlessLog = []
        wc.confirmDelete(ref)
        await UI.wait("explained") { !Prompt.headlessLog.isEmpty }
        #expect(Prompt.headlessLog.first?.contains("is checked out in the worktree") == true, "\(Prompt.headlessLog)")
        #expect(wc.repository.localBranch(named: "wt-branch") != nil)

        // Git's own error is explained too.
        let r = await wc.repository.git.run(["switch", "wt-branch"])
        #expect(WorktreeProblem.explain(r.errorMessage)?.contains("only one worktree") == true)
    }

    @Test func newWorktreeIsCreatedAndOpened() async throws {
        let main = try Fixture.makeRepo()
        try Fixture.git(["stash", "-q", "--include-untracked"], in: main)
        let app = try app()
        defer { closeAll(app) }
        await app.open(main, select: true)
        let wc = try #require(app.controllers.first)
        await UI.wait("refs") { wc.repository.localBranch(named: "feature") != nil }
        Prompt.headlessLog = []
        Prompt.headlessAnswers = [0]   // Create Worktree with the defaults
        wc.promptNewWorktree(branch: "feature")
        await UI.wait("worktree tab", timeout: 15) { app.controllers.count == 2 }
        #expect(app.controllers.count == 2, "\(Prompt.headlessLog)")
        let tab = try #require(app.controllers.last)
        await UI.wait("tab loaded") { tab.repository.currentBranch != nil }
        #expect(tab.repository.currentBranch == "feature")
        #expect(tab.repository.root.lastPathComponent == "feature")
        #expect(tab.repository.root.deletingLastPathComponent().lastPathComponent == main.lastPathComponent + ".worktrees")
        await wc.repository.refreshRefs()
        #expect(wc.repository.worktreeUsing(branch: "feature") != nil)

        // A name that isn't a branch yet becomes a new branch from the current one.
        #expect(wc.repository.worktreeBranch(for: "brand/new", start: nil) == .new(name: "brand/new", start: "main", track: false))
        #expect(wc.repository.worktreeBranch(for: "feature", start: nil) == .existing("feature"))

        // Removing it from its own tab: changes are stashed, the tab closes, main is shown.
        try Fixture.write(tab.repository.root, "wip.txt", "work in progress\n")
        await tab.repository.refreshAll()
        let me = try #require(tab.repository.currentWorktree)
        let state = await tab.repository.worktreeState(me)
        #expect(state.changedFiles == ["wip.txt"])
        await tab.removeWorktree(me, state: state, deleteBranch: false)
        await UI.wait("tab closed") { app.controllers.count == 1 }
        await wc.repository.refreshRefs()
        #expect(wc.repository.worktrees.count == 1)
        #expect(wc.repository.stashes.first?.message.contains("changes from worktree feature") == true,
                "\(wc.repository.stashes.map(\.message))")
        #expect(wc.repository.localBranch(named: "feature") != nil)
    }

    @Test func removeWorktreeFromAnotherTabDeletesItsBranch() async throws {
        let (main, linked) = try WorktreeFixture.make()
        let app = try app()
        defer { closeAll(app) }
        await app.open(main, select: true)
        await app.open(linked, select: false)
        #expect(app.controllers.count == 2)
        let wc = try #require(app.controllers.first)
        await UI.wait("worktrees") { wc.repository.worktrees.count == 2 }
        let wt = try #require(wc.repository.worktreeUsing(branch: "wt-branch"))
        Prompt.headlessLog = []
        Prompt.headlessAnswers = [0]
        wc.confirmRemoveWorktree(wt)
        await UI.wait("removed", timeout: 15) { wc.repository.worktrees.count == 1 }
        #expect(app.controllers.count == 1, "the worktree's own tab is closed")
        #expect(!FileManager.default.fileExists(atPath: linked.path))
        #expect(Prompt.headlessLog.first?.contains("No uncommitted changes") == true, "\(Prompt.headlessLog)")
        // wt-branch has no commits of its own and isn't merged-by-flag, so the
        // delete option defaulted off: the branch stays.
        #expect(wc.repository.localBranch(named: "wt-branch") != nil)
    }

    @Test func bareRepositoryOpensItsWorktrees() async throws {
        let source = try Fixture.makeRepo()
        let bare = source.deletingLastPathComponent().appendingPathComponent("bare-\(UUID().uuidString.prefix(6)).git")
        try Fixture.git(["clone", "-q", "--bare", source.path, bare.path], in: source.deletingLastPathComponent())
        let app = try app()
        defer { closeAll(app) }

        // No worktrees yet: explained, then "New Worktree…" › Create with the defaults.
        Prompt.headlessLog = []
        Prompt.headlessAnswers = [0, 0]
        await app.open(bare, select: true)
        #expect(Prompt.headlessLog.first?.contains("is a bare repository") == true, "\(Prompt.headlessLog)")
        #expect(app.controllers.count == 1)
        let first = try #require(app.controllers.first)
        #expect(first.repository.isLinkedWorktree)
        #expect(first.repository.root.deletingLastPathComponent().lastPathComponent == bare.deletingPathExtension().lastPathComponent + ".worktrees")

        // One worktree: opened directly (already open → no new tab).
        Prompt.headlessLog = []
        await app.open(bare, select: true)
        #expect(Prompt.headlessLog.isEmpty)
        #expect(app.controllers.count == 1)

        // Two: "Open All".
        await UI.wait("first loaded") { first.repository.currentBranch != nil }
        let other = first.repository.currentBranch == "feature" ? "main" : "feature"
        let second = BareRepositoryWorktrees.defaultFolder(bare, branch: other)
        #expect(await BareRepositoryWorktrees.addWorktree(bare, path: second, branch: other).ok)
        closeAll(app)
        Prompt.headlessAnswers = [0]
        await app.open(bare, select: true)
        #expect(app.controllers.count == 2)
        await UI.wait("both loaded") { app.controllers.allSatisfy { $0.repository.currentBranch != nil } }
        #expect(Set(app.controllers.map { $0.repository.currentBranch ?? "" }) == ["main", "feature"])
    }
}
