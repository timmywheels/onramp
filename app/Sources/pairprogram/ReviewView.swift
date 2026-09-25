import AppKit

/// The endless scroll: every changed file in one scroll view.
final class ReviewView: NSView {
    private let repoPath: String
    let scrollView = NSScrollView()
    let document: ReviewDocumentView
    private let statusBar = StatusBarView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let progress = ProgressBarView()
    private let foldAllButton = NSButton()
    private let progressLabel = NSTextField(labelWithString: "")
    private let agentButton = NSButton(title: "Connect an agent…", target: nil, action: nil)
    private let reviewButton = NSButton(title: "Review changes", target: nil, action: nil)
    /// Branch (everything since you forked from main, like a PR) vs uncommitted only.
    private let modeToggle = NSSegmentedControl(labels: ["Branch", "Uncommitted"], trackingMode: .selectOne, target: nil, action: nil)
    private var base: ReviewBase?
    private var statusParts: [(priority: Int, text: NSAttributedString)] = []
    private let runner = AgentRunner()
    private var reviewPopover: NSPopover?
    private var agentTimer: Timer?
    private var loadMs: Double = 0

    var onLoad: (([ReviewFile]) -> Void)?
    var onFileChanged: ((Int) -> Void)?
    var onCurrentFile: ((Int) -> Void)?

