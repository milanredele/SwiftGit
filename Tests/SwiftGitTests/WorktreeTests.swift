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
}
