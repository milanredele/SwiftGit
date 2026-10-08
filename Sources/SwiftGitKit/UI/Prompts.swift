import AppKit

/// Small async wrappers around NSAlert sheets.
@MainActor
enum Prompt {
    private static func run(_ alert: NSAlert, _ window: NSWindow?) async -> NSApplication.ModalResponse {
        if let window, window.attachedSheet == nil, window.isVisible {
            return await withCheckedContinuation { cont in
                alert.beginSheetModal(for: window) { cont.resume(returning: $0) }
            }
        }
        return alert.runModal()
    }

    static func text(_ window: NSWindow?, title: String, message: String = "", value: String = "",
                     placeholder: String = "", ok: String = "OK",
                     checkbox: String? = nil, checkboxOn: Bool = true) async -> (text: String, checked: Bool)? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: ok)
        alert.addButton(withTitle: "Cancel")

        let width: CGFloat = 320
        let field = NSTextField(frame: NSRect(x: 0, y: checkbox == nil ? 0 : 28, width: width, height: 24))
        field.stringValue = value
        field.placeholderString = placeholder
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: checkbox == nil ? 24 : 52))
        container.addSubview(field)
        var box: NSButton?
        if let checkbox {
            let b = NSButton(checkboxWithTitle: checkbox, target: nil, action: nil)
            b.state = checkboxOn ? .on : .off
            b.frame = NSRect(x: 0, y: 0, width: width, height: 20)
            container.addSubview(b)
            box = b
        }
        alert.accessoryView = container
        alert.window.initialFirstResponder = field
        let response = await run(alert, window)
        guard response == .alertFirstButtonReturn else { return nil }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return (text, box?.state == .on)
    }

    /// Combo box: pick from `options` or type a value.
    static func choose(_ window: NSWindow?, title: String, message: String = "", options: [String],
                       selected: String? = nil, ok: String = "OK") async -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: ok)
        alert.addButton(withTitle: "Cancel")
        let combo = NSComboBox(frame: NSRect(x: 0, y: 0, width: 320, height: 26))
        combo.addItems(withObjectValues: options)
        combo.completes = true
        combo.numberOfVisibleItems = 15
        if let selected { combo.stringValue = selected } else if let first = options.first { combo.stringValue = first }
        alert.accessoryView = combo
        alert.window.initialFirstResponder = combo
        let response = await run(alert, window)
        guard response == .alertFirstButtonReturn else { return nil }
        let v = combo.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }

    static func confirm(_ window: NSWindow?, title: String, message: String, ok: String,
                        destructive: Bool = false) async -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = destructive ? .critical : .warning
        let okButton = alert.addButton(withTitle: ok)
        if destructive { okButton.hasDestructiveAction = true }
        alert.addButton(withTitle: "Cancel")
        return await run(alert, window) == .alertFirstButtonReturn
    }

    static func error(_ window: NSWindow?, title: String, message: String) async {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = String(message.prefix(4000))
        alert.addButton(withTitle: "OK")
        _ = await run(alert, window)
    }
}
