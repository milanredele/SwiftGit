import Foundation

/// Runs a TextMate grammar over a file, line by line, and produces syntax
/// spans for the requested lines. Follows vscode-textmate's semantics for the
/// parts grammars commonly use: match, begin/end, begin/while, includes,
/// captures (with nested patterns), back-references and \G. Not supported:
/// injections and embedded-language selectors.
final class TMTokenizer {
    /// Lines longer than this (bytes) are skipped (left plain); the state carries over.
    static let maxLineBytes = 20_000

    private struct Frame {
        let rule: TMRule
        /// Scopes for text inside the rule (name + contentName).
        let scopes: [String]
        /// Scopes of the rule itself, without contentName (for begin/end text).
        let nameScopes: [String]
        /// Resolved styles of `scopes` / `nameScopes` (computed once per frame).
        let style: SyntaxStyle?
        let nameStyle: SyntaxStyle?
        let end: TMPattern?
        let whilePattern: TMPattern?
        /// Byte position in the current line where begin (or the last while) matched, for \G; -1 otherwise.
        var anchor: Int
        let enterLine: Int
        let enterPos: Int
        /// Injected rules for these scopes (before / after the rule's own patterns).
        let injected: (left: [TMRule], right: [TMRule])
    }

    private let grammar: TMGrammar
    private let deadline: Date
    private var stack: [Frame]
    private let styleCache = StyleCache()

    init(grammar: TMGrammar, timeBudget: TimeInterval = 2.0) {
        self.grammar = grammar
        deadline = Date().addingTimeInterval(timeBudget)
        let root = grammar.root!
        let base = [grammar.scopeName]
        let baseStyle = styleCache.style(for: base)
        stack = [Frame(rule: root, scopes: base, nameScopes: base, style: baseStyle, nameStyle: baseStyle,
                       end: nil, whilePattern: nil, anchor: -1, enterLine: -1, enterPos: -1,
                       injected: grammar.injected(for: base))]
    }

    // MARK: Per-line state

    private var bytes: [UInt8] = []
    private var lineIndex = 0
    /// Style per byte of the current line (255 = none), only for requested lines.
    private var paint: [UInt8]?
    /// Search results already computed on this line: regex → (searched from, result).
    private var cache: [ObjectIdentifier: (Int, TMRegex.Match?)] = [:]

    /// Tokenizes `text` and returns, for each requested 1-based line, the style
    /// of every byte range (byte offsets within the line, without the newline).
    func run(_ text: String, lines wanted: Set<Int>) -> [Int: [(start: Int, end: Int, style: SyntaxStyle)]] {
        var result: [Int: [(start: Int, end: Int, style: SyntaxStyle)]] = [:]
        guard let last = wanted.max() else { return result }
        var index = 0
        var lineStart = text.utf8.startIndex
        let utf8 = text.utf8
        while lineIndex < last && lineStart <= utf8.endIndex {
            if index % 64 == 0 && Date() > deadline { break }
            index += 1
            let lineEnd = utf8[lineStart...].firstIndex(of: 10) ?? utf8.endIndex
            let lineBytes = utf8[lineStart..<lineEnd]
            let requested = wanted.contains(lineIndex + 1)
            if lineBytes.count <= TMTokenizer.maxLineBytes {
                bytes = Array(lineBytes)
                bytes.append(10)   // grammars expect the newline (e.g. for $ and comments to end of line)
                paint = requested ? [UInt8](repeating: 255, count: bytes.count) : nil
                tokenizeLine()
                if requested, let p = paint {
                    result[lineIndex + 1] = TMTokenizer.spans(from: p, count: bytes.count - 1)
                }
            }
            lineIndex += 1
            if lineEnd == utf8.endIndex { break }
            lineStart = utf8.index(after: lineEnd)
        }
        return result
    }

    private static func spans(from paint: [UInt8], count: Int) -> [(start: Int, end: Int, style: SyntaxStyle)] {
        var out: [(start: Int, end: Int, style: SyntaxStyle)] = []
        var i = 0
        while i < count {
            let s = paint[i]
            var j = i + 1
            while j < count && paint[j] == s { j += 1 }
            if s != 255, let style = SyntaxStyle(rawValue: s) { out.append((i, j, style)) }
            i = j
        }
        return out
    }

    // MARK: Tokenizing one line

