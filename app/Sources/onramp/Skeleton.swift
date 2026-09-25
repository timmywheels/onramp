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
