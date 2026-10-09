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

    struct Account: Equatable {
        var host: String
        var login: String
        var isActive: Bool
        /// false when gh reports the stored token as invalid.
        var isValid: Bool
    }

    /// Parses `gh auth status` (gh ≥ 2.40 lists every account per host).
    static func parseAuthStatus(_ text: String) -> [Account] {
        var accounts: [Account] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            for (marker, valid) in [("Logged in to ", true), ("Failed to log in to ", false)] {
                guard let r = line.range(of: marker) else { continue }
                let words = line[r.upperBound...].split(separator: " ")
                // "<host> account <login> (...)" or older "<host> as <login> (...)"
                guard words.count >= 3, words[1] == "account" || words[1] == "as" else { continue }
                accounts.append(Account(host: String(words[0]), login: String(words[2]), isActive: false, isValid: valid))
            }
            if line.hasPrefix("- Active account:"), !accounts.isEmpty {
                accounts[accounts.count - 1].isActive = line.hasSuffix("true")
            }
        }
        // Older gh versions have one account per host and no "Active account" line.
        let hosts = Set(accounts.map(\.host))
        for h in hosts where !accounts.contains(where: { $0.host == h && $0.isActive }) {
            if let i = accounts.firstIndex(where: { $0.host == h }) { accounts[i].isActive = true }
        }
        return accounts
    }

    static func accounts() async -> [Account] {
        guard executable != nil else { return [] }
        let r = await run(["auth", "status"], cwd: nil)
        return parseAuthStatus(r.output + "\n" + r.stderr)
    }

    static func switchAccount(_ account: Account) async throws {
        let r = await run(["auth", "switch", "--hostname", account.host, "--user", account.login], cwd: nil)
        guard r.ok else { throw GitHubError(message: r.errorMessage) }
    }

    /// Logins of the organizations the active github.com account belongs to.
    /// Private memberships are only listed when the token has `read:org`
    /// (gh requests it by default). nil when the request failed.
    static func organizations() async -> [String]? {
        guard executable != nil else { return nil }
        let r = await run(["api", "user/orgs", "--paginate", "--jq", ".[].login"], cwd: nil)
        guard r.ok else { return nil }
        return parseLines(r.output)
    }

    static func parseLines(_ text: String) -> [String] {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
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
            .appendingPathComponent("SwiftGit", isDirectory: true)
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

    struct ExistingPullRequest: Equatable {
        var number: Int
        var url: String
        var title: String
        var body: String
        var isDraft: Bool
        var base: String
        /// Requested reviewers in `--reviewer` form (login, or org/team-slug).
        var reviewers: [String]
    }

    static let pullRequestFields = "number,url,title,body,isDraft,baseRefName,headRefName,reviewRequests"

    /// Parses `gh pr list --json <pullRequestFields>`; keeps PRs whose head is `head`.
    static func parsePullRequests(_ data: Data, head: String, owner: String) -> [ExistingPullRequest] {
        guard let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return list.compactMap { pr in
            guard let number = pr["number"] as? Int,
                  (pr["headRefName"] as? String).map({ $0 == head }) ?? true else { return nil }
            var reviewers: [String] = []
            for r in pr["reviewRequests"] as? [[String: Any]] ?? [] {
                if let login = r["login"] as? String, !login.isEmpty {
                    reviewers.append(login)
                } else if let slug = r["slug"] as? String, !slug.isEmpty {
                    let org = (r["organization"] as? [String: Any])?["login"] as? String ?? owner
                    reviewers.append(slug.contains("/") ? slug : "\(org)/\(slug)")
                }
            }
            return ExistingPullRequest(number: number, url: pr["url"] as? String ?? "",
                                       title: pr["title"] as? String ?? "", body: pr["body"] as? String ?? "",
                                       isDraft: pr["isDraft"] as? Bool ?? false,
                                       base: pr["baseRefName"] as? String ?? "", reviewers: reviewers)
        }
    }

    /// The open pull request (draft or not) whose head is `branch`, if any.
    static func openPullRequest(_ repo: GitHubRepo, head branch: String) async throws -> ExistingPullRequest? {
        let r = await run(["pr", "list", "--repo", repo.slug, "--head", branch, "--state", "open",
                           "--json", pullRequestFields, "--limit", "5"], cwd: nil)
        guard r.ok else { throw GitHubError(message: r.errorMessage) }
        return parsePullRequests(r.stdout, head: branch, owner: repo.owner).first
    }

    struct PullRequestUpdate {
        var repo: GitHubRepo
        var number: Int
        var title: String
        var body: String
        var base: String?
        var addReviewers: [String]
        var removeReviewers: [String]
        /// nil: leave as is.
        var draft: Bool?
    }

    static func updatePullRequest(_ u: PullRequestUpdate, cwd: URL) async throws {
        var args = ["pr", "edit", String(u.number), "--repo", u.repo.slug, "--title", u.title, "--body-file", "-"]
        if let base = u.base { args += ["--base", base] }
        if !u.addReviewers.isEmpty { args += ["--add-reviewer", u.addReviewers.joined(separator: ",")] }
        if !u.removeReviewers.isEmpty { args += ["--remove-reviewer", u.removeReviewers.joined(separator: ",")] }
        let r = await run(args, cwd: cwd, stdin: Data(u.body.utf8))
        guard r.ok else { throw GitHubError(message: friendlyError(r.errorMessage, head: nil, base: u.base)) }
        if let draft = u.draft {
            let d = await run(["pr", "ready", String(u.number), "--repo", u.repo.slug] + (draft ? ["--undo"] : []), cwd: cwd)
            guard d.ok else { throw GitHubError(message: d.errorMessage) }
        }
    }

    /// Turns common `gh pr create/edit` failures into an explanation.
    static func friendlyError(_ message: String, head: String?, base: String?) -> String {
        let m = message.lowercased()
        let h = head ?? "The branch", b = base ?? "the base branch"
        if m.contains("already exists") {
            return "A pull request for \(h) already exists.\n\n\(message)"
        }
        if m.contains("no commits between") {
            return "\(h) has no commits that aren’t already on \(b), so there is nothing to review."
        }
        if m.contains("head sha can't be blank") || m.contains("head ref must be a branch")
            || m.contains("must first push") || m.contains("head repository") && m.contains("not found") {
            return "\(h) isn’t on GitHub yet. Tick “Push branch first” and try again."
        }
        if m.contains("could not resolve to a user") || m.contains("could not resolve to a team")
            || m.contains("reviews may only be requested from collaborators") || m.contains("review cannot be requested from pull request author") {
            return "Some reviewers couldn’t be requested (not collaborators of this repository, or the author).\n\n\(message)"
        }
        if m.contains("draft pull requests are not supported") {
            return "This repository doesn’t support draft pull requests (private repos on GitHub Free). Untick “Create as draft”."
        }
        return message
    }

    /// Returns the URL of the created pull request.
    static func createPullRequest(_ req: PullRequestRequest, cwd: URL) async throws -> String {
        var args = ["pr", "create", "--repo", req.repo.slug, "--base", req.base, "--head", req.head,
                    "--title", req.title, "--body-file", "-"]
        if !req.reviewers.isEmpty { args += ["--reviewer", req.reviewers.joined(separator: ",")] }
        if req.draft { args.append("--draft") }
        let r = await run(args, cwd: cwd, stdin: Data(req.body.utf8))
        guard r.ok else { throw GitHubError(message: friendlyError(r.errorMessage, head: req.head, base: req.base)) }
        let lines = r.output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        return lines.last(where: { $0.hasPrefix("https://") }) ?? r.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
