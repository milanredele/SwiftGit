import AppKit

/// Asks for a branch and a folder for a new worktree. The folder follows the
/// branch name until the user edits it.
@MainActor
final class NewWorktreePrompt: NSObject, NSComboBoxDelegate, NSTextFieldDelegate {
    struct Result {
        let branch: String
        let path: URL
        let openInTab: Bool
    }

    private let combo = NSComboBox()
    private let pathField = NSTextField()
    private let openBox = NSButton(checkboxWithTitle: "Open it in a new tab", target: nil, action: nil)
    private let defaultPath: (String) -> URL
    private var pathEdited = false

    private init(defaultPath: @escaping (String) -> URL) {
        self.defaultPath = defaultPath
    }

    /// `branches`: the choices (local branches first, then remote ones); the
    /// user may also type a new branch name.
    static func run(_ window: NSWindow?, title: String = "New Worktree", message: String,
                    branches: [String], initial: String?, defaultPath: @escaping (String) -> URL) async -> Result? {
        let p = NewWorktreePrompt(defaultPath: defaultPath)
        return await p.show(window, title: title, message: message, branches: branches, initial: initial)
    }

    private func show(_ window: NSWindow?, title: String, message: String, branches: [String], initial: String?) async -> Result? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Create Worktree")
        alert.addButton(withTitle: "Cancel")

        let width: CGFloat = 420
        combo.addItems(withObjectValues: branches)
        combo.completes = true
        combo.numberOfVisibleItems = 15
        combo.placeholderString = "Branch, remote branch or new branch name"
        combo.stringValue = initial ?? branches.first ?? ""
        combo.delegate = self
        pathField.delegate = self
        pathField.lineBreakMode = .byTruncatingHead
        pathField.stringValue = combo.stringValue.isEmpty ? "" : defaultPath(combo.stringValue).path
        openBox.state = .on
        let choose = NSButton(title: "Choose…", target: self, action: #selector(chooseFolder(_:)))

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Branch:"), combo],
            [NSTextField(labelWithString: "Folder:"), pathField],
            [NSGridCell.emptyContentView, choose],
            [NSGridCell.emptyContentView, openBox],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.columnSpacing = 8
        grid.rowSpacing = 8
        grid.row(at: 2).topPadding = -2
        grid.translatesAutoresizingMaskIntoConstraints = false
        combo.widthAnchor.constraint(equalToConstant: width - 60).isActive = true
        pathField.widthAnchor.constraint(equalToConstant: width - 60).isActive = true
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: grid.fittingSize.height))
        container.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            grid.topAnchor.constraint(equalTo: container.topAnchor),
        ])
        alert.accessoryView = container
        alert.window.initialFirstResponder = combo

        guard await Prompt.run(alert, window) == .alertFirstButtonReturn else { return nil }
        let branch = combo.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var path = (pathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        if path.isEmpty, !branch.isEmpty { path = defaultPath(branch).path }
        guard !branch.isEmpty, path.hasPrefix("/") else { return nil }
        return Result(branch: branch, path: URL(fileURLWithPath: path, isDirectory: true), openInTab: openBox.state == .on)
    }

    private func branchChanged(_ value: String) {
        guard !pathEdited else { return }
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        pathField.stringValue = v.isEmpty ? "" : defaultPath(v).path
    }

    func comboBoxSelectionDidChange(_ notification: Notification) {
        if let v = combo.objectValueOfSelectedItem as? String { branchChanged(v) }
    }

    func controlTextDidChange(_ obj: Notification) {
        if (obj.object as? NSTextField) === pathField {
            pathEdited = true
        } else {
            branchChanged(combo.stringValue)
        }
    }

    @objc private func chooseFolder(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose the folder that will contain the new worktree"
        let current = URL(fileURLWithPath: pathField.stringValue)
        panel.directoryURL = current.deletingLastPathComponent()
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        let name = current.lastPathComponent.isEmpty ? "worktree" : current.lastPathComponent
        pathField.stringValue = parent.appendingPathComponent(name).path
        pathEdited = true
    }
}
