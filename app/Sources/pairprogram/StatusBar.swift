import AppKit

/// The bar under the review: progress on the left, controls on the right.
final class StatusBarView: NSView {
    static let height: CGFloat = 32

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        DiffStyle.headerBackground.setFill()
        bounds.fill()
        DiffStyle.separator.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
}

/// A thin rounded progress bar ("files viewed"); turns green when complete.
final class ProgressBarView: NSView {
    var fraction: CGFloat = 0 { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.height / 2
        DiffStyle.separator.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: r, yRadius: r).fill()
        guard fraction > 0 else { return }
        let fill = NSRect(x: 0, y: 0, width: max(bounds.height, bounds.width * min(1, fraction)), height: bounds.height)
        (fraction >= 1 ? NSColor.systemGreen : DiffStyle.accent).setFill()
        NSBezierPath(roundedRect: fill, xRadius: r, yRadius: r).fill()
    }
}
