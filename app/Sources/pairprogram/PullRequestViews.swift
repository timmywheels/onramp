import AppKit

/// "Open Pull Request": your review requests, your PRs, or all open ones —
/// or type a number / paste a URL.
final class PullRequestPicker: NSViewController, NSTextFieldDelegate {
    private let repo: String
    private let filterControl = NSSegmentedControl(labels: GitHub.Filter.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    private let field = NSTextField()
    private let list = PickerList()
    private let scroll = NSScrollView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private var loadID = 0
    /// Fetches the PR and switches the review; returns an error to show, or nil.
    var onOpen: ((Int, @escaping (String?) -> Void) -> Void)?

    init(repo: String) {
        self.repo = repo
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let width: CGFloat = 460
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 440))
        let title = PopoverUI.title("Open Pull Request")
        filterControl.selectedSegment = 0
        filterControl.segmentDistribution = .fillEqually
        filterControl.target = self
        filterControl.action = #selector(reloadList)
        field.placeholderString = "PR number or URL"
        field.delegate = self
        field.font = .systemFont(ofSize: 13)
        let open = NSButton(title: "Open", target: self, action: #selector(openTyped))
        open.bezelStyle = .push
        open.keyEquivalent = "\r"
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = list
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        status.alignment = .center
        for v in [title, filterControl, scroll, status, field, open] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: width),
            root.heightAnchor.constraint(equalToConstant: 440),
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            filterControl.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 12),
            filterControl.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            filterControl.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            scroll.topAnchor.constraint(equalTo: filterControl.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: field.topAnchor, constant: -12),
            status.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            status.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 30),
            status.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -30),
            field.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            field.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            open.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: 8),
            open.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            open.centerYAnchor.constraint(equalTo: field.centerYAnchor),
        ])
        view = root
        preferredContentSize = root.frame.size
        reloadList()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(field)
    }

    @objc private func reloadList() {
        loadID += 1
        let id = loadID, repo = self.repo
        let filter = GitHub.Filter.allCases[max(0, filterControl.selectedSegment)]
        show(status: "Loading…")
        list.set([])
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try GitHub.list(repo: repo, filter: filter) }
            DispatchQueue.main.async { [weak self] in
                guard let self, id == self.loadID else { return } // a newer filter won
                switch result {
                case let .success(prs):
                    self.list.set(prs) { [weak self] n in self?.open(n) }
                    self.show(status: prs.isEmpty ? (filter == .reviewRequested ? "No reviews requested from you." : "No pull requests.") : nil)
                case let .failure(e):
                    self.show(status: "\(e)", error: true)
                }
                self.layoutList()
            }
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        layoutList()
    }

    private func layoutList() {
        let w = scroll.contentSize.width
        var y: CGFloat = 0
        for row in list.subviews {
            row.frame = NSRect(x: 0, y: y, width: w, height: PickerRow.height)
            y += PickerRow.height
        }
        list.frame = NSRect(x: 0, y: 0, width: w, height: max(y, scroll.contentSize.height))
    }

    private func show(status text: String?, error: Bool = false) {
        status.stringValue = text ?? ""
        status.isHidden = text == nil
        status.textColor = error ? .systemRed : .secondaryLabelColor
    }

    @objc private func openTyped() {
        guard let n = GitHub.number(from: field.stringValue) else { return show(status: "Type a PR number, like 123, or paste its URL.", error: true) }
        open(n)
    }

    private func open(_ n: Int) {
        list.set([])
        show(status: "Fetching #\(n)…")
        onOpen?(n) { [weak self] error in
            if let error { self?.show(status: error, error: true) }
        }
    }
}

private final class PickerList: NSView {
    override var isFlipped: Bool { true }

    func set(_ prs: [GitHub.PRSummary], onPick: @escaping (Int) -> Void = { _ in }) {
        subviews.forEach { $0.removeFromSuperview() }
        for pr in prs {
            let row = PickerRow(pr)
            row.onClick = { onPick(pr.number) }
            addSubview(row)
        }
    }
}

/// #123  Title                         Draft
/// author · head → base · 2h ago
private final class PickerRow: NSView {
    static let height: CGFloat = 50
    let pr: GitHub.PRSummary
    var onClick: (() -> Void)?
    private var hovering = false { didSet { needsDisplay = true } }

