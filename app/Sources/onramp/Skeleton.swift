import AppKit

/// Placeholder shapes with a slow shimmer while something loads: PR rows in the
/// sidebar, diff lines in the review. Respects Reduce Motion (no shimmer).
final class SkeletonView: NSView {
    enum Shape { case pullRequests, diff }

    private let shape: Shape
    private let bars = CAShapeLayer()
    private let shine = CAGradientLayer()
    private let shineMask = CAShapeLayer()
    private let caption = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    /// Behind the spinner and caption, so they never sit on the bars.
    private let pill = NSView()

    init(_ shape: Shape) {
        self.shape = shape
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(bars)
        shine.startPoint = CGPoint(x: 0, y: 0.5)
        shine.endPoint = CGPoint(x: 1, y: 0.5)
        shine.mask = shineMask
        layer?.addSublayer(shine)
        caption.font = .systemFont(ofSize: 12)
        caption.textColor = .secondaryLabelColor
        caption.alignment = .center
        caption.lineBreakMode = .byTruncatingMiddle
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        pill.wantsLayer = true
        pill.isHidden = true
        caption.isHidden = true
        pill.layer?.cornerRadius = 12
        for v in [pill, caption, spinner] as [NSView] { addSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// The line under the shapes ("Getting #42 from GitHub…"); nil hides it.
    func set(caption text: String?) {
        caption.stringValue = text ?? ""
        caption.isHidden = text == nil
        pill.isHidden = text == nil
        text == nil ? spinner.stopAnimation(nil) : spinner.startAnimation(nil)
        needsLayout = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window == nil ? shine.removeAllAnimations() : startShimmer()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let path = CGMutablePath()
        var y: CGFloat
        switch shape {
        case .pullRequests:
            // Like PRRow: a title line and a meta line, 54pt apart.
            y = 0
            var i = 0
            while y < bounds.height, i < 12 {
                let w = bounds.width - 28
                path.addRoundedRect(in: CGRect(x: 14, y: y + 12, width: w * [0.82, 0.64, 0.74, 0.58, 0.9][i % 5], height: 10), cornerWidth: 4, cornerHeight: 4)
                path.addRoundedRect(in: CGRect(x: 14, y: y + 31, width: w * [0.46, 0.38, 0.52, 0.34, 0.42][i % 5], height: 8), cornerWidth: 3, cornerHeight: 3)
                y += 54
                i += 1
            }
        case .diff:
            // A file header, then code lines of varying length, then another file.
            y = 16
            var line = 0
            while y < bounds.height - 40 {
                if line % 14 == 0 {
                    if line > 0 { y += 14 }
                    path.addRoundedRect(in: CGRect(x: 20, y: y, width: min(360, bounds.width * 0.4), height: 12), cornerWidth: 4, cornerHeight: 4)
                    y += 30
                }
                let indent: CGFloat = [0, 16, 16, 32, 32, 32, 16, 16, 0, 16, 32, 16][line % 12]
                let widths: [CGFloat] = [0.52, 0.38, 0.61, 0.27, 0.45, 0.33, 0.56, 0.22, 0.48, 0.4]
                path.addRoundedRect(in: CGRect(x: 60 + indent, y: y, width: (bounds.width - 140) * widths[line % widths.count], height: 9), cornerWidth: 3, cornerHeight: 3)
                y += 21
                line += 1
            }
        }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            bars.fillColor = NSColor(white: dark ? 1 : 0, alpha: dark ? 0.07 : 0.06).cgColor
            let hi = NSColor(white: dark ? 1 : 0, alpha: dark ? 0.07 : 0.05).cgColor
            shine.colors = [NSColor.clear.cgColor, hi, NSColor.clear.cgColor]
        }
        bars.path = path
        bars.frame = bounds
        shine.frame = bounds
        shineMask.path = path
        shineMask.frame = bounds
        let captionY = shape == .diff ? bounds.midY - 10 : min(bounds.height - 30, 54 * 3 + 20)
        let textWidth = min(bounds.width - 80, ceil(caption.cell?.cellSize.width ?? 0) + 2)
        spinner.frame = NSRect(x: bounds.midX - 8, y: captionY - 26, width: 16, height: 16)
        caption.frame = NSRect(x: bounds.midX - textWidth / 2, y: captionY, width: textWidth, height: 18)
        pill.frame = NSRect(x: bounds.midX - textWidth / 2 - 22, y: captionY - 38, width: textWidth + 44, height: 66)
        pill.layer?.backgroundColor = (layer?.backgroundColor).flatMap { NSColor(cgColor: $0) }?.cgColor ?? DiffStyle.background.cgColor
        pill.layer?.borderWidth = 1
        effectiveAppearance.performAsCurrentDrawingAppearance { pill.layer?.borderColor = NSColor.separatorColor.cgColor }
        CATransaction.commit()
    }

    private func startShimmer() {
        shine.removeAllAnimations()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { shine.isHidden = true; return }
        let sweep = CABasicAnimation(keyPath: "locations")
        sweep.fromValue = [-0.6, -0.3, 0.0]
        sweep.toValue = [1.0, 1.3, 1.6]
        sweep.duration = 1.6
        sweep.repeatCount = .infinity
        shine.add(sweep, forKey: "shimmer")
    }
}

/// What the review shows when there's nothing to review: why, and the way in (a pull request).
final class EmptyReviewView: NSView {
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "Nothing to review here yet")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let browse = NSButton(title: "Browse Pull Requests", target: nil, action: nil)
    private let hint = NSTextField(labelWithString: "⇧⌘P to search pull requests by title, #number or link")
    var onBrowse: (() -> Void)?

