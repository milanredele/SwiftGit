import AppKit

/// Shared view of the gh CLI accounts (shown in every window's toolbar).
@MainActor
final class GitHubAccounts {
    static let shared = GitHubAccounts()
    static let changed = Notification.Name("SwiftGitGitHubAccountsChanged")

    private(set) var accounts: [GitHub.Account] = []
    private(set) var loaded = false
    private var avatars: [String: NSImage] = [:]
    private var refreshTask: Task<Void, Never>?
    /// github.com login → organization logins (cached; refetched every 10 minutes at most).
    private var orgs: [String: [String]] = [:]
    private var orgsLoadedAt: [String: Date] = [:]
    private var orgTask: Task<Void, Never>?

    var active: GitHub.Account? {
        accounts.first { $0.host == "github.com" && $0.isActive } ?? accounts.first { $0.isActive }
    }

    func refresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task {
            let list = await GitHub.accounts()
            refreshTask = nil
            loaded = true
            if list != accounts {
                accounts = list
                NotificationCenter.default.post(name: GitHubAccounts.changed, object: nil)
                for a in list where a.host == "github.com" { loadAvatar(a.login) }
            }
            loadOrganizations()
        }
    }

    /// Organizations of a github.com account (known only for accounts that were active).
    func organizations(of login: String) -> [String] { orgs[login] ?? [] }

    private func loadOrganizations(force: Bool = false) {
        guard orgTask == nil, let account = active, account.host == "github.com", account.isValid else { return }
        let login = account.login
        if !force, let at = orgsLoadedAt[login], Date().timeIntervalSince(at) < 600 { return }
        orgTask = Task {
            let list = await GitHub.organizations()
            orgTask = nil
            // gh answers for whichever account is active; drop the result if it changed meanwhile.
            guard let list, active?.login == login else { return }
            orgsLoadedAt[login] = Date()
            guard orgs[login] != list else { return }
            orgs[login] = list
            NotificationCenter.default.post(name: GitHubAccounts.changed, object: nil)
            for o in list { loadAvatar(o) }
        }
    }

    func switchTo(_ account: GitHub.Account) async throws {
        try await GitHub.switchAccount(account)
        accounts = accounts.map { a in
            var a = a
            if a.host == account.host { a.isActive = a.login == account.login }
            return a
        }
        NotificationCenter.default.post(name: GitHubAccounts.changed, object: nil)
        refresh()
        loadOrganizations(force: true)
    }

    func avatar(_ login: String) -> NSImage? { avatars[login] }

    private func loadAvatar(_ login: String) {
        guard avatars[login] == nil,
              let url = URL(string: "https://avatars.githubusercontent.com/\(login)?s=48") else { return }
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = NSImage(data: data) else { return }
            avatars[login] = GitHubAccounts.circular(image, size: 18)
            NotificationCenter.default.post(name: GitHubAccounts.changed, object: nil)
        }
    }

    private static func circular(_ image: NSImage, size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            NSBezierPath(ovalIn: rect).addClip()
            image.draw(in: rect)
            return true
        }
    }
}

/// Toolbar item: active gh account; its menu switches between accounts.
@MainActor
final class GitHubAccountToolbarItem: NSMenuToolbarItem {
    /// The window's repository; its GitHub owner decides which organization is shown.
    weak var repository: Repository?

    init(identifier: NSToolbarItem.Identifier, repository: Repository? = nil) {
        self.repository = repository
        super.init(itemIdentifier: identifier)
        label = "GitHub"
        paletteLabel = "GitHub Account"
        showsIndicator = true
        NotificationCenter.default.addObserver(self, selector: #selector(accountsChanged(_:)),
                                               name: GitHubAccounts.changed, object: nil)
        update()
        GitHubAccounts.shared.refresh()
    }

    @objc private func accountsChanged(_ n: Notification) { update() }

    private var shownOwner: String?

    /// Called when the repository's refs/remotes changed; rebuilds only if the GitHub owner did.
    func repositoryChanged() {
        if repository?.gitHubRemote?.repo.owner != shownOwner { update() }
    }

