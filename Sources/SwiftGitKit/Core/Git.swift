import Foundation

/// Thin wrapper around the git binary for one repository.
final class Git: @unchecked Sendable {
    let root: URL

    init(root: URL) {
        self.root = root
    }

    static var executable: String { Tooling.find("git") ?? "/usr/bin/git" }

    /// Options that make output stable regardless of the user's config.
    static let baseArgs = [
        "-c", "core.quotepath=off",
        "-c", "color.ui=false",
        "-c", "diff.noprefix=false",
        "-c", "diff.mnemonicPrefix=false",
        "-c", "log.showSignature=false",
    ]

    func run(_ args: [String],
             stdin: Data? = nil,
             environment: [String: String] = [:],
             cancel: CancelToken? = nil,
             onStdout: (@Sendable (Data) -> Void)? = nil,
             onStderrLine: (@Sendable (String) -> Void)? = nil) async -> RunResult {
        await ProcessRunner.run(executable: Git.executable, arguments: Git.baseArgs + args, cwd: root,
                                stdin: stdin, environment: environment, cancel: cancel,
                                onStdout: onStdout, onStderrLine: onStderrLine)
    }
}

// MARK: - Working tree status

struct FileChange: Hashable {
    var path: String
    var origPath: String?
    /// M, A, D, R, C, T, U (conflict) or ? (untracked)
    var code: Character

    var isUntracked: Bool { code == "?" }
    var isConflict: Bool { code == "U" }
}

struct WorkingStatus {
    var branch: String?
    var headOID: String?
    var upstream: String?
    var ahead = 0
    var behind = 0
    var staged: [FileChange] = []
    var unstaged: [FileChange] = []
    var conflicts: [FileChange] = []

    var changeCount: Int { staged.count + unstaged.count + conflicts.count }

    /// Parses `git status --porcelain=v2 -z --branch`.
    static func parse(_ data: Data) -> WorkingStatus {
        var s = WorkingStatus()
        let fields = data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }

        func add(_ xy: Substring, _ path: String, _ orig: String?) {
            guard xy.count == 2 else { return }
            let x = xy.first!, y = xy.last!
            if x != "." { s.staged.append(FileChange(path: path, origPath: orig, code: x)) }
            if y != "." { s.unstaged.append(FileChange(path: path, origPath: nil, code: y)) }
        }

        var i = 0
        while i < fields.count {
            let f = fields[i]
            i += 1
            guard let t = f.first else { continue }
            switch t {
            case "#":
                let parts = f.split(separator: " ", maxSplits: 2).map(String.init)
                guard parts.count == 3 else { continue }
                switch parts[1] {
                case "branch.oid": s.headOID = parts[2] == "(initial)" ? nil : parts[2]
                case "branch.head": s.branch = parts[2] == "(detached)" ? nil : parts[2]
                case "branch.upstream": s.upstream = parts[2]
                case "branch.ab":
                    for p in parts[2].split(separator: " ") {
                        if p.hasPrefix("+") { s.ahead = Int(p.dropFirst()) ?? 0 }
                        if p.hasPrefix("-") { s.behind = Int(p.dropFirst()) ?? 0 }
                    }
                default: break
                }
            case "1":
                let parts = f.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
                guard parts.count == 9 else { continue }
                add(parts[1], String(parts[8]), nil)
            case "2":
                let parts = f.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
                let orig: String? = i < fields.count ? fields[i] : nil
                i += 1
                guard parts.count == 10 else { continue }
                add(parts[1], String(parts[9]), orig)
            case "u":
                let parts = f.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
                guard parts.count == 11 else { continue }
                s.conflicts.append(FileChange(path: String(parts[10]), origPath: nil, code: "U"))
            case "?":
                s.unstaged.append(FileChange(path: String(f.dropFirst(2)), origPath: nil, code: "?"))
            default:
                break
            }
        }
        return s
    }
}

// MARK: - Refs

enum RefKind: Int {
    case local, remote, tag
}

struct RefInfo: Hashable {
    var fullName: String
    var name: String
    var kind: RefKind
    var target: String
    var upstream: String?
    var ahead = 0
    var behind = 0
    var upstreamGone = false
    var isHead = false
    /// Unix time of the tip commit (tagger date for annotated tags).
    var date: Int64 = 0
    /// Fully merged into the repository's main branch (local branches only).
    var isMerged = false
    /// Merged by squash or rebase (content is in main, history is not).
    var mergedByContent = false

    /// Merged into main, or its upstream was deleted on the remote: likely done.
    var isStale: Bool { kind == .local && !isHead && (upstreamGone || isMerged) }

    var remoteName: String? {
        guard kind == .remote, let slash = name.firstIndex(of: "/") else { return nil }
        return String(name[..<slash])
    }

    var remoteBranch: String? {
        guard kind == .remote, let slash = name.firstIndex(of: "/") else { return nil }
        return String(name[name.index(after: slash)...])
    }

    static let format = "%(refname)%09%(objectname)%09%(*objectname)%09%(upstream:short)%09%(upstream:track,nobracket)%09%(HEAD)%09%(creatordate:unix)%09%(symref:short)"

