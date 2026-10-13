import Foundation
import Testing
@testable import SwiftGitKit

/// A repository with one linked worktree next to it.
enum WorktreeFixture {
    static func make(branch: String = "wt-branch") throws -> (main: URL, linked: URL) {
        let main = try Fixture.makeRepo()
        try Fixture.git(["stash", "-q", "--include-untracked"], in: main)
        let linked = main.deletingLastPathComponent().appendingPathComponent(main.lastPathComponent + "-wt")
        try Fixture.git(["worktree", "add", "-q", "-b", branch, linked.path], in: main)
        return (main, linked.resolvingSymlinksInPath())
    }
}

@MainActor
@Suite("Worktrees", .disabled(if: MemoryTests.measuring, "memory measurement run"))
struct WorktreeTests {
    @Test func linkedWorktreeIsDetected() async throws {
        let (main, linked) = try WorktreeFixture.make()
        let repo = try await Repository.open(linked)
        #expect(repo.isLinkedWorktree)
        #expect(repo.root.path == linked.path)
        #expect(repo.commonDir.path == main.appendingPathComponent(".git").path)
        #expect(repo.gitDir.path.hasPrefix(repo.commonDir.path + "/worktrees/"))
        #expect(repo.displayName == "\(main.lastPathComponent) › \(linked.lastPathComponent)")
        let mainRepo = try await Repository.open(main)
        #expect(!mainRepo.isLinkedWorktree)
        #expect(mainRepo.displayName == main.lastPathComponent)
        // Opening from a subfolder still finds the worktree root.
        try FileManager.default.createDirectory(at: linked.appendingPathComponent("sub"), withIntermediateDirectories: true)
        #expect(try await Repository.open(linked.appendingPathComponent("sub")).root.path == linked.path)
    }

    @Test func gitDirEventsAreClassified() {
        typealias C = Repository.GitDirChange
        func own(_ s: String) -> C { Repository.classify(Substring(s), own: true) }
        func shared(_ s: String) -> C { Repository.classify(Substring(s), own: false) }
        #expect(own("/index") == .status)
        #expect(own("/HEAD") == .refs)
        #expect(own("/rebase-merge/done") == .refs)
        #expect(own("/objects/ab/cdef") == .ignore)
        #expect(own("/logs/HEAD") == .ignore)
        #expect(own("/worktrees/other/index") == .ignore)
        #expect(own("/worktrees/other/HEAD") == .refs)
        #expect(own("/worktrees/new") == .refs)
        #expect(shared("/refs/heads/main") == .refs)
        #expect(shared("/packed-refs") == .refs)
        #expect(shared("/HEAD") == .refs)
        #expect(shared("/index") == .ignore)
        #expect(shared("/MERGE_HEAD") == .ignore)
    }

    @Test func commitsInAnotherWorktreeAreSeen() async throws {
        let (main, linked) = try WorktreeFixture.make()
        let repo = try await Repository.open(linked)
        repo.start()
        defer { repo.stop() }
        await UI.wait("first refresh") { repo.localBranch(named: "main") != nil }
        let before = repo.localBranch(named: "main")?.target
        try Fixture.write(main, "elsewhere.txt", "x\n")
        try Fixture.git(["add", "elsewhere.txt"], in: main)
        try Fixture.git(["commit", "-q", "-m", "made in the main worktree"], in: main)
        let after = try Fixture.git(["rev-parse", "main"], in: main).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(before != after)
        await UI.wait("ref change seen", timeout: 10) { repo.localBranch(named: "main")?.target == after }
    }

    @Test func discardedChangesArePerWorktree() async throws {
        let (main, linked) = try WorktreeFixture.make()
        let a = try await Repository.open(main)
        let b = try await Repository.open(linked)
        try Fixture.write(main, "a.txt", "changed in main\n")
        try Fixture.write(linked, "a.txt", "changed in linked\n")
        await a.refreshAll(); await b.refreshAll()
        await a.discard(a.status.unstaged)
        await b.discard(b.status.unstaged)
        let la = await a.discardedChanges(), lb = await b.discardedChanges()
        #expect(la.count == 1 && lb.count == 1)
        #expect(la.first?.sha != lb.first?.sha)

        // Snapshots in the old shared ref move to the main worktree's own.
        // (any commit will do; it must differ from the current snapshot or git logs nothing)
        let sha = try Fixture.git(["rev-parse", "HEAD"], in: main).trimmingCharacters(in: .whitespacesAndNewlines)
        try Fixture.git(["update-ref", "--create-reflog", "-m", "Discard old.txt", Repository.legacyDiscardRef, sha], in: main)
        await b.migrateLegacyDiscards()   // linked worktrees leave it alone
        #expect((try? Fixture.git(["rev-parse", "-q", "--verify", Repository.legacyDiscardRef], in: main)) != nil)
        await a.migrateLegacyDiscards()
        #expect((try? Fixture.git(["rev-parse", "-q", "--verify", Repository.legacyDiscardRef], in: main)) == nil)
        #expect(await a.discardedChanges().map(\.summary) == ["Discard old.txt", "Discard a.txt"])
        #expect(await b.discardedChanges().count == 1)
    }

