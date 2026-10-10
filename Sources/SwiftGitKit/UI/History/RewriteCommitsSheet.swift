import AppKit

/// "Edit Commits…": keep, reword, squash, fixup, drop and reorder the commits
/// from a chosen one up to HEAD. Runs `git rebase -i` with the resulting list.
final class RewriteCommitsSheet: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSTextViewDelegate {
    let repository: Repository
    let plan: RewritePlan
    var onFinish: (() -> Void)?
    private(set) var steps: [RebaseStep]
    private let table = NSTableView()
    private let messageScroll = NSTextView.scrollableTextView()
    private var messageView: NSTextView { messageScroll.documentView as! NSTextView }
    private let messageLabel = makeLabel("Message", font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
    private let rewriteButton = NSButton(title: "Rewrite Commits", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private static let dragType = NSPasteboard.PasteboardType("hu.pepitaponi.swiftgit.rebase-row")
    private var updatingMessage = false

    init(repository: Repository, plan: RewritePlan) {
        self.repository = repository
        self.plan = plan
        self.steps = plan.commits.map { RebaseStep(commit: $0) }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
                         styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        w.title = "Edit Commits"
        w.minSize = NSSize(width: 560, height: 420)
        super.init(window: w)
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        let branch = repository.currentBranch ?? "HEAD"
        var introText = "\(plan.commits.count) commit\(plan.commits.count == 1 ? "" : "s") on \(branch), oldest first. "
            + "Choose what happens to each, drag rows to reorder, and edit a message to reword it."
        if plan.pushedCount > 0 {
            introText += "\n\(plan.pushedCount) of them are already pushed: afterwards the branch has to be force pushed."
        }
        let intro = NSTextField(wrappingLabelWithString: introText)
        intro.font = .systemFont(ofSize: 12)
        intro.textColor = plan.pushedCount > 0 ? .systemOrange : .secondaryLabelColor

        for (id, title, width) in [("action", "Action", 210.0), ("subject", "Commit", 360.0), ("sha", "", 96.0)] {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.title = title
            c.width = width
            table.addTableColumn(c)
        }
        table.rowHeight = 26
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.registerForDraggedTypes([Self.dragType])
        table.draggingDestinationFeedbackStyle = .gap
        let scroll = makeScrollingTable(table)
        scroll.borderType = .bezelBorder

        messageView.isRichText = false
        messageView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        messageView.allowsUndo = true
        messageView.delegate = self
        messageView.textContainerInset = NSSize(width: 4, height: 6)
        messageScroll.borderType = .bezelBorder

        rewriteButton.bezelStyle = .rounded
        rewriteButton.keyEquivalent = "\r"
        rewriteButton.target = self
        rewriteButton.action = #selector(rewrite(_:))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.target = self
        cancelButton.action = #selector(cancel(_:))
        let buttons = NSStackView(views: [NSView(), cancelButton, rewriteButton])
        buttons.orientation = .horizontal

        let stack = NSStackView(views: [intro, scroll, messageLabel, messageScroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            intro.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            messageScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
            messageScroll.heightAnchor.constraint(equalToConstant: 110),
        ])
        table.selectRowIndexes([max(0, steps.count - 1)], byExtendingSelection: false)
        showMessage()
    }

    func present(on parent: NSWindow) {
        guard let window else { return }
        parent.beginSheet(window) { [weak self] _ in self?.onFinish?() }
    }

    private func finish() {
        guard let window, let parent = window.sheetParent else { window?.close(); return }
        parent.endSheet(window)
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { steps.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < steps.count, let id = tableColumn?.identifier else { return nil }
        let step = steps[row]
        switch id.rawValue {
        case "action":
            let popup = tableView.makeView(withIdentifier: id, owner: nil) as? NSPopUpButton ?? {
                let p = NSPopUpButton(frame: .zero, pullsDown: false)
                p.identifier = id
                p.controlSize = .small
                p.addItems(withTitles: RebaseStep.Action.allCases.map(\.title))
                p.target = self
                p.action = #selector(actionChanged(_:))
                return p
            }()
            popup.selectItem(at: RebaseStep.Action.allCases.firstIndex(of: step.action) ?? 0)
            popup.tag = row
            return popup
        default:
            let cell = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? {
                let c = NSTableCellView()
                c.identifier = id
                let l = makeLabel("", font: id.rawValue == "sha" ? Theme.monoSmall : .systemFont(ofSize: 12))
                l.lineBreakMode = .byTruncatingTail
                l.translatesAutoresizingMaskIntoConstraints = false
                c.addSubview(l)
                c.textField = l
                NSLayoutConstraint.activate([
                    l.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2),
                    l.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -2),
                    l.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                ])
                return c
            }()
            let label = cell.textField!
            if id.rawValue == "sha" {
                label.stringValue = String(step.commit.hash.prefix(8))
            } else {
                let subject = step.message.map { String($0.split(separator: "\n").first ?? "") } ?? step.commit.subject
                let attrs: [NSAttributedString.Key: Any] = step.action == .drop
                    ? [.strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: NSColor.tertiaryLabelColor]
                    : [.foregroundColor: [.squash, .fixup].contains(step.action) ? NSColor.secondaryLabelColor : NSColor.labelColor]
                label.attributedStringValue = NSAttributedString(
                    string: ([.squash, .fixup].contains(step.action) ? "    ↳ " : "") + subject,
                    attributes: attrs.merging([.font: NSFont.systemFont(ofSize: 12)]) { a, _ in a })
            }
            return cell
        }
    }

    @objc private func actionChanged(_ sender: NSPopUpButton) {
        guard sender.tag < steps.count else { return }
        steps[sender.tag].action = RebaseStep.Action.allCases[max(0, sender.indexOfSelectedItem)]
        if steps[sender.tag].action != .reword { steps[sender.tag].message = nil }
        table.reloadData(forRowIndexes: [sender.tag], columnIndexes: [1])
        if table.selectedRow == sender.tag { showMessage() }
    }

    func tableViewSelectionDidChange(_ notification: Notification) { showMessage() }

    private func showMessage() {
        let row = table.selectedRow
        updatingMessage = true
        defer { updatingMessage = false }
        guard row >= 0, row < steps.count else {
            messageView.string = ""
            messageView.isEditable = false
            return
        }
        let s = steps[row]
        messageView.string = s.message ?? s.commit.message
        messageView.isEditable = s.action != .drop && s.action != .fixup
        messageLabel.stringValue = "Message of \(s.commit.hash.prefix(8))" + (messageView.isEditable ? " (editing it rewords the commit)" : "")
    }

    func textDidChange(_ notification: Notification) {
        guard !updatingMessage else { return }
        let row = table.selectedRow
        guard row >= 0, row < steps.count else { return }
        let text = messageView.string
        if text == steps[row].commit.message {
            steps[row].message = nil
            if steps[row].action == .reword { steps[row].action = .pick }
        } else {
            steps[row].message = text
            if steps[row].action == .pick { steps[row].action = .reword }
        }
        table.reloadData(forRowIndexes: [row], columnIndexes: [0, 1])
    }

    // Drag to reorder
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.dragType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        dropOperation == .above ? .move : []
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard let s = info.draggingPasteboard.string(forType: Self.dragType), let from = Int(s) else { return false }
        move(from: from, to: row)
        return true
    }

