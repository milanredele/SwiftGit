import Foundation

/// A capture of a match/begin/end/while: a scope name and optional patterns
/// applied to the captured text.
struct TMCapture {
    var name: String?
    var patterns: [TMRule]
}

/// One rule of a TextMate grammar. Rules form a tree; `parent` is the lexical
/// parent used to look up `#name` includes in enclosing repositories.
final class TMRule {
    enum Kind { case match, beginEnd, beginWhile, include, container }

    nonisolated(unsafe) private static var nextID = 0
    private static let idLock = NSLock()
    let id: Int
    unowned let grammar: TMGrammar
    weak var parent: TMRule?

    var kind: Kind = .container
    var name: String?
    var contentName: String?
    var match: TMPattern?
    var begin: TMPattern?
    var end: String?
    var whilePattern: String?
    var endPattern: TMPattern?
    var whileRegex: TMPattern?
    var endHasBackrefs = false
    var whileHasBackrefs = false
    var applyEndPatternLast = false
    var include: String?
    var captures: [Int: TMCapture] = [:]
    var beginCaptures: [Int: TMCapture] = [:]
    var endCaptures: [Int: TMCapture] = [:]
    var whileCaptures: [Int: TMCapture] = [:]
    var patterns: [TMRule] = []
    var repository: [String: TMRule] = [:]

    /// Flattened candidates (match / begin rules) for matching inside this rule.
    var resolved: [TMRule]?
    /// End/while patterns with back-references, compiled per begin text.
    var backrefCache: [String: TMPattern] = [:]

    init(_ dict: [String: Any], parent: TMRule?, grammar: TMGrammar) {
        TMRule.idLock.lock()
        TMRule.nextID += 1
        id = TMRule.nextID
        TMRule.idLock.unlock()
        self.grammar = grammar
        self.parent = parent
        name = dict["name"] as? String
        contentName = dict["contentName"] as? String
        include = dict["include"] as? String
        applyEndPatternLast = (dict["applyEndPatternLast"] as? Bool) ?? ((dict["applyEndPatternLast"] as? Int) == 1)

        if let repo = dict["repository"] as? [String: Any] {
            for (key, value) in repo {
                if let d = value as? [String: Any] { repository[key] = TMRule(d, parent: self, grammar: grammar) }
            }
        }
        if let m = dict["match"] as? String {
            kind = .match
            match = TMPattern(m)
            captures = TMRule.captures(dict["captures"], parent: self, grammar: grammar)
        } else if let b = dict["begin"] as? String {
            begin = TMPattern(b)
            captures = TMRule.captures(dict["captures"], parent: self, grammar: grammar)
            beginCaptures = TMRule.captures(dict["beginCaptures"], parent: self, grammar: grammar)
            if let w = dict["while"] as? String {
                kind = .beginWhile
                whilePattern = w
                whileHasBackrefs = TMRule.hasBackrefs(w)
                if !whileHasBackrefs { whileRegex = TMPattern(w) }
                whileCaptures = TMRule.captures(dict["whileCaptures"], parent: self, grammar: grammar)
            } else {
                kind = .beginEnd
                // A begin without end never ends (like vscode-textmate).
                let e = (dict["end"] as? String) ?? "\\x{FFFF}"
                end = e
                endHasBackrefs = TMRule.hasBackrefs(e)
                if !endHasBackrefs { endPattern = TMPattern(e) }
                endCaptures = TMRule.captures(dict["endCaptures"], parent: self, grammar: grammar)
            }
        } else if include != nil {
            kind = .include
        }
        if let list = dict["patterns"] as? [Any] {
            patterns = list.compactMap { ($0 as? [String: Any]).map { TMRule($0, parent: self, grammar: grammar) } }
        }
    }

    private static func captures(_ value: Any?, parent: TMRule, grammar: TMGrammar) -> [Int: TMCapture] {
        var out: [Int: TMCapture] = [:]
        // Usually a dictionary {"1": {...}}, sometimes an array.
        if let d = value as? [String: Any] {
            for (k, v) in d {
                guard let i = Int(k), let c = v as? [String: Any] else { continue }
                out[i] = capture(c, parent: parent, grammar: grammar)
            }
        } else if let a = value as? [Any] {
            for (i, v) in a.enumerated() {
                if let c = v as? [String: Any] { out[i] = capture(c, parent: parent, grammar: grammar) }
            }
        }
        return out
    }

    private static func capture(_ d: [String: Any], parent: TMRule, grammar: TMGrammar) -> TMCapture {
        let patterns = (d["patterns"] as? [Any])?.compactMap { ($0 as? [String: Any]).map { TMRule($0, parent: parent, grammar: grammar) } } ?? []
        return TMCapture(name: d["name"] as? String, patterns: patterns)
    }

    static func hasBackrefs(_ s: String) -> Bool {
        var escaped = false
        for c in s.unicodeScalars {
            if escaped {
                if c >= "1" && c <= "9" { return true }
                escaped = false
            } else if c == "\\" {
                escaped = true
            }
        }
        return false
    }