    private func tokenizeLine() {
        cache.removeAll(keepingCapacity: true)
        for i in stack.indices { stack[i].anchor = -1 }
        var pos = 0
        pos = checkWhileRules(pos)
        let length = bytes.count
        var guardCount = 0
        while pos < length {
            guardCount += 1
            if guardCount > 10_000 { paintRange(pos, length, stack.last!.style); return }
            let frame = stack.last!
            guard let (kind, rule, m) = bestMatch(at: pos, frame: frame) else {
                paintRange(pos, length, frame.style)
                return
            }
            paintRange(pos, m.start, frame.style)
            switch kind {
            case .end:
                // An end that matches nothing right where its begin matched would loop forever.
                if m.end == m.start && frame.enterLine == lineIndex && frame.enterPos == m.start {
                    paintRange(m.start, length, frame.style)
                    return
                }
                paintRange(m.start, m.end, frame.nameStyle)
                applyCaptures(frame.rule.endCaptures.isEmpty ? frame.rule.captures : frame.rule.endCaptures, m, frame.nameStyle)
                stack.removeLast()
                if stack.isEmpty { stack.append(frame) }   // never pop the root
                pos = m.end
            case .rule:
                let ruleStyle = styleCache.style(rule.name, inheriting: frame.style)
                switch rule.kind {
                case .match:
                    paintRange(m.start, m.end, ruleStyle)
                    applyCaptures(rule.captures, m, ruleStyle)
                    if m.end == m.start {
                        // Empty match: step over one character so the line makes progress.
                        let next = nextCharStart(m.end)
                        paintRange(m.end, next, frame.style)
                        pos = next
                    } else {
                        pos = m.end
                    }
                case .beginEnd, .beginWhile:
                    if m.end == m.start, stack.contains(where: { $0.rule === rule && $0.enterLine == lineIndex && $0.enterPos == m.start }) {
                        paintRange(m.start, length, frame.style)
                        return
                    }
                    paintRange(m.start, m.end, ruleStyle)
                    applyCaptures(rule.beginCaptures.isEmpty ? rule.captures : rule.beginCaptures, m, ruleStyle)
                    let captured = capturedTexts(m)
                    var endPattern: TMPattern?
                    var whilePattern: TMPattern?
                    if rule.kind == .beginEnd {
                        endPattern = rule.endHasBackrefs ? rule.patternWithBackrefs(rule.end ?? "", captured: captured) : rule.endPattern
                    } else {
                        whilePattern = rule.whileHasBackrefs ? rule.patternWithBackrefs(rule.whilePattern ?? "", captured: captured) : rule.whileRegex
                    }
                    let scopes = frame.scopes + (rule.name.map { [$0] } ?? [])
                    let content = scopes + (rule.contentName.map { [$0] } ?? [])
                    stack.append(Frame(rule: rule, scopes: content, nameScopes: scopes,
                                       style: styleCache.style(rule.contentName, inheriting: ruleStyle), nameStyle: ruleStyle,
                                       end: endPattern, whilePattern: whilePattern,
                                       anchor: m.end, enterLine: lineIndex, enterPos: m.start,
                                       injected: grammar.injected(for: content)))
                    pos = m.end
                default:
                    pos = m.end
                }
            }
        }
    }

    /// begin/while rules continue only while their `while` matches at the start
    /// of each following line (checked from the outermost one in).
    private func checkWhileRules(_ start: Int) -> Int {
        var pos = start
        var i = 1
        while i < stack.count {
            let frame = stack[i]
            if let w = frame.whilePattern, frame.enterLine < lineIndex {
                let regex = w.regex(atAnchor: true, atFileStart: lineIndex == 0 && pos == 0)
                if let found = search(regex, from: pos), found.start == pos {
                    let m = groups(regex, found)
                    paintRange(m.start, m.end, frame.nameStyle)
                    applyCaptures(frame.rule.whileCaptures, m, frame.nameStyle)
                    pos = m.end
                    stack[i].anchor = m.end
                } else {
                    stack.removeSubrange(i...)
                    break
                }
            }
            i += 1
        }
        return pos
    }

    private enum MatchKind { case end, rule }