    init() {
        super.init(frame: .zero)
        let sign = MenuBarItem.icon(working: false, dot: false)
        sign.size = NSSize(width: 44, height: 44)
        icon.image = sign
        icon.contentTintColor = .tertiaryLabelColor
        icon.imageScaling = .scaleProportionallyUpOrDown
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.alignment = .center
        detail.font = .systemFont(ofSize: 12.5)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .center
        detail.preferredMaxLayoutWidth = 380
        browse.bezelStyle = .push
        browse.controlSize = .large
        browse.bezelColor = DiffStyle.primaryButton
        browse.target = self
        browse.action = #selector(browseClicked)
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        let stack = NSStackView(views: [icon, title, detail, browse, hint])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.setCustomSpacing(14, after: icon)
        stack.setCustomSpacing(18, after: detail)
        stack.setCustomSpacing(10, after: browse)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 44), icon.heightAnchor.constraint(equalToConstant: 44),
            detail.widthAnchor.constraint(lessThanOrEqualToConstant: 380),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -30),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// "main matches origin/main." — why there's nothing, in terms of what you're comparing.
    func set(comparing: String?) {
        let what = comparing.map { "This matches \($0)." } ?? "There are no changes yet."
        detail.stringValue = what + " Open a pull request to review it, or ask your agent for a change: it shows up here as it's written."
    }

    @objc private func browseClicked() { onBrowse?() }
}


/// The agent's cursor, Zed-style: its line tinted in the agent's colour, a caret at
/// the start of the text, and a small name tag above it.
final class AgentCursorView: NSView {
    static let labelHeight: CGFloat = 14
    private let agent: String
    private let color: NSColor
    /// The code it's typing, drawn over the lines it replaces until the file is saved.
    var preview: String? { didSet { if preview != oldValue { needsDisplay = true } } }
    var previewLines: Int { preview.map { max(1, $0.components(separatedBy: "\n").count) } ?? 0 }

    init(agent: String, color: NSColor) {
        self.agent = agent
        self.color = color
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil } // never in the way of your clicks

    override func draw(_ dirtyRect: NSRect) {
        let line = NSRect(x: 0, y: Self.labelHeight, width: bounds.width, height: bounds.height - Self.labelHeight)
        if let preview { // the new code as it streams in, on an opaque band so the old lines don't show through
            DiffStyle.background.setFill()
            line.fill()
            color.withAlphaComponent(0.10).setFill()
            line.fill()
            let attrs: [NSAttributedString.Key: Any] = [.font: DiffStyle.font, .foregroundColor: DiffStyle.text]
            for (k, text) in preview.components(separatedBy: "\n").enumerated() {
                NSAttributedString(string: text, attributes: attrs).draw(at: NSPoint(x: DiffStyle.gutterWidth + 8, y: line.minY + CGFloat(k) * DiffStyle.lineHeight + 2))
            }
        } else {
            color.withAlphaComponent(0.13).setFill()
            line.fill()
        }
        let x = DiffStyle.gutterWidth + 2
        color.setFill()
        NSRect(x: x, y: line.minY, width: 2, height: line.height).fill() // the caret
        let tag = NSAttributedString(string: agent, attributes: [.font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: NSColor.white])
        let size = tag.size()
        let pill = NSRect(x: x, y: 0, width: size.width + 10, height: Self.labelHeight)
        NSBezierPath(roundedRect: pill, xRadius: 3, yRadius: 3).fill()
        tag.draw(at: NSPoint(x: pill.minX + 5, y: (Self.labelHeight - size.height) / 2))
    }
}
