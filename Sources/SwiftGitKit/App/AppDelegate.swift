import AppKit

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
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
        } catch {
            let alert = NSAlert()
            alert.messageText = "Can’t open repository"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            return
        }
        if let existing = controllers.first(where: { $0.repository.root == repo.root }) {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = RepoWindowController(repository: repo)
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