    /// The end (or while) pattern for a begin match, with \1…\9 replaced by the
    /// text those groups captured.
    func patternWithBackrefs(_ source: String, captured: [String?]) -> TMPattern {
        let key = captured.map { $0 ?? "" }.joined(separator: "\u{0}")
        if let p = backrefCache[key] { return p }
        var out = ""
        var escaped = false
        for c in source {
            if escaped {
                if let d = c.wholeNumberValue, d >= 1, d <= 9 {
                    out += TMPattern.escapeLiteral(d < captured.count ? (captured[d] ?? "") : "")
                } else {
                    out += "\\" + String(c)
                }
                escaped = false
            } else if c == "\\" {
                escaped = true
            } else {
                out.append(c)
            }
        }
        let p = TMPattern(out)
        if backrefCache.count > 64 { backrefCache.removeAll() }
        backrefCache[key] = p
        return p
    }

    /// Looks up `#name` in this rule's repository and its enclosing ones.
    func lookup(_ key: String) -> TMRule? {
        var r: TMRule? = self
        while let rule = r {
            if let found = rule.repository[key] { return found }
            r = rule.parent
        }
        return nil
    }
}

/// A loaded TextMate grammar (from a .tmLanguage.json or plist dictionary).
final class TMGrammar {
    let scopeName: String
    private(set) var root: TMRule!
    weak var registry: TMRegistry?
    /// Injections: rules added inside scopes matching a selector (e.g. PHP tags in HTML).
    private(set) var injections: [(selector: TMSelector, rule: TMRule)] = []

    init(_ dict: [String: Any], registry: TMRegistry?) {
        scopeName = (dict["scopeName"] as? String) ?? "source.unknown"
        self.registry = registry
        root = TMRule(dict, parent: nil, grammar: self)
        root.kind = .container
        root.match = nil
        root.begin = nil
        if let inj = dict["injections"] as? [String: Any] {
            for (selector, value) in inj.sorted(by: { $0.key < $1.key }) {
                guard let d = value as? [String: Any] else { continue }
                injections.append((TMSelector(selector), TMRule(d, parent: root, grammar: self)))
            }
        }
    }

    private var injectionCache: [String: (left: [TMRule], right: [TMRule])] = [:]

    /// Injected candidates for a scope stack: (before the normal rules, after them).
    func injected(for scopes: [String]) -> (left: [TMRule], right: [TMRule]) {
        guard !injections.isEmpty else { return ([], []) }
        let key = scopes.joined(separator: " ")
        if let hit = injectionCache[key] { return hit }
        let flat = scopes.flatMap { $0.split(separator: " ").map(String.init) }
        var left: [TMRule] = [], right: [TMRule] = []
        for (selector, rule) in injections {
            guard let priority = selector.match(flat) else { continue }
            let c = candidates(of: rule)
            if priority < 0 { left += c } else { right += c }
        }
        if injectionCache.count > 512 { injectionCache.removeAll() }
        injectionCache[key] = (left, right)
        return (left, right)
    }

    /// The match/begin rules to try inside `rule` (its patterns with includes
    /// expanded, in order). Cached per rule.
    func candidates(of rule: TMRule) -> [TMRule] {
        if let r = rule.resolved { return r }
        var out: [TMRule] = []
        var seen = Set<Int>()
        expand(rule.patterns, context: rule, into: &out, seen: &seen)
        rule.resolved = out
        return out
    }

    private var listCache: [String: [TMRule]] = [:]

    /// Candidates for a free-standing pattern list (capture patterns).
    func candidates(list: [TMRule]) -> [TMRule] {
        let key = list.map { String($0.id) }.joined(separator: ",")
        if let r = listCache[key] { return r }
        var out: [TMRule] = []
        var seen = Set<Int>()
        if let first = list.first { expand(list, context: first, into: &out, seen: &seen) }
        listCache[key] = out
        return out
    }

    private func expand(_ rules: [TMRule], context: TMRule, into out: inout [TMRule], seen: inout Set<Int>) {
        for r in rules {
            switch r.kind {
            case .match, .beginEnd, .beginWhile:
                out.append(r)
            case .container:
                guard seen.insert(r.id).inserted else { continue }
                expand(r.patterns, context: r, into: &out, seen: &seen)
            case .include:
                guard let target = resolve(r.include ?? "", from: r) else { continue }
                switch target.kind {
                case .match, .beginEnd, .beginWhile:
                    out.append(target)
                default:
                    guard seen.insert(target.id).inserted else { continue }
                    expand(target.patterns, context: target, into: &out, seen: &seen)
                }
            }
        }
    }

    /// Resolves an include: `#name`, `$self` (the rule's own grammar), `$base`
    /// (the grammar of the file being highlighted), `scope` or `scope#name`.
    func resolve(_ include: String, from rule: TMRule) -> TMRule? {
        if include == "$self" { return rule.grammar.root }
        if include == "$base" { return root }
        if include.hasPrefix("#") { return rule.lookup(String(include.dropFirst())) }
        let parts = include.split(separator: "#", maxSplits: 1).map(String.init)
        guard let other = (parts[0] == scopeName ? self : registry?.grammar(scope: parts[0])) else { return nil }
        if parts.count == 2 { return other.root.repository[parts[1]] }
        return other.root
    }
}