    @Test func backgroundFetchIsSharedBetweenWorktrees() async throws {
        let (main, linked) = try WorktreeFixture.make()
        let bare = main.deletingLastPathComponent().appendingPathComponent(main.lastPathComponent + "-origin.git")
        try Fixture.git(["clone", "-q", "--bare", main.path, bare.path], in: main.deletingLastPathComponent())
        try Fixture.git(["remote", "add", "origin", bare.path], in: main)
        let a = try await Repository.open(main)
        let b = try await Repository.open(linked)
        await a.refreshAll(); await b.refreshAll()
        a.fetchInBackground(minInterval: 0)
        #expect(a.isFetchingInBackground && b.isFetchingInBackground)
        await UI.wait("fetch") { !a.isFetchingInBackground }
        // The other tab's focus right after doesn't fetch again (throttle is shared).
        b.fetchInBackground()
        #expect(!b.isFetchingInBackground)
    }

    // MARK: Phase 2 & 3: listing and managing worktrees

    @Test func porcelainListIsParsed() {
        let text = "worktree /r/main\0HEAD 1111\0branch refs/heads/main\0\0"
            + "worktree /r/wt\0HEAD 2222\0detached\0locked on a USB disk\0\0"
            + "worktree /r/gone\0HEAD 3333\0branch refs/heads/feature/x\0locked\0prunable gitdir file points to non-existent location\0\0"
        let list = WorktreeInfo.parse(Data(text.utf8))
        #expect(list.count == 3)
        #expect(list[0].isMain && list[0].branch == "main" && list[0].head == "1111")
        #expect(!list[1].isMain && list[1].isDetached && list[1].branch == nil && list[1].lockReason == "on a USB disk")
        #expect(list[2].branch == "feature/x" && list[2].isLocked && list[2].lockReason == nil && list[2].isPrunable)
        #expect(list[2].name == "gone")
        let bare = WorktreeInfo.parse(Data("worktree /r/x.git\0bare\0\0".utf8))
        #expect(bare.first?.isBare == true && bare.first?.isMain == true)
        #expect(samePath("/private/var/x/", "/var/x"))
    }

    @Test func worktreesAndTheirBranchesAreKnown() async throws {
        let (main, linked) = try WorktreeFixture.make()
        let a = try await Repository.open(main)
        let b = try await Repository.open(linked)
        await a.refreshAll(); await b.refreshAll()
        #expect(a.worktrees.count == 2)
        #expect(a.currentWorktree?.isMain == true)
        #expect(samePath(a.worktreeUsing(branch: "wt-branch")?.path ?? "", linked.path))
        #expect(a.worktreeUsing(branch: "main") == nil)
        #expect(samePath(b.worktreeUsing(branch: "main")?.path ?? "", main.path))
        #expect(b.currentWorktree?.branch == "wt-branch")
        // Git's refusal is turned into an explanation naming the other worktree.
        let r = await a.git.run(["switch", "wt-branch"])
        #expect(!r.ok)
        #expect(samePath(WorktreeProblem.busyWorktreePath(r.errorMessage) ?? "", linked.path))
        #expect(WorktreeProblem.explain(r.errorMessage)?.contains(linked.lastPathComponent) == true)
        #expect(WorktreeProblem.explain("fatal: something else") == nil)
    }

