import AppKit

/// Actions sent through the responder chain to the key RepoWindowController.
@objc protocol RepoActions {
    func fetch(_ sender: Any?)
    func pull(_ sender: Any?)
    func pullRebase(_ sender: Any?)
    func push(_ sender: Any?)
    func forcePush(_ sender: Any?)
    func newBranch(_ sender: Any?)
    func mergeBranch(_ sender: Any?)
    func rebaseBranch(_ sender: Any?)
    func stashChanges(_ sender: Any?)
    func popStash(_ sender: Any?)
    func createPullRequest(_ sender: Any?)
    func refresh(_ sender: Any?)
    func showHistory(_ sender: Any?)
    func showChanges(_ sender: Any?)
    func toggleUnifiedDiff(_ sender: Any?)
    func toggleWholeFile(_ sender: Any?)
    func nextChange(_ sender: Any?)
    func previousChange(_ sender: Any?)
    func revealInFinder(_ sender: Any?)
    func openInTerminal(_ sender: Any?)
}

enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()

        // App
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About GitUI", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let services = NSMenu()
        let servicesItem = appMenu.addItem(withTitle: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        NSApp.servicesMenu = services
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide GitUI", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit GitUI", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        add(appMenu, title: "GitUI", to: main)

        // File
        let file = NSMenu(title: "File")
        file.addItem(withTitle: "Open Repository…", action: #selector(AppDelegate.openDocument(_:)), keyEquivalent: "o")
        file.addItem(withTitle: "New Tab", action: #selector(AppDelegate.newWindowForTab(_:)), keyEquivalent: "t")
        file.addItem(.separator())
        file.addItem(withTitle: "Show in Finder", action: #selector(RepoActions.revealInFinder(_:)), keyEquivalent: "")
        file.addItem(withTitle: "Open in Terminal", action: #selector(RepoActions.openInTerminal(_:)), keyEquivalent: "")
        file.addItem(.separator())
        file.addItem(withTitle: "Close Tab", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        add(file, title: "File", to: main)

        // Edit
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        add(edit, title: "Edit", to: main)

        // View
        let view = NSMenu(title: "View")
        view.addItem(withTitle: "History", action: #selector(RepoActions.showHistory(_:)), keyEquivalent: "1")
        view.addItem(withTitle: "Changes", action: #selector(RepoActions.showChanges(_:)), keyEquivalent: "2")
        view.addItem(.separator())
        let unified = view.addItem(withTitle: "Unified Diff", action: #selector(RepoActions.toggleUnifiedDiff(_:)), keyEquivalent: "u")
        unified.keyEquivalentModifierMask = [.command, .option]
        let whole = view.addItem(withTitle: "Show Whole File", action: #selector(RepoActions.toggleWholeFile(_:)), keyEquivalent: "f")
        whole.keyEquivalentModifierMask = [.command, .option]
        let next = view.addItem(withTitle: "Next Change", action: #selector(RepoActions.nextChange(_:)), keyEquivalent: String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)))
        next.keyEquivalentModifierMask = [.option, .command]
        let prev = view.addItem(withTitle: "Previous Change", action: #selector(RepoActions.previousChange(_:)), keyEquivalent: String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)))
        prev.keyEquivalentModifierMask = [.option, .command]
        view.addItem(.separator())
        view.addItem(withTitle: "Refresh", action: #selector(RepoActions.refresh(_:)), keyEquivalent: "r")
        view.addItem(.separator())
        let fs = view.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fs.keyEquivalentModifierMask = [.command, .control]
        add(view, title: "View", to: main)

        // Repository
        let repo = NSMenu(title: "Repository")
        let fetch = repo.addItem(withTitle: "Fetch", action: #selector(RepoActions.fetch(_:)), keyEquivalent: "f")
        fetch.keyEquivalentModifierMask = [.command, .shift]
        let pull = repo.addItem(withTitle: "Pull", action: #selector(RepoActions.pull(_:)), keyEquivalent: "l")
        pull.keyEquivalentModifierMask = [.command, .shift]
        repo.addItem(withTitle: "Pull (Rebase)", action: #selector(RepoActions.pullRebase(_:)), keyEquivalent: "")
        let push = repo.addItem(withTitle: "Push", action: #selector(RepoActions.push(_:)), keyEquivalent: "p")
        push.keyEquivalentModifierMask = [.command, .shift]
        repo.addItem(withTitle: "Force Push (with lease)…", action: #selector(RepoActions.forcePush(_:)), keyEquivalent: "")
        repo.addItem(.separator())
        let branch = repo.addItem(withTitle: "New Branch…", action: #selector(RepoActions.newBranch(_:)), keyEquivalent: "b")
        branch.keyEquivalentModifierMask = [.command, .shift]
        repo.addItem(withTitle: "Merge into Current Branch…", action: #selector(RepoActions.mergeBranch(_:)), keyEquivalent: "")
        repo.addItem(withTitle: "Rebase Current Branch onto…", action: #selector(RepoActions.rebaseBranch(_:)), keyEquivalent: "")
        repo.addItem(.separator())
        let stash = repo.addItem(withTitle: "Stash Changes", action: #selector(RepoActions.stashChanges(_:)), keyEquivalent: "s")
        stash.keyEquivalentModifierMask = [.command, .shift]
        repo.addItem(withTitle: "Pop Stash", action: #selector(RepoActions.popStash(_:)), keyEquivalent: "")
        repo.addItem(.separator())
        let pr = repo.addItem(withTitle: "Create Pull Request…", action: #selector(RepoActions.createPullRequest(_:)), keyEquivalent: "r")
        pr.keyEquivalentModifierMask = [.command, .shift]
        add(repo, title: "Repository", to: main)

        // Window
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        let nextTab = window.addItem(withTitle: "Show Next Tab", action: #selector(NSWindow.selectNextTab(_:)), keyEquivalent: "}")
        nextTab.keyEquivalentModifierMask = [.command]
        let prevTab = window.addItem(withTitle: "Show Previous Tab", action: #selector(NSWindow.selectPreviousTab(_:)), keyEquivalent: "{")
        prevTab.keyEquivalentModifierMask = [.command]
        window.addItem(.separator())
        window.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        add(window, title: "Window", to: main)
        NSApp.windowsMenu = window

        return main
    }

    private static func add(_ menu: NSMenu, title: String, to main: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        menu.title = title
        main.addItem(item)
    }
}