    init(_ pr: GitHub.PRSummary) {
        self.pr = pr
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        if hovering {
            NSColor.labelColor.withAlphaComponent(0.07).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 2), xRadius: 6, yRadius: 6).fill()
        }
        let pad: CGFloat = 14
        var right = bounds.width - pad
        if pr.isDraft {
            let chip = NSAttributedString(string: "Draft", attributes: [.font: NSFont.systemFont(ofSize: 10.5, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor])
            let s = chip.size()
            let r = NSRect(x: right - s.width - 12, y: 9, width: s.width + 12, height: 16)
            NSColor.labelColor.withAlphaComponent(0.1).setFill()
            NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8).fill()
            chip.draw(at: NSPoint(x: r.minX + 6, y: r.minY + (16 - s.height) / 2))
            right = r.minX - 8
        }
        let title = NSMutableAttributedString(string: "#\(pr.number)  ", attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor])
        title.append(NSAttributedString(string: pr.title, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.labelColor]))
        title.draw(with: NSRect(x: pad, y: 8, width: right - pad, height: 18), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        let when = RelativeDateTimeFormatter()
        when.unitsStyle = .short
        let meta = "\(pr.author.login) · \(pr.headRefName) → \(pr.baseRefName) · \(when.localizedString(for: pr.updatedAt, relativeTo: Date()))"
        NSAttributedString(string: meta, attributes: [.font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: NSColor.secondaryLabelColor])
            .draw(with: NSRect(x: pad, y: 28, width: bounds.width - 2 * pad, height: 16), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

/// Above the diff while reviewing a pull request: title, who, where, state —
/// click to show the description.
final class PullRequestBar: NSView {
    static let collapsedHeight: CGFloat = 36
    private(set) var expanded = false
    private var pr: GitHub.PR?
    private let bodyScroll = NSScrollView()
    private let bodyText = NSTextView()
    private let openButton = CapsuleButton()
    var onToggle: (() -> Void)?

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        bodyText.isEditable = false
        bodyText.drawsBackground = false
        bodyText.textContainerInset = NSSize(width: 14, height: 4)
        bodyScroll.documentView = bodyText
        bodyScroll.hasVerticalScroller = true
        bodyScroll.autohidesScrollers = true
        bodyScroll.drawsBackground = false
        bodyText.autoresizingMask = [.width]
        bodyScroll.isHidden = true
        addSubview(bodyScroll)
        openButton.setText("Open on GitHub ↗")
        openButton.horizontalPadding = 10
        openButton.target = self
        openButton.action = #selector(openOnGitHub)
        addSubview(openButton)
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(_ pr: GitHub.PR?) {
        self.pr = pr
        let body = (pr?.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        bodyText.textStorage?.setAttributedString(body.isEmpty
            ? NSAttributedString(string: "No description.", attributes: [.font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: NSColor.secondaryLabelColor])
            : CommentMarkdown.render(body, font: .systemFont(ofSize: 12.5), color: .labelColor))
        needsLayout = true
        needsDisplay = true
    }

    /// Height wanted: the bar, plus the description (up to `max`) when open.
    func height(max: CGFloat) -> CGFloat {
        guard expanded, let lm = bodyText.layoutManager, let tc = bodyText.textContainer else { return Self.collapsedHeight }
        bodyText.frame.size.width = bounds.width
        lm.ensureLayout(for: tc)
        let body = lm.usedRect(for: tc).height + 2 * bodyText.textContainerInset.height + 10
        return Self.collapsedHeight + min(body, max)
    }

    override func layout() {
        super.layout()
        openButton.fit()
        openButton.frame.origin = NSPoint(x: bounds.width - 12 - openButton.frame.width, y: (Self.collapsedHeight - CapsuleButton.height) / 2)
        bodyScroll.isHidden = !expanded
        bodyScroll.frame = NSRect(x: 0, y: Self.collapsedHeight, width: bounds.width, height: max(0, bounds.height - Self.collapsedHeight - 6))
        bodyText.frame.size.width = bodyScroll.contentSize.width
    }

    override func draw(_ dirtyRect: NSRect) {
        DiffStyle.headerBackground.setFill()
        bounds.fill()
        DiffStyle.separator.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        guard let pr else { return }
        let mid = Self.collapsedHeight / 2
        // Chevron
        let c = NSBezierPath()
        let cx: CGFloat = 17, s: CGFloat = 3.5
        if expanded {
            c.move(to: NSPoint(x: cx - s, y: mid - s / 2)); c.line(to: NSPoint(x: cx, y: mid + s / 2)); c.line(to: NSPoint(x: cx + s, y: mid - s / 2))
        } else {
            c.move(to: NSPoint(x: cx - s / 2, y: mid - s)); c.line(to: NSPoint(x: cx + s / 2, y: mid)); c.line(to: NSPoint(x: cx - s / 2, y: mid + s))
        }
        c.lineWidth = 1.6; c.lineCapStyle = .round; c.lineJoinStyle = .round
        DiffStyle.headerText.withAlphaComponent(0.55).setStroke()
        c.stroke()
        // State chip
        let (state, color): (String, NSColor) = pr.isDraft ? ("Draft", .secondaryLabelColor)
            : pr.state == "MERGED" ? ("Merged", .systemPurple) : pr.state == "CLOSED" ? ("Closed", DiffStyle.deletedAccent) : ("Open", DiffStyle.addedAccent)
        let chip = NSAttributedString(string: state, attributes: [.font: NSFont.systemFont(ofSize: 10.5, weight: .semibold), .foregroundColor: color])
        let cs = chip.size()
        let chipRect = NSRect(x: 30, y: mid - 8, width: cs.width + 12, height: 16)
        color.withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: chipRect, xRadius: 8, yRadius: 8).fill()
        chip.draw(at: NSPoint(x: chipRect.minX + 6, y: chipRect.minY + (16 - cs.height) / 2))
        // "#123 Title · author · base ← head · +a −d"
        let line = NSMutableAttributedString(string: "#\(pr.number)  ", attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .regular), .foregroundColor: DiffStyle.headerText.withAlphaComponent(0.6)])
        line.append(NSAttributedString(string: pr.title, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: DiffStyle.headerText]))
        let meta: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: DiffStyle.headerText.withAlphaComponent(0.6)]
        line.append(NSAttributedString(string: "   \(pr.author) · \(pr.baseRefName) ← \(pr.headRefName)", attributes: meta))
        if !pr.labels.isEmpty { line.append(NSAttributedString(string: " · " + pr.labels.joined(separator: ", "), attributes: meta)) }
        let x = chipRect.maxX + 10
        let lh = line.size().height
        line.draw(with: NSRect(x: x, y: mid - lh / 2, width: openButton.frame.minX - 12 - x, height: lh), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard p.y < Self.collapsedHeight else { return }
        expanded.toggle()
        needsDisplay = true
        onToggle?()
    }

    @objc private func openOnGitHub() {
        if let url = pr.flatMap({ URL(string: $0.url) }) { NSWorkspace.shared.open(url) }
    }
}
