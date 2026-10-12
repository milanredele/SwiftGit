import Foundation
import Testing
@testable import SwiftGitKit

@Suite("TextMate", .serialized, .disabled(if: MemoryTests.measuring, "memory measurement run"))
struct TextMateTests {
    /// Style of the first occurrence of `token` on a line.
    static func style(_ spans: [Int: [SyntaxSpan]], line: Int, _ text: String, _ token: String) -> SyntaxStyle? {
        let lines = text.components(separatedBy: "\n")
        guard line - 1 < lines.count, let r = lines[line - 1].range(of: token) else { return nil }
        let col = lines[line - 1].utf16.distance(from: lines[line - 1].startIndex, to: r.lowerBound)
        return spans[line]?.first { Int($0.start) <= col && col < Int($0.start + $0.length) }?.style
    }

    @Test func onigurumaRegex() throws {
        let r = TMRegex(#"(?<word>\w+)\s*=\s*(\d+)"#)
        #expect(r.isValid)
        let text = Array("  answer = 42\n".utf8)
        let found = try #require(text.withUnsafeBufferPointer { r.search($0.baseAddress!, length: $0.count, from: 0) })
        let m = r.withGroups(found)
        #expect(m.start == 2 && m.end == 13)
        #expect(m.groups[1] == (2, 8) && m.groups[2] == (11, 13))
        #expect(!TMRegex("(unclosed").isValid)
        #expect(TMRegex("(unclosed").error != nil)
        // \G only where allowed; elsewhere it becomes a never-matching character.
        #expect(TMPattern.replaceEscape("G", in: #"\Gfoo\\G\d"#) == #"\x{FFFF}foo\\G\d"#)
        #expect(TMPattern.escapeLiteral("a.b*c") == #"a\.b\*c"#)
        // Lookbehind, possessive and Unicode classes (common in grammars).
        #expect(TMRegex(#"(?<=\.)\p{Lu}[\p{L}\d_]*+"#).isValid)
    }

    /// A small grammar using the features the tokenizer implements.
    static let testGrammar: [String: Any] = [
        "scopeName": "source.test",
        "patterns": [
            ["include": "#comment"],
            ["include": "#heredoc"],
            ["include": "#quote"],
            ["match": #"\b(let)\s+([a-z]+)"#, "captures": ["1": ["name": "keyword.other"], "2": ["name": "entity.name.function"]]],
            ["begin": "\"", "end": "\"", "name": "string.quoted.double", "patterns": [["match": #"\\."#, "name": "constant.character.escape"]]],
            ["begin": #"\("#, "end": #"\)"#, "patterns": [["include": "$self"]]],
            ["match": #"\b\d+\b"#, "name": "constant.numeric"],
        ],
        "repository": [
            "comment": ["match": "#.*$", "name": "comment.line"],
            "heredoc": [
                "begin": #"<<([A-Z]+)"#, "end": #"^\1$"#,
                "beginCaptures": ["0": ["name": "keyword.operator.heredoc"], "1": ["name": "entity.name.tag"]],
                "contentName": "string.unquoted.heredoc",
            ],
            "quote": ["begin": "^>", "while": "^>", "name": "markup.quote",
                      "patterns": [["match": #"\bTODO\b"#, "name": "keyword.todo"]]],
        ],
    ]

    @Test func tokenizerFeatures() throws {
        let registry = TMRegistry(directory: URL(fileURLWithPath: "/nonexistent"))
        let grammar = TMGrammar(Self.testGrammar, registry: registry)
        let text = """
        let foo = "a\\"b" # note
        x = <<EOT
        not code 42
        EOT
        (let bar (42))
        > quoted TODO
        > still
        after 7
        """
        let raw = TMTokenizer(grammar: grammar).run(text, lines: Set(1...8))
        func style(_ line: Int, _ token: String) -> SyntaxStyle? {
            let l = text.components(separatedBy: "\n")[line - 1]
            guard let r = l.range(of: token) else { return nil }
            let b = l.utf8.distance(from: l.startIndex, to: r.lowerBound)
            return raw[line]?.first { $0.start <= b && b < $0.end }?.style
        }
        #expect(style(1, "let") == .keyword)
        #expect(style(1, "foo") == .function)
        #expect(style(1, "\\\"") == .escape)
        #expect(style(1, "b\"") == .string)
        #expect(style(1, "# note") == .comment)
        #expect(style(2, "EOT") == .tag)
        #expect(style(3, "42") == .string)          // inside the heredoc (back-referenced end)
        #expect(style(5, "let") == .keyword)        // $self inside parentheses
        #expect(style(5, "42") == .number)
        #expect(style(6, "quoted") == .comment)     // begin/while
        #expect(style(6, "TODO") == .keyword)
        #expect(style(7, "still") == .comment)
        #expect(style(8, "after") == nil)           // while ended
        #expect(style(8, "7") == .number)
    }

    @Test func bundledGrammarsLoadAndCompile() throws {
        let registry = TMRegistry()   // own instance: compiling here must not race the shared grammars
        let scopes = registry.allScopeNames
        #expect(scopes.count >= 25, "\(scopes)")
        var report: [String] = []
        for scope in scopes {
            let g = try #require(registry.grammar(scope: scope), "\(scope)")
            var total = 0, invalid: [String] = []
            var seen = Set<Int>()
            func walk(_ r: TMRule) {
                guard seen.insert(r.id).inserted else { return }
                for p in [r.match, r.begin, r.endPattern, r.whileRegex].compactMap({ $0 }) {
                    total += 1
                    let re = p.regex(atAnchor: true, atFileStart: true)
                    if !re.isValid { invalid.append("\(String(p.source.prefix(40))): \(re.error ?? "")") }
                }
                r.patterns.forEach(walk)
                r.repository.values.forEach(walk)
                for c in [r.captures, r.beginCaptures, r.endCaptures, r.whileCaptures] { c.values.forEach { $0.patterns.forEach(walk) } }
            }
            walk(g.root)
            report.append("\(scope): \(total) regexes" + (invalid.isEmpty ? "" : ", \(invalid.count) invalid: \(invalid.prefix(3))"))
            #expect(invalid.count * 20 <= max(total, 1), "\(scope): \(invalid)")
        }
        print("DIAG grammars\n" + report.joined(separator: "\n"))
    }

    @Test func scopeSelectors() {
        let s = TMSelector("text.html.php - (meta.embedded | meta.tag), L:((text.html.php meta.tag) - (meta.embedded.block.php | meta.embedded.line.php))")
        #expect(s.match(["text.html.php"]) == 1)
        #expect(s.match(["text.html.php", "meta.embedded.block.php"]) == nil)
        #expect(s.match(["text.html.php", "meta.tag.inline.a.html", "string.quoted"]) == -1)
        #expect(s.match(["source.js"]) == nil)
        #expect(TMSelector("R:text.html - (comment.block, meta.tag.*.*.html)").match(["text.html.basic"]) == 1)
        #expect(TMSelector("entity.other.attribute-name").match(["text.xml", "entity.other.attribute-name.localname.xml"]) == 1)
    }

    @Test func fileAssociations() {
        let r = TMRegistry.shared
        #expect(r.scopeName(forPath: "docker/Dockerfile") == "source.dockerfile")
        #expect(r.scopeName(forPath: "Dockerfile.prod") == "source.dockerfile")
        #expect(r.scopeName(forPath: "Makefile") == "source.makefile")
        #expect(r.scopeName(forPath: "ci/config.yml") == "source.yaml")
        #expect(r.scopeName(forPath: "README.md") == "text.html.markdown")
        #expect(r.scopeName(forPath: "index.php") == "text.html.php")
        #expect(r.scopeName(forPath: "App.csproj.user") == "text.xml")
        #expect(r.scopeName(forPath: "notes.txt") == nil)
        #expect(SyntaxHighlighter.shared.canHighlight(path: "build.gradle"))
        #expect(SyntaxHighlighter.shared.languageID(forPath: "logo.svg") == "html")   // tree-sitter wins
    }

    @Test func realLanguages() throws {
        func check(_ path: String, _ text: String, _ expectations: [(Int, String, SyntaxStyle?)]) throws {
            let spans = try #require(SyntaxHighlighter.shared.highlight(text, path: path, lines: Set(1...text.components(separatedBy: "\n").count)), "\(path)")
            for (line, token, style) in expectations {
                #expect(Self.style(spans, line: line, text, token) == style, "\(path) line \(line) “\(token)”: \(spans[line] ?? [])")
            }
        }
        try check("config.yml", "name: \"build\"   # the job\ncount: 12\nlist:\n  - true\n", [
            (1, "name", .tag), (1, "\"build\"", .string), (1, "# the job", .comment), (4, "true", .keyword)])
        try check("README.md", "# Title\n\nSome `code` and [a link](https://x.y).\n\n```swift\nlet x = 1\n```\n", [
            (1, "Title", .keyword), (3, "code", .string), (5, "swift", .string)])
        try check("Dockerfile", "FROM ubuntu:24.04\n# comment\nRUN apt-get update\n", [
            (1, "FROM", .keyword), (2, "comment", .comment), (3, "RUN", .keyword)])
        try check("Makefile", "all: build\n\t$(CC) -o out main.c\n# cc\n", [(1, "all", .function), (3, "# cc", .comment)])
        try check("q.sql", "SELECT name FROM users WHERE id = 'x' -- why\n", [
            (1, "SELECT", .keyword), (1, "'x'", .string), (1, "-- why", .comment)])
        try check("page.php", "<p>Hi</p>\n<?php echo \"hello\"; // done\n", [
            (1, "p", .tag), (2, "echo", .function), (2, "\"hello\"", .string), (2, "// done", .comment)])
        try check("data.xml", "<?xml version=\"1.0\"?>\n<item id=\"7\"><!-- c --></item>\n", [
            (2, "item", .tag), (2, "id", .attribute), (2, "\"7\"", .string), (2, "c --", .comment)])
        try check("x.diff", "--- a/f\n+++ b/f\n@@ -1 +1 @@\n-old\n+new\n", [(5, "new", .string)])
        try check("main.lua", "local x = \"s\" -- c\nfunction f() return 1 end\n", [
            (1, "local", .keyword), (1, "\"s\"", .string), (1, "-- c", .comment), (2, "function", .keyword)])
        try check("settings.ini", "[core]\neditor = vim ; c\n", [(2, "; c", .comment)])
    }

    @Test func throughputDiagnostic() throws {
        var out: [String] = []
        for (path, block) in [("a.yaml", "key: value\nlist:\n  - \"item\" # c\n  - 42\n"),
                              ("a.md", "# Head\nSome *text* with `code` and [link](x).\n\n"),
                              ("a.sql", "SELECT a, b FROM t WHERE c = 'x' -- c\n"),
                              ("a.php", "<?php $x = foo(\"s\"); // c\n"),
                              ("a.xml", "<a b=\"c\">text</a>\n")] {
            let text = String(repeating: block, count: 5_000)
            let n = text.components(separatedBy: "\n").count - 1
            let start = Date()
            _ = TMRegistry.shared.highlight(text, path: path, lines: [n], timeBudget: 60)
            let t = Date().timeIntervalSince(start)
            out.append(String(format: "%@: %d lines (%d KB) in %.2f s = %.0f lines/s", path, n, text.utf8.count / 1024, t, Double(n) / t))
        }
        print("DIAG tm throughput\n" + out.joined(separator: "\n"))
    }

    @Test func largeFileStaysWithinBudget() throws {
        let block = "key: value\nlist:\n  - \"item\" # c\n  - 42\n"
        let text = String(repeating: block, count: 20_000)   // ~800 KB
        let last = text.components(separatedBy: "\n").count - 1
        let start = Date()
        let spans = try #require(TMRegistry.shared.highlight(text, path: "big.yaml", lines: [last - 1, last]))
        let t = Date().timeIntervalSince(start)
        print(String(format: "DIAG yaml 800 KB: %.2f s, last lines %@", t, spans.isEmpty ? "plain (budget)" : "highlighted"))
        #expect(t < 4)
    }
}
