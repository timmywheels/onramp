import AppKit
import QuartzCore

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
        case ci
        case working(agent: String)
        case finding(severity: String?)
    }

    enum Filter: Int { case open, resolved, all }

    /// The selected segment: a quiet grey pill like the toolbar's, not the system accent.
    static let selectedSegment = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.16) : NSColor(white: 0, alpha: 0.1) }

    var onSelect: ((Thread) -> Void)?
    /// Seen these replies: they stop needing you (swipe right, or Mark All as Read).
    var onMarkRead: (([Thread]) -> Void)?
    /// Resolve (true) or reopen (false) a thread (swipe left).
    var onSetResolved: ((Thread, Bool) -> Void)?

    private var items: [Item] = []
    private var filter = Filter.open
    private let filterControl = NSSegmentedControl(labels: ["Open", "Resolved", "All"], trackingMode: .selectOne, target: nil, action: nil)
    private let scroll = NSScrollView()
    private let list = FlippedStack()
    private let empty = NSTextField(labelWithString: "")
    private let markAll = NSButton(title: "Mark All as Read", target: nil, action: nil)
    private lazy var scrollBelowFilter = scroll.topAnchor.constraint(equalTo: filterControl.bottomAnchor, constant: 10)
    private lazy var scrollBelowMarkAll = scroll.topAnchor.constraint(equalTo: markAll.bottomAnchor, constant: 4)

    override func loadView() {
        let root = NSView()
        filterControl.controlSize = .small
        filterControl.selectedSegment = 0
        filterControl.target = self
        filterControl.action = #selector(filterChanged)
        filterControl.segmentDistribution = .fillEqually
        filterControl.selectedSegmentBezelColor = Self.selectedSegment

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = list
        empty.font = .systemFont(ofSize: 12)
        empty.textColor = .secondaryLabelColor
        empty.alignment = .center

        markAll.bezelStyle = .inline
        markAll.controlSize = .small
        markAll.font = .systemFont(ofSize: 11)
        markAll.target = self
        markAll.action = #selector(markAllClicked)
        markAll.toolTip = "Every reply waiting on you: seen (a new reply brings it back)"
        markAll.isHidden = true

        for v in [filterControl, markAll, scroll, empty] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            filterControl.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            filterControl.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            filterControl.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            scrollBelowFilter,
            markAll.topAnchor.constraint(equalTo: filterControl.bottomAnchor, constant: 8),
            markAll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
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
        let waiting = items.filter { $0.status == .needsYou }.count
        if isViewLoaded {
            markAll.isHidden = waiting < 1
            scrollBelowFilter.isActive = waiting < 1
            scrollBelowMarkAll.isActive = waiting > 0
        }
        rebuild()
    }

    @objc private func markAllClicked() { onMarkRead?(items.filter { $0.status == .needsYou }.map(\.thread)) }

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
            row.onMarkRead = { [weak self] in self?.onMarkRead?([item.thread]) }
            row.onSetResolved = { [weak self] in self?.onSetResolved?(item.thread, $0) }
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
    var onMarkRead: (() -> Void)?
    var onSetResolved: ((Bool) -> Void)?
    /// Two-finger swipe, like Mail: right marks read, left resolves (or reopens).
    private var offset: CGFloat = 0 { didSet { needsDisplay = true } }
    private var swipe: Bool? // nil until the gesture's direction is known; true = sideways
    private static let swipeAt: CGFloat = 70
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
        case .ci: ("CI failing", DiffStyle.deletedAccent)
        case let .finding(severity): ((severity ?? "finding") + " · triage", CommentMetrics.severityColor(severity))
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

    /// What a swipe does here: right → read (only if it needs you); left → resolve or reopen.
    private var canMarkRead: Bool { item.status == .needsYou }
    private var resolveAction: (title: String, resolve: Bool)? {
        switch item.status {
        case .open, .needsYou, .ci: ("Resolve", true)
        case .resolved: ("Reopen", false)
        default: nil // pending, being worked on, or a finding to triage
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        if offset != 0 {
            let right = offset > 0
            let (title, color): (String, NSColor) = right ? ("Mark Read", .systemBlue) : (resolveAction?.title ?? "", resolveAction?.resolve == false ? .systemOrange : .systemGreen)
            let progress = min(1, abs(offset) / Self.swipeAt)
            // The strip the row slid off of (the row itself is see-through: the panel's material shows).
            let strip = right ? NSRect(x: 6, y: 2, width: offset, height: bounds.height - 4)
                              : NSRect(x: bounds.width - 6 + offset, y: 2, width: -offset, height: bounds.height - 4)
            color.withAlphaComponent(0.35 + 0.65 * progress).setFill() // deepens as you near the threshold
            NSBezierPath(roundedRect: strip, xRadius: 6, yRadius: 6).fill()
            let label = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 11.5, weight: .semibold), .foregroundColor: NSColor.white])
            let size = label.size()
            if size.width + 16 < strip.width { label.draw(at: NSPoint(x: strip.midX - size.width / 2, y: strip.midY - size.height / 2)) }
            NSGraphicsContext.current?.cgContext.translateBy(x: offset, y: 0)
        }
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

    override func scrollWheel(with event: NSEvent) {
        if !event.momentumPhase.isEmpty { if swipe == true { return }; return super.scrollWheel(with: event) } // the fling after a swipe: ours, drop it
        guard !event.phase.isEmpty else { return super.scrollWheel(with: event) } // a mouse wheel: just scroll
        if event.phase == .began { swipe = nil; animation?.invalidate() }
        if swipe == nil, event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0 {
            swipe = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) * 1.5 // clearly sideways, or it's a scroll
        }
        guard swipe == true else { return super.scrollWheel(with: event) }
        // Follow the fingers (natural scrolling already reports their direction); past the
        // threshold it gets heavier, like pulling on a rubber band.
        let dx = event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
        let heavy: CGFloat = abs(offset) > Self.swipeAt ? 0.35 : 1
        let wasArmed = abs(offset) >= Self.swipeAt
        let next = offset + dx * heavy
        offset = next > 0 ? (canMarkRead ? min(next, bounds.width * 0.6) : 0) : (resolveAction != nil ? max(next, -bounds.width * 0.6) : 0)
        if wasArmed != (abs(offset) >= Self.swipeAt) { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
        if event.phase == .ended || event.phase == .cancelled {
            var action: (() -> Void)?
            if event.phase == .ended, offset >= Self.swipeAt { action = onMarkRead }
            if event.phase == .ended, offset <= -Self.swipeAt, let r = resolveAction { action = { [weak self] in self?.onSetResolved?(r.resolve) } }
            if let action {
                animate(to: offset > 0 ? bounds.width : -bounds.width, duration: 0.18, done: action) // slides away, then it's done
            } else {
                animate(to: 0, duration: 0.25) // springs back
            }
        }
    }

    private var animation: Timer?

    /// Ease `offset` to `target` (ease-out), then run `done`.
    private func animate(to target: CGFloat, duration: TimeInterval, done: (() -> Void)? = nil) {
        animation?.invalidate()
        let from = offset, start = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { return timer.invalidate() }
                let t = min(1, (CACurrentMediaTime() - start) / duration)
                self.offset = from + (target - from) * (1 - pow(1 - t, 3))
                if t >= 1 {
                    timer.invalidate()
                    self.swipe = nil
                    done?()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common) // keeps going while the trackpad is still sending events
        animation = timer
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        if canMarkRead { menu.addItem(ClosureMenuItem("Mark as Read") { [weak self] in self?.onMarkRead?() }) }
        if let r = resolveAction { menu.addItem(ClosureMenuItem(r.title) { [weak self] in self?.onSetResolved?(r.resolve) }) }
        return menu.items.isEmpty ? nil : menu
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// A menu item that runs a closure.
private final class ClosureMenuItem: NSMenuItem {
    private let run: () -> Void
    init(_ title: String, _ run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { run() }
}