    func move(from: Int, to row: Int) {
        guard from >= 0, from < steps.count else { return }
        let step = steps.remove(at: from)
        let dest = min(steps.count, row > from ? row - 1 : row)
        steps.insert(step, at: dest)
        table.reloadData()
        table.selectRowIndexes([dest], byExtendingSelection: false)
    }

    // MARK: Actions

    @objc private func cancel(_ sender: Any?) { finish() }

    @objc private func rewrite(_ sender: Any?) {
        window?.makeFirstResponder(nil)
        if let problem = Repository.validate(steps, original: plan.commits) {
            Task { await Prompt.error(window, title: "Can’t rewrite the commits", message: problem) }
            return
        }
        let steps = self.steps
        finish()
        Task {
            let r = await repository.rewrite(plan, steps: steps)
            if !r.ok, repository.opState == .rebasing {
                repository.onError?("Edit commits", "A commit couldn’t be applied cleanly. Resolve the conflicts in Changes, "
                                    + "then Continue — or Abort to go back to how it was.\n\n" + r.errorMessage)
            }
        }
    }

    // MARK: Testing

    func testSet(_ row: Int, _ action: RebaseStep.Action, message: String? = nil) {
        steps[row].action = action
        steps[row].message = message
        table.reloadData()
    }
}
