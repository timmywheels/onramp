import AppKit

/// The bar under the review: progress on the left, controls on the right.
final class StatusBarView: NSView {
    static let height: CGFloat = 40 // a 24pt capsule with 8pt above and below

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
        (fraction >= 1 ? DiffStyle.addedAccent : DiffStyle.accent).setFill()
        NSBezierPath(roundedRect: fill, xRadius: r, yRadius: r).fill()
    }
}

/// onramp's button look (toolbar pickers and status bar): a 24pt capsule
/// drawn by the button itself, so height and padding are ours. With 8pt around
/// it, its corners follow the window's rounded corner.
class CapsuleButton: NSButton {
    static let height: CGFloat = 24
    var horizontalPadding: CGFloat = 12

    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.height / 2
        NSColor.labelColor.withAlphaComponent(isHighlighted ? 0.16 : 0.08).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: r, yRadius: r).fill()
        super.draw(dirtyRect)
    }

    /// Title in the standard capsule font, optionally with a symbol before it (inline, so
    /// it sits beside the text instead of on top of it).
    func setText(_ text: String, symbol: String? = nil, color: NSColor = .labelColor) {
        let font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        let s = NSMutableAttributedString()
        if let symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .medium).applying(.init(paletteColors: [color]))) {
            let a = NSTextAttachment()
            a.image = image
            a.bounds = NSRect(x: 0, y: (font.capHeight - image.size.height) / 2, width: image.size.width, height: image.size.height)
            s.append(NSAttributedString(attachment: a))
            s.append(NSAttributedString(string: " ", attributes: [.font: font]))
        }
        s.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
        attributedTitle = s
    }

    /// Size to the title plus padding.
    func fit() {
        setFrameSize(NSSize(width: ceil(cell!.cellSize.width) + 2 * horizontalPadding, height: Self.height))
    }
}

/// The Agent button: a status dot (pulsing while an agent works) and a label.
final class AgentButton: CapsuleButton {
    private let dot = CALayer()
    private var dotColor = NSColor.tertiaryLabelColor
    private var pulsing = false
    /// Showing an agent at work (the pulsing dot).
    var isWorking: Bool { pulsing }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        dot.cornerRadius = 3.5
        layer?.addSublayer(dot)
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(label: String, color: NSColor, pulsing: Bool) {
        // Room for the dot before the label.
        attributedTitle = NSAttributedString(string: "\u{2007}\u{2007}" + label, attributes: [.font: NSFont.systemFont(ofSize: 11.5, weight: .medium)])
        dotColor = color
        effectiveAppearance.performAsCurrentDrawingAppearance { dot.backgroundColor = color.cgColor }
        guard pulsing != self.pulsing else { return }
        self.pulsing = pulsing
        if pulsing {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1
            pulse.toValue = 0.25
            pulse.duration = 0.8
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            dot.add(pulse, forKey: "pulse")
        } else {
            dot.removeAnimation(forKey: "pulse")
        }
    }

    override func layout() {
        super.layout()
        dot.frame = CGRect(x: horizontalPadding, y: (bounds.height - 7) / 2, width: 7, height: 7)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { dot.backgroundColor = dotColor.cgColor }
    }
}
