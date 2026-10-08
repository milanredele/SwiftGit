import Foundation
import SwiftTreeSitter
import TreeSitterAda
import TreeSitterBash
import TreeSitterC
import TreeSitterCPP
import TreeSitterCSharp
import TreeSitterCSS
import TreeSitterGo
import TreeSitterHTML
import TreeSitterJava
import TreeSitterJavaScript
import TreeSitterJSON
import TreeSitterPython
import TreeSitterRuby
import TreeSitterRust
import TreeSitterSwift
import TreeSitterTSX
import TreeSitterTypeScript

/// Highlight categories; the theme maps each to a light/dark color.
enum SyntaxStyle: UInt8, CaseIterable {
    case keyword, string, comment, number, type, function, property, constant
    case builtin, tag, attribute, escape, label

    init?(captureName n: String) {
        func has(_ p: String) -> Bool { n == p || n.hasPrefix(p + ".") }
        if has("comment") { self = .comment }
        else if has("string.escape") || has("escape") || has("string.special") { self = .escape }
        else if has("string") || has("character") { self = .string }
        else if has("constant.builtin") || has("boolean") { self = .keyword }
        else if has("keyword") || has("conditional") || has("repeat") || has("include")
                    || has("exception") || has("storageclass") || has("operator.keyword") { self = .keyword }
        else if has("number") || has("float") || has("constant.numeric") { self = .number }
        else if has("constant") { self = .constant }
        else if has("type") || has("constructor") || has("module") || has("namespace") { self = .type }
        else if has("function") || has("method") { self = .function }
        else if has("property") || has("field") || has("variable.member") { self = .property }
        else if has("variable.builtin") || has("variable.parameter.builtin") { self = .builtin }
        else if has("tag") { self = .tag }
        else if has("attribute") || has("annotation") || has("decorator") { self = .attribute }
        else if has("label") { self = .label }
        else { return nil }
    }
}

/// A colored range within one line, in UTF-16 units of the tab-expanded line text.
struct SyntaxSpan {
    var start: Int32
    var length: Int32
    var style: SyntaxStyle
}

/// Tree-sitter based highlighting. Grammars are compiled into the app (read-only
/// pages, no heap cost); a whole file is parsed, spans are extracted for the
/// lines the diff shows, and the syntax tree is freed immediately.
final class SyntaxHighlighter: @unchecked Sendable {
    static let shared = SyntaxHighlighter()

    static let maxBytes = 1_000_000

    private final class Spec {
        let language: Language
        let query: Query
        init(language: Language, query: Query) {
            self.language = language
            self.query = query
        }
    }

    private let lock = NSLock()
    private var specs: [String: Spec] = [:]
    private var failed = Set<String>()

    // MARK: Language detection

    func languageID(forPath path: String) -> String? {
        let name = (path as NSString).lastPathComponent
        switch name {
        case "Gemfile", "Rakefile", "Podfile", "Fastfile": return "ruby"
        case ".bashrc", ".zshrc", ".bash_profile", ".profile": return "bash"
        default: break
        }
        switch (name as NSString).pathExtension.lowercased() {
        case "swift": return "swift"
        case "js", "mjs", "cjs", "jsx": return "javascript"
        case "ts", "mts", "cts": return "typescript"
        case "tsx": return "tsx"
        case "py", "pyi": return "python"
        case "go": return "go"
        case "rs": return "rust"
        case "c", "h": return "c"
        case "cc", "cpp", "cxx", "hpp", "hh", "hxx", "ipp": return "cpp"
        case "java": return "java"
        case "json", "jsonc", "geojson": return "json"
        case "sh", "bash", "zsh": return "bash"
        case "rb", "rake", "gemspec": return "ruby"
        case "css": return "css"
        case "html", "htm", "xhtml": return "html"
        case "cs": return "csharp"
        case "ads", "adb", "ada": return "ada"
        default: return nil
        }
    }

    // MARK: Query loading

    /// Directories that may contain the grammars' SwiftPM resource bundles:
    /// the app's Resources folder, next to the executable (swift run) and next
    /// to the test bundle (swift test).
    private lazy var bundleDirectories: [URL] = {
        var dirs: [URL] = []
        if let r = Bundle.main.resourceURL { dirs.append(r) }
        if let e = Bundle.main.executableURL { dirs.append(e.deletingLastPathComponent()) }
        dirs.append(Bundle(for: SyntaxHighlighter.self).bundleURL.deletingLastPathComponent())
        return dirs
    }()

    private func queryText(_ bundle: String, _ name: String) -> String? {
        for dir in bundleDirectories {
            let url = dir.appendingPathComponent("\(bundle).bundle/queries/\(name).scm")
            if let text = try? String(contentsOf: url, encoding: .utf8) { return text }
            let nested = dir.appendingPathComponent("\(bundle).bundle/Contents/Resources/queries/\(name).scm")
            if let text = try? String(contentsOf: nested, encoding: .utf8) { return text }
        }
        return nil
    }

