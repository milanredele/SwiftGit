import Foundation

/// Names for the two sides of a conflict, which depend on the operation:
/// in a rebase "ours" is the branch being rebased onto and "theirs" is your commit.
struct ConflictSides: Equatable {
    var ours: String
    var theirs: String
    /// One sentence explaining which side is which.
    var explanation: String
}

enum ConflictSide { case ours, theirs }

extension Repository {
    func conflictSides() async -> ConflictSides {
        let branch = status.branch ?? "HEAD"
        func read(_ name: String) -> String? {
            (try? String(contentsOf: gitDir.appendingPathComponent(name), encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func shortName(_ sha: String) async -> String {
            let r = await git.run(["name-rev", "--name-only", "--no-undefined", "--refs=refs/heads/*", "--refs=refs/remotes/*", sha])
            let n = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
            return r.ok && !n.isEmpty && !n.contains("~") && !n.contains("^") ? n.replacingOccurrences(of: "remotes/", with: "") : String(sha.prefix(8))
        }
        switch opState {
        case .rebasing:
            let dir = FileManager.default.fileExists(atPath: gitDir.appendingPathComponent("rebase-merge").path) ? "rebase-merge" : "rebase-apply"
            let head = read("\(dir)/head-name").map { $0.replacingOccurrences(of: "refs/heads/", with: "") } ?? "your branch"
            let onto = await read("\(dir)/onto").asyncMap(shortName) ?? "the new base"
            return ConflictSides(ours: onto, theirs: head,
                                 explanation: "Rebasing \(head) onto \(onto): “\(onto)” is the version already there, “\(head)” is your commit being replayed.")
        case .merging:
            var theirs = "the merged branch"
            if let msg = read("MERGE_MSG")?.split(separator: "\n").first.map(String.init),
               let open = msg.firstIndex(of: "'"), let close = msg[msg.index(after: open)...].firstIndex(of: "'") {
                theirs = String(msg[msg.index(after: open)..<close])
            } else if let sha = read("MERGE_HEAD") {
                theirs = await shortName(sha)
            }
            return ConflictSides(ours: branch, theirs: theirs, explanation: "Merging \(theirs) into \(branch).")
        case .cherryPicking:
            return ConflictSides(ours: branch, theirs: "picked commit",
                                 explanation: "Cherry-picking a commit onto \(branch).")
        case .reverting:
            return ConflictSides(ours: branch, theirs: "revert",
                                 explanation: "Reverting a commit on \(branch).")
        case .none:
            return ConflictSides(ours: branch, theirs: "incoming", explanation: "")
        }
    }

    /// What happened to a conflicted file, in words.
    static func describeConflict(_ xy: String?, _ sides: ConflictSides) -> String {
        switch xy {
        case "DU": return "Deleted in \(sides.ours), changed in \(sides.theirs)."
        case "UD": return "Changed in \(sides.ours), deleted in \(sides.theirs)."
        case "AA": return "Added on both sides with different content."
        case "AU": return "Added in \(sides.ours) and conflicting with \(sides.theirs)."
        case "UA": return "Added in \(sides.theirs) and conflicting with \(sides.ours)."
        case "DD": return "Deleted on both sides (a rename conflict)."
        default: return "Both sides changed the same lines."
        }
    }

    /// Resolves each file by taking one side's whole version (or its deletion) and stages it.
    @discardableResult
    func resolveConflicts(_ files: [FileChange], keeping side: ConflictSide) async -> Bool {
        let flag = side == .ours ? "--ours" : "--theirs"
        var ok = true
        for f in files where f.isConflict {
            let deletedOnChosenSide = (side == .ours && (f.conflictXY == "DU" || f.conflictXY == "DD"))
                || (side == .theirs && (f.conflictXY == "UD" || f.conflictXY == "DD"))
            let args = deletedOnChosenSide ? ["rm", "-q", "--", f.path] : ["checkout", flag, "--", f.path]
            let r = await perform("Resolve \(f.path)", args)
            guard r.ok else { ok = false; continue }
            if !deletedOnChosenSide {
                ok = await perform("Resolve \(f.path)", ["add", "--", f.path]).ok && ok
            }
        }
        return ok
    }

    /// Conflicted files that still contain conflict markers.
    func filesWithConflictMarkers(_ files: [FileChange]) -> [String] {
        files.filter { f in
            guard let data = FileManager.default.contents(atPath: root.appendingPathComponent(f.path).path) else { return false }
            let text = String(decoding: data.prefix(5_000_000), as: UTF8.self)
            return text.contains("\n<<<<<<< ") || text.hasPrefix("<<<<<<< ") || text.contains("\n>>>>>>> ")
        }.map(\.path)
    }

    /// Stages the files as resolved (deleted files are removed).
    func markResolved(_ files: [FileChange]) async {
        await perform("Mark resolved", ["add", "-A", "--"] + files.map(\.path))
    }
}

private extension Optional where Wrapped == String {
    func asyncMap(_ f: (String) async -> String) async -> String? {
        guard let s = self else { return nil }
        return await f(s)
    }
}