    init(repoPath: String) {
        self.repoPath = repoPath
        self.document = ReviewDocumentView(repoPath: repoPath)
        super.init(frame: .zero)

        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = DiffStyle.background
        scrollView.documentView = document
        scrollView.contentView.postsBoundsChangedNotifications = true
        addSubview(scrollView)

        addSubview(statusBar)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.cell?.truncatesLastVisibleLine = true
        progressLabel.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
        progressLabel.textColor = .secondaryLabelColor
        progress.toolTip = "Files marked Viewed"
        agentButton.isBordered = false
        agentButton.target = self
        agentButton.action = #selector(agentButtonClicked)
        reviewButton.bezelStyle = .push
        reviewButton.controlSize = .small
        reviewButton.font = .systemFont(ofSize: 11.5, weight: .medium)
        reviewButton.target = self
        reviewButton.action = #selector(showReview)
        modeToggle.controlSize = .small
        modeToggle.font = .systemFont(ofSize: 11.5)
        modeToggle.target = self
        modeToggle.action = #selector(modeChanged)
        modeToggle.setToolTip("All changes on this branch, committed or not (like a pull request)", forSegment: 0)
        modeToggle.setToolTip("Only changes that aren't committed yet", forSegment: 1)
        foldAllButton.isBordered = false
        foldAllButton.imagePosition = .imageOnly
        foldAllButton.target = self
        foldAllButton.action = #selector(toggleFoldAll)
        for v in [foldAllButton, progress, progressLabel, statusLabel, modeToggle, reviewButton, agentButton] as [NSView] { statusBar.addSubview(v) }
        runner.onChange = { [weak self] in self?.updateAgents() }
        // Agents come and go (sessions start/end); poll cheaply.
        agentTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateAgents() }
        }

        document.onChange = { [weak self] in self?.updateStatus(); self?.updateAgents() }
        document.onFileChanged = { [weak self] i in self?.onFileChanged?(i) }
        document.onCurrentFile = { [weak self] i in self?.onCurrentFile?(i) }
        NotificationCenter.default.addObserver(
            self, selector: #selector(didScroll), name: NSView.boundsDidChangeNotification, object: scrollView.contentView
        )
        NotificationCenter.default.addObserver(self, selector: #selector(styleChanged), name: .styleChanged, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func styleChanged() {
        scrollView.backgroundColor = DiffStyle.background
        statusBar.needsDisplay = true
        progress.needsDisplay = true
        document.styleChanged()
    }

    override func layout() {
        super.layout()
        let h = StatusBarView.height
        statusBar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: h)
        scrollView.frame = NSRect(x: 0, y: h, width: bounds.width, height: bounds.height - h)
        document.width = scrollView.contentSize.width
        DiffStyle.paintWidth = document.width

        // Everything centered on the bar's midline; 12pt between groups.
        func center(_ v: NSView, x: CGFloat) {
            v.frame.origin = NSPoint(x: x, y: round((h - v.frame.height) / 2) + 0.5)
        }
        var right = bounds.width - 14
        for v in [agentButton, reviewButton, modeToggle] as [NSControl] {
            v.sizeToFit()
            right -= v.frame.width
            center(v, x: right)
            right -= 12
        }
        var left: CGFloat = 10
        foldAllButton.frame = NSRect(x: left, y: round((h - 22) / 2), width: 22, height: 22)
        left = foldAllButton.frame.maxX + 8
        progress.frame = NSRect(x: left, y: round((h - 6) / 2), width: 72, height: 6)
        left = progress.frame.maxX + 8
        progressLabel.sizeToFit()
        center(progressLabel, x: left)
        left = progressLabel.frame.maxX + 18
        statusLabel.attributedStringValue = fittedStatus(width: right - 6 - left)
        statusLabel.sizeToFit()
        statusLabel.frame.size.width = max(0, min(statusLabel.frame.width, right - 6 - left))
        center(statusLabel, x: left)
    }

    func reload() {
        let start = CACurrentMediaTime()
        do {
            let base = try reviewBase(repoRoot: repoPath)
            self.base = base
            document.baseRev = base.rev
            modeToggle.selectedSegment = base.mode == .branch ? 0 : 1
            document.setFiles(try loadReview(repoRoot: repoPath, baseRev: base.rev).map(ReviewFile.init))
        } catch {
            statusLabel.stringValue = "Error: \(error)"
            return
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
        loadMs = (CACurrentMediaTime() - start) * 1000
        onLoad?(document.files)
        updateAgents()
        document.onFilesReplaced = { [weak self] files in self?.onLoad?(files); self?.updateStatus() }
        document.watchWorkingTree()
        updateStatus()
        SelfTest.run(review: self)
    }

    private func updateStatus() {
        let added = document.files.reduce(0) { $0 + $1.added }
        let removed = document.files.reduce(0) { $0 + $1.removed }
        let dirty = document.dirtyCount
        let comments = document.openCommentCount
        let collapseNext = document.anyExpanded
        let symbol = collapseNext ? "rectangle.compress.vertical" : "rectangle.expand.vertical"
        let tip = collapseNext ? "Collapse all files (⌥⌘←)" : "Expand all files (⌥⌘→)"
        if foldAllButton.toolTip != tip {
            let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
            foldAllButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?.withSymbolConfiguration(config)
            foldAllButton.contentTintColor = .secondaryLabelColor
            foldAllButton.toolTip = tip
        }
        let count = document.files.count
        let viewed = document.viewedCount
        progress.fraction = count == 0 ? 0 : CGFloat(viewed) / CGFloat(count)
        progressLabel.stringValue = "\(viewed) / \(count) viewed"

        // Parts in display order with a priority; when the bar is narrow the
        // least important ones go whole, rather than truncating mid-word.
        let font = NSFont.systemFont(ofSize: 11.5)
        let digits = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
        func part(_ pieces: [(String, NSColor, NSFont)]) -> NSAttributedString {
            let a = NSMutableAttributedString()
            for (t, c, f) in pieces { a.append(NSAttributedString(string: t, attributes: [.font: f, .foregroundColor: c])) }
            return a
        }
        var parts: [(priority: Int, text: NSAttributedString)] = [
            (0, part([("+\(added)", .systemGreen, digits), (" −\(removed)", .systemRed, digits)])),
        ]
        if let base, base.mode == .branch {
            parts.append((2, part([(base.branch.map { "vs \($0)" } ?? "vs HEAD (no main branch found)", .secondaryLabelColor, font)])))
            if base.commits > 0 { parts.append((4, part([("\(base.commits) commit\(base.commits == 1 ? "" : "s")", .secondaryLabelColor, font)]))) }
        } else {
            parts.append((2, part([("uncommitted changes", .secondaryLabelColor, font)])))
        }
        if comments > 0 { parts.append((1, part([("\(comments) open comment\(comments == 1 ? "" : "s")", DiffStyle.accent, font)]))) }
        if dirty > 0 { parts.append((1, part([("\(dirty) unsaved (⌘S)", .systemOrange, font)]))) }
        statusParts = parts
        statusLabel.toolTip = String(format: "Loaded in %.0f ms", loadMs)
        needsLayout = true
    }

    /// The status parts that fit in `width`, dropping the least important first.
    private func fittedStatus(width: CGFloat) -> NSAttributedString {
        let dot = NSAttributedString(string: "   ·   ", attributes: [.font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: NSColor.tertiaryLabelColor])
        var parts = statusParts
        while true {
            let joined = NSMutableAttributedString()
            for (i, p) in parts.enumerated() {
                if i > 0 { joined.append(dot) }
                joined.append(p.text)
            }
            if joined.size().width <= width || parts.count <= 1 { return joined }
            let drop = parts.indices.max { parts[$0].priority < parts[$1].priority }!
            parts.remove(at: drop)
        }
    }

    @objc func toggleFoldAll() {
        document.setAllCollapsed(document.anyExpanded)
    }

    @objc private func modeChanged() {
        setMode(modeToggle.selectedSegment == 0 ? .branch : .uncommitted)
    }

    func setMode(_ mode: ReviewMode) {
        try? setReviewMode(repoRoot: repoPath, mode: mode)
        reload()
    }

    var statusText: String { statusLabel.stringValue }

    func saveAll() {
        document.saveAll()
        updateStatus()
    }

    private func updateAgents() {
        let agents = ConnectedAgents.list(repoRoot: repoPath)
        var title = agents.isEmpty ? "Connect an agent…" : "● " + agents.joined(separator: ", ") + " connected"
        var color: NSColor = agents.isEmpty ? .secondaryLabelColor : .systemGreen
        switch runner.state {
        case let .running(t): title = "◌ \(t.title) is working on your review…"; color = .controlAccentColor
        case let .finished(t, ok): title = ok ? "✓ \(t.title) finished · view log" : "✗ \(t.title) failed · view log"; color = ok ? .systemGreen : .systemRed
        case .idle: break
        }
        let pending = document.pendingCount
        let reviewTitle = pending > 0 ? "Finish review (\(pending))" : "Review changes"
        if reviewButton.title != reviewTitle { reviewButton.title = reviewTitle; needsLayout = true }
        guard agentButton.title != title else { return }
        agentButton.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: color,
            .font: NSFont.systemFont(ofSize: 11.5),
        ])
        agentButton.toolTip = agents.isEmpty ? "Set up an agent to read and resolve your comments over MCP" : "Connected over MCP. Click for setup."
        needsLayout = true
    }

    @objc private func agentButtonClicked() {
        if case .finished = runner.state, let log = runner.logURL { NSWorkspace.shared.open(log); return }
        showConnect()
    }

    @objc func showReview() {
        let vc = ReviewSubmitViewController(pending: document.pendingCount, repo: repoPath)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = vc
        vc.onSubmit = { [weak self] body, verdict, target in
            if self?.submit(body: body, verdict: verdict, target: target) == true { popover.close() }
        }
        vc.onDiscard = { [weak self] in
            guard let self else { return }
            try? discardPending(repoRoot: self.repoPath, author: self.document.reviewAuthor)
            popover.close()
            self.document.reloadThreads()
            self.updateAgents()
        }
        reviewPopover = popover
        popover.show(relativeTo: reviewButton.bounds, of: reviewButton, preferredEdge: .maxY)
    }

    /// Publish the pending review and, optionally, start an agent on it.
    @discardableResult
    func submit(body: String, verdict: Verdict, target: AgentRunner.Target) -> Bool {
        do {
            _ = try submitReview(repoRoot: repoPath, author: document.reviewAuthor, body: body, verdict: verdict)
        } catch {
            NSSound.beep()
            return false
        }
        document.reloadThreads()
        if target != .none { runner.run(target, repo: repoPath) }
        updateAgents()
        return true
    }

    var agentState: AgentRunner.State { runner.state }

    @objc func showConnect() {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = AgentConnectViewController()
        popover.show(relativeTo: agentButton.bounds, of: agentButton, preferredEdge: .maxY)
    }

    @objc private func didScroll() {
        document.didScroll()
    }
}

