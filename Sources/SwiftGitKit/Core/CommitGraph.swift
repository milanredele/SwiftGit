import Foundation

/// A commit hash stored in 20 bytes (SHA-1). For SHA-256 repositories the first
/// 40 hex digits are kept, which git accepts as an unambiguous prefix.
struct Hash20: Hashable {
    var a: UInt64 = 0
    var b: UInt64 = 0
    var c: UInt32 = 0

    init() {}

    init?(_ hex: String) {
        var bytes = Array(hex.utf8)
        guard bytes.count >= 40 else { return nil }
        bytes = Array(bytes[0..<40])
        guard let h = bytes.withUnsafeBufferPointer({ Hash20(ascii: $0, at: 0) }) else { return nil }
        self = h
    }

    /// Parses 40 ASCII hex digits starting at `at`.
    init?(ascii p: UnsafeBufferPointer<UInt8>, at start: Int) {
        guard start + 40 <= p.count else { return nil }
        var a: UInt64 = 0, b: UInt64 = 0, c: UInt32 = 0
        for i in 0..<40 {
            guard let v = Hash20.hexValue(p[start + i]) else { return nil }
            if i < 16 { a = a << 4 | UInt64(v) }
            else if i < 32 { b = b << 4 | UInt64(v) }
            else { c = c << 4 | UInt32(v) }
        }
        self.a = a; self.b = b; self.c = c
    }

    @inline(__always)
    static func hexValue(_ ch: UInt8) -> UInt8? {
        switch ch {
        case 48...57: return ch - 48
        case 97...102: return ch - 87
        case 65...70: return ch - 55
        default: return nil
        }
    }

    private static let digits: [UInt8] = Array("0123456789abcdef".utf8)

    var hex: String {
        var out = [UInt8](repeating: 0, count: 40)
        for i in 0..<16 { out[i] = Hash20.digits[Int((a >> UInt64(60 - i * 4)) & 0xF)] }
        for i in 0..<16 { out[16 + i] = Hash20.digits[Int((b >> UInt64(60 - i * 4)) & 0xF)] }
        for i in 0..<8 { out[32 + i] = Hash20.digits[Int((c >> UInt32(28 - i * 4)) & 0xF)] }
        return String(decoding: out, as: UTF8.self)
    }

    var short: String { String(hex.prefix(8)) }
}

/// Commit topology and graph lanes for the whole history, in flat arrays.
/// About 49 bytes per commit: hash (24) + node lane (1) + three lane masks (24).
///
/// Lane masks per row (bit n = lane n, lanes ≥ 64 are not drawn):
///  - through:   lanes passing straight through the row
///  - topIn:     lanes coming from the top into this row's node
///  - bottomOut: lanes leaving the node towards the bottom (to parents)
final class CommitGraph: @unchecked Sendable {
    fileprivate(set) var hashes: [Hash20] = []
    fileprivate(set) var nodeLane: [UInt8] = []
    fileprivate(set) var through: [UInt64] = []
    fileprivate(set) var topIn: [UInt64] = []
    fileprivate(set) var bottomOut: [UInt64] = []
    fileprivate(set) var maxLanes = 0

    var count: Int { hashes.count }

    func row(of hash: Hash20) -> Int? { hashes.firstIndex(of: hash) }

    var approximateBytes: Int {
        hashes.capacity * MemoryLayout<Hash20>.stride + nodeLane.capacity
            + (through.capacity + topIn.capacity + bottomOut.capacity) * 8
    }

    fileprivate func compact() {
        hashes = hashes.withUnsafeBufferPointer { Array($0) }
        nodeLane = nodeLane.withUnsafeBufferPointer { Array($0) }
        through = through.withUnsafeBufferPointer { Array($0) }
        topIn = topIn.withUnsafeBufferPointer { Array($0) }
        bottomOut = bottomOut.withUnsafeBufferPointer { Array($0) }
    }
}