    private func bestMatch(at pos: Int, frame: Frame) -> (MatchKind, TMRule, TMRegex.Match)? {
        let atAnchor = pos == frame.anchor
        let atFileStart = lineIndex == 0 && pos == 0
        var best: (MatchKind, TMRule, TMRegex.Match)?
        var bestRegex: TMRegex?
        func consider(_ kind: MatchKind, _ rule: TMRule, _ pattern: TMPattern?) {
            guard let pattern else { return }
            let regex = pattern.regex(atAnchor: atAnchor, atFileStart: atFileStart)
            guard let m = search(regex, from: pos) else { return }
            if best == nil || m.start < best!.2.start { best = (kind, rule, m); bestRegex = regex }
        }
        func finish() -> (MatchKind, TMRule, TMRegex.Match)? {
            guard let b = best, let r = bestRegex else { return nil }
            return (b.0, b.1, groups(r, b.2))
        }
        let endLast = frame.rule.applyEndPatternLast
        if !endLast { consider(.end, frame.rule, frame.end) }
        if let first = best, first.2.start == pos {
            return finish()   // nothing can start earlier than the current position
        }
        let injected = frame.injected
        for list in [injected.left, grammar.candidates(of: frame.rule), injected.right] {
            for rule in list {
                consider(.rule, rule, rule.kind == .match ? rule.match : rule.begin)
                if let b = best, b.2.start == pos { break }   // earlier rules win ties
            }
            if let b = best, b.2.start == pos { break }
        }
        if endLast { consider(.end, frame.rule, frame.end) }
        return finish()
    }

    /// Searches with a per-line cache: a result found from an earlier position is
    /// still valid if it starts at or after `from`; "no match" stays "no match".
    private func search(_ regex: TMRegex, from: Int) -> TMRegex.Match? {
        let key = ObjectIdentifier(regex)
        if let (searchedFrom, result) = cache[key], searchedFrom <= from {
            if let r = result {
                // The regex's region must still hold this match (it does: it wasn't searched since).
                if r.start >= from { return r }
            } else {
                return nil
            }
        }
        let result = bytes.withUnsafeBufferPointer { buf -> TMRegex.Match? in
            guard let base = buf.baseAddress else { return nil }
            return regex.search(base, length: buf.count, from: from)
        }
        cache[key] = (from, result)
        return result
    }

    /// The match with its capture groups. Uses the regex's last search when that
    /// was this match, otherwise searches again from the match start.
    private func groups(_ regex: TMRegex, _ m: TMRegex.Match) -> TMRegex.Match {
        let filled = regex.withGroups(m)
        if !filled.groups.isEmpty { return filled }
        let again = bytes.withUnsafeBufferPointer { regex.search($0.baseAddress!, length: $0.count, from: m.start) }
        return again.map { regex.withGroups($0) } ?? m
    }

    private func capturedTexts(_ m: TMRegex.Match) -> [String?] {
        m.groups.map { g in
            g.0 >= 0 && g.1 >= g.0 ? String(decoding: bytes[g.0..<g.1], as: UTF8.self) : nil
        }
    }

    private func applyCaptures(_ captures: [Int: TMCapture], _ m: TMRegex.Match, _ style: SyntaxStyle?) {
        guard !captures.isEmpty, paint != nil else { return }   // captures only color; they never change the state
        for i in captures.keys.sorted() where i < m.groups.count {
            let (s, e) = m.groups[i]
            guard s >= 0, e > s, let cap = captures[i] else { continue }
            let capStyle = styleCache.style(cap.name, inheriting: style)
            paintRange(s, e, capStyle)
            if !cap.patterns.isEmpty { tokenizeCapture(cap.patterns, from: s, to: e, style: capStyle) }
        }
    }

