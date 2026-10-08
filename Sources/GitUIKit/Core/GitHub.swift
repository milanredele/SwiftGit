import Foundation

struct GitHubRepo: Hashable {
    var owner: String
    var name: String
    var slug: String { "\(owner)/\(name)" }

    /// Accepts git@github.com:o/n.git, https://github.com/o/n(.git), ssh://git@github.com/o/n.git
    static func parse(remoteURL: String) -> GitHubRepo? {
        var s = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let r = s.range(of: "github.com") else { return nil }
        s = String(s[r.upperBound...])
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: ":/"))
        if s.hasSuffix(".git") { s.removeLast(4) }
        if s.hasSuffix("/") { s.removeLast() }
        let parts = s.split(separator: "/")
        guard parts.count >= 2 else { return nil }
        return GitHubRepo(owner: String(parts[0]), name: String(parts[1]))
    }
}

struct Reviewer: Hashable, Codable {
    /// Login for users, "org/slug" for teams (the form `gh pr create --reviewer` expects).
    var id: String
    var name: String
    var isTeam: Bool

    var title: String {
        if isTeam { return name.isEmpty ? id : "\(id) — \(name) (team)" }
        return name.isEmpty ? id : "\(id) — \(name)"
    }
}

struct GitHubError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

/// Talks to GitHub through the `gh` CLI, which already holds the user's login.
enum GitHub {
    static var executable: String? { Tooling.find("gh") }

    static let missingMessage = "The GitHub CLI (gh) was not found. Install it with `brew install gh` and run `gh auth login`."

    static func run(_ args: [String], cwd: URL?, stdin: Data? = nil) async -> RunResult {
        guard let gh = executable else {
            return RunResult(status: -1, stdout: Data(), stderr: missingMessage)
        }
        return await ProcessRunner.run(executable: gh, arguments: args, cwd: cwd, stdin: stdin)
    }

    private static func json(_ r: RunResult) -> [String: Any]? {
        guard r.ok else { return nil }
        return (try? JSONSerialization.jsonObject(with: r.stdout)) as? [String: Any]
    }

    static func viewerLogin() async -> String? {
        let r = await run(["api", "user", "--jq", ".login"], cwd: nil)
        let s = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return r.ok && !s.isEmpty ? s : nil
    }

    static func defaultBranch(_ repo: GitHubRepo) async -> String? {
        let r = await run(["repo", "view", repo.slug, "--json", "defaultBranchRef", "--jq", ".defaultBranchRef.name"], cwd: nil)
        let s = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return r.ok && !s.isEmpty ? s : nil
    }

    /// Assignable users (first 100) plus the organization's teams (if the owner is an org).
    static func reviewers(_ repo: GitHubRepo) async throws -> [Reviewer] {
        let userQuery = """
        query($owner: String!, $name: String!) {
          repository(owner: $owner, name: $name) {
            assignableUsers(first: 100) { nodes { login name } }
          }
        }
        """
        let r = await run(["api", "graphql", "-f", "query=\(userQuery)", "-F", "owner=\(repo.owner)", "-F", "name=\(repo.name)"], cwd: nil)
        guard r.ok else { throw GitHubError(message: r.errorMessage) }
        var result: [Reviewer] = []
        if let root = json(r),
           let data = root["data"] as? [String: Any],
           let repository = data["repository"] as? [String: Any],
           let users = repository["assignableUsers"] as? [String: Any],
           let nodes = users["nodes"] as? [[String: Any]] {
            for n in nodes {
                guard let login = n["login"] as? String else { continue }
                result.append(Reviewer(id: login, name: (n["name"] as? String) ?? "", isTeam: false))
            }
        }

        let teamQuery = """
        query($owner: String!) {
          organization(login: $owner) { teams(first: 100) { nodes { slug name } } }
        }
        """
        let t = await run(["api", "graphql", "-f", "query=\(teamQuery)", "-F", "owner=\(repo.owner)"], cwd: nil)
        if let root = json(t),
           let data = root["data"] as? [String: Any],
           let org = data["organization"] as? [String: Any],
           let teams = org["teams"] as? [String: Any],
           let nodes = teams["nodes"] as? [[String: Any]] {
            for n in nodes {
                guard let slug = n["slug"] as? String else { continue }
                result.append(Reviewer(id: "\(repo.owner)/\(slug)", name: (n["name"] as? String) ?? "", isTeam: true))
            }
        }
        return result.sorted { ($0.isTeam ? 1 : 0, $0.id.lowercased()) < ($1.isTeam ? 1 : 0, $1.id.lowercased()) }
    }

    // MARK: Reviewer cache on disk (not in memory)

    private static func cacheURL(_ repo: GitHubRepo) -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GitUI", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("reviewers-\(repo.owner)-\(repo.name).json")
    }

    static func cachedReviewers(_ repo: GitHubRepo) -> [Reviewer] {
        guard let data = try? Data(contentsOf: cacheURL(repo)) else { return [] }
        return (try? JSONDecoder().decode([Reviewer].self, from: data)) ?? []
    }

    static func storeReviewers(_ list: [Reviewer], for repo: GitHubRepo) {
        if let data = try? JSONEncoder().encode(list) { try? data.write(to: cacheURL(repo)) }
    }

    // MARK: Pull requests

    struct PullRequestRequest {
        var repo: GitHubRepo
        var base: String
        var head: String
        var title: String
        var body: String
        var reviewers: [String]
        var draft: Bool
    }

    /// Returns the URL of the created pull request.
    static func createPullRequest(_ req: PullRequestRequest, cwd: URL) async throws -> String {
        var args = ["pr", "create", "--repo", req.repo.slug, "--base", req.base, "--head", req.head,
                    "--title", req.title, "--body-file", "-"]
        if !req.reviewers.isEmpty { args += ["--reviewer", req.reviewers.joined(separator: ",")] }
        if req.draft { args.append("--draft") }
        let r = await run(args, cwd: cwd, stdin: Data(req.body.utf8))
        guard r.ok else { throw GitHubError(message: r.errorMessage) }
        let lines = r.output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        return lines.last(where: { $0.hasPrefix("https://") }) ?? r.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
