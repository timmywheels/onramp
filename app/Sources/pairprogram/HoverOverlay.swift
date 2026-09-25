import AppKit

/// Highlights the line under the pointer and shows a "+" on the left to
/// comment on it. Sits above the canvas and editors; only the "+" takes clicks.
final class HoverOverlay: NSView {
    var onPlus: (() -> Void)?

    override var isFlipped: Bool { true }

    static var plusSize: CGFloat { min(DiffStyle.lineHeight - 2, 15) }
    private var plusRect: NSRect {
        let s = Self.plusSize
        return NSRect(x: 5, y: (bounds.height - s) / 2, width: s, height: s)
    }

    override func draw(_ dirtyRect: NSRect) {
        DiffStyle.hover.setFill()
        bounds.fill()
        let r = plusRect
        DiffStyle.accent.setFill()
        NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
        let plus = NSBezierPath()
        let inset: CGFloat = 4
        plus.move(to: NSPoint(x: r.midX, y: r.minY + inset)); plus.line(to: NSPoint(x: r.midX, y: r.maxY - inset))
        plus.move(to: NSPoint(x: r.minX + inset, y: r.midY)); plus.line(to: NSPoint(x: r.maxX - inset, y: r.midY))
        plus.lineWidth = 1.5
        plus.lineCapStyle = .round
        NSColor.white.setStroke()
        plus.stroke()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        return plusRect.insetBy(dx: -3, dy: -3).contains(p) ? self : nil // everything else passes through
    }

    override func resetCursorRects() { addCursorRect(plusRect, cursor: .pointingHand) }

    override func mouseDown(with event: NSEvent) { onPlus?() }
}