/// Sizes the scroll to the whole review and hosts the canvas (which follows the
/// viewport) plus a real editor over any file you're editing.
final class ReviewDocumentView: NSView, DiffEditorDelegate {
    private let repoPath: String
    private(set) var files: [ReviewFile] = []
    private var indexByPath: [String: Int] = [:]
    private(set) var tops: [CGFloat] = [] // tops[i] = y of file i; tops[count] = total height
    private let canvas = ReviewCanvasView()
    private var editors: [Int: DiffEditor] = [:]
    /// Comment boxes on or near screen: "t:<thread id>" or "c:<file index>" (composer).
    private var commentViews: [String: NSView] = [:]
    private var allThreads: [Thread] = []
    private var commentsWatcher: DispatchSourceFileSystemObject?
    private let hover = HoverOverlay()
    let stickyHeader = StickyHeaderView()
    /// path → fingerprint of the file when you marked it viewed.
    private lazy var viewedFingerprints = ViewedStore.load(repoPath)
    var viewedCount: Int { files.filter(\.viewed).count }
    private var hoverTarget: (path: String, target: CommentTarget)?
    private lazy var author: String = Self.gitUserName(repoPath) ?? "you"

    var openCommentCount: Int { allThreads.filter { $0.status == .open }.count }
    /// Your comments/replies waiting in a review you haven't submitted.
    private(set) var pendingCount = 0
    var reviewAuthor: String { author }

    var onChange: (() -> Void)?
    var onFilesReplaced: (([ReviewFile]) -> Void)?
    private var treeWatcher: TreeWatcher?
    private var reloading = false
    /// Commit the review diffs against (see `reviewBase`); set by ReviewView.reload.
    var baseRev = "HEAD"
    private var reloadAgain = false
    var onFileChanged: ((Int) -> Void)?
    var onCurrentFile: ((Int) -> Void)?
    private var currentFile = -1
    var width: CGFloat = 800 {
        didSet { if width != oldValue { needsLayout = true } }
    }

    var dirtyCount: Int { editors.values.filter(\.isDirty).count }

    override var isFlipped: Bool { true }

