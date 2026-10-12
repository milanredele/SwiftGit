import Foundation

/// The bundled TextMate grammars (Resources/Grammars: compressed JSON plus an
/// index of file extensions). Used for languages without a tree-sitter grammar.
final class TMRegistry: @unchecked Sendable {
    static let shared = TMRegistry()

    struct Entry: Decodable {
        let scopeName: String
        let file: String
        let language: String?
        let extensions: [String]
        let filenames: [String]
        let filenamePatterns: [String]
    }

    private let lock = NSLock()
    /// One tokenization at a time: compiled regexes are shared and keep search state.
    private let tokenizeLock = NSLock()
    private var loadedIndex = false
    private var entries: [String: Entry] = [:]
    private var byExtension: [String: String] = [:]
    private var byFilename: [String: String] = [:]
    private var patterns: [(prefix: String, suffix: String, scope: String)] = []
    private var grammars: [String: TMGrammar] = [:]
    private var directory: URL?
    /// Loaded grammars are dropped (all together, between highlights) when more
    /// than this many are loaded: compiled regexes of big grammars take MBs.
    static let maxLoadedGrammars = 6
    /// Grammars whose file is missing or invalid.
    private var failed = Set<String>()

    init(directory: URL? = nil) {
        self.directory = directory
    }

    private func loadIndex() {
        guard !loadedIndex else { return }
        loadedIndex = true
        if directory == nil { directory = TMRegistry.findDirectory() }
        guard let dir = directory,
              let data = try? Data(contentsOf: dir.appendingPathComponent("index.json")),
              let list = try? JSONDecoder().decode([Entry].self, from: data) else {
            NSLog("SwiftGit: TextMate grammar index not found")
            return
        }
        for e in list {
            entries[e.scopeName] = e
            for x in e.extensions where byExtension[x] == nil { byExtension[x] = e.scopeName }
            for n in e.filenames where byFilename[n] == nil { byFilename[n] = e.scopeName }
            for p in e.filenamePatterns {
                // Simple "prefix*suffix" patterns (e.g. "Dockerfile.*", "compose.*.yml").
                let parts = p.split(separator: "*", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                patterns.append((parts[0], parts.count > 1 ? parts[1].replacingOccurrences(of: "*", with: "") : "", e.scopeName))
            }
        }
    }

    /// Directories that may hold SwiftGitKit's resource bundle (app, swift run, swift test).
    private static func findDirectory() -> URL? {
        var dirs: [URL] = []
        if let r = Bundle.main.resourceURL { dirs.append(r) }
        if let e = Bundle.main.executableURL { dirs.append(e.deletingLastPathComponent()) }
        dirs.append(Bundle(for: TMRegistry.self).bundleURL.deletingLastPathComponent())
        let fm = FileManager.default
        for d in dirs {
            for sub in ["SwiftGit_SwiftGitKit.bundle/Grammars", "SwiftGit_SwiftGitKit.bundle/Contents/Resources/Grammars"] {
                let url = d.appendingPathComponent(sub)
                if fm.fileExists(atPath: url.appendingPathComponent("index.json").path) { return url }
            }
        }
        return nil
    }

    /// Scope name of the grammar for a file, or nil.
    func scopeName(forPath path: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        loadIndex()
        let name = (path as NSString).lastPathComponent
        if let s = byFilename[name] { return s }
        for p in patterns where name.hasPrefix(p.prefix) && name.hasSuffix(p.suffix) && name.count > p.prefix.count {
            return p.scope
        }
        let lower = name.lowercased()
        // Longest matching extension first ("csproj.user" before "user").
        var dot = lower.firstIndex(of: ".")
        while let d = dot {
            let ext = String(lower[lower.index(after: d)...])
            if let s = byExtension[ext] { return s }
            dot = lower[lower.index(after: d)...].firstIndex(of: ".")
        }
        return nil
    }

    var allScopeNames: [String] {
        lock.lock(); defer { lock.unlock() }
        loadIndex()
        return entries.keys.sorted()
    }

    /// Loads (once) and returns a grammar by scope name.
    func grammar(scope: String) -> TMGrammar? {
        lock.lock(); defer { lock.unlock() }
        loadIndex()
        if let g = grammars[scope] { return g }
        guard !failed.contains(scope), let entry = entries[scope], let dir = directory else { return nil }
        guard let compressed = try? Data(contentsOf: dir.appendingPathComponent(entry.file)),
              let data = try? (compressed as NSData).decompressed(using: .zlib) as Data,
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            NSLog("SwiftGit: could not load grammar \(scope)")
            failed.insert(scope)
            return nil
        }
        let g = TMGrammar(dict, registry: self)
        grammars[scope] = g
        return g
    }

    /// Spans keyed by 1-based line number for the requested lines, in the same
    /// units as tree-sitter spans (UTF-16 offsets after expanding tabs to 4).
    func highlight(_ text: String, path: String, lines: Set<Int>, timeBudget: TimeInterval = 3.0) -> [Int: [SyntaxSpan]]? {
        guard let scope = scopeName(forPath: path) else { return nil }
        tokenizeLock.lock()
        lock.lock()
        // Nothing is tokenizing now, so no rule of these grammars is in use.
        if grammars.count > TMRegistry.maxLoadedGrammars && grammars[scope] == nil { grammars.removeAll() }
        lock.unlock()
        guard let grammar = grammar(scope: scope) else { tokenizeLock.unlock(); return nil }
        let raw = TMTokenizer(grammar: grammar, timeBudget: timeBudget).run(text, lines: lines)
        tokenizeLock.unlock()
        guard !raw.isEmpty else { return [:] }

        var result: [Int: [SyntaxSpan]] = [:]
        var lineNo = 1
        var start = text.utf8.startIndex
        let utf8 = text.utf8
        let last = raw.keys.max() ?? 0
        while lineNo <= last {
            let end = utf8[start...].firstIndex(of: 10) ?? utf8.endIndex
            if let spans = raw[lineNo], !spans.isEmpty,
               let line = String(utf8[start..<end]) {
                // Byte offset -> drawn column (UTF-16 units, tabs as 4).
                var column = [Int](repeating: 0, count: utf8.distance(from: start, to: end) + 1)
                var b = 0, c = 0
                for scalar in line.unicodeScalars {
                    let n = String(scalar).utf8.count
                    for k in 0..<n where b + k < column.count { column[b + k] = c }
                    b += n
                    c += scalar == "\t" ? 4 : (scalar.value > 0xFFFF ? 2 : 1)
                }
                if b < column.count { column[b] = c }
                result[lineNo] = spans.compactMap { s in
                    let from = column[min(s.start, column.count - 1)], to = column[min(s.end, column.count - 1)]
                    return to > from ? SyntaxSpan(start: Int32(from), length: Int32(to - from), style: s.style) : nil
                }
            }
            lineNo += 1
            if end == utf8.endIndex { break }
            start = utf8.index(after: end)
        }
        return result
    }
}
