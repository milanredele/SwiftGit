import Foundation

enum DiffLineKind: UInt8 {
    case context, deleted, added
}

struct DiffLine {
    var kind: DiffLineKind
    /// Byte range of the line text in `FileDiff.raw` (without the +/-/space prefix and newline).
    var start: Int32
    var length: Int32
    var oldNo: Int32
    var newNo: Int32
    var noNewline: Bool
}

struct DiffHunk {
    var oldStart: Int
    var oldCount: Int
    var newStart: Int
    var newCount: Int
    var firstLine: Int
    var lineCount: Int
    var lines: Range<Int> { firstLine..<(firstLine + lineCount) }
}

enum RowKind: UInt8 {
    case context, changed, deleted, added, gap
}

/// One visual row in the diff panes. `left` / `right` index `FileDiff.lines` (-1 = filler).
struct DiffRow {
    var kind: RowKind
    var left: Int32
    var right: Int32
    var hunk: Int32
    var gap: Int32
}

/// A parsed unified diff of a single file, kept as raw bytes plus small index arrays.
final class FileDiff: @unchecked Sendable {
    let raw: [UInt8]
    private(set) var headerBytes: [UInt8] = []
    private(set) var lines: [DiffLine] = []
    private(set) var hunks: [DiffHunk] = []
    private(set) var isBinary = false
    private(set) var maxColumns = 0
    private(set) var isNewFile = false
    private(set) var isDeletedFile = false

    var isEmpty: Bool { hunks.isEmpty && !isBinary }
    var byteSize: Int { raw.count }

    init(data: Data) {
        raw = [UInt8](data)
        parse()
    }

    func text(_ index: Int) -> String {
        let l = lines[index]
        let s = Int(l.start), e = Int(l.start + l.length)
        return String(decoding: raw[s..<e], as: UTF8.self)
    }

    private func startsWith(_ s: Int, _ e: Int, _ prefix: String) -> Bool {
        let p = Array(prefix.utf8)
        guard e - s >= p.count else { return false }
        for i in 0..<p.count where raw[s + i] != p[i] { return false }
        return true
    }

    private func parse() {
        var pos = 0
        let n = raw.count
        var inHunk = false
        var seenFile = false
        var oldNo: Int32 = 0
        var newNo: Int32 = 0

        while pos < n {
            var end = pos
            while end < n && raw[end] != 10 { end += 1 }
            let s = pos, e = end
            pos = end + 1

            if startsWith(s, e, "diff --git ") {
                if seenFile { break }  // only the first file
                seenFile = true
            }

            if startsWith(s, e, "@@") {
                guard let h = parseHunkHeader(s, e) else { continue }
                inHunk = true
                hunks.append(DiffHunk(oldStart: h.0, oldCount: h.1, newStart: h.2, newCount: h.3,
                                      firstLine: lines.count, lineCount: 0))
                oldNo = Int32(h.0)
                newNo = Int32(h.2)
                continue
            }

            if !inHunk {
                if startsWith(s, e, "Binary files") || startsWith(s, e, "GIT binary patch") { isBinary = true }
                if startsWith(s, e, "new file mode") { isNewFile = true }
                if startsWith(s, e, "deleted file mode") { isDeletedFile = true }
                headerBytes.append(contentsOf: raw[s..<e])
                headerBytes.append(10)
                continue
            }

            let first: UInt8 = e > s ? raw[s] : 32
            var line: DiffLine
            switch first {
            case 32:
                line = DiffLine(kind: .context, start: Int32(min(s + 1, e)), length: Int32(max(0, e - s - 1)),
                                oldNo: oldNo, newNo: newNo, noNewline: false)
                oldNo += 1; newNo += 1
            case 45: // -
                line = DiffLine(kind: .deleted, start: Int32(s + 1), length: Int32(e - s - 1),
                                oldNo: oldNo, newNo: 0, noNewline: false)
                oldNo += 1
            case 43: // +
                line = DiffLine(kind: .added, start: Int32(s + 1), length: Int32(e - s - 1),
                                oldNo: 0, newNo: newNo, noNewline: false)
                newNo += 1
            case 92: // backslash: "\ No newline at end of file"
                if !lines.isEmpty { lines[lines.count - 1].noNewline = true }
                continue
            default:
                continue
            }
            var cols = Int(line.length)
            let ls = Int(line.start)
            for i in ls..<(ls + Int(line.length)) where raw[i] == 9 { cols += 3 }
            maxColumns = max(maxColumns, cols)
            lines.append(line)
            hunks[hunks.count - 1].lineCount += 1
        }
    }

    private func parseHunkHeader(_ s: Int, _ e: Int) -> (Int, Int, Int, Int)? {
        // @@ -a[,b] +c[,d] @@
        var i = s + 2
        func skipSpaces() { while i < e && raw[i] == 32 { i += 1 } }
        func number() -> Int? {
            var v = 0, any = false
            while i < e, raw[i] >= 48, raw[i] <= 57 { v = v * 10 + Int(raw[i] - 48); i += 1; any = true }
            return any ? v : nil
        }
        skipSpaces()
        guard i < e, raw[i] == 45 else { return nil }
        i += 1
        guard let a = number() else { return nil }
        var b = 1
        if i < e, raw[i] == 44 { i += 1; b = number() ?? 1 }
        skipSpaces()
        guard i < e, raw[i] == 43 else { return nil }
        i += 1
        guard let c = number() else { return nil }
        var d = 1
        if i < e, raw[i] == 44 { i += 1; d = number() ?? 1 }
        return (a, b, c, d)
    }

