import Foundation

/// Word-level differences between two paired lines, as UTF-16 ranges.
enum Intraline {
    private static func tokens(_ s: [UInt16]) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var i = 0
        func isWord(_ c: UInt16) -> Bool {
            (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c > 127
        }
        func isSpace(_ c: UInt16) -> Bool { c == 32 || c == 9 }
        while i < s.count {
            let start = i
            let c = s[i]
            if isWord(c) {
                while i < s.count && isWord(s[i]) { i += 1 }
            } else if isSpace(c) {
                while i < s.count && isSpace(s[i]) { i += 1 }
            } else {
                i += 1
            }
            out.append(start..<i)
        }
        return out
    }

    /// Returns changed ranges in `a` and `b`. Empty when the lines are too
    /// different for word highlighting to be useful.
    static func compute(_ aStr: String, _ bStr: String) -> (old: [NSRange], new: [NSRange]) {
        let a = Array(aStr.utf16), b = Array(bStr.utf16)
        let ta = tokens(a), tb = tokens(b)
        let n = ta.count, m = tb.count
        if n == 0 || m == 0 { return ([], []) }

        func eq(_ i: Int, _ j: Int) -> Bool { a[ta[i]] == b[tb[j]] }

        var pre = 0
        while pre < n && pre < m && eq(pre, pre) { pre += 1 }
        var suf = 0
        while suf < n - pre && suf < m - pre && eq(n - 1 - suf, m - 1 - suf) { suf += 1 }

        let an = n - pre - suf, bm = m - pre - suf
        var matchA = [Bool](repeating: false, count: n)
        var matchB = [Bool](repeating: false, count: m)
        for i in 0..<pre { matchA[i] = true; matchB[i] = true }
        for k in 0..<suf { matchA[n - 1 - k] = true; matchB[m - 1 - k] = true }

        if an > 0 && bm > 0 && an * bm <= 40_000 {
            // LCS on the middle part
            let w = bm + 1
            var dp = [Int32](repeating: 0, count: (an + 1) * w)
            for i in stride(from: an - 1, through: 0, by: -1) {
                for j in stride(from: bm - 1, through: 0, by: -1) {
                    dp[i * w + j] = eq(pre + i, pre + j)
                        ? dp[(i + 1) * w + j + 1] + 1
                        : max(dp[(i + 1) * w + j], dp[i * w + j + 1])
                }
            }
            var i = 0, j = 0
            while i < an && j < bm {
                if eq(pre + i, pre + j) {
                    matchA[pre + i] = true; matchB[pre + j] = true; i += 1; j += 1
                } else if dp[(i + 1) * w + j] >= dp[i * w + j + 1] {
                    i += 1
                } else {
                    j += 1
                }
            }
        }

        // Skip highlighting when most of the line changed.
        let matchedChars = (0..<n).reduce(0) { $0 + (matchA[$1] ? ta[$1].count : 0) }
        if a.count > 0 && Double(matchedChars) / Double(a.count) < 0.3 { return ([], []) }

        func ranges(_ t: [Range<Int>], _ match: [Bool]) -> [NSRange] {
            var out: [NSRange] = []
            var k = 0
            while k < t.count {
                if match[k] { k += 1; continue }
                let start = t[k].lowerBound
                var end = t[k].upperBound
                k += 1
                while k < t.count && !match[k] { end = t[k].upperBound; k += 1 }
                out.append(NSRange(location: start, length: end - start))
            }
            return out
        }
        return (ranges(ta, matchA), ranges(tb, matchB))
    }
}
