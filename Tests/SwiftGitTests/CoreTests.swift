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

    @Test func syntaxLanguagesLoad() {
        let h = SyntaxHighlighter.shared
        for path in ["a.swift", "a.js", "a.ts", "a.tsx", "a.py", "a.go", "a.rs", "a.c", "a.cpp",
                     "a.java", "a.json", "a.sh", "a.rb", "a.css", "a.html", "a.cs"] {
            #expect(h.isSupported(path: path), "no highlighting for \(path)")
        }
        #expect(!h.isSupported(path: "README"))
    }

    @Test func intralineHighlightsChangedWord() {
        let (old, new) = Intraline.compute("    let value = 1", "    let value = 2")
        #expect(old == [NSRange(location: 16, length: 1)])
        #expect(new == [NSRange(location: 16, length: 1)])
    }

    @Test func gitHubRemoteParsing() {
        #expect(GitHubRepo.parse(remoteURL: "git@github.com:acme/widgets.git") == GitHubRepo(owner: "acme", name: "widgets"))
        #expect(GitHubRepo.parse(remoteURL: "https://github.com/acme/widgets") == GitHubRepo(owner: "acme", name: "widgets"))
        #expect(GitHubRepo.parse(remoteURL: "ssh://git@github.com/acme/widgets.git/") == GitHubRepo(owner: "acme", name: "widgets"))
        #expect(GitHubRepo.parse(remoteURL: "git@gitlab.com:acme/widgets.git") == nil)
    }
}
