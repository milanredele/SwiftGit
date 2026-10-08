import AppKit

/// Line-number gutter that stays fixed while the pane scrolls horizontally.
final class LineNumberRuler: NSRulerView {
    weak var pane: DiffPaneView?
    private let numberFont = Theme.monoSmall

    init(scrollView: NSScrollView, pane: DiffPaneView) {
        self.pane = pane
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = pane
        ruleThickness = 40
        clipsToBounds = true
    }

    required init(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var requiredThickness: CGFloat { ruleThickness }

    func updateThickness() {
        guard let pane, let diff = pane.diff else { ruleThickness = 40; return }
        var maxNo: Int32 = 1
        if let last = diff.hunks.last {
            maxNo = Int32(max(last.oldStart + last.oldCount, last.newStart + last.newCount))
        }
        let digits = CGFloat(max(3, String(maxNo).count))
        let one = digits * pane.charWidth * (11.0 / 12.0) + 12
        let t = ceil(pane.side == .unified ? one * 2 : one)
        if abs(ruleThickness - t) > 0.5 {
            ruleThickness = t
            scrollView?.tile()
        }
    }

    override func draw(_ rect: NSRect) {
        let dirtyRect = rect.intersection(bounds)
        Theme.gutterBackground.setFill()
        dirtyRect.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.maxX - 1, y: dirtyRect.minY, width: 1, height: dirtyRect.height).fill()

        guard let pane, let diff = pane.diff, !pane.rows.isEmpty, let scrollView else { return }
        let offset = scrollView.contentView.bounds.origin.y
        let rh = pane.rowHeight
        let first = max(0, Int((offset + dirtyRect.minY) / rh))
        let last = min(pane.rows.count - 1, Int((offset + dirtyRect.maxY) / rh))
        guard first <= last else { return }
        let attrs: [NSAttributedString.Key: Any] = [.font: numberFont, .foregroundColor: NSColor.tertiaryLabelColor]
        let colWidth = pane.side == .unified ? ruleThickness / 2 : ruleThickness

        func drawNumber(_ n: Int32, column: Int, y: CGFloat) {
            guard n > 0 else { return }
            let s = NSAttributedString(string: String(n), attributes: attrs)
            let w = s.size().width
            s.draw(at: NSPoint(x: CGFloat(column + 1) * colWidth - w - 6, y: y + 2))
        }

        for r in first...last {
            let row = pane.rows[r]
            guard row.kind != .gap else { continue }
            let y = CGFloat(r) * rh - offset
            switch pane.side {
            case .left:
                if row.left >= 0 { drawNumber(diff.lines[Int(row.left)].oldNo, column: 0, y: y) }
            case .right:
                if row.right >= 0 { drawNumber(diff.lines[Int(row.right)].newNo, column: 0, y: y) }
            case .unified:
                let li = Int(row.left >= 0 ? row.left : row.right)
                guard li >= 0 else { continue }
                let line = diff.lines[li]
                drawNumber(line.oldNo, column: 0, y: y)
                drawNumber(line.newNo, column: 1, y: y)
            }
        }
    }
}

/// Thin strip next to the scroller marking every change in the file.
final class OverviewRuler: NSView {
    weak var controller: DiffViewController?
    private var runs: [(start: Int, end: Int, kind: RowKind)] = []
    private var rowCount = 0

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func setRows(_ rows: [DiffRow]) {
        runs.removeAll()
        rowCount = rows.count
        var i = 0
        while i < rows.count {
            let k = rows[i].kind
            if k == .context || k == .gap { i += 1; continue }
            let start = i
            var kind = k
            while i < rows.count, rows[i].kind != .context, rows[i].kind != .gap {
                if rows[i].kind != kind { kind = .changed }
                i += 1
            }
            runs.append((start, i, kind))
        }
        needsDisplay = true
    }

    override func draw(_ rect: NSRect) {
        let dirtyRect = rect.intersection(bounds)
        NSColor.controlBackgroundColor.setFill()
        dirtyRect.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: dirtyRect.minY, width: 1, height: dirtyRect.height).fill()
        guard rowCount > 0 else { return }
        let h = bounds.height
        for run in runs {
            let y1 = CGFloat(run.start) / CGFloat(rowCount) * h
            let y2 = max(y1 + 2, CGFloat(run.end) / CGFloat(rowCount) * h)
            switch run.kind {
            case .added: Theme.markerAdded.setFill()
            case .deleted: Theme.markerDeleted.setFill()
            default: Theme.markerChanged.setFill()
            }
            NSRect(x: 3, y: y1, width: bounds.width - 5, height: y2 - y1).fill()
        }
        if let (start, length) = controller?.visibleFraction() {
            let r = NSRect(x: 1, y: start * h, width: bounds.width - 1, height: max(4, length * h))
            NSColor.labelColor.withAlphaComponent(0.10).setFill()
            r.fill()
        }
    }

    override func mouseDown(with event: NSEvent) { jump(event) }
    override func mouseDragged(with event: NSEvent) { jump(event) }

    private func jump(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        controller?.scrollToFraction(max(0, min(1, p.y / max(1, bounds.height))))
    }
}
