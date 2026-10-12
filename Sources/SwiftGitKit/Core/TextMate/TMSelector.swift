import Foundation

/// A TextMate scope selector, as used by grammar injections, e.g.
/// `text.html.php - (meta.embedded | meta.tag), L:(source.js - meta.embedded)`.
/// Supports paths (descendant scopes), `,`/`|` (or), `&` (and), `-` (and not),
/// parentheses and the `L:`/`R:` priority prefixes.
struct TMSelector {
    indirect enum Node {
        case path([String])
        case or([Node])
        case and(Node, Node)
        case andNot(Node, Node)
    }

    /// One top-level alternative with its priority: -1 for L: (before the
    /// grammar's own rules), +1 for R: or none (after them).
    struct Alternative {
        let priority: Int
        let node: Node
    }

    let alternatives: [Alternative]

    init(_ source: String) {
        var parts: [Alternative] = []
        for raw in TMSelector.splitTopLevel(source) {
            var s = raw.trimmingCharacters(in: .whitespaces)
            var priority = 1
            if s.hasPrefix("L:") { priority = -1; s.removeFirst(2) }
            else if s.hasPrefix("R:") { priority = 1; s.removeFirst(2) }
            var parser = Parser(tokens: TMSelector.tokenize(s))
            if let node = parser.parseExpression() { parts.append(Alternative(priority: priority, node: node)) }
        }
        alternatives = parts
    }

    /// Priority of the first alternative that matches `scopes` (outermost first), or nil.
    func match(_ scopes: [String]) -> Int? {
        for a in alternatives where TMSelector.matches(a.node, scopes) { return a.priority }
        return nil
    }

    static func matches(_ node: Node, _ scopes: [String]) -> Bool {
        switch node {
        case .path(let names):
            var i = 0
            for scope in scopes where i < names.count {
                if scope == names[i] || scope.hasPrefix(names[i] + ".") { i += 1 }
            }
            return i == names.count
        case .or(let nodes): return nodes.contains { matches($0, scopes) }
        case .and(let a, let b): return matches(a, scopes) && matches(b, scopes)
        case .andNot(let a, let b): return matches(a, scopes) && !matches(b, scopes)
        }
    }

    /// Splits on commas that are not inside parentheses.
    private static func splitTopLevel(_ s: String) -> [String] {
        var out: [String] = []
        var depth = 0
        var current = ""
        for c in s {
            if c == "(" { depth += 1 } else if c == ")" { depth -= 1 }
            if c == "," && depth == 0 { out.append(current); current = "" } else { current.append(c) }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { out.append(current) }
        return out
    }

    private static func tokenize(_ s: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        func flush() { if !current.isEmpty { tokens.append(current); current = "" } }
        for c in s {
            if c == " " || c == "\t" { flush() }
            else if "()|,&-".contains(c) && !(c == "-" && !current.isEmpty) { flush(); tokens.append(String(c)) }
            else { current.append(c) }
        }
        flush()
        // "L:" / "R:" inside groups are ignored (priority only counts at the top level).
        return tokens.map { $0.hasPrefix("L:") || $0.hasPrefix("R:") ? String($0.dropFirst(2)) : $0 }.filter { !$0.isEmpty }
    }

    private struct Parser {
        var tokens: [String]
        var i = 0

        mutating func peek() -> String? { i < tokens.count ? tokens[i] : nil }

        mutating func parseExpression() -> Node? {
            guard var left = parseConjunction() else { return nil }
            var alternatives = [left]
            while let t = peek(), t == "|" || t == "," {
                i += 1
                if let next = parseConjunction() { alternatives.append(next) }
            }
            if alternatives.count > 1 { left = .or(alternatives) }
            return left
        }

        mutating func parseConjunction() -> Node? {
            guard var left = parseOperand() else { return nil }
            while let t = peek(), t == "&" || t == "-" {
                i += 1
                guard let right = parseOperand() else { break }
                left = t == "&" ? .and(left, right) : .andNot(left, right)
            }
            return left
        }

        mutating func parseOperand() -> Node? {
            guard let t = peek() else { return nil }
            if t == "(" {
                i += 1
                let inner = parseExpression()
                if peek() == ")" { i += 1 }
                return inner
            }
            var names: [String] = []
            while let n = peek(), !["(", ")", "|", ",", "&", "-"].contains(n) {
                names.append(n)
                i += 1
            }
            return names.isEmpty ? nil : .path(names)
        }
    }
}