    init(repoPath: String) {
        self.repoPath = repoPath
        super.init(frame: .zero)
        canvas.document = self
        addSubview(canvas)
        hover.isHidden = true
        hover.onPlus = { [weak self] in
            guard let self, let t = self.hoverTarget else { return }
            self.withFile(t.path) { self.startComment($0, t.target) }
        }
        addSubview(hover)
        stickyHeader.document = self
        stickyHeader.isHidden = true
        addSubview(stickyHeader) // on top of editors, comments and hover
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) { updateHover(convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { setHover(nil) }

    /// Highlight the code line under the pointer (in the canvas or an editor).
    private func updateHover(_ p: NSPoint) {
        guard !files.isEmpty, p.y >= 0 else { return setHover(nil) }
        if !stickyHeader.isHidden, p.y < stickyHeader.frame.maxY { return setHover(nil) } // under the pinned header
        let i = index(at: p.y)
        let layout = files[i].layout
        let row = layout.rows[layout.rowIndex(at: p.y - tops[i])]
        guard p.y < tops[i] + row.y + row.height else { return setHover(nil) }
        let target: CommentTarget
        switch row.kind {
        case let .line(line, _): target = CommentTarget(line: line, old: false)
        case let .deleted(h, k): target = CommentTarget(line: Int(files[i].hunks[h].oldStart) + k, old: true)
        default: return setHover(nil)
        }
        setHover((files[i].path, target), frame: NSRect(x: 0, y: tops[i] + row.y, width: width, height: row.height))
    }

    private func setHover(_ target: (path: String, target: CommentTarget)?, frame: NSRect = .zero) {
        hoverTarget = target
        hover.isHidden = target == nil
        guard target != nil, hover.frame != frame else { return }
        hover.frame = frame
        hover.needsDisplay = true
        window?.invalidateCursorRects(for: hover)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setFiles(_ newFiles: [ReviewFile]) {
        editors.values.forEach { $0.host.removeFromSuperview() }
        editors = [:]
        commentViews.values.forEach { $0.removeFromSuperview() }
        commentViews = [:]
        files = newFiles
        for f in files {
            applyViewed(f)
            f.collapsed = f.viewed
        }
        indexByPath = Dictionary(uniqueKeysWithValues: files.enumerated().map { ($1.path, $0) })
        recomputeTops() // before anything can trigger a layout pass against the new files
        reloadThreads()
        watchComments()
        needsLayout = true
    }

    private func recomputeTops() {
        var t: [CGFloat] = [0]
        t.reserveCapacity(files.count + 1)
        for f in files { t.append(t.last! + f.height) }
        tops = t
    }

    /// Index of the file containing y.
    func index(at y: CGFloat) -> Int {
        guard tops.count == files.count + 1 else { recomputeTops(); return index(at: y) }
        var lo = 0, hi = max(0, files.count - 1)
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if tops[mid] <= y { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    func frame(ofFile i: Int) -> NSRect {
        NSRect(x: 0, y: tops[i], width: width, height: tops[i + 1] - tops[i])
    }

    /// Callbacks hold a path, not an index: indices move when files are reloaded.
    private func withFile(_ path: String, _ body: (Int) -> Void) {
        if let i = indexByPath[path] { body(i) }
    }

    func hasEditor(_ i: Int) -> Bool { editors[i] != nil }
    func editor(_ i: Int) -> DiffEditor? { editors[i] }

    func isDirty(_ file: ReviewFile) -> Bool {
        guard let i = files.firstIndex(where: { $0 === file }) else { return false }
        return editors[i]?.isDirty ?? false
    }

    override func layout() {
        super.layout()
        let minHeight = superview?.bounds.height ?? 0
        setFrameSize(NSSize(width: width, height: contentHeight(minHeight)))
        let boxWidth = min(760, width - DiffStyle.gutterWidth - 5 - 24)
        if boxWidth != CommentMetrics.boxWidth { // comment heights depend on width
            CommentMetrics.boxWidth = boxWidth
            files.forEach { $0.invalidateLayout() }
            recomputeTops()
            setFrameSize(NSSize(width: width, height: contentHeight(minHeight)))
        }
        for (i, editor) in editors { positionEditor(editor, i) }
        followViewport()
        updateCommentViews()
        refreshHover() // rows may have moved under the pointer
    }

    private func refreshHover() {
        guard let w = window else { return }
        updateHover(convert(w.mouseLocationOutsideOfEventStream, from: nil))
    }

    private var viewport: NSRect { (superview as? NSClipView)?.bounds ?? bounds }

    private func followViewport() {
        let v = viewport
        canvas.frame = NSRect(x: 0, y: v.minY, width: width, height: v.height)
        canvas.needsDisplay = true
        positionStickyHeader(v)
    }

    /// Pin the header of the file at the top of the viewport; the next file's
    /// header pushes it up.
    private func positionStickyHeader(_ v: NSRect) {
        let i = files.isEmpty ? -1 : index(at: v.minY)
        guard i >= 0, i < files.count, tops[i] < v.minY, !files[i].collapsed else {
            stickyHeader.isHidden = true
            return
        }
        let h = FileLayout.headerHeight
        let fileBottom = tops[i] + files[i].height - FileLayout.spacing
        let frame = NSRect(x: 0, y: min(v.minY, fileBottom - h), width: width, height: h)
        if stickyHeader.fileIndex != i || stickyHeader.frame != frame {
            stickyHeader.fileIndex = i
            stickyHeader.frame = frame
            window?.invalidateCursorRects(for: stickyHeader)
        }
        stickyHeader.isHidden = false
        stickyHeader.needsDisplay = true
    }

    func didScroll() {
        followViewport()
        let v = viewport
        let current = files.isEmpty ? -1 : index(at: v.minY + FileLayout.headerHeight)
        if current != currentFile { currentFile = current; onCurrentFile?(current) }
        // Lay out whatever part of an open editor just scrolled into view.
        for (i, editor) in editors where frame(ofFile: i).intersects(v) {
            editor.textView.layout.textViewportLayoutController.layoutViewport()
            editor.host.setNeedsDisplay(editor.host.convert(v, from: self)) // decorate newly laid-out lines
        }
        dropIdleEditors(keeping: v.insetBy(dx: 0, dy: -2 * v.height))
        updateCommentViews()
        refreshHover() // content moved under the pointer
    }

    /// Scroll so file `i`'s header is at the top.
    /// The review's height plus room to scroll past the end until the last
    /// file's header reaches the top (like Zed), so every file can be scrolled
    /// to, jumped to from the sidebar, and becomes the current file.
    private func contentHeight(_ viewportHeight: CGFloat) -> CGFloat {
        guard !files.isEmpty else { return viewportHeight }
        return max(tops.last ?? 0, tops[files.count - 1] + viewportHeight)
    }

    func scrollToFile(_ i: Int) {
        guard let clip = superview as? NSClipView, i < files.count else { return }
        let maxY = max(0, frame.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: 0, y: min(tops[i], maxY)))
        (clip.superview as? NSScrollView)?.reflectScrolledClipView(clip)
    }

    /// Font or theme changed. Heights depend on the font, so re-layout and keep
    /// the file at the top of the viewport where it was.
    func styleChanged() {
        let v = viewport
        let anchor = files.isEmpty ? 0 : index(at: v.minY)
        let into = files.isEmpty ? 0 : (v.minY - tops[anchor]) / max(1, tops[anchor + 1] - tops[anchor])
        files.forEach { $0.invalidateLayout() }
        for (i, editor) in editors {
            if editor.isDirty { editor.applyStyle() } else { editor.host.removeFromSuperview(); editors[i] = nil }
        }
        recomputeTops()
        canvas.styleChanged()
        guard let clip = superview as? NSClipView, !files.isEmpty else { return needsLayout = true }
        setFrameSize(NSSize(width: width, height: contentHeight(clip.bounds.height)))
        clip.scroll(to: NSPoint(x: 0, y: tops[anchor] + into * (tops[anchor + 1] - tops[anchor])))
        (clip.superview as? NSScrollView)?.reflectScrolledClipView(clip)
        needsLayout = true
    }

    // MARK: Editing

    private func positionEditor(_ editor: DiffEditor, _ i: Int) {
        editor.host.frame = NSRect(x: 0, y: tops[i] + FileLayout.editorTop(files[i]), width: width, height: editor.textView.fixedHeight)
        editor.host.layoutSubtreeIfNeeded()
    }

    /// Put a real editor over file `i`, caret at UTF-16 `offset`.
    @discardableResult
    func activateEditor(_ i: Int, offset: Int) -> DiffEditor? {
        let file = files[i]
        guard file.kind == .text, !file.collapsed else { return nil }
        var marks: [(String, CFTimeInterval)] = [("start", CACurrentMediaTime())]
        func mark(_ n: String) { marks.append((n, CACurrentMediaTime())) }
        defer {
            if ProcessInfo.processInfo.environment["PP_SELFTEST"] == "open-time" {
                let parts = zip(marks.dropFirst(), marks).map { String(format: "%@ %.1f", $0.0, ($0.1 - $1.1) * 1000) }
                FileHandle.standardError.write(("[open] " + parts.joined(separator: ", ") + "\n").data(using: .utf8)!)
            }
        }
        let editor = editors[i] ?? {
            let e = DiffEditor(path: file.path, oldText: file.oldText, newText: file.newText as String, hunks: file.hunks,
                               expanded: file.revealed, syntax: file.syntax, oldSyntax: file.oldSyntax)
            mark("init")
            e.setReveal(expanded: file.revealed, commentSpace: file.commentSpace, deletedCommentSpace: file.deletedCommentSpace)
            mark("reveal")
            e.delegate = self
            let path = file.path
            e.textView.onFoldClick = { [weak self] start, end, all in self?.withFile(path) { self?.expand($0, start: start, end: end, all: all) } }
            e.textView.onGutterClick = { [weak self] line in self?.withFile(path) { self?.startComment($0, CommentTarget(line: line, old: false)) } }
            editors[i] = e
            addSubview(e.host, positioned: .above, relativeTo: canvas) // comment boxes + hover stay on top
            positionEditor(e, i)
            mark("place")
            e.textView.redisplayVisibleFragments() // first layout happens here, once it has a window and size
            mark("relayout")
            return e
        }()
        editor.textView.setSelectedRange(NSRange(location: min(offset, file.newText.length), length: 0))
        mark("select")
        window?.makeFirstResponder(editor.textView)
        mark("focus")
        dropIdleEditors(keeping: viewport.insetBy(dx: 0, dy: -2 * viewport.height), except: i)
        canvas.needsDisplay = true
        return editor
    }

    /// Clean editors go back to the canvas when they scroll away, or when
    /// another file is opened and they don't have focus.
    private func dropIdleEditors(keeping band: NSRect, except keep: Int? = nil) {
        for (i, editor) in editors where i != keep && !editor.isDirty {
            let nearby = frame(ofFile: i).intersects(band)
            let focused = window?.firstResponder === editor.textView
            if nearby && (focused || keep == nil) { continue }
            editor.host.removeFromSuperview()
            editors[i] = nil
            canvas.needsDisplay = true
        }
    }

    func diffEditorDidHighlight(_ editor: DiffEditor, spans: SyntaxSpans, text: String) {
        guard let i = editors.first(where: { $0.value === editor })?.key else { return }
        files[i].adoptSyntax(spans, for: text)
    }

    func diffEditorDidChange(_ editor: DiffEditor) {
        guard let i = editors.first(where: { $0.value === editor })?.key else { return }
        let before = files[i].height
        files[i].update(text: editor.text, hunks: editor.hunks)
        relocateThreads(i) // comments follow their lines as you type
        editor.setReveal(expanded: files[i].revealed, commentSpace: files[i].commentSpace, deletedCommentSpace: files[i].deletedCommentSpace)
        if files[i].height != before { recomputeTops() }
        needsLayout = true // leading deletions above the editor may have changed
        canvas.needsDisplay = true // header counts / dirty dot
        onChange?()
        onFileChanged?(i)
    }

    // MARK: Clicks

    func click(atDocumentY y: CGFloat, x: CGFloat) {
        let i = index(at: y)
        guard i < files.count else { return }
        let file = files[i]
        let layout = file.layout
        let r = layout.rowIndex(at: y - tops[i])
        switch layout.rows[r].kind {
        case .header:
            if FileHeader.viewedRect(width: width).insetBy(dx: -8, dy: 0).contains(CGPoint(x: x, y: FileLayout.headerHeight / 2)) {
                toggleViewed(i)
            } else if NSEvent.modifierFlags.contains(.option) {
                setAllCollapsed(!file.collapsed) // ⌥-click: all files follow this one
            } else {
                toggleCollapse(i)
            }
        case let .line(line, _):
            if x < DiffStyle.gutterWidth { return startComment(i, CommentTarget(line: line, old: false)) } // clicked the line number
            activateEditor(i, offset: file.lineStarts[line] + canvas.column(in: file, line: line, x: x))
        case let .fold(start, end):
            expand(i, start: start, end: end, all: NSEvent.modifierFlags.contains(.option))
        case let .deleted(h, k):
            if x < DiffStyle.gutterWidth { return startComment(i, CommentTarget(line: Int(file.hunks[h].oldStart) + k, old: true)) }
            // Caret at the start of the next real line.
            let next = layout.rows[r...].lazy.compactMap { row -> Int? in
                if case let .line(l, _) = row.kind { return l } else { return nil }
            }.first
            if let next { activateEditor(i, offset: file.lineStarts[next]) }
        case .note, .spacer, .thread, .composer:
            break
        }
    }

    static let expandStep = 20
    static let expandAllUpTo = 40

    /// Reveal hidden unchanged lines start..<end: all of them, or `expandStep`
    /// lines next to the changes on each side (GitHub's "expand" buttons).
    func expand(_ i: Int, start: Int, end: Int, all: Bool) {
        let file = files[i]
        let step = Self.expandStep
        if all || end - start <= Self.expandAllUpTo {
            file.expanded.append(start..<end)
        } else if start == 0 {
            file.expanded.append((end - step)..<end)            // above the first change
        } else if end == file.lineCount {
            file.expanded.append(start..<(start + step))        // below the last change
        } else {
            file.expanded += [start..<(start + step), (end - step)..<end]
        }
        editors[i]?.setReveal(expanded: file.revealed, commentSpace: file.commentSpace, deletedCommentSpace: file.deletedCommentSpace)
        recomputeTops()
        needsLayout = true
        canvas.needsDisplay = true
    }

    // MARK: Fold all

    var anyExpanded: Bool { files.contains { !$0.collapsed } }

    /// Fold or unfold every file, keeping the file at the top of the viewport
    /// in place. Files with unsaved edits stay open.
    func setAllCollapsed(_ collapsed: Bool) {
        guard !files.isEmpty else { return }
        let anchor = index(at: viewport.minY + 1)
        for (i, f) in files.enumerated() where f.collapsed != collapsed {
            if collapsed, editors[i]?.isDirty == true { continue }
            if collapsed { editors[i]?.host.removeFromSuperview(); editors[i] = nil }
            f.collapsed = collapsed
        }
        recomputeTops()
        if let clip = superview as? NSClipView {
            setFrameSize(NSSize(width: width, height: contentHeight(clip.bounds.height)))
            clip.scroll(to: NSPoint(x: 0, y: max(0, min(tops[anchor], frame.height - clip.bounds.height))))
            (clip.superview as? NSScrollView)?.reflectScrolledClipView(clip)
        }
        needsLayout = true
        canvas.needsDisplay = true
        onChange?()
    }

    // MARK: Viewed

    /// Viewed if you marked it and it hasn't changed since.
    private func applyViewed(_ f: ReviewFile) {
        guard let saved = viewedFingerprints[f.path] else { f.viewed = false; f.changedSinceViewed = false; return }
        f.viewed = saved == ViewedStore.fingerprint(f)
        f.changedSinceViewed = !f.viewed
    }

    /// GitHub's "Viewed" checkbox: marking folds the file, unmarking opens it.
    func toggleViewed(_ i: Int) {
        let f = files[i]
        if !f.viewed, editors[i]?.isDirty == true { NSSound.beep(); return } // save first
        f.viewed.toggle()
        f.changedSinceViewed = false
        viewedFingerprints[f.path] = f.viewed ? ViewedStore.fingerprint(f) : nil
        ViewedStore.save(repoPath, viewedFingerprints)
        if f.collapsed != f.viewed {
            toggleCollapse(i)
        } else {
            canvas.needsDisplay = true
            onChange?()
        }
        onFileChanged?(i)
    }

    func toggleCollapse(_ i: Int) {
        if let editor = editors[i], editor.isDirty { NSSound.beep(); return } // save first
        editors[i]?.host.removeFromSuperview()
        editors[i] = nil
        files[i].collapsed.toggle()
        recomputeTops()
        // If the file's header had scrolled off the top (sticky header click), bring it back.
        if let clip = superview as? NSClipView, tops[i] < clip.bounds.minY {
            setFrameSize(NSSize(width: width, height: contentHeight(clip.bounds.height)))
            clip.scroll(to: NSPoint(x: 0, y: tops[i]))
            (clip.superview as? NSScrollView)?.reflectScrolledClipView(clip)
        }
        needsLayout = true
        onChange?()
    }

    // MARK: Live reload

    /// Agents edit files while you review: reload the diff when the tree changes.
    func watchWorkingTree() {
        treeWatcher?.stop()
        treeWatcher = TreeWatcher(root: repoPath) { [weak self] in self?.treeChanged() }
        treeWatcher?.start()
    }

    private func treeChanged() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(reloadFromDisk), object: nil)
        perform(#selector(reloadFromDisk), with: nil, afterDelay: 0.1)
    }

    /// Load and diff off the main thread, then merge into what's on screen.
    @objc private func reloadFromDisk() {
        guard !reloading else { reloadAgain = true; return }
        reloading = true
        let repo = repoPath, rev = baseRev
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let diffs = try? loadReview(repoRoot: repo, baseRev: rev)
            DispatchQueue.main.async {
                guard let self else { return }
                self.reloading = false
                if let diffs { self.merge(diffs.map(ReviewFile.init)) }
                if self.reloadAgain { self.reloadAgain = false; self.reloadFromDisk() }
            }
        }
    }

    /// Swap in freshly loaded files, keeping per-file UI state, open editors
    /// (unsaved edits always win), comments, and the scroll position.
    private func merge(_ newFiles: [ReviewFile]) {
        let v = viewport
        let anchorPath = files.isEmpty ? nil : files[index(at: v.minY)].path
        let anchorOffset = anchorPath.flatMap { p in indexByPath[p].map { v.minY - tops[$0] } } ?? 0

        var newIndex: [String: Int] = [:]
        for (i, f) in newFiles.enumerated() { newIndex[f.path] = i }
        for f in newFiles {
            guard let old = indexByPath[f.path].map({ files[$0] }) else { applyViewed(f); f.collapsed = f.viewed; continue }
            f.collapsed = old.collapsed
            f.expanded = old.expanded
            f.composer = old.composer
            f.replyingTo = old.replyingTo
            applyViewed(f)
            if old.viewed, !f.viewed { f.collapsed = false } // changed since you viewed it: show it again
        }

        var kept: [Int: DiffEditor] = [:]
        for (oldI, editor) in editors {
            let path = files[oldI].path
            guard let ni = newIndex[path] else {
                if !editor.isDirty { editor.host.removeFromSuperview() }
                continue
            }
            let fresh = newFiles[ni]
            if editor.text == fresh.newText as String {
                kept[ni] = editor // e.g. our own save: nothing to do
            } else if editor.isDirty {
                fresh.update(text: editor.text, hunks: editor.hunks) // your unsaved edits win on screen
                fresh.changedOnDisk = true
                kept[ni] = editor
            } else {
                editor.host.removeFromSuperview() // clean: show the new content
            }
        }

        files = newFiles
        indexByPath = newIndex
        recomputeTops()
        editors = kept
        reloadThreads() // re-locate comments in the new text; recomputes tops
        if let clip = superview as? NSClipView, let p = anchorPath, let i = indexByPath[p] {
            setFrameSize(NSSize(width: width, height: contentHeight(clip.bounds.height)))
            clip.scroll(to: NSPoint(x: 0, y: max(0, min(tops[i] + anchorOffset, frame.height - clip.bounds.height))))
            (clip.superview as? NSScrollView)?.reflectScrolledClipView(clip)
        }
        needsLayout = true
        canvas.needsDisplay = true
        onFilesReplaced?(files)
    }

    // MARK: Comments

    private static func gitUserName(_ repo: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git", "-C", repo, "config", "user.name"]
        let out = Pipe()
        p.standardOutput = out
        try? p.run()
        p.waitUntilExit()
        let name = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return name?.isEmpty == false ? name : nil
    }

    /// Re-read comments.json (ours or an agent's changes) and place every thread.
    func reloadThreads() {
        allThreads = (try? loadThreads(repoRoot: repoPath)) ?? []
        pendingCount = Int((try? pairprogram.pendingCount(repoRoot: repoPath, author: author)) ?? 0)
        let byPath = Dictionary(grouping: allThreads, by: \.path)
        for (i, file) in files.enumerated() {
            let mine = byPath[file.path] ?? []
            if mine.isEmpty, file.threads.isEmpty { continue }
            file.threads = mine.isEmpty ? [] : locateThreads(threads: mine, path: file.path, text: file.newText as String, oldText: file.oldText)
            if let r = file.replyingTo, !mine.contains(where: { $0.id == r }) { file.replyingTo = nil }
            editors[i]?.setReveal(expanded: file.revealed, commentSpace: file.commentSpace, deletedCommentSpace: file.deletedCommentSpace)
        }
        layoutChanged()
    }

    private func relocateThreads(_ i: Int) {
        let file = files[i]
        guard !file.threads.isEmpty else { return }
        file.threads = locateThreads(threads: file.threads.map(\.thread), path: file.path, text: file.newText as String, oldText: file.oldText)
    }

    /// Agents change comments through the CLI; pick that up live.
    private func watchComments() {
        commentsWatcher?.cancel()
        guard let path = try? commentsPath(repoRoot: repoPath) else { return }
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let fd = open(dir, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(self.commentsChangedOnDisk), object: nil)
            self.perform(#selector(self.commentsChangedOnDisk), with: nil, afterDelay: 0.05)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        commentsWatcher = source
    }

    @objc private func commentsChangedOnDisk() { reloadThreads() }

    /// Heights changed (comments added/removed, box opened): re-stack files.
    private func layoutChanged() {
        recomputeTops()
        needsLayout = true
        canvas.needsDisplay = true
        onChange?()
    }

    func startComment(_ i: Int, _ target: CommentTarget) {
        let file = files[i]
        guard !file.collapsed, target.old || target.line < file.lineCount else { return }
        for (j, f) in files.enumerated() where f.composer != nil && j != i { f.composer = nil; syncEditor(j) }
        file.composer = target
        syncEditor(i)
        layoutChanged()
        layoutSubtreeIfNeeded()
        (commentViews["c:" + file.path] as? CommentComposerView)?.input.focus()
    }

    private func syncEditor(_ i: Int) {
        editors[i]?.setReveal(expanded: files[i].revealed, commentSpace: files[i].commentSpace, deletedCommentSpace: files[i].deletedCommentSpace)
    }

    private func submitComment(_ i: Int, _ body: String, pending: Bool) {
        let file = files[i]
        guard let target = file.composer else { return }
        do {
            _ = try addThread(repoRoot: repoPath, path: file.path, text: target.old ? file.oldText : file.newText as String,
                              line: UInt32(target.line), oldSide: target.old, author: author, body: body, pending: pending)
            file.composer = nil
            reloadThreads()
        } catch { NSSound.beep() }
    }

    private func cancelComment(_ i: Int) {
        files[i].composer = nil
        syncEditor(i)
        layoutChanged()
    }

    private func threadAction(_ i: Int, _ action: () throws -> Void) {
        do { try action() } catch { NSSound.beep() }
        reloadThreads()
        syncEditor(i)
    }

    /// Create, place and drop comment boxes for files near the viewport.
    private func updateCommentViews() {
        let v = viewport
        let band = v.insetBy(dx: 0, dy: -v.height)
        var seen = Set<String>()
        guard !files.isEmpty else { return }
        let x = DiffStyle.gutterWidth + 5
        var i = index(at: max(0, band.minY))
        while i < files.count, tops[i] < band.maxY {
            let file = files[i]
            if file.threads.isEmpty && file.composer == nil { i += 1; continue }
            for row in file.layout.rows {
                let frame = NSRect(x: x, y: tops[i] + row.y + CommentMetrics.margin,
                                   width: CommentMetrics.boxWidth, height: row.height - 2 * CommentMetrics.margin)
                switch row.kind {
                case let .thread(id):
                    guard let located = file.threads.first(where: { $0.thread.id == id }) else { continue }
                    let key = "t:" + id
                    seen.insert(key)
                    let replying = file.replyingTo == id
                    let editing = file.editingEntry?.id == id ? file.editingEntry?.index : nil
                    let view = (commentViews[key] as? CommentThreadView) ?? makeThreadView(located, file: i, key: key)
                    view.inReview = pendingCount > 0
                    if view.located != located || view.replying != replying || view.editing != editing {
                        view.update(located, replying: replying, editing: editing)
                        if editing != nil { view.editInput?.focus() }
                    }
                    view.frame = frame
                case .composer:
                    let key = "c:" + file.path
                    seen.insert(key)
                    let view = (commentViews[key] as? CommentComposerView) ?? makeComposer(i, key: key)
                    view.frame = frame
                default:
                    continue
                }
            }
            i += 1
        }
        for (key, view) in commentViews where !seen.contains(key) {
            view.removeFromSuperview()
            commentViews[key] = nil
        }
    }

    private func makeThreadView(_ located: LocatedThread, file i: Int, key: String) -> CommentThreadView {
        let view = CommentThreadView(located, replying: files[i].replyingTo == located.thread.id, editing: nil, me: author)
        view.inReview = pendingCount > 0
        let id = located.thread.id
        let path = files[i].path
        view.onStartEdit = { [weak self] k in
            self?.withFile(path) { i in
                guard let self else { return }
                self.files[i].editingEntry = (id, k)
                self.syncEditor(i)
                self.layoutChanged()
            }
        }
        view.onCancelEdit = { [weak self] in
            self?.withFile(path) { i in
                guard let self else { return }
                self.files[i].editingEntry = nil
                self.syncEditor(i)
                self.layoutChanged()
            }
        }
        view.onSaveEdit = { [weak self] k, text in
            self?.withFile(path) { i in
                guard let self else { return }
                self.files[i].editingEntry = nil
                self.threadAction(i) { _ = try editEntry(repoRoot: self.repoPath, id: id, index: UInt32(k), body: text) }
            }
        }
        view.onStartReply = { [weak self] in
            self?.withFile(path) { i in
                guard let self else { return }
                self.files[i].replyingTo = id
                self.syncEditor(i)
                self.layoutChanged()
                self.layoutSubtreeIfNeeded()
                (self.commentViews[key] as? CommentThreadView)?.replyInput?.focus()
            }
        }
        view.onCancelReply = { [weak self] in
            self?.withFile(path) { i in
                guard let self else { return }
                self.files[i].replyingTo = nil
                self.syncEditor(i)
                self.layoutChanged()
            }
        }
        view.onReply = { [weak self] text, pending in
            self?.withFile(path) { i in
                guard let self else { return }
                self.files[i].replyingTo = nil
                self.threadAction(i) { _ = try reply(repoRoot: self.repoPath, id: id, author: self.author, body: text, pending: pending) }
            }
        }
        view.onToggleResolved = { [weak self] in
            self?.withFile(path) { i in
                guard let self, let t = self.files[i].threads.first(where: { $0.thread.id == id }) else { return }
                self.threadAction(i) {
                    _ = try setResolved(repoRoot: self.repoPath, id: id, resolved: t.thread.status == .open, author: self.author, note: nil)
                }
            }
        }
        view.onDelete = { [weak self] in
            self?.withFile(path) { i in
                guard let self else { return }
                self.threadAction(i) { try deleteThread(repoRoot: self.repoPath, id: id) }
            }
        }
        addSubview(view, positioned: .below, relativeTo: hover) // above canvas and editors
        commentViews[key] = view
        return view
    }

    private func makeComposer(_ i: Int, key: String) -> CommentComposerView {
        let view = CommentComposerView()
        let path = files[i].path
        let inReview = pendingCount > 0
        // GitHub-style: comment now, or hold it in a review you submit later.
        view.input.setActions(primary: inReview ? "Add to review" : "Comment", secondary: inReview ? "Comment now" : "Start a review")
        view.input.onSubmit = { [weak self] text in self?.withFile(path) { self?.submitComment($0, text, pending: inReview) } }
        view.input.onSecondary = { [weak self] text in self?.withFile(path) { self?.submitComment($0, text, pending: !inReview) } }
        view.input.onCancel = { [weak self] in self?.withFile(path) { self?.cancelComment($0) } }
        addSubview(view, positioned: .below, relativeTo: hover)
        commentViews[key] = view
        return view
    }

    func threadView(_ id: String) -> CommentThreadView? { commentViews["t:" + id] as? CommentThreadView }

    func composerView(_ i: Int) -> CommentComposerView? { commentViews["c:" + files[i].path] as? CommentComposerView }

    func setShowResolved(_ show: Bool) {
        ReviewFile.showResolved = show
        files.forEach { $0.invalidateLayout() }
        for i in editors.keys { syncEditor(i) }
        layoutChanged()
    }

    // MARK: Saving

    func saveAll() {
        for (i, editor) in editors where editor.isDirty {
            let url = URL(fileURLWithPath: repoPath).appendingPathComponent(files[i].path)
            do {
                try editor.text.write(to: url, atomically: true, encoding: .utf8)
                editor.markSaved()
                files[i].changedOnDisk = false
                onFileChanged?(i)
            } catch {
                NSSound.beep()
            }
        }
        canvas.needsDisplay = true
    }
}