    /// Remote default branches from `refs/remotes/<remote>/HEAD`, e.g. ["origin": "origin/main"].
    static func parseRemoteHeads(_ text: String) -> [String: String] {
        var heads: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count == 8, f[0].hasPrefix("refs/remotes/"), f[0].hasSuffix("/HEAD"), !f[7].isEmpty else { continue }
            let remote = String(f[0].dropFirst(13).dropLast(5))
            heads[remote] = f[7]
        }
        return heads
    }

    static func parse(_ text: String) -> [RefInfo] {
        var refs: [RefInfo] = []
        for line in text.split(separator: "\n") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count == 8 else { continue }
            let full = f[0]
            var r: RefInfo
            if full.hasPrefix("refs/heads/") {
                r = RefInfo(fullName: full, name: String(full.dropFirst(11)), kind: .local, target: f[1])
            } else if full.hasPrefix("refs/remotes/") {
                if full.hasSuffix("/HEAD") { continue }
                r = RefInfo(fullName: full, name: String(full.dropFirst(13)), kind: .remote, target: f[1])
            } else if full.hasPrefix("refs/tags/") {
                r = RefInfo(fullName: full, name: String(full.dropFirst(10)), kind: .tag,
                            target: f[2].isEmpty ? f[1] : f[2])
            } else {
                continue
            }
            r.upstream = f[3].isEmpty ? nil : f[3]
            let track = f[4]
            if track == "gone" { r.upstreamGone = true }
            for part in track.split(separator: ",") {
                let kv = part.trimmingCharacters(in: .whitespaces).split(separator: " ")
                guard kv.count == 2, let n = Int(kv[1]) else { continue }
                if kv[0] == "ahead" { r.ahead = n }
                if kv[0] == "behind" { r.behind = n }
            }
            r.isHead = f[5] == "*"
            r.date = Int64(f[6]) ?? 0
            refs.append(r)
        }
        return refs
    }
}

struct StashInfo: Hashable {
    var ref: String
    var hash: String
    var message: String

    static func parse(_ text: String) -> [StashInfo] {
        text.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard f.count == 3 else { return nil }
            return StashInfo(ref: f[0], hash: f[1], message: f[2])
        }
    }
}

struct RemoteInfo: Hashable {
    var name: String
    var url: String

    static func parse(_ text: String) -> [RemoteInfo] {
        var result: [RemoteInfo] = []
        for line in text.split(separator: "\n") where line.hasSuffix("(fetch)") {
            let f = line.split(whereSeparator: { $0 == "\t" || $0 == " " })
            guard f.count >= 2 else { continue }
            result.append(RemoteInfo(name: String(f[0]), url: String(f[1])))
        }
        return result
    }
}

/// Details of one commit, loaded on selection.
struct CommitDetail {
    var hash: String
    var parents: [String]
    var author: String
    var authorEmail: String
    var authorTime: Date
    var committer: String
    var commitTime: Date
    var message: String
    var files: [FileChange]

    static let format = "%H%x00%P%x00%an%x00%ae%x00%at%x00%cn%x00%ct%x00%B"

    static func parseHeader(_ data: Data) -> CommitDetail? {
        let f = data.split(separator: 0, maxSplits: 7, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        guard f.count == 8 else { return nil }
        return CommitDetail(hash: f[0].trimmingCharacters(in: .whitespacesAndNewlines),
                            parents: f[1].split(separator: " ").map(String.init),
                            author: f[2], authorEmail: f[3],
                            authorTime: Date(timeIntervalSince1970: Double(f[4]) ?? 0),
                            committer: f[5],
                            commitTime: Date(timeIntervalSince1970: Double(f[6]) ?? 0),
                            message: f[7].trimmingCharacters(in: .whitespacesAndNewlines),
                            files: [])
    }

    /// Parses `--name-status -z` output.
    static func parseNameStatus(_ data: Data) -> [FileChange] {
        let fields = data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        var files: [FileChange] = []
        var i = 0
        while i < fields.count {
            let status = fields[i].trimmingCharacters(in: .whitespacesAndNewlines)
            i += 1
            guard let code = status.first else { continue }
            if code == "R" || code == "C" {
                guard i + 1 < fields.count else { break }
                files.append(FileChange(path: fields[i + 1], origPath: fields[i], code: code))
                i += 2
            } else {
                guard i < fields.count else { break }
                files.append(FileChange(path: fields[i], origPath: nil, code: code))
                i += 1
            }
        }
        return files
    }
}

enum OperationState: Equatable {
    case none
    case merging
    case rebasing
    case cherryPicking
    case reverting

    var title: String {
        switch self {
        case .none: return ""
        case .merging: return "Merge in progress"
        case .rebasing: return "Rebase in progress"
        case .cherryPicking: return "Cherry-pick in progress"
        case .reverting: return "Revert in progress"
        }
    }
}

/// The SHA-1 of git's empty tree, used to diff root commits.
let emptyTreeHash = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

/// One commit of a branch, as used for pull request text.
struct BranchCommit: Equatable {
    var hash: String
    var subject: String
    var body: String