    // MARK: Rows

    func sideBySideRows() -> [DiffRow] {
        var rows: [DiffRow] = []
        rows.reserveCapacity(lines.count + hunks.count)
        var prevOldEnd = 1
        for (hi, h) in hunks.enumerated() {
            let gap = h.oldStart - prevOldEnd
            if gap > 0 && h.oldCount > 0 {
                rows.append(DiffRow(kind: .gap, left: -1, right: -1, hunk: Int32(hi), gap: Int32(gap)))
            }
            var i = h.firstLine
            let end = h.firstLine + h.lineCount
            while i < end {
                if lines[i].kind == .context {
                    rows.append(DiffRow(kind: .context, left: Int32(i), right: Int32(i), hunk: Int32(hi), gap: 0))
                    i += 1
                    continue
                }
                var dels: [Int] = []
                var adds: [Int] = []
                while i < end && lines[i].kind == .deleted { dels.append(i); i += 1 }
                while i < end && lines[i].kind == .added { adds.append(i); i += 1 }
                for k in 0..<max(dels.count, adds.count) {
                    let l = k < dels.count ? Int32(dels[k]) : -1
                    let r = k < adds.count ? Int32(adds[k]) : -1
                    let kind: RowKind = (l >= 0 && r >= 0) ? .changed : (l >= 0 ? .deleted : .added)
                    rows.append(DiffRow(kind: kind, left: l, right: r, hunk: Int32(hi), gap: 0))
                }
            }
            prevOldEnd = h.oldStart + h.oldCount
        }
        return rows
    }

    func unifiedRows() -> [DiffRow] {
        var rows: [DiffRow] = []
        rows.reserveCapacity(lines.count + hunks.count)
        var prevOldEnd = 1
        for (hi, h) in hunks.enumerated() {
            let gap = h.oldStart - prevOldEnd
            if gap > 0 && h.oldCount > 0 {
                rows.append(DiffRow(kind: .gap, left: -1, right: -1, hunk: Int32(hi), gap: Int32(gap)))
            }
            for i in h.lines {
                switch lines[i].kind {
                case .context: rows.append(DiffRow(kind: .context, left: Int32(i), right: Int32(i), hunk: Int32(hi), gap: 0))
                case .deleted: rows.append(DiffRow(kind: .deleted, left: Int32(i), right: -1, hunk: Int32(hi), gap: 0))
                case .added: rows.append(DiffRow(kind: .added, left: -1, right: Int32(i), hunk: Int32(hi), gap: 0))
                }
            }
            prevOldEnd = h.oldStart + h.oldCount
        }
        return rows
    }

    // MARK: Patches for staging

    private func appendLine(_ out: inout [UInt8], prefix: UInt8, _ l: DiffLine) {
        out.append(prefix)
        out.append(contentsOf: raw[Int(l.start)..<Int(l.start + l.length)])
        out.append(10)
        if l.noNewline { out.append(contentsOf: Array("\\ No newline at end of file\n".utf8)) }
    }

    private static func prefix(_ k: DiffLineKind) -> UInt8 {
        switch k {
        case .context: return 32
        case .deleted: return 45
        case .added: return 43
        }
    }

    /// Patch containing whole hunks.
    func patch(hunks selected: Set<Int>) -> Data? {
        var out = headerBytes
        var any = false
        for (hi, h) in hunks.enumerated() where selected.contains(hi) {
            any = true
            out.append(contentsOf: Array("@@ -\(h.oldStart),\(h.oldCount) +\(h.newStart),\(h.newCount) @@\n".utf8))
            for i in h.lines { appendLine(&out, prefix: FileDiff.prefix(lines[i].kind), lines[i]) }
        }
        return any ? Data(out) : nil
    }

    /// Patch containing only the selected +/- lines. `reverse` = the patch will
    /// be applied with `git apply -R` (unstaging, discarding).
    func patch(lines selected: Set<Int>, reverse: Bool) -> Data? {
        var out = headerBytes
        var any = false
        var delta = 0
        for h in hunks {
            var body: [UInt8] = []
            var oldC = 0, newC = 0
            var hunkHasChange = false
            for i in h.lines {
                let l = lines[i]
                let sel = selected.contains(i)
                switch l.kind {
                case .context:
                    appendLine(&body, prefix: 32, l); oldC += 1; newC += 1
                case .deleted:
                    if sel { appendLine(&body, prefix: 45, l); oldC += 1; hunkHasChange = true }
                    else if !reverse { appendLine(&body, prefix: 32, l); oldC += 1; newC += 1 }
                case .added:
                    if sel { appendLine(&body, prefix: 43, l); newC += 1; hunkHasChange = true }
                    else if reverse { appendLine(&body, prefix: 32, l); oldC += 1; newC += 1 }
                }
            }
            guard hunkHasChange else { continue }
            any = true
            let oldStart = reverse ? h.oldStart : h.oldStart
            let newStart = reverse ? h.newStart : h.oldStart + delta
            out.append(contentsOf: Array("@@ -\(oldStart),\(oldC) +\(newStart),\(newC) @@\n".utf8))
            out.append(contentsOf: body)
            delta += newC - oldC
        }
        return any ? Data(out) : nil
    }
}
