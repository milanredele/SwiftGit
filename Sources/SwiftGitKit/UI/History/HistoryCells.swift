import AppKit

let graphLaneWidth: CGFloat = 12
let graphLeftInset: CGFloat = 8

/// Draws one row of the commit graph from the compact lane masks.
final class GraphCellView: NSView {
    var node = 0
    var through: UInt64 = 0
    var topIn: UInt64 = 0
    var bottomOut: UInt64 = 0
    var isHead = false
    var isMerge = false

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError() }

    private func x(_ lane: Int) -> CGFloat { graphLeftInset + CGFloat(lane) * graphLaneWidth + graphLaneWidth / 2 }

    private func forEachBit(_ mask: UInt64, _ body: (Int) -> Void) {
        var m = mask
        while m != 0 {
            body(m.trailingZeroBitCount)
            m &= m - 1
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let h = bounds.height
        let mid = h / 2
        let nx = x(node)

        forEachBit(through) { j in
            let p = NSBezierPath()
            p.move(to: NSPoint(x: x(j), y: 0))
            p.line(to: NSPoint(x: x(j), y: h))
            p.lineWidth = 1.6
            Theme.laneColor(j).setStroke()
            p.stroke()
        }
        forEachBit(topIn) { j in
            let p = NSBezierPath()
            p.move(to: NSPoint(x: x(j), y: 0))
            if j == node {
                p.line(to: NSPoint(x: nx, y: mid))
            } else {
                p.curve(to: NSPoint(x: nx, y: mid),
                        controlPoint1: NSPoint(x: x(j), y: mid * 0.7),
                        controlPoint2: NSPoint(x: nx, y: mid * 0.5))
            }
            p.lineWidth = 1.6
            Theme.laneColor(j).setStroke()
            p.stroke()
        }
        forEachBit(bottomOut) { j in
            let p = NSBezierPath()
            p.move(to: NSPoint(x: nx, y: mid))
            if j == node {
                p.line(to: NSPoint(x: nx, y: h))
            } else {
                p.curve(to: NSPoint(x: x(j), y: h),
                        controlPoint1: NSPoint(x: nx, y: mid + (h - mid) * 0.5),
                        controlPoint2: NSPoint(x: x(j), y: mid + (h - mid) * 0.3))
            }
            p.lineWidth = 1.6
            Theme.laneColor(j).setStroke()
            p.stroke()
        }

        let r: CGFloat = isHead ? 5 : 4
        let dot = NSBezierPath(ovalIn: NSRect(x: nx - r, y: mid - r, width: r * 2, height: r * 2))
        Theme.laneColor(node).setFill()
        dot.fill()
        if isHead || isMerge {
            let inner: CGFloat = isHead ? 2.2 : 1.8
            NSColor.textBackgroundColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: nx - inner, y: mid - inner, width: inner * 2, height: inner * 2)).fill()
        }
    }
}

/// Ref badges followed by the commit subject.
final class SubjectCellView: NSTableCellView {
    var refs: [RefInfo] = []
    var subject = ""
    var currentBranch: String?

    override var isFlipped: Bool { true }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { needsDisplay = true }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError() }

    private static let badgeFont = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
    private static let subjectFont = NSFont.systemFont(ofSize: 12.5)

    private func badgeColor(_ ref: RefInfo) -> NSColor {
        if ref.name == "HEAD" { return .systemRed }
        switch ref.kind {
        case .local: return ref.name == currentBranch ? .controlAccentColor : .systemGreen
        case .remote: return .systemBlue
        case .tag: return .systemOrange
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let emphasized = backgroundStyle == .emphasized
        var x: CGFloat = 4
        let h = bounds.height
        for ref in refs.prefix(6) {
            let isCurrent = ref.kind == .local && ref.name == currentBranch
            let label = (isCurrent ? "✓ " : "") + (ref.kind == .tag ? "◆ " : "") + ref.name
            let text = NSAttributedString(string: label, attributes: [
                .font: SubjectCellView.badgeFont,
                .foregroundColor: emphasized ? NSColor.white : badgeColor(ref),
            ])
            let size = text.size()
            let w = min(size.width + 10, 220)
            let rect = NSRect(x: x, y: (h - 16) / 2, width: w, height: 16)
            let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
            (emphasized ? NSColor.white.withAlphaComponent(0.2) : badgeColor(ref).withAlphaComponent(0.14)).setFill()
            path.fill()
            if isCurrent {
                path.lineWidth = 1
                (emphasized ? NSColor.white : badgeColor(ref)).setStroke()
                path.stroke()
            }
            text.draw(with: NSRect(x: rect.minX + 5, y: rect.minY + 1.5, width: w - 10, height: 14),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            x += w + 4
            if x > bounds.width * 0.6 { break }
        }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let s = NSAttributedString(string: subject, attributes: [
            .font: SubjectCellView.subjectFont,
            .foregroundColor: emphasized ? NSColor.alternateSelectedControlTextColor : NSColor.labelColor,
            .paragraphStyle: style,
        ])
        s.draw(with: NSRect(x: x + 2, y: (h - 16) / 2, width: max(0, bounds.width - x - 4), height: 17),
               options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}

/// Plain text cell (author, date, hash).
final class TextCellView: NSTableCellView {
    let label = NSTextField(labelWithString: "")

    init(font: NSFont, color: NSColor = .secondaryLabelColor) {
        super.init(frame: .zero)
        label.font = font
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}
