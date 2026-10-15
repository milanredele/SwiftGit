import AppKit

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate, RepositoryTabHost {
    public override init() {
        defaults = .standard
        super.init()
    }

    init(defaults: UserDefaults, presentsWindows: Bool = true) {
        self.defaults = defaults
        self.presentsWindows = presentsWindows
        super.init()
    }

    private(set) var controllers: [RepoWindowController] = []
    private let openReposKey = "openRepositories"
    private let defaults: UserDefaults
    /// Tests drive controllers without putting windows on screen.
    private var presentsWindows = true
    /// Quitting closes every tab window; those closes must not shrink the saved list.
    private var isTerminating = false

    public func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN)
        Tooling.loadLoginShellPath()
        Settings.registerDefaults()
        NSWindow.allowsAutomaticWindowTabbing = true
        NSApp.mainMenu = MainMenu.build()

        Task {
            await restoreOpenRepositories()
            if controllers.isEmpty { openRepositoryPanel() }
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Reopens the tabs that were open at the last quit, in the same order.
    func restoreOpenRepositories() async {
        let paths = defaults.stringArray(forKey: openReposKey) ?? []
        for p in paths where FileManager.default.fileExists(atPath: p) {
            await open(URL(fileURLWithPath: p), select: false)
        }
        if presentsWindows { controllers.first?.window?.makeKeyAndOrderFront(nil) }
    }

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        saveOpenRepositories()
        isTerminating = true
        return .terminateNow
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            if let c = controllers.first { c.showWindow(nil) } else { openRepositoryPanel() }
        }
        return true
    }

    public func applicationWillTerminate(_ notification: Notification) {
        if !isTerminating { saveOpenRepositories() }
        isTerminating = true
    }

    public func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        Task { await open(URL(fileURLWithPath: filename), select: true) }
        return true
    }

    // MARK: Opening

    @objc func showSettings(_ sender: Any?) {
        SettingsWindowController.shared.show()
    }

    @objc func openDocument(_ sender: Any?) {
        openRepositoryPanel()
    }

    @objc func newWindowForTab(_ sender: Any?) {
        openRepositoryPanel()
    }

    func openRepositoryPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Open"
        panel.message = "Choose a git repository"
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task {
            for url in urls { await open(url, select: true) }
        }
    }

    func open(_ url: URL, select: Bool) async {
        let repo: Repository
        do {
            repo = try await Repository.open(url)
        } catch let bare as Repository.BareRepository {
            await openBare(bare.commonDir)
            return
        } catch {
            // Through Prompt: never blocks in headless test runs.
            await Prompt.error(nil, title: "Can’t open repository", message: error.localizedDescription)
            return
        }
        if let existing = controllers.first(where: { samePath($0.repository.root.path, repo.root.path) }) {
            if select { existing.window?.makeKeyAndOrderFront(nil) }
            return
        }
        let controller = RepoWindowController(repository: repo)
        controller.tabHost = self
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.controllers.removeAll { $0 === controller }
            if !self.isTerminating { self.saveOpenRepositories() }
        }
        let host = controllers.last?.window
        controllers.append(controller)
        if !presentsWindows {
            // headless (tests): no windows on screen
        } else if let host, let window = controller.window {
            host.addTabbedWindow(window, ordered: .above)
            if select { window.makeKeyAndOrderFront(nil) }
        } else {
            controller.showWindow(nil)
            if let w = controller.window, let group = w.tabGroup, !group.isTabBarVisible {
                w.toggleTabBar(nil)
            }
        }
        repo.start()
        saveOpenRepositories()
    }

    func closeTab(root: URL) {
        for c in controllers where samePath(c.repository.root.path, root.path) { c.window?.close() }
    }

    func isOpen(root: URL) -> Bool {
        controllers.contains { samePath($0.repository.root.path, root.path) }
    }

    /// A bare repository has no files of its own: offers its worktrees, or to create one.
    func openBare(_ commonDir: URL) async {
        let name = WorktreeLocation.repositoryName(commonDir: commonDir)
        let worktrees = await BareRepositoryWorktrees.worktrees(of: commonDir)
        let existing = worktrees.filter { FileManager.default.fileExists(atPath: $0.path) }
        let intro = "“\(name)” is a bare repository: it has no working files of its own. Its branches are checked out in worktrees — folders that share the repository."
        if existing.count == 1 {
            await open(existing[0].url, select: true)
            return
        }
        if existing.isEmpty {
            let choice = await Prompt.buttons(nil, title: "Open a worktree of “\(name)”",
                                              message: intro + "\n\nIt has none yet. Create one to start working.",
                                              buttons: ["New Worktree…", "Cancel"])
            if choice == 0 { await newBareWorktree(commonDir, busy: Set(worktrees.compactMap(\.branch))) }
            return
        }
        let list = existing.map { "• \($0.name)" + ($0.branch.map { " (\($0))" } ?? "") + " — \($0.path)" }.joined(separator: "\n")
        let choice = await Prompt.buttons(nil, title: "Open worktrees of “\(name)”",
                                          message: intro + "\n\n\(list)",
                                          buttons: ["Open All (\(existing.count))", "Choose…", "New Worktree…", "Cancel"])
        switch choice {
        case 0:
            for (i, wt) in existing.enumerated() { await open(wt.url, select: i == 0) }
        case 1:
            let labels = existing.map { $0.name + ($0.branch.map { " (\($0))" } ?? "") }
            guard let picked = await Prompt.choose(nil, title: "Open a worktree of “\(name)”", options: labels, ok: "Open"),
                  let i = labels.firstIndex(of: picked) else { return }
            await open(existing[i].url, select: true)
        case 2:
            await newBareWorktree(commonDir, busy: Set(worktrees.compactMap(\.branch)))
        default:
            break
        }
    }

    private func newBareWorktree(_ commonDir: URL, busy: Set<String>) async {
        let branches = await BareRepositoryWorktrees.branches(of: commonDir)
        let remoteSet = Set(branches.remote)
        let locals = branches.local.filter { !busy.contains($0) }
        let remotes = branches.remote.filter { !busy.contains(BareRepositoryWorktrees.localName($0, remoteBranches: remoteSet)) }
        guard let r = await NewWorktreePrompt.run(nil, message: "Choose the branch to check out, or type a new branch name.",
                                                  branches: locals + remotes, initial: nil,
                                                  defaultPath: { BareRepositoryWorktrees.defaultFolder(commonDir, branch: BareRepositoryWorktrees.localName($0, remoteBranches: remoteSet)) })
        else { return }
        let result = await BareRepositoryWorktrees.addWorktree(commonDir, path: r.path, branch: r.branch)
        guard result.ok else {
            await Prompt.error(nil, title: "Add worktree failed", message: WorktreeProblem.explain(result.errorMessage) ?? result.errorMessage)
            return
        }
        await open(r.path, select: true)
    }

    private func saveOpenRepositories() {
        var ordered: [String] = []
        if let group = controllers.first?.window?.tabGroup {
            for w in group.windows {
                if let c = controllers.first(where: { $0.window === w }) { ordered.append(c.repository.root.path) }
            }
        }
        for c in controllers where !ordered.contains(c.repository.root.path) {
            ordered.append(c.repository.root.path)
        }
        defaults.set(ordered, forKey: openReposKey)
    }
}