    @Test func worktreeIsAddedLockedMovedAndRemoved() async throws {
        let main = try Fixture.makeRepo()
        try Fixture.git(["stash", "-q", "--include-untracked"], in: main)
        let repo = try await Repository.open(main)
        await repo.refreshAll()
        let path = repo.defaultWorktreePath(for: "topic/x")
        #expect(path.lastPathComponent == "topic-x")
        #expect(path.deletingLastPathComponent().lastPathComponent == main.lastPathComponent + ".worktrees")
        let added = await repo.addWorktree(at: path, .new(name: "topic/x", start: "main", track: false))
        #expect(added.ok, "\(added.errorMessage)")
        #expect(FileManager.default.fileExists(atPath: path.appendingPathComponent("a.txt").path))
        var wt = try #require(repo.worktreeUsing(branch: "topic/x"))
        #expect(!wt.isMain)

        #expect(await repo.lockWorktree(wt, reason: "on a USB disk"))
        wt = try #require(repo.worktreeUsing(branch: "topic/x"))
        #expect(wt.isLocked && wt.lockReason == "on a USB disk")
        #expect(await repo.unlockWorktree(wt))
        wt = try #require(repo.worktreeUsing(branch: "topic/x"))
        #expect(!wt.isLocked)

        let moved = main.deletingLastPathComponent().appendingPathComponent(main.lastPathComponent + "-moved")
        #expect(await repo.moveWorktree(wt, to: moved))
        wt = try #require(repo.worktreeUsing(branch: "topic/x"))
        #expect(samePath(wt.path, moved.resolvingSymlinksInPath().path) || samePath(wt.path, moved.path))

        // Changes and a commit of its own.
        try Fixture.write(moved, "new.txt", "x\n")
        try Fixture.write(moved, "a.txt", "changed\n")
        var state = await repo.worktreeState(wt)
        #expect(Set(state.changedFiles) == ["new.txt", "a.txt"])
        #expect(state.unpushedCommits == 0)
        try Fixture.git(["commit", "-q", "-am", "work"], in: moved)
        state = await repo.worktreeState(wt)
        #expect(state.changedFiles == ["new.txt"])
        #expect(state.unpushedCommits == 1)

        // Its changes are stashed (stashes are shared), then it is removed even though locked.
        #expect(await repo.lockWorktree(wt, reason: nil))
        wt = try #require(repo.worktreeUsing(branch: "topic/x"))
        let stashes = repo.stashes.count
        #expect(await repo.stashChanges(in: wt, message: "SwiftGit: changes from topic-x"))
        #expect(repo.stashes.count == stashes + 1)
        #expect(await repo.removeWorktree(wt, force: true))
        #expect(!FileManager.default.fileExists(atPath: moved.path))
        #expect(repo.worktrees.count == 1)
        #expect(repo.localBranch(named: "topic/x") != nil)
    }

    @Test func missingWorktreeIsPruned() async throws {
        let (main, linked) = try WorktreeFixture.make()
        let repo = try await Repository.open(main)
        try FileManager.default.removeItem(at: linked)
        await repo.refreshAll()
        let wt = try #require(repo.worktreeUsing(branch: "wt-branch"))
        #expect(wt.isPrunable)
        #expect(await repo.worktreeState(wt).missing)
        #expect(await repo.removeWorktree(wt, force: false))
        #expect(repo.worktrees.count == 1)
    }

    @Test func linkedWorktreeCanRemoveItself() async throws {
        let (main, linked) = try WorktreeFixture.make()
        let repo = try await Repository.open(linked)
        await repo.refreshAll()
        let me = try #require(repo.currentWorktree)
        #expect(await repo.removeWorktree(me, force: false))
        #expect(!FileManager.default.fileExists(atPath: linked.path))
        let mainRepo = try await Repository.open(main)
        await mainRepo.refreshAll()
        #expect(mainRepo.worktrees.count == 1)
    }

    // MARK: Phase 4: bare repositories

    @Test func bareRepositoryOffersItsWorktrees() async throws {
        let main = try Fixture.makeRepo()
        let folder = main.deletingLastPathComponent().appendingPathComponent("bare-\(UUID().uuidString.prefix(6))")
        let bare = folder.appendingPathComponent(".bare")
        try Fixture.git(["clone", "-q", "--bare", main.path, bare.path], in: main.deletingLastPathComponent())
        do {
            _ = try await Repository.open(bare)
            Issue.record("a bare repository can't be opened as a tab")
        } catch let e as Repository.BareRepository {
            #expect(samePath(e.commonDir.path, bare.resolvingSymlinksInPath().path))
        }
        #expect(await BareRepositoryWorktrees.worktrees(of: bare).isEmpty)
        #expect(await BareRepositoryWorktrees.branches(of: bare).contains("main"))
        let target = BareRepositoryWorktrees.defaultFolder(bare, branch: "main")
        #expect(target.path == folder.appendingPathComponent("main").path)
        #expect(await BareRepositoryWorktrees.addWorktree(bare, path: target, branch: "main").ok)
        let list = await BareRepositoryWorktrees.worktrees(of: bare)
        #expect(list.count == 1 && list.first?.branch == "main")

        let repo = try await Repository.open(target)
        await repo.refreshAll()
        #expect(repo.isLinkedWorktree)
        #expect(repo.repositoryName == folder.lastPathComponent)
        #expect(repo.openableWorktrees.count == 1)
        #expect(repo.defaultWorktreePath(for: "x").path == folder.appendingPathComponent("x").path)
        // "repo.git" layout: worktrees go in "repo.worktrees".
        let dotGit = main.deletingLastPathComponent().appendingPathComponent("plain.git")
        #expect(BareRepositoryWorktrees.defaultFolder(dotGit, branch: "a/b").path
                == main.deletingLastPathComponent().appendingPathComponent("plain.worktrees/a-b").path)
    }
}
