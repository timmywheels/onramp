import AppKit

/// The Pull Requests sidebar: every open PR, searchable and filterable by
/// review status, author, draft and checks. Click one to view it here.
final class PullRequestList: NSViewController, NSSearchFieldDelegate {
    enum ReviewFilter: String, CaseIterable { case any = "Any", requestedFromMe = "Requested from me", needsReview = "Needs review", approved = "Approved", changesRequested = "Changes requested" }
    enum StateFilter: String, CaseIterable { case open = "Open", ready = "Ready", draft = "Draft" }
    enum ChecksFilter: String, CaseIterable { case any = "Any", passing = "Passing", failing = "Failing", pending = "Pending" }

    private let repo: String
    private var items: [GitHub.PRItem] = []
    private var me: String?
    private var review = ReviewFilter.any, author: String? = nil, state = StateFilter.open, checks = ChecksFilter.any
    private let search = NSSearchField()
    private let chips = NSStackView()
    private let scroll = NSScrollView()
    private let list = PRRows()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let chooseGh = NSButton(title: "Choose gh…", target: nil, action: nil)
    private var loading = false { didSet { updateLoading() } }
    /// Row-shaped placeholders until the first page lands.
    private let skeleton = SkeletonView(.pullRequests)
    /// "Loading more…" under the rows while later pages arrive.
    private let more = LoadingMoreView()
    /// The PR shown in this tab (highlighted).
    var current: Int? { didSet { list.subviews.forEach { $0.needsDisplay = true }; list.current = current } }
    /// View a PR; `done` gets an error to show, or nil.
    var onView: ((Int, @escaping (String?) -> Void) -> Void)?