    func update() {
        let model = GitHubAccounts.shared
        let menu = NSMenu()
        shownOwner = repository?.gitHubRemote?.repo.owner
        if let active = model.active {
            let orgs = model.organizations(of: active.login)
            let repoOrg = GitHubAccountToolbarItem.repositoryOrganization(owner: repository?.gitHubRemote?.repo.owner, orgs: orgs)
            title = repoOrg.map { "\(active.login) · \($0)" } ?? active.login
            image = model.avatar(active.login) ?? Theme.symbol("person.crop.circle", "GitHub account")
            var tip = "GitHub account used by gh for pull requests: \(active.login) on \(active.host)"
            if !orgs.isEmpty { tip += "\nMember of: " + orgs.joined(separator: ", ") }
            if let repoOrg { tip += "\nThis repository belongs to \(repoOrg)." }
            toolTip = tip
        } else {
            title = model.loaded ? "Not logged in" : "GitHub"
            image = Theme.symbol("person.crop.circle.badge.questionmark", "GitHub account")
            toolTip = GitHub.executable == nil ? GitHub.missingMessage : "Run `gh auth login` in Terminal to log in to GitHub."
        }

        let hosts = Array(Set(model.accounts.map(\.host))).sorted { a, b in a == "github.com" || (b != "github.com" && a < b) }
        for host in hosts {
            if hosts.count > 1 { menu.addItem(NSMenuItem.sectionHeader(title: host)) }
            for account in model.accounts where account.host == host {
                let item = NSMenuItem(title: account.login + (account.isValid ? "" : " (token invalid)"),
                                      action: #selector(choose(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = account.login + "@" + account.host
                item.state = account.isActive ? .on : .off
                item.image = model.avatar(account.login)
                menu.addItem(item)
            }
        }
        if let active = model.active {
            let orgs = model.organizations(of: active.login)
            let owner = repository?.gitHubRemote?.repo.owner
            if !orgs.isEmpty {
                menu.addItem(.separator())
                menu.addItem(NSMenuItem.sectionHeader(title: "\(active.login)’s organizations"))
                for org in orgs {
                    let isOwner = owner?.caseInsensitiveCompare(org) == .orderedSame
                    let item = NSMenuItem(title: org + (isOwner ? " (this repository)" : ""),
                                          action: #selector(openOrganization(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = org
                    item.image = model.avatar(org)
                    item.toolTip = "Open github.com/\(org)"
                    menu.addItem(item)
                }
            }
        }
        if model.accounts.isEmpty {
            let item = NSMenuItem(title: "Not logged in — run `gh auth login`", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let note = NSMenuItem(title: "Switching changes the account for gh everywhere", action: nil, keyEquivalent: "")
        note.isEnabled = false
        menu.addItem(note)
        let refresh = NSMenuItem(title: "Refresh Accounts", action: #selector(refreshAccounts(_:)), keyEquivalent: "")
        refresh.target = self
        menu.addItem(refresh)
        self.menu = menu
    }

    @objc private func refreshAccounts(_ sender: Any?) { GitHubAccounts.shared.refresh() }

    @objc private func openOrganization(_ item: NSMenuItem) {
        guard let org = item.representedObject as? String, let url = URL(string: "https://github.com/\(org)") else { return }
        NSWorkspace.shared.open(url)
    }

    /// The organization (spelled as GitHub returns it) that owns the repository, if the user is a member.
    nonisolated static func repositoryOrganization(owner: String?, orgs: [String]) -> String? {
        guard let owner else { return nil }
        return orgs.first { $0.caseInsensitiveCompare(owner) == .orderedSame }
    }

    @objc private func choose(_ item: NSMenuItem) {
        guard let key = item.representedObject as? String,
              let account = GitHubAccounts.shared.accounts.first(where: { $0.login + "@" + $0.host == key }),
              !account.isActive else { return }
        Task {
            do {
                try await GitHubAccounts.shared.switchTo(account)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Couldn’t switch to \(account.login)"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }
}
