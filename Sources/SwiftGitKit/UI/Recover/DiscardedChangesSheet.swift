import AppKit

/// Lists the snapshots taken before discards and restores one of them.
final class DiscardedChangesSheet: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    let repository: Repository
    private var entries: [DiscardedChanges] = []
    private let table = NSTableView()
    private let filesLabel = NSTextField(wrappingLabelWithString: "")
    private let restoreButton = NSButton(title: "Restore", target: nil, action: nil)
    private let deleteButton = NSButton(title: "Delete", target: nil, action: nil)
    private let closeButton = NSButton(title: "Close", target: nil, action: nil)
    private var filesTask: Task<Void, Never>?
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()

    init(repository: Repository) {
        self.repository = repository
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
                         styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        w.title = "Recover Discarded Changes"
        w.minSize = NSSize(width: 460, height: 320)
        super.init(window: w)
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        let intro = NSTextField(wrappingLabelWithString:
            "Changes are saved here before they are discarded (and before a hard reset), and kept for \(Repository.discardKeepDays) days. "
            + "Restoring puts the saved content of those files back into your working copy; their current content is saved first.")
        intro.font = .systemFont(ofSize: 12)
        intro.textColor = .secondaryLabelColor

        for (id, title, width) in [("date", "When", 150.0), ("summary", "What", 320.0)] {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.title = title
            c.width = width
            table.addTableColumn(c)
        }
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let scroll = makeScrollingTable(table)
        scroll.borderType = .bezelBorder

        filesLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        filesLabel.textColor = .secondaryLabelColor
        filesLabel.maximumNumberOfLines = 6

        restoreButton.bezelStyle = .rounded
        restoreButton.keyEquivalent = "\r"
        restoreButton.target = self
        restoreButton.action = #selector(restore(_:))
        deleteButton.bezelStyle = .rounded
        deleteButton.target = self
        deleteButton.action = #selector(deleteEntry(_:))
        closeButton.bezelStyle = .rounded
        closeButton.keyEquivalent = "\u{1b}"
        closeButton.target = self
        closeButton.action = #selector(close(_:))
        let buttons = NSStackView(views: [deleteButton, NSView(), closeButton, restoreButton])
        buttons.orientation = .horizontal

        let stack = NSStackView(views: [intro, scroll, filesLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            intro.widthAnchor.constraint(equalTo: stack.widthAnchor),
            filesLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
        ])
    }

    var onFinish: (() -> Void)?

    func present(on parent: NSWindow) {
        guard let window else { return }
        parent.beginSheet(window) { [weak self] _ in self?.onFinish?() }
        reload()
    }

    func reload() {
        Task {
            entries = await repository.discardedChanges()
            table.reloadData()
            if !entries.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
            selectionChanged()
        }
    }

    var testEntries: [DiscardedChanges] { entries }

    private var selected: DiscardedChanges? {
        let r = table.selectedRow
        return r >= 0 && r < entries.count ? entries[r] : nil
    }

    private func selectionChanged() {
        restoreButton.isEnabled = selected != nil
        deleteButton.isEnabled = selected != nil
        filesTask?.cancel()
        guard let e = selected else {
            filesLabel.stringValue = entries.isEmpty ? "Nothing has been discarded in the last \(Repository.discardKeepDays) days." : ""
            return
        }
        filesTask = Task {
            let files = await repository.discardedFiles(e)
            guard !Task.isCancelled else { return }
            filesLabel.stringValue = files.isEmpty ? "(no file changes)" : files.joined(separator: "\n")
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < entries.count, let id = tableColumn?.identifier else { return nil }
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? NSTextField ?? {
            let l = makeLabel("")
            l.identifier = id
            l.lineBreakMode = .byTruncatingTail
            return l
        }()
        let e = entries[row]
        cell.stringValue = id.rawValue == "date" ? Self.dateFormatter.string(from: e.date) : e.summary
        cell.toolTip = e.summary
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) { selectionChanged() }

    @objc private func restore(_ sender: Any?) {
        guard let e = selected else { return }
        Task {
            let files = await repository.discardedFiles(e)
            guard await Prompt.confirm(window, title: "Restore \(files.count == 1 ? files[0] : "\(files.count) files")?",
                                       message: "Their current content is replaced by the version saved \(Self.dateFormatter.string(from: e.date)). "
                                        + "The current content is saved here first.", ok: "Restore") else { return }
            if await repository.restoreDiscarded(e) { close(nil) } else { reload() }
        }
    }

    @objc private func deleteEntry(_ sender: Any?) {
        guard let e = selected else { return }
        Task {
            await repository.deleteDiscarded(e)
            reload()
        }
    }

    @objc private func close(_ sender: Any?) {
        guard let window, let parent = window.sheetParent else { window?.close(); return }
        parent.endSheet(window)
    }
}