    private func definition(_ id: String) -> (OpaquePointer?, [(String, String)])? {
        let js = "TreeSitterJavaScript_TreeSitterJavaScript"
        let ts = "TreeSitterTypeScript_TreeSitterTypeScript"
        switch id {
        case "swift": return (tree_sitter_swift(), [("TreeSitterSwift_TreeSitterSwift", "highlights")])
        case "javascript": return (tree_sitter_javascript(), [(js, "highlights"), (js, "highlights-jsx")])
        case "typescript": return (tree_sitter_typescript(), [(js, "highlights"), (ts, "highlights")])
        case "tsx": return (tree_sitter_tsx(), [(js, "highlights"), (js, "highlights-jsx"), (ts, "highlights")])
        case "python": return (tree_sitter_python(), [("TreeSitterPython_TreeSitterPython", "highlights")])
        case "go": return (tree_sitter_go(), [("TreeSitterGo_TreeSitterGo", "highlights")])
        case "rust": return (tree_sitter_rust(), [("TreeSitterRust_TreeSitterRust", "highlights")])
        case "c": return (tree_sitter_c(), [("TreeSitterC_TreeSitterC", "highlights")])
        case "cpp": return (tree_sitter_cpp(), [("TreeSitterC_TreeSitterC", "highlights"), ("TreeSitterCPP_TreeSitterCPP", "highlights")])
        case "java": return (tree_sitter_java(), [("TreeSitterJava_TreeSitterJava", "highlights")])
        case "json": return (tree_sitter_json(), [("TreeSitterJSON_TreeSitterJSON", "highlights")])
        case "bash": return (tree_sitter_bash(), [("TreeSitterBash_TreeSitterBash", "highlights")])
        case "ruby": return (tree_sitter_ruby(), [("TreeSitterRuby_TreeSitterRuby", "highlights")])
        case "css": return (tree_sitter_css(), [("TreeSitterCSS_TreeSitterCSS", "highlights")])
        case "html": return (tree_sitter_html(), [("TreeSitterHTML_TreeSitterHTML", "highlights")])
        case "csharp": return (tree_sitter_c_sharp(), [("TreeSitterCSharp_TreeSitterCSharp", "highlights")])
        case "ada": return (tree_sitter_ada(), [("TreeSitterAda_TreeSitterAda", "highlights")])
        default: return nil
        }
    }

    private func spec(_ id: String) -> Spec? {
        lock.lock()
        defer { lock.unlock() }
        if let s = specs[id] { return s }
        if failed.contains(id) { return nil }
        guard let def = definition(id), let ptr = def.0 else { failed.insert(id); return nil }
        let parts = def.1
        let text = parts.compactMap { queryText($0.0, $0.1) }.joined(separator: "\n")
        guard !text.isEmpty else {
            NSLog("SwiftGit: no highlight queries found for \(id)")
            failed.insert(id)
            return nil
        }
        let language = Language(language: ptr)
        do {
            let query = try Query(language: language, data: Data(text.utf8))
            let s = Spec(language: language, query: query)
            specs[id] = s
            return s
        } catch {
            NSLog("SwiftGit: highlight query for \(id) failed: \(error)")
            failed.insert(id)
            return nil
        }
    }

    func isSupported(path: String) -> Bool {
        guard let id = languageID(forPath: path) else { return false }
        return spec(id) != nil
    }

    // MARK: Highlighting

    /// Highlights `text` and returns spans keyed by 1-based line number,
    /// only for the lines in `lines`.
    func highlight(_ text: String, path: String, lines: Set<Int>) -> [Int: [SyntaxSpan]]? {
        guard !lines.isEmpty, text.utf8.count <= SyntaxHighlighter.maxBytes,
              let id = languageID(forPath: path), let spec = spec(id) else { return nil }

        let utf16 = Array(text.utf16)
        let ns = NSString(characters: utf16, length: utf16.count)
        let parser = Parser()
        do { try parser.setLanguage(spec.language) } catch { return nil }
        guard let tree = parser.parse(text) else { return nil }

        let context = Predicate.Context(textProvider: { range, _ in
            guard range.location >= 0, range.location + range.length <= ns.length else { return nil }
            return ns.substring(with: range)
        })
        let named = spec.query.execute(in: tree).resolve(with: context).highlights()

        var lineStarts = [0]
        for (i, c) in utf16.enumerated() where c == 10 { lineStarts.append(i + 1) }

        func lineIndex(containing offset: Int) -> Int {
            var lo = 0, hi = lineStarts.count - 1
            while lo < hi {
                let mid = (lo + hi + 1) / 2
                if lineStarts[mid] <= offset { lo = mid } else { hi = mid - 1 }
            }
            return lo
        }

        /// Offset within the line after tabs are expanded to 4 spaces (as drawn).
        func expanded(_ lineStart: Int, _ offset: Int) -> Int {
            var extra = 0
            var i = lineStart
            while i < offset { if utf16[i] == 9 { extra += 3 }; i += 1 }
            return offset - lineStart + extra
        }

        var result: [Int: [SyntaxSpan]] = [:]
        for nr in named {
            guard let style = SyntaxStyle(captureName: nr.name) else { continue }
            let r = nr.range
            guard r.length > 0, r.location >= 0, r.location + r.length <= utf16.count else { continue }
            var loc = r.location
            let end = r.location + r.length
            var line = lineIndex(containing: loc)
            while loc < end && line < lineStarts.count {
                let lineStart = lineStarts[line]
                let lineEnd = line + 1 < lineStarts.count ? lineStarts[line + 1] - 1 : utf16.count
                let segEnd = min(end, lineEnd)
                if segEnd > loc, lines.contains(line + 1) {
                    let s = expanded(lineStart, loc)
                    let e = expanded(lineStart, segEnd)
                    result[line + 1, default: []].append(SyntaxSpan(start: Int32(s), length: Int32(e - s), style: style))
                }
                line += 1
                loc = line < lineStarts.count ? lineStarts[line] : end
            }
        }
        return result
    }
}