    /// Applies a capture's own patterns to the captured text only.
    private func tokenizeCapture(_ patterns: [TMRule], from start: Int, to end: Int, style: SyntaxStyle?) {
        let candidates = grammar.candidates(list: patterns)
        var pos = start
        var guardCount = 0
        while pos < end, guardCount < 1_000 {
            guardCount += 1
            var best: (TMRule, TMRegex.Match, TMRegex)?
            for rule in candidates {
                guard let p = rule.kind == .match ? rule.match : rule.begin else { continue }
                let regex = p.regex(atAnchor: pos == start, atFileStart: false)
                let m = bytes.withUnsafeBufferPointer { buf in regex.search(buf.baseAddress!, length: end, from: pos) }
                if let m, best == nil || m.start < best!.1.start { best = (rule, m, regex) }
            }
            guard let (rule, found, winner) = best, found.start < end else { return }
            let m = winner.withGroups(found)
            let s = styleCache.style(rule.name, inheriting: style)
            if rule.kind == .match {
                paintRange(m.start, m.end, s)
                applyCaptures(rule.captures, m, s)
                pos = max(m.end, m.start + 1)
            } else {
                // begin/end inside a capture: paint up to its end (or the capture's end).
                var stop = end
                if let ePattern = rule.kind == .beginEnd
                    ? (rule.endHasBackrefs ? rule.patternWithBackrefs(rule.end ?? "", captured: capturedTexts(m)) : rule.endPattern)
                    : nil {
                    let regex = ePattern.regex(atAnchor: false, atFileStart: false)
                    if let em = bytes.withUnsafeBufferPointer({ regex.search($0.baseAddress!, length: end, from: m.end) }) {
                        stop = em.end
                    }
                }
                paintRange(m.start, stop, s)
                applyCaptures(rule.beginCaptures.isEmpty ? rule.captures : rule.beginCaptures, m, s)
                pos = max(stop, m.start + 1)
            }
        }
    }

    private func nextCharStart(_ i: Int) -> Int {
        var j = i + 1
        while j < bytes.count && bytes[j] & 0xC0 == 0x80 { j += 1 }
        return min(j, bytes.count)
    }

    private func paintRange(_ start: Int, _ end: Int, _ style: SyntaxStyle?) {
        guard paint != nil, end > start else { return }
        let value = style.map { $0.rawValue } ?? 255
        let e = min(end, paint!.count)
        var i = max(0, start)
        while i < e { paint![i] = value; i += 1 }
    }
}

/// Maps TextMate scope stacks to the app's syntax styles (innermost scope first).
final class StyleCache {
    private var byName: [String: SyntaxStyle?] = [:]

    /// Style of a scope stack: the innermost scope that maps to a style wins.
    func style(for scopes: [String]) -> SyntaxStyle? {
        var result: SyntaxStyle?
        for s in scopes { result = style(s, inheriting: result) }
        return result
    }

    /// Style of text with scope `name` (possibly several space-separated scopes)
    /// inside text styled `parent`: the name's own style, else the parent's.
    func style(_ name: String?, inheriting parent: SyntaxStyle?) -> SyntaxStyle? {
        guard let name else { return parent }
        if let hit = byName[name] { return hit ?? parent }
        var own: SyntaxStyle?
        for scope in name.split(separator: " ").reversed() {
            if case .style(let s) = StyleCache.map(String(scope)) { own = s; break }
        }
        byName[name] = .some(own)
        return own ?? parent
    }

    enum Mapping: Equatable { case style(SyntaxStyle), unknown }

    static func map(_ scope: String) -> Mapping {
        func has(_ p: String) -> Bool { scope == p || scope.hasPrefix(p + ".") }
        if has("comment") || has("punctuation.definition.comment") || has("markup.quote") { return .style(.comment) }
        if has("constant.character.escape") || has("string.regexp") && scope.contains("escape") { return .style(.escape) }
        if has("string") || has("punctuation.definition.string") || has("markup.inline.raw") || has("markup.fenced_code")
            || has("markup.raw") || has("markup.inserted") { return .style(.string) }
        if has("constant.numeric") { return .style(.number) }
        if has("constant.language") { return .style(.keyword) }
        if has("constant") || has("support.constant") || has("variable.other.constant") || has("variable.other.enummember") {
            return .style(.constant)
        }
        if has("keyword.operator") { return .unknown }
        if has("keyword") || has("storage.type") || has("storage.modifier") || has("markup.heading") || has("markup.deleted")
            || has("entity.name.section") { return .style(.keyword) }
        if has("entity.name.tag") { return .style(.tag) }
        if has("entity.other.attribute-name") { return .style(.attribute) }
        if has("entity.name.function") || has("support.function") || has("meta.function-call.name") { return .style(.function) }
        if has("support.type.property-name") || has("variable.other.property") || has("variable.other.member")
            || has("support.variable.property") || has("entity.name.property") { return .style(.property) }
        if has("entity.name.type") || has("entity.name.class") || has("entity.name.namespace") || has("entity.other.inherited-class")
            || has("support.type") || has("support.class") { return .style(.type) }
        if has("variable.language") { return .style(.builtin) }
        if has("entity.name.label") || has("markup.underline.link") || has("markup.link") { return .style(.label) }
        if has("entity.name") { return .style(.type) }
        return .unknown
    }
}
