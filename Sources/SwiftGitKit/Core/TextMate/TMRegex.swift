import COniguruma
import Foundation

/// A compiled Oniguruma regular expression, the dialect TextMate grammars use.
/// Matching works on UTF-8 bytes; offsets are byte offsets.
final class TMRegex: @unchecked Sendable {
    struct Match {
        var start: Int
        var end: Int
        /// (start, end) per capture group, index 0 = whole match; (-1, -1) if the group didn't take part.
        /// Filled only for the chosen match (see `withGroups`).
        var groups: [(Int, Int)] = []
    }

    private static let initialized: Bool = {
        swiftgit_onig_init() == ONIG_NORMAL
    }()

    private var regex: COniguruma.OnigRegex?
    private let region: UnsafeMutablePointer<OnigRegion>
    let source: String
    /// Compile error, if the pattern isn't valid Oniguruma (the rule is then skipped).
    private(set) var error: String?

    init(_ pattern: String) {
        _ = TMRegex.initialized
        source = pattern
        region = onig_region_new()
        let bytes = Array(pattern.utf8)
        let code: Int32 = bytes.withUnsafeBufferPointer { b in
            guard let base = b.baseAddress else { return ONIGERR_INVALID_ARGUMENT }
            return swiftgit_onig_new(&regex, base, b.count)
        }
        if code != ONIG_NORMAL {
            var buf = [UInt8](repeating: 0, count: Int(ONIG_MAX_ERROR_MESSAGE_LEN) + 1)
            swiftgit_onig_error(code, &buf)
            error = String(decoding: buf.prefix { $0 != 0 }, as: UTF8.self)
            regex = nil
        }
    }

    deinit {
        if let regex { onig_free(regex) }
        onig_region_free(region, 1)
    }

    var isValid: Bool { regex != nil }

    /// First match at or after byte offset `from` in `buffer[0..<length]`.
    func search(_ buffer: UnsafePointer<UInt8>, length: Int, from: Int) -> Match? {
        guard let regex, from <= length else { return nil }
        let r = onig_search(regex, buffer, buffer + length, buffer + from, buffer + length, region, ONIG_OPTION_NONE)
        guard r >= 0 else { return nil }
        return Match(start: Int(region.pointee.beg[0]), end: Int(region.pointee.end[0]))
    }

    /// Adds the capture groups of the last search of this regex (which must be `m`).
    func withGroups(_ m: Match) -> Match {
        let n = Int(region.pointee.num_regs)
        guard n > 0, Int(region.pointee.beg[0]) == m.start, Int(region.pointee.end[0]) == m.end else { return m }
        var out = m
        out.groups = (0..<n).map { (Int(region.pointee.beg[$0]), Int(region.pointee.end[$0])) }
        return out
    }
}

/// A grammar regex with the variants TextMate needs: `\G` only matches where
/// the enclosing rule's begin ended, `\A` only at the very start of the file.
/// Elsewhere they're replaced with a character that never occurs (U+FFFF).
final class TMPattern: @unchecked Sendable {
    let source: String
    private let hasG: Bool
    private let hasA: Bool
    private var variants: [TMRegex?] = [nil, nil, nil, nil]

    init(_ source: String) {
        self.source = source
        let (g, a) = TMPattern.anchors(in: source)
        hasG = g
        hasA = a
    }

    /// The regex to use; `atAnchor`: the search starts where \G may match.
    func regex(atAnchor: Bool, atFileStart: Bool) -> TMRegex {
        let key = (hasG && atAnchor ? 1 : 0) | (hasA && atFileStart ? 2 : 0)
        if let r = variants[key] { return r }   // 4 slots: \G allowed × \A allowed
        var s = source
        if hasG && !atAnchor { s = TMPattern.replaceEscape("G", in: s) }
        if hasA && !atFileStart { s = TMPattern.replaceEscape("A", in: s) }
        let r = TMRegex(s)
        variants[key] = r
        return r
    }

    private static func anchors(in s: String) -> (Bool, Bool) {
        var g = false, a = false
        var escaped = false
        for c in s.unicodeScalars {
            if escaped {
                if c == "G" { g = true }
                if c == "A" { a = true }
                escaped = false
            } else if c == "\\" {
                escaped = true
            }
        }
        return (g, a)
    }

    /// Replaces the escape `\<letter>` (not `\\<letter>`) with `\x{FFFF}`.
    static func replaceEscape(_ letter: Character, in s: String) -> String {
        var out = ""
        var escaped = false
        for c in s {
            if escaped {
                out += c == letter ? "\\x{FFFF}" : "\\" + String(c)
                escaped = false
            } else if c == "\\" {
                escaped = true
            } else {
                out.append(c)
            }
        }
        if escaped { out += "\\" }
        return out
    }

    /// Escapes text captured by `begin` for use in an `end`/`while` back-reference.
    static func escapeLiteral(_ s: String) -> String {
        var out = ""
        for c in s.unicodeScalars {
            if c.isASCII, !(CharacterSet.alphanumerics.contains(c)) { out += "\\" }
            out.unicodeScalars.append(c)
        }
        return out
    }
}
