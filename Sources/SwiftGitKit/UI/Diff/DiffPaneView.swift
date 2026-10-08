import AppKit

enum PaneSide {
    case left, right, unified
}

/// Draws only the visible rows of one side of the diff with a monospaced font.
final class DiffPaneView: NSView {
    weak var controller: DiffViewController?
    let side: PaneSide
    var diff: FileDiff?
    var rows: [DiffRow] = []

    let font = Theme.monoFont
    let rowHeight: CGFloat = 18
    let textInset: CGFloat = 6
    let charWidth: CGFloat
    private let baselineOffset: CGFloat

    init(side: PaneSide) {
        self.side = side
        let probe = NSAttributedString(string: "M", attributes: [.font: Theme.monoFont])
        charWidth = probe.size().width
        baselineOffset = 1
        super.init(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    func reload() {
        updateSize()
        needsDisplay = true
    }

    func updateSize() {
        let visible = enclosingScrollView?.contentSize ?? NSSize(width: 100, height: 100)
        let cols = CGFloat(diff?.maxColumns ?? 0)
        let width = max(visible.width, textInset * 2 + cols * charWidth + 24)
        let height = max(visible.height, CGFloat(rows.count) * rowHeight + 4)
        if frame.size != NSSize(width: width, height: height) {
            setFrameSize(NSSize(width: width, height: height))
        }
    }

    /// Index into `diff.lines` shown by this pane for a row, or -1 for filler.
    func lineIndex(_ row: DiffRow) -> Int {
        switch side {
        case .left: return Int(row.left)
        case .right: return Int(row.right)
        case .unified: return Int(row.left >= 0 ? row.left : row.right)
        }
    }

    static func expandTabs(_ s: String) -> String {
        s.contains("\t") ? s.replacingOccurrences(of: "\t", with: "    ") : s
    }

    override func draw(_ rect: NSRect) {
        let dirtyRect = rect.intersection(bounds)
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
        guard let diff, !rows.isEmpty else { return }

        let first = max(0, Int(dirtyRect.minY / rowHeight))
        let last = min(rows.count - 1, Int(dirtyRect.maxY / rowHeight))
        guard first <= last else { return }
        let maxChars = max(0, Int((dirtyRect.maxX - textInset) / charWidth) + 4)

        for r in first...last {
            let row = rows[r]
            let y = CGFloat(r) * rowHeight
            let rect = NSRect(x: dirtyRect.minX, y: y, width: dirtyRect.width, height: rowHeight)

            if row.kind == .gap {
                Theme.gapBackground.setFill()
                rect.fill()
                let text = "⋯  \(row.gap) unchanged line\(row.gap == 1 ? "" : "s") — click to expand"
                let attr = NSAttributedString(string: text, attributes: [
                    .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
                attr.draw(at: NSPoint(x: textInset, y: y + 2))
                continue
            }

            let li = lineIndex(row)
            if li < 0 {
                drawFiller(rect)
                if controller?.isSelected(row: r) == true { Theme.selection.setFill(); rect.fill() }
                continue
            }

            let line = diff.lines[li]
            switch line.kind {
            case .deleted: Theme.deletedBackground.setFill(); rect.fill()
            case .added: Theme.addedBackground.setFill(); rect.fill()
            case .context: break
            }
            if controller?.isSelected(row: r) == true {
                Theme.selection.setFill()
                rect.fill()
            }

            let text = DiffPaneView.expandTabs(diff.text(li))
            let attr = NSMutableAttributedString(string: text, attributes: [
                .font: font, .foregroundColor: NSColor.textColor])
            if row.kind == .changed, side != .unified, let ranges = controller?.intraline(row: r) {
                let list = side == .left ? ranges.old : ranges.new
                let color = side == .left ? Theme.deletedWord : Theme.addedWord
                let length = attr.length
                for range in list where range.location + range.length <= length {
                    attr.addAttribute(.backgroundColor, value: color, range: range)
                }
            }
            if let hl = controller?.syntaxColors(lineIndex: li) {
                let length = attr.length
                for (range, color) in hl where range.location + range.length <= length {
                    attr.addAttribute(.foregroundColor, value: color, range: range)
                }
            }
            if attr.length > maxChars {
                attr.deleteCharacters(in: NSRange(location: maxChars, length: attr.length - maxChars))
            }
            attr.draw(at: NSPoint(x: textInset, y: y + baselineOffset))
        }
    }

    private func drawFiller(_ rect: NSRect) {
        Theme.fillerBackground.setFill()
        rect.fill()
        let path = NSBezierPath()
        let h = rect.height
        var x = floor(rect.minX / 8) * 8 - h
        while x < rect.maxX {
            path.move(to: NSPoint(x: x, y: rect.maxY))
            path.line(to: NSPoint(x: x + h, y: rect.minY))
            x += 8
        }
        path.lineWidth = 1
        Theme.fillerStripe.setStroke()
        NSGraphicsContext.saveGraphicsState()
        rect.clip()
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: Mouse & keyboard

    private func row(at event: NSEvent) -> Int {
        let p = convert(event.locationInWindow, from: nil)
        return Int(p.y / rowHeight)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let r = row(at: event)
        guard r >= 0, r < rows.count else { controller?.clearSelection(); return }
        if rows[r].kind == .gap {
            controller?.expandContext()
            return
        }
        if event.modifierFlags.contains(.shift) {
            controller?.extendSelection(to: r, side: side)
        } else {
            controller?.beginSelection(at: r, side: side)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        autoscroll(with: event)
        let r = max(0, min(rows.count - 1, row(at: event)))
        guard !rows.isEmpty else { return }
        controller?.extendSelection(to: r, side: side)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let r = row(at: event)
        if r >= 0, r < rows.count, controller?.isSelected(row: r) != true, rows[r].kind != .gap {
            controller?.beginSelection(at: r, side: side)
        }
        return controller?.contextMenu()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 125: controller?.moveSelection(by: 1, extend: event.modifierFlags.contains(.shift), side: side)
        case 126: controller?.moveSelection(by: -1, extend: event.modifierFlags.contains(.shift), side: side)
        default: super.keyDown(with: event)
        }
    }

    @objc func copy(_ sender: Any?) {
        controller?.copySelection(side: side)
    }

    override func selectAll(_ sender: Any?) {
        controller?.selectAll(side: side)
    }
}