    init(repo: String) {
        self.repo = repo
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        search.placeholderString = "Search, #number or URL"
        search.delegate = self
        search.sendsSearchStringImmediately = true
        search.target = self
        search.action = #selector(searchChanged)
        search.controlSize = .small
        chips.orientation = .horizontal
        chips.spacing = 6
        chips.alignment = .centerY
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = list
        scroll.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(layoutRows), name: NSView.frameDidChangeNotification, object: scroll.contentView)
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        status.alignment = .center
        chooseGh.bezelStyle = .push
        chooseGh.target = self
        chooseGh.action = #selector(chooseGhClicked)
        chooseGh.isHidden = true
        skeleton.isHidden = true
        for v in [search, chips, scroll, skeleton, status, chooseGh] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            search.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            search.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            chips.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 8),
            chips.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            chips.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: chips.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            skeleton.topAnchor.constraint(equalTo: scroll.topAnchor),
            skeleton.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            skeleton.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            skeleton.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
            status.topAnchor.constraint(equalTo: chips.bottomAnchor, constant: 40),
            status.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            status.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            chooseGh.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 12),
            chooseGh.centerXAnchor.constraint(equalTo: root.centerXAnchor),
        ])
        view = root
        buildChips()
    }

    /// Fetch the open PRs (and your login, for "me" filters).
    func refresh() {
        guard !loading else { return }
        loading = true
        let repo = self.repo
        DispatchQueue.global(qos: .userInitiated).async {
            let me = GitHub.myLogin(repo: repo)
            let result = Result {
                try GitHub.listAll(repo: repo) { soFar in // show each page as it lands
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.loading else { return }
                        self.me = me
                        self.items = soFar
                        self.apply()
                    }
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.loading = false
                self.me = me
                switch result {
                case let .success(prs): self.items = prs; self.apply()
                case let .failure(e):
                    self.items = []
                    self.list.set([])
                    self.show("\(e)", error: true)
                    self.chooseGh.isHidden = !((e as? GitHub.Failure)?.notFound ?? false)
                }
                self.buildChips()
            }
        }
    }

    func focusSearch() { view.window?.makeFirstResponder(search) }

    /// Pick the gh binary; saved as gh_path in settings.json.
    @objc private func chooseGhClicked() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.message = "Where is the GitHub CLI (gh)?"
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")
        panel.treatsFilePackagesAsDirectories = true
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                Style.shared.update { $0.ghPath = url.path }
                self?.chooseGh.isHidden = true
                self?.refresh()
            }
        }
    }

    // MARK: Filters

    private func buildChips() {
        chips.arrangedSubviews.forEach { $0.removeFromSuperview() }
        chips.addArrangedSubview(chip("Review", review.rawValue, review != .any, ReviewFilter.allCases.map(\.rawValue)) { [weak self] v in self?.review = ReviewFilter(rawValue: v) ?? .any })
        let authors = ["Anyone", "Me"] + Array(Set(items.map(\.author))).filter { $0 != me }.sorted()
        let authorLabel = author == nil ? "Anyone" : author == me ? "Me" : author!
        chips.addArrangedSubview(chip("Author", authorLabel, author != nil, authors) { [weak self] v in
            self?.author = v == "Anyone" ? nil : v == "Me" ? (self?.me ?? v) : v
        })
        chips.addArrangedSubview(chip("", state.rawValue, state != .open, StateFilter.allCases.map(\.rawValue)) { [weak self] v in self?.state = StateFilter(rawValue: v) ?? .open })
        chips.addArrangedSubview(chip("Checks", checks.rawValue, checks != .any, ChecksFilter.allCases.map(\.rawValue)) { [weak self] v in self?.checks = ChecksFilter(rawValue: v) ?? .any })
    }

    /// A capsule showing "Label: value ⌄" that opens a menu of choices; tinted when set.
    private func chip(_ label: String, _ value: String, _ active: Bool, _ options: [String], _ pick: @escaping (String) -> Void) -> NSView {
        let b = ChipButton()
        b.set(text: label.isEmpty ? value : "\(label): \(value)", active: active)
        b.options = options
        b.selected = value
        b.onPick = { [weak self] v in pick(v); self?.buildChips(); self?.apply() }
        return b
    }

    @objc private func searchChanged() { apply() }

    func controlTextDidEndEditing(_ obj: Notification) {
        // Enter on "#123" or a URL views it even if it isn't in the list.
        guard (obj.userInfo?["NSTextMovement"] as? Int) == NSTextMovement.return.rawValue,
              let n = GitHub.number(from: search.stringValue), !search.stringValue.isEmpty,
              search.stringValue.contains("#") || search.stringValue.contains("/pull/") || Int(search.stringValue) != nil else { return }
        view(n)
    }

    private func apply() {
        let q = search.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        let shown = items.filter { pr in
            if !q.isEmpty, !(pr.title.lowercased().contains(q) || pr.author.lowercased().contains(q) || "#\(pr.number)".contains(q)
                            || pr.headRefName.lowercased().contains(q) || pr.labels.contains { $0.lowercased().contains(q) }) { return false }
            switch state {
            case .open: break
            case .ready: if pr.isDraft { return false }
            case .draft: if !pr.isDraft { return false }
            }
            if let author, pr.author != author { return false }
            switch review {
            case .any: break
            case .requestedFromMe: if !(me.map { pr.requested.contains($0) } ?? false) { return false }
            case .needsReview: if pr.review == .approved || pr.review == .changesRequested { return false }
            case .approved: if pr.review != .approved { return false }
            case .changesRequested: if pr.review != .changesRequested { return false }
            }
            switch checks {
            case .any: break
            case .passing: if pr.checks != .passing { return false }
            case .failing: if pr.checks != .failing { return false }
            case .pending: if pr.checks != .pending { return false }
            }
            return true
        }
        list.me = me
        list.current = current
        list.set(shown) { [weak self] n in self?.view(n) }
        list.addSubview(more)
        updateLoading()
        show(shown.isEmpty && !loading ? (items.isEmpty ? "No open pull requests." : "No pull requests match these filters.") : nil)
        layoutRows()
    }

    private func view(_ n: Int) {
        show(nil)
        onView?(n) { [weak self] error in
            if let error { self?.show(error, error: true) } else { self?.current = n }
        }
    }

    /// Placeholders before anything arrives; a spinner row under the list after.
    private func updateLoading() {
        guard isViewLoaded else { return }
        skeleton.isHidden = !(loading && items.isEmpty)
        more.isHidden = !(loading && !items.isEmpty)
        more.isHidden ? more.spinner.stopAnimation(nil) : more.spinner.startAnimation(nil)
        layoutRows()
    }

    private func show(_ text: String?, error: Bool = false) {
        status.stringValue = text ?? ""
        status.isHidden = text == nil
        status.textColor = error ? .systemRed : .secondaryLabelColor
    }

    @objc private func layoutRows() {
        let w = scroll.contentSize.width
        var y: CGFloat = 0
        for row in list.subviews where row is PRRow {
            row.frame = NSRect(x: 0, y: y, width: w, height: PRRow.height)
            y += PRRow.height
        }
        if !more.isHidden {
            more.frame = NSRect(x: 0, y: y, width: w, height: 36)
            y += 36
        }
        list.frame = NSRect(x: 0, y: 0, width: w, height: max(y, scroll.contentSize.height))
    }
}

