import AppKit
import Testing
@testable import SwiftGitKit

/// Drives the real window controllers in an offscreen window (no screen
/// access needed), asserts on the view state and writes PNG snapshots.
@MainActor
@Suite("UI", .serialized)
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
}