    /// The full message: subject, blank line, body.
    var message: String { body.isEmpty ? subject : subject + "\n\n" + body }

    /// Parses `git log --format=%H%x1f%s%x1f%b%x1e`.
    static func parse(_ text: String) -> [BranchCommit] {
        text.split(separator: "\u{1e}").compactMap { record in
            let f = record.split(separator: "\u{1f}", maxSplits: 2, omittingEmptySubsequences: false)
            let hash = f[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard f.count >= 2, hash.count >= 7 else { return nil }
            return BranchCommit(hash: hash,
                                subject: String(f[1]).trimmingCharacters(in: .whitespacesAndNewlines),
                                body: f.count > 2 ? String(f[2]).trimmingCharacters(in: .whitespacesAndNewlines) : "")
        }
    }
}

/// Commit message conventions, e.g. Conventional Commits ("feat(ui): …").
enum CommitStyle {
    struct Prefix: Equatable {
        var type: String
        var scope: String?
        var breaking: Bool
        var text: String { type + (scope.map { "(\($0))" } ?? "") + (breaking ? "!" : "") + ":" }
    }

    private static let pattern = try! NSRegularExpression(pattern: #"^([a-z][a-z0-9-]*)(?:\(([^)\n]+)\))?(!)?:\s+\S"#)

    /// The conventional-commit prefix of a subject line, if it has one.
    static func prefix(of subject: String) -> Prefix? {
        let ns = subject as NSString
        guard let m = pattern.firstMatch(in: subject, range: NSRange(location: 0, length: ns.length)) else { return nil }
        func group(_ i: Int) -> String? {
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
        guard let type = group(1) else { return nil }
        return Prefix(type: type, scope: group(2), breaking: group(3) != nil)
    }

    /// Most significant first; anything else ranks after these.
    static let typeOrder = ["feat", "fix", "perf", "refactor", "revert", "build", "ci", "docs", "style", "test", "chore"]

    /// The prefix a pull request should use when (at least half of) the commits
    /// use one: the most significant type, a scope only if all share it, and
    /// "!" if any commit is breaking. nil when the commits don't follow it.
    static func pullRequestPrefix(_ subjects: [String]) -> Prefix? {
        let parsed = subjects.compactMap(prefix(of:))
        guard !parsed.isEmpty, parsed.count * 2 >= subjects.count else { return nil }
        let types = parsed.map(\.type)
        let counts = Dictionary(types.map { ($0, 1) }, uniquingKeysWith: +)
        let type = typeOrder.first(where: { counts[$0] != nil })
            ?? counts.max { a, b in a.value < b.value || (a.value == b.value && a.key > b.key) }!.key
        let scopes = Set(parsed.map { $0.scope ?? "" })
        let scope = scopes.count == 1 ? parsed[0].scope : nil
        return Prefix(type: type, scope: scope, breaking: parsed.contains { $0.breaking })
    }

    /// Puts `prefix` in front of `title` unless it already has one.
    static func apply(_ prefix: Prefix?, to title: String) -> String {
        guard let prefix, self.prefix(of: title) == nil else { return title }
        var rest = title
        // "Feat: x" / "[feat] x" style near-misses: replace rather than double up.
        if let r = rest.range(of: #"^\[?[A-Za-z]+\]?:?\s+"#, options: .regularExpression),
           rest[r].trimmingCharacters(in: CharacterSet(charactersIn: "[]: ")).lowercased() == prefix.type {
            rest = String(rest[r.upperBound...])
        }
        return prefix.text + " " + rest
    }
}

/// Why a pull failed, from git's output.
enum PullProblem: Equatable {
    /// Uncommitted changes are in the way (fixable by stashing them first).
    case localChanges
    /// Fast-forward only was requested but the branches diverged.
    case notFastForward
    case other

    static func classify(_ output: String) -> PullProblem {
        let s = output.lowercased()
        if s.contains("would be overwritten by") || s.contains("you have unstaged changes")
            || s.contains("your index contains uncommitted changes") || s.contains("commit your changes or stash them") {
            return .localChanges
        }
        if s.contains("not possible to fast-forward") || s.contains("diverging branches can't be fast-forwarded") {
            return .notFastForward
        }
        return .other
    }

    /// git kept the stashed changes because re-applying them conflicted.
    static func autostashConflicted(_ output: String) -> Bool {
        output.lowercased().contains("autostash resulted in conflicts")
    }
}

/// Why a push was refused, from git's stderr.
enum PushProblem: Equatable {
    /// The remote branch has commits the local one doesn't (rebased/amended
    /// locally, or someone else pushed): needs a pull or a force push.
    case diverged
    /// --force-with-lease refused: the remote moved since the last fetch.
    case staleLease
    case other

    static func classify(_ stderr: String) -> PushProblem {
        let s = stderr.lowercased()
        if s.contains("stale info") { return .staleLease }
        if s.contains("non-fast-forward") || s.contains("fetch first") || s.contains("tip of your current branch is behind")
            || (s.contains("[rejected]") && s.contains("updates were rejected")) { return .diverged }
        return .other
    }
}