/// A spinner and "Loading more…", under the rows while later pages arrive.
private final class LoadingMoreView: NSView {
    let spinner = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "Loading more…")

    init() {
        super.init(frame: .zero)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        label.font = .systemFont(ofSize: 11.5)
        label.textColor = .secondaryLabelColor
        let row = NSStackView(views: [spinner, label])
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([row.centerXAnchor.constraint(equalTo: centerXAnchor), row.centerYAnchor.constraint(equalTo: centerYAnchor)])
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// "Review: Any ⌄" — a small capsule that pops up its choices.
private final class ChipButton: CapsuleButton {
    var options: [String] = []
    var selected = ""
    var onPick: ((String) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        horizontalPadding = 9
        target = self
        action = #selector(open)
        heightAnchor.constraint(equalToConstant: 22).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(text: String, active: Bool) {
        let s = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: active ? .semibold : .regular),
            .foregroundColor: active ? NSColor.labelColor : NSColor.secondaryLabelColor,
        ])
        if let chevron = PickerButton.padded("chevron.down", left: 4, right: 0, pointSize: 7.5, color: active ? .secondaryLabelColor : .tertiaryLabelColor) {
            let a = NSTextAttachment()
            a.image = chevron
            a.bounds = NSRect(x: 0, y: 1, width: chevron.size.width, height: chevron.size.height)
            s.append(NSAttributedString(attachment: a))
        }
        attributedTitle = s
        widthAnchor.constraint(equalToConstant: ceil(cell!.cellSize.width) + 2 * horizontalPadding).isActive = true
    }

    @objc private func open() {
        let menu = NSMenu()
        for o in options {
            let item = menu.addItem(withTitle: o, action: #selector(picked(_:)), keyEquivalent: "")
            item.target = self
            item.state = o == selected ? .on : .off
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 4), in: self)
    }

    @objc private func picked(_ sender: NSMenuItem) { onPick?(sender.title) }
}

private final class PRRows: NSView {
    var me: String?
    var current: Int?
    override var isFlipped: Bool { true }

    func set(_ prs: [GitHub.PRItem], onPick: @escaping (Int) -> Void = { _ in }) {
        subviews.forEach { $0.removeFromSuperview() }
        for pr in prs {
            let row = PRRow(pr, list: self)
            row.onClick = { onPick(pr.number) }
            addSubview(row)
        }
    }
}

/// #153  Title
/// author · 2h · +120 −8          ✓ ● draft
private final class PRRow: NSView {
    static let height: CGFloat = 54
    let pr: GitHub.PRItem
    weak var list: PRRows?
    var onClick: (() -> Void)?
    private var hovering = false { didSet { needsDisplay = true } }

