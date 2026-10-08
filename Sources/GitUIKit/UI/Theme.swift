import AppKit

enum Theme {
    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    private static func dynamic(_ light: NSColor, _ dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }

    static let addedBackground = dynamic(rgb(0.90, 0.97, 0.91), rgb(0.11, 0.23, 0.14))
    static let deletedBackground = dynamic(rgb(1.00, 0.92, 0.92), rgb(0.28, 0.12, 0.13))
    static let addedWord = dynamic(rgb(0.66, 0.92, 0.69), rgb(0.17, 0.43, 0.23))
    static let deletedWord = dynamic(rgb(1.00, 0.74, 0.74), rgb(0.55, 0.19, 0.21))
    static let gapBackground = dynamic(rgb(0.93, 0.95, 0.98), rgb(0.16, 0.18, 0.22))
    static let gutterBackground = dynamic(rgb(0.97, 0.97, 0.97), rgb(0.12, 0.12, 0.13))
    static let fillerBackground = dynamic(rgb(0.965, 0.965, 0.965), rgb(0.14, 0.14, 0.15))
    static let fillerStripe = dynamic(rgb(0.0, 0.0, 0.0, 0.07), rgb(1.0, 1.0, 1.0, 0.06))
    static let selection = dynamic(rgb(0.25, 0.50, 1.0, 0.22), rgb(0.35, 0.55, 1.0, 0.30))
    static let markerAdded = dynamic(rgb(0.20, 0.70, 0.30), rgb(0.30, 0.75, 0.40))
    static let markerDeleted = dynamic(rgb(0.90, 0.25, 0.25), rgb(0.95, 0.40, 0.40))
    static let markerChanged = dynamic(rgb(0.25, 0.50, 0.95), rgb(0.40, 0.60, 1.0))

    static let laneColors: [NSColor] = [
        .systemBlue, .systemPink, .systemGreen, .systemOrange, .systemPurple,
        .systemTeal, .systemRed, .systemYellow, .systemIndigo, .systemBrown,
    ]

    static func laneColor(_ lane: Int) -> NSColor { laneColors[lane % laneColors.count] }

    static func statusColor(_ code: Character) -> NSColor {
        switch code {
        case "M", "T": return .systemOrange
        case "A": return .systemGreen
        case "D": return .systemRed
        case "R", "C": return .systemBlue
        case "U": return .systemRed
        case "?": return .systemGray
        default: return .secondaryLabelColor
        }
    }

    static let monoFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let monoSmall = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

    static func symbol(_ name: String, _ label: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: label)
    }
}

extension NSView {
    func pinEdges(to other: NSView, insets: NSEdgeInsets = NSEdgeInsetsZero) {
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: other.leadingAnchor, constant: insets.left),
            trailingAnchor.constraint(equalTo: other.trailingAnchor, constant: -insets.right),
            topAnchor.constraint(equalTo: other.topAnchor, constant: insets.top),
            bottomAnchor.constraint(equalTo: other.bottomAnchor, constant: -insets.bottom),
        ])
    }
}

func makeLabel(_ text: String, font: NSFont = .systemFont(ofSize: NSFont.systemFontSize), color: NSColor = .labelColor) -> NSTextField {
    let l = NSTextField(labelWithString: text)
    l.font = font
    l.textColor = color
    l.lineBreakMode = .byTruncatingTail
    l.translatesAutoresizingMaskIntoConstraints = false
    return l
}

func makeScrollingTable(_ table: NSTableView) -> NSScrollView {
    let scroll = NSScrollView()
    scroll.documentView = table
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = false
    scroll.autohidesScrollers = true
    scroll.borderType = .noBorder
    scroll.translatesAutoresizingMaskIntoConstraints = false
    return scroll
}

/// Table view that reports space/return/delete key presses.
final class KeyTableView: NSTableView {
    var onKey: ((String) -> Bool)?

    override func keyDown(with event: NSEvent) {
        let key: String?
        switch event.keyCode {
        case 49: key = "space"
        case 36, 76: key = "return"
        case 51, 117: key = "delete"
        default: key = nil
        }
        if let key, let onKey, onKey(key) { return }
        super.keyDown(with: event)
    }
}

/// Two-pane split view rules: minimum sizes and an initial divider position
/// (also used when an autosaved position left a pane collapsed).
final class SplitRules: NSObject, NSSplitViewDelegate {
    let minFirst: CGFloat
    let minSecond: CGFloat
    let initial: (CGFloat) -> CGFloat

    init(minFirst: CGFloat, minSecond: CGFloat, initial: @escaping (CGFloat) -> CGFloat) {
        self.minFirst = minFirst
        self.minSecond = minSecond
        self.initial = initial
    }

    private func length(_ sv: NSSplitView) -> CGFloat { sv.isVertical ? sv.bounds.width : sv.bounds.height }
    private func size(_ v: NSView, _ sv: NSSplitView) -> CGFloat { sv.isVertical ? v.frame.width : v.frame.height }

    func splitView(_ sv: NSSplitView, constrainMinCoordinate proposed: CGFloat, ofSubviewAt i: Int) -> CGFloat {
        max(proposed, minFirst)
    }

    func splitView(_ sv: NSSplitView, constrainMaxCoordinate proposed: CGFloat, ofSubviewAt i: Int) -> CGFloat {
        min(proposed, length(sv) - minSecond - sv.dividerThickness)
    }

    func splitView(_ sv: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }

    /// Call from viewDidLayout: fixes a collapsed or too-small pane.
    func enforce(_ sv: NSSplitView) {
        let total = length(sv)
        guard total > minFirst + minSecond, sv.arrangedSubviews.count == 2 else { return }
        let first = size(sv.arrangedSubviews[0], sv)
        let second = size(sv.arrangedSubviews[1], sv)
        if first < minFirst || second < minSecond {
            let target = min(max(initial(total), minFirst), total - minSecond - sv.dividerThickness)
            sv.setPosition(floor(target), ofDividerAt: 0)
        }
    }
}

let relativeDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .medium
    f.timeStyle = .short
    f.doesRelativeDateFormatting = true
    return f
}()
