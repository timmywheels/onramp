import AppKit

/// One window (or tab) reviewing one project: its review, file tree,
/// toolbar and comments panel. ⌘T opens another as a tab.
@MainActor
final class ProjectWindowController: NSWindowController, NSWindowDelegate {
    private(set) var repoPath: String
    private var reviewView: ReviewView!
    private var sidebar: FileTreeSidebar!
    private var toolbar: SourceToolbar!
    private var commentsPanel = CommentsPanel()
    private var commentsItem: NSSplitViewItem?
    private var contextWindow: ContextWindowController?
    private var sidebarController: SidebarController?
    private var prList: PullRequestList?
    var onClose: ((ProjectWindowController) -> Void)?

    var review: ReviewView { reviewView }
    var sourceToolbar: SourceToolbar { toolbar }
    var commentsVisible: Bool { commentsItem?.isCollapsed == false }

    init(repoPath: String, first: Bool) {
        self.repoPath = repoPath
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.tabbingIdentifier = "onramp" // projects open as tabs of one window
        window.tabbingMode = .preferred
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        build(first: first)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build(first: Bool) {
        guard let window else { return }
        toolbar = SourceToolbar(repoPath: repoPath)
        toolbar.onOpenRepo = { [weak self] path in self?.open(repo: path) }
        toolbar.onToggleComments = { [weak self] in self?.toggleComments(nil) }
        toolbar.onToggleFiles = { [weak self] in (self?.window?.contentViewController as? NSSplitViewController)?.toggleSidebar(nil) }
        toolbar.onOpenContext = { [weak self] in self?.openContext(nil) }
        toolbar.onOpenPullRequest = { [weak self] in self?.openPullRequest(nil) }
        toolbar.onViewPullRequest = { [weak self] n in
            guard let self else { return }
            (NSApp.delegate as? AppDelegate)?.viewPullRequest(n, repo: self.repoPath) { _ in }
        }
        toolbar.setContextCount(ContextWindowController.enabledCount(repo: repoPath))
        toolbar.install(in: window)
        RecentProjects.add(repoPath)

        reviewView = ReviewView(repoPath: repoPath)
        toolbar.review = reviewView
        reviewView.onBaseChanged = { [weak self] _ in self?.baseChanged() }
        reviewView.onBrowsePullRequests = { [weak self] in self?.openPullRequest(nil) }
        sidebar = FileTreeSidebar()
        wireSidebar()
        // A content view controller resizes the window to its fitting size (tiny, since
        // the review has no intrinsic size), so size it after, then restore any saved frame.
        window.contentViewController = makeSplit()
        window.contentMinSize = NSSize(width: 700, height: 400)
        window.setContentSize(NSSize(width: 1300, height: 850))
        window.center()
        if first {
            window.setFrameAutosaveName("onramp.window")
            if UserDefaults.standard.object(forKey: "NSSplitView Subview Frames onramp.split.v2") == nil,
               let split = window.contentViewController as? NSSplitViewController {
                // First launch: files 260, right panel 340; afterwards the saved widths win.
                split.splitView.setPosition(260, ofDividerAt: 0)
                split.splitView.setPosition(split.splitView.bounds.width - 340, ofDividerAt: 1)
            }
        }
        updateTitle()
    }

    func start() { reviewView.reload() }

    /// The tab's label: "hexyl · PR #149", "servicepro · feat/x".
    private func updateTitle() {
        let name = (repoPath as NSString).lastPathComponent
        var detail: String?
        switch reviewView.base?.mode {
        case .pullRequest?: detail = reviewView.base?.title
        case .commit?: detail = reviewView.base?.title.map { "commit " + ($0.split(separator: " ").first.map(String.init) ?? $0) }
        default: detail = (try? listWorktrees(repoRoot: repoPath))?.first { $0.isCurrent }?.branch
        }
        window?.title = detail.map { "\(name) · \($0)" } ?? name
    }

    private func baseChanged() {
        toolbar.refreshTitles()
        updateTitle()
        let choice = reviewView.choice
        prList?.current = choice.mode == .pullRequest ? choice.pr.map(Int.init) : nil
    }

    /// The front tab's review is the repo's review (agents and the CLI read it).
    func windowDidBecomeKey(_ notification: Notification) { reviewView?.publishChoice() }

    /// Showing this PR already?
    func isShowing(pr n: Int) -> Bool { reviewView.choice.mode == .pullRequest && reviewView.choice.pr.map(Int.init) == n }

    func windowWillClose(_ notification: Notification) {
        reviewView.close()
        contextWindow?.close()
        onClose?(self)
    }

    /// Show another project or worktree in this window.
    func open(repo path: String) {
        guard path != repoPath else { return }
        guard reviewView.document.dirtyCount == 0 else { return NSSound.beep() } // save first (⌘S)
        reviewView.close()
        repoPath = path
        RecentProjects.add(path)
        reviewView = ReviewView(repoPath: path)
        reviewView.onBaseChanged = { [weak self] _ in self?.baseChanged() }
        reviewView.onBrowsePullRequests = { [weak self] in self?.openPullRequest(nil) }
        sidebar = FileTreeSidebar()
        wireSidebar()
        guard let window else { return }
        let frame = window.frame // a new content view controller resizes the window to fit
        window.contentViewController = makeSplit()
        window.setFrame(frame, display: true)
        toolbar.repoPath = path
        toolbar.review = reviewView
        contextWindow?.close()
        contextWindow = nil // per repo
        toolbar.setContextCount(ContextWindowController.enabledCount(repo: path))
        reviewView.reload()
    }

    @objc func openFolder(_ sender: Any?) { toolbar.openFolder(sender) }

    private func makeSplit() -> NSSplitViewController {
        let split = NSSplitViewController()
        let side = NSSplitViewItem(sidebarWithViewController: sidebar)
        side.minimumThickness = 200
        side.maximumThickness = 360
        side.holdingPriority = .init(260) // the diff grows first when the window does
        side.canCollapse = true
        let content = NSViewController()
        content.view = reviewView
        split.addSplitViewItem(side)
        split.addSplitViewItem(NSSplitViewItem(viewController: content))
        commentsPanel = CommentsPanel()
        wireComments()
        let prs = PullRequestList(repo: repoPath)
        prs.onView = { [weak self] n, done in
            guard let self else { return }
            (NSApp.delegate as? AppDelegate)?.viewPullRequest(n, repo: self.repoPath, done: done) // its own tab
        }
        prList = prs
        let right = SidebarController(comments: commentsPanel, pullRequests: prs)
        sidebarController = right
        let comments = NSSplitViewItem(inspectorWithViewController: right)
        comments.minimumThickness = 280
        comments.maximumThickness = 460
        comments.holdingPriority = .init(260)
        comments.canCollapse = true
        comments.isCollapsed = UserDefaults.standard.bool(forKey: "onramp.commentsHidden")
        split.addSplitViewItem(comments)
        commentsItem = comments
        split.splitView.autosaveName = "onramp.split.v2" // three panes now; older saved widths don't apply
        return split
    }

    private func wireComments() {
        commentsPanel.onSelect = { [weak self] t in self?.reviewView.document.scrollToThread(t) }
        reviewView.document.onThreadsChanged = { [weak self] in
            guard let self else { return }
            let items = self.reviewView.document.panelItems
            self.commentsPanel.update(items)
            self.toolbar.setCommentCount(items.filter { $0.status != .resolved }.count)
        }
    }

    /// ⇧⌘P: the Pull Requests sidebar, search focused.
    @objc func openPullRequest(_ sender: Any?) {
        showRight(.pullRequests)
        prList?.focusSearch()
    }

    @objc func showComments(_ sender: Any?) { showRight(.comments) }
    @objc func showPullRequests(_ sender: Any?) { showRight(.pullRequests) }

    /// Open the right-hand panel on a tab.
    private func showRight(_ tab: SidebarController.Tab) {
        if commentsItem?.isCollapsed == true {
            commentsItem?.animator().isCollapsed = false
            UserDefaults.standard.set(false, forKey: "onramp.commentsHidden")
        }
        sidebarController?.show(tab)
    }

    @objc func openContext(_ sender: Any?) {
        if contextWindow == nil {
            let c = ContextWindowController(repo: repoPath)
            c.onChange = { [weak self] n in self?.toolbar.setContextCount(n) }
            contextWindow = c
        }
        contextWindow?.showWindow(nil)
        contextWindow?.window?.center()
    }

    @objc func toggleComments(_ sender: Any?) {
        guard let item = commentsItem else { return }
        item.animator().isCollapsed.toggle()
        UserDefaults.standard.set(item.isCollapsed, forKey: "onramp.commentsHidden")
    }

    private func wireSidebar() {
        sidebar.isDirty = { [weak self] i in self?.reviewView.document.editor(i)?.isDirty ?? false }
        sidebar.onSelectFile = { [weak self] i in self?.reviewView.document.scrollToFile(i) }
        reviewView.onLoad = { [weak self] files in self?.sidebar.setFiles(files) }
        reviewView.onFileChanged = { [weak self] i in self?.sidebar.refresh(i) }
        reviewView.onCurrentFile = { [weak self] i in self?.sidebar.reveal(i) }
    }

    // MARK: Menu actions (forwarded by AppDelegate for the front tab)

    @objc func saveDocument(_ sender: Any?) { reviewView.saveAll() }

    @objc func reloadReview(_ sender: Any?) {
        let choice = reviewView.choice
        reviewView.syncCI(force: true)
        if choice.mode == .pullRequest, let n = choice.pr { return reviewView.openPullRequest(Int(n)) } // re-fetch: new commits
        reviewView.reload()
    }

    @objc func collapseAll(_ sender: Any?) { reviewView.document.setAllCollapsed(true) }
    @objc func expandAll(_ sender: Any?) { reviewView.document.setAllCollapsed(false) }
    @objc func toggleResolved(_ sender: Any?) { reviewView.document.setShowResolved(!ReviewFile.showResolved) }
}