    init(_ pr: GitHub.PRItem, list: PRRows) {
        self.pr = pr
        self.list = list
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let isCurrent = list?.current == pr.number
        if isCurrent || hovering {
            (isCurrent ? DiffStyle.selection : NSColor.labelColor.withAlphaComponent(0.06)).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 2), xRadius: 6, yRadius: 6).fill()
        }
        let pad: CGFloat = 14
        // Right-hand badges: requested-from-you, review decision, checks, draft.
        var right = bounds.width - pad
        func badge(_ text: String, _ color: NSColor) {
            let a = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: color])
            let s = a.size()
            let r = NSRect(x: right - s.width - 10, y: 9, width: s.width + 10, height: 15)
            color.withAlphaComponent(0.15).setFill()
            NSBezierPath(roundedRect: r, xRadius: 7.5, yRadius: 7.5).fill()
            a.draw(at: NSPoint(x: r.minX + 5, y: r.minY + (15 - s.height) / 2))
            right = r.minX - 5
        }
        switch pr.checks {
        case .failing: badge("✗ checks", DiffStyle.deletedAccent)
        case .pending: badge("● checks", .systemYellow)
        case .passing: badge("✓ checks", DiffStyle.addedAccent)
        case .none: break
        }
        switch pr.review {
        case .approved: badge("approved", DiffStyle.addedAccent)
        case .changesRequested: badge("changes", DiffStyle.deletedAccent)
        default: break
        }
        if let me = list?.me, pr.requested.contains(me) { badge("you", DiffStyle.accent) }
        if pr.isDraft { badge("draft", .secondaryLabelColor) }

        let title = NSMutableAttributedString(string: "#\(pr.number)  ", attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor])
        title.append(NSAttributedString(string: pr.title, attributes: [.font: NSFont.systemFont(ofSize: 12.5, weight: .medium), .foregroundColor: NSColor.labelColor]))
        title.draw(with: NSRect(x: pad, y: 8, width: right - pad, height: 17), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])

        let when = RelativeDateTimeFormatter()
        when.unitsStyle = .abbreviated
        let meta = NSMutableAttributedString(string: "\(pr.author) · \(when.localizedString(for: pr.updatedAt, relativeTo: Date()))   ",
                                             attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        let digits = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        meta.append(NSAttributedString(string: "+\(pr.additions)", attributes: [.font: digits, .foregroundColor: DiffStyle.addedAccent]))
        meta.append(NSAttributedString(string: " −\(pr.deletions)", attributes: [.font: digits, .foregroundColor: DiffStyle.deletedAccent]))
        meta.draw(with: NSRect(x: pad, y: 30, width: bounds.width - 2 * pad, height: 15), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        NSColor.separatorColor.withAlphaComponent(0.5).setFill()
        NSRect(x: pad, y: bounds.height - 1, width: bounds.width - 2 * pad, height: 1).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
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
    let mergeButton = CapsuleButton()
    var onToggle: (() -> Void)?
    var onMerge: (() -> Void)?

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
        mergeButton.setText("Merge…")
        mergeButton.horizontalPadding = 10
        mergeButton.target = self
        mergeButton.action = #selector(mergeClicked)
        mergeButton.isHidden = true
        mergeButton.toolTip = "Merge this pull request on GitHub"
        addSubview(mergeButton)
    }

    /// Show "Merge…" (your own open PR).
    func showMerge(_ show: Bool) {
        mergeButton.isHidden = !show
        needsLayout = true
        needsDisplay = true
    }

    @objc private func mergeClicked() { onMerge?() }

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
        mergeButton.fit()
        mergeButton.frame.origin = NSPoint(x: openButton.frame.minX - 8 - mergeButton.frame.width, y: openButton.frame.minY)
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
        let rightEdge = mergeButton.isHidden ? openButton.frame.minX : mergeButton.frame.minX
        line.draw(with: NSRect(x: x, y: mid - lh / 2, width: rightEdge - 12 - x, height: lh), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
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
