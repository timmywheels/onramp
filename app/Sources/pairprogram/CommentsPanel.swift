import AppKit

/// The right-hand panel: every comment thread in the review, in review order,
/// filterable (Open / Resolved / All). Click one to jump to it.
final class CommentsPanel: NSViewController {
    struct Item {
        let thread: Thread
        let line: Int?          // 1-based where it is now; nil = outdated
        let status: Status
    }

    enum Status: Equatable {
        case open, resolved, pending
        case needsYou
        case working(agent: String)
    }

    enum Filter: Int { case open, resolved, all }

    var onSelect: ((Thread) -> Void)?

    private var items: [Item] = []
    private var filter = Filter.open
    private let filterControl = NSSegmentedControl(labels: ["Open", "Resolved", "All"], trackingMode: .selectOne, target: nil, action: nil)
    private let scroll = NSScrollView()
    private let list = FlippedStack()
    private let empty = NSTextField(labelWithString: "")

    override func loadView() {
        let root = NSView()
        filterControl.controlSize = .small
        filterControl.selectedSegment = 0
        filterControl.target = self
        filterControl.action = #selector(filterChanged)
        filterControl.segmentDistribution = .fillEqually

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = list
        empty.font = .systemFont(ofSize: 12)
        empty.textColor = .secondaryLabelColor
        empty.alignment = .center

        for v in [filterControl, scroll, empty] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            filterControl.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            filterControl.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            filterControl.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: filterControl.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            empty.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            empty.topAnchor.constraint(equalTo: filterControl.bottomAnchor, constant: 40),
            empty.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, constant: -40),
        ])
        view = root
        NotificationCenter.default.addObserver(self, selector: #selector(rebuild), name: .styleChanged, object: nil)
    }

    func update(_ items: [Item]) {
        self.items = items
        let open = items.filter { $0.status != .resolved }.count
        filterControl.setLabel(open > 0 ? "Open (\(open))" : "Open", forSegment: 0)
        rebuild()
    }

    @objc private func filterChanged() {
        filter = Filter(rawValue: filterControl.selectedSegment) ?? .open
        rebuild()
    }

    @objc private func rebuild() {
        guard isViewLoaded else { return }
        let shown = items.filter {
            switch filter {
            case .open: $0.status != .resolved
            case .resolved: $0.status == .resolved
            case .all: true
            }
        }
        list.subviews.forEach { $0.removeFromSuperview() }
        for item in shown {
            let row = CommentRow(item)
            row.onClick = { [weak self] in self?.onSelect?(item.thread) }
            list.addSubview(row)
        }
        empty.stringValue = switch filter {
        case .open: items.isEmpty ? "No comments yet.\nHover a line and click + to add one." : "Nothing open. 🎉"
        case .resolved: "No resolved comments."
        case .all: "No comments yet."
        }
        empty.isHidden = !shown.isEmpty
        viewDidLayout()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let width = scroll.contentSize.width
        var y: CGFloat = 0
        for row in list.subviews.compactMap({ $0 as? CommentRow }) {
            let h = row.height(for: width)
            row.frame = NSRect(x: 0, y: y, width: width, height: h)
            y += h
        }
        list.frame = NSRect(x: 0, y: 0, width: width, height: max(y, scroll.contentSize.height))
    }
}

private final class FlippedStack: NSView {
    override var isFlipped: Bool { true }
}

/// One thread: where, what, who, and its status chip.
private final class CommentRow: NSView {
    let item: CommentsPanel.Item
    var onClick: (() -> Void)?
    private var hovering = false { didSet { needsDisplay = true } }
    private static let pad: CGFloat = 12

    init(_ item: CommentsPanel.Item) {
        self.item = item
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private var location: NSAttributedString {
        let name = (item.thread.path as NSString).lastPathComponent
        let s = NSMutableAttributedString(string: name, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.labelColor])
        let where_ = item.line.map { ":\($0)" } ?? " (outdated)"
        s.append(NSAttributedString(string: where_, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]))
        return s
    }

    private var snippet: NSAttributedString {
        let first = item.thread.entries.first?.body ?? ""
        // The comment as plain text: markdown parsed away, not stripped by hand (keeps "a > 0").
        let parsed = (try? AttributedString(markdown: first, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))).map { String($0.characters) } ?? first
        let plain = parsed.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: " ")
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        return NSAttributedString(string: plain, attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: item.status == .resolved ? NSColor.secondaryLabelColor : NSColor.labelColor,
            .paragraphStyle: para,
        ])
    }

    private var meta: String {
        let t = item.thread
        let replies = t.entries.count - 1
        let who = t.entries.first?.author ?? ""
        let when = RelativeDateTimeFormatter()
        when.unitsStyle = .short
        let last = Date(timeIntervalSince1970: TimeInterval(t.entries.last?.createdAt ?? 0))
        let ago = Date().timeIntervalSince(last) < 45 ? "just now" : when.localizedString(for: last, relativeTo: Date())
        return [who, replies > 0 ? "\(replies) repl\(replies == 1 ? "y" : "ies")" : nil, ago].compactMap { $0 }.joined(separator: " · ")
    }

    private var chip: (String, NSColor)? {
        switch item.status {
        case .needsYou: ("needs you", .systemYellow)
        case let .working(agent): ("\(agent) · working", AgentColor.of(agent))
        case .pending: ("pending", DiffStyle.accent)
        case .resolved: ("resolved", .secondaryLabelColor)
        case .open: nil
        }
    }

    private func snippetHeight(_ width: CGFloat) -> CGFloat {
        let line = ceil(NSFont.systemFont(ofSize: 12).boundingRectForFont.height)
        let h = snippet.boundingRect(with: NSSize(width: width - 2 * Self.pad, height: 1000), options: [.usesLineFragmentOrigin, .usesFontLeading]).height
        return min(ceil(h), line * 2) // at most two lines
    }

    func height(for width: CGFloat) -> CGFloat { 10 + 17 + 3 + snippetHeight(width) + 3 + 15 + 10 }

    override func draw(_ dirtyRect: NSRect) {
        let pad = Self.pad
        if hovering {
            NSColor.labelColor.withAlphaComponent(0.06).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 2), xRadius: 6, yRadius: 6).fill()
        }
        var y: CGFloat = 10
        var chipWidth: CGFloat = 0
        if let (text, color) = chip {
            let label = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 10.5, weight: .medium), .foregroundColor: color])
            let size = label.size()
            let r = NSRect(x: bounds.width - pad - size.width - 12, y: y, width: size.width + 12, height: 16)
            color.withAlphaComponent(0.15).setFill()
            NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8).fill()
            label.draw(at: NSPoint(x: r.minX + 6, y: r.minY + (16 - size.height) / 2))
            chipWidth = r.width + 8
        }
        location.draw(with: NSRect(x: pad, y: y, width: bounds.width - 2 * pad - chipWidth, height: 17), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        y += 17 + 3
        let sh = snippetHeight(bounds.width)
        snippet.draw(with: NSRect(x: pad, y: y, width: bounds.width - 2 * pad, height: sh), options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine])
        y += sh + 3
        NSAttributedString(string: meta, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
            .draw(with: NSRect(x: pad, y: y, width: bounds.width - 2 * pad, height: 15), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        NSColor.separatorColor.setFill()
        NSRect(x: pad, y: bounds.height - 1, width: bounds.width - 2 * pad, height: 1).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