/// Builds a CommitGraph from streamed `git log --topo-order --format=%H %P` output.
final class GraphBuilder: @unchecked Sendable {
    private let graph = CommitGraph()
    private var lanes: [Hash20?] = []
    private var line: [UInt8] = []

    init() {
        line.reserveCapacity(256)
    }

    func feed(_ data: Data) {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for byte in raw {
                if byte == 10 {
                    processLine()
                    line.removeAll(keepingCapacity: true)
                } else {
                    line.append(byte)
                }
            }
        }
    }

    func finish() -> CommitGraph {
        if !line.isEmpty { processLine() }
        lanes = []
        graph.compact()
        return graph
    }

    @inline(__always)
    private func bit(_ lane: Int) -> UInt64 { lane < 64 ? (UInt64(1) << UInt64(lane)) : 0 }

    private func firstFreeLane() -> Int {
        if let i = lanes.firstIndex(where: { $0 == nil }) { return i }
        lanes.append(nil)
        return lanes.count - 1
    }

    private func processLine() {
        var ids: [Hash20] = []
        line.withUnsafeBufferPointer { p in
            var i = 0
            while i < p.count {
                while i < p.count && p[i] == 32 { i += 1 }
                let start = i
                while i < p.count && p[i] != 32 { i += 1 }
                if i - start >= 40, let h = Hash20(ascii: p, at: start) { ids.append(h) }
            }
        }
        guard let commit = ids.first else { return }
        let parents = ids.dropFirst()

        var topIn: UInt64 = 0
        var node = -1
        for j in 0..<lanes.count where lanes[j] == commit {
            topIn |= bit(j)
            if node < 0 { node = j }
            lanes[j] = nil
        }
        if node < 0 { node = firstFreeLane() }

        var through: UInt64 = 0
        for j in 0..<lanes.count where lanes[j] != nil { through |= bit(j) }

        var bottomOut: UInt64 = 0
        var first = true
        for p in parents {
            if let existing = lanes.firstIndex(where: { $0 == p }) {
                bottomOut |= bit(existing)
            } else if first {
                while lanes.count <= node { lanes.append(nil) }
                lanes[node] = p
                bottomOut |= bit(node)
            } else {
                let k = firstFreeLane()
                lanes[k] = p
                bottomOut |= bit(k)
            }
            first = false
        }
        while let last = lanes.last, last == nil { lanes.removeLast() }

        graph.hashes.append(commit)
        graph.nodeLane.append(UInt8(min(node, 255)))
        graph.through.append(through)
        graph.topIn.append(topIn)
        graph.bottomOut.append(bottomOut)
        graph.maxLanes = max(graph.maxLanes, node + 1, lanes.count)
    }
}

/// One line of the history list, fetched lazily for the visible rows.
struct CommitSummary {
    var subject: String
    var author: String
    var time: Int64
}

/// Small LRU of summary blocks (~2,000 rows) so memory stays flat while scrolling.
final class SummaryCache {
    static let blockSize = 256
    private let maxBlocks = 8
    private var blocks: [Int: [CommitSummary]] = [:]
    private var lru: [Int] = []
    private(set) var pending = Set<Int>()

    func summary(row: Int) -> CommitSummary? {
        let b = row / SummaryCache.blockSize
        guard let block = blocks[b] else { return nil }
        let i = row - b * SummaryCache.blockSize
        return i < block.count ? block[i] : nil
    }

    func needsLoad(block: Int) -> Bool { blocks[block] == nil && !pending.contains(block) }
    func markPending(_ block: Int) { pending.insert(block) }

    func store(block: Int, _ items: [CommitSummary]) {
        pending.remove(block)
        blocks[block] = items
        lru.removeAll { $0 == block }
        lru.append(block)
        while lru.count > maxBlocks {
            let old = lru.removeFirst()
            blocks[old] = nil
        }
    }

    func clear() {
        blocks.removeAll()
        lru.removeAll()
        pending.removeAll()
    }
}
