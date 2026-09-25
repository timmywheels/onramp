import AppKit

/// Shared layout for pairprogram's popovers, so they all get the same width,
/// padding and type scale, and size themselves after Auto Layout has run
/// (sizing a stack before layout clipped the right edge).
@MainActor
enum PopoverUI {
    static let width: CGFloat = 380
    static let padding = NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20)

    /// A vertical stack of full-width rows.
    static func stack(_ views: [NSView], spacing: CGFloat = 12) -> NSStackView {
        let s = NSStackView()
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = spacing
        for v in views { add(v, to: s) }
        return s
    }

    static func add(_ v: NSView, to s: NSStackView, spacingAfter: CGFloat? = nil) {
        s.addArrangedSubview(v)
        v.widthAnchor.constraint(equalTo: s.widthAnchor).isActive = true
        if let spacingAfter { s.setCustomSpacing(spacingAfter, after: v) }
    }

    /// Pads `stack` inside a view sized to fit it.
    static func container(_ stack: NSStackView) -> NSView {
        let root = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: padding.top),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: padding.left),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -padding.right),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -padding.bottom),
            stack.widthAnchor.constraint(equalToConstant: width),
        ])
        root.layoutSubtreeIfNeeded()
        root.setFrameSize(root.fittingSize)
        return root
    }

    static func title(_ s: String) -> NSTextField {
        let f = NSTextField(labelWithString: s)
        f.font = .systemFont(ofSize: 14, weight: .semibold)
        return f
    }

    static func note(_ s: String, size: CGFloat = 12) -> NSTextField {
        let f = NSTextField(wrappingLabelWithString: s)
        f.font = .systemFont(ofSize: size)
        f.textColor = .secondaryLabelColor
        f.preferredMaxLayoutWidth = width
        return f
    }

    static func separator() -> NSBox {
        let b = NSBox()
        b.boxType = .separator
        return b
    }

    /// Items spread across one row: `leading` on the left, `trailing` on the right.
    static func row(_ leading: [NSView], _ trailing: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let r = NSStackView(views: leading + [spacer] + trailing)
        r.orientation = .horizontal
        r.alignment = .centerY
        r.spacing = spacing
        return r
    }
}
