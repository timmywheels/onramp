import AppKit

/// The endless scroll: every changed file in one scroll view.
final class ReviewView: NSView, NSPopoverDelegate {
    let repoPath: String
    let scrollView = NSScrollView()
    let document: ReviewDocumentView
    private let statusBar = StatusBarView()
    /// Title, author and description while reviewing a pull request.
    private let prBar = PullRequestBar()
    private let statusLabel = NSTextField(labelWithString: "")
    private let progress = ProgressBarView()
    private let foldAllButton = NSButton()
    private let progressLabel = NSTextField(labelWithString: "")
    private let agentButton = AgentButton()
    private let reviewButton = CapsuleButton()
    /// "Follow" while an agent works: keep its edits in view (Zed-style).
    private let followButton = CapsuleButton()
    private var scrollMonitor: Any?
    /// Commit / push your branch (working-tree views only).
    private let gitButton = CapsuleButton()
    /// "Update to 0.3.0" when a newer release is out (installed app only).
    private let updateButton = CapsuleButton()
    private var gitStatus: BranchStatus?
    private var gitPopover: NSPopover?
    /// Agents with onramp set up (from each agent's CLI; checked in the background).
    private var configuredAgents: [String] = []
    private var agentChecks = 0
    /// What's being reviewed (see `reviewBase`); chosen in the toolbar's Changes menu.
    private(set) var base: ReviewBase?
    /// This tab's choice (branch / uncommitted / commit / PR). Tabs on one repo can
    /// differ; the front tab's is saved to the repo so agents and the CLI see it.
    private(set) lazy var choice: ReviewChoice = reviewChoice(repoRoot: repoPath)

    /// Save this tab's choice as the repo's (when it's the one in front).
    func publishChoice() { try? setReviewChoice(repoRoot: repoPath, choice: choice) }
    /// Called after every reload, so the toolbar can show what's loaded.
    var onBaseChanged: ((ReviewBase?) -> Void)?
    private var statusParts: [(priority: Int, text: NSAttributedString)] = []
    /// One background agent run per target (Claude Code and Codex can work side by side).
    private var runners: [AgentRunner.Target: AgentRunner] = [:]
    private var nextWaiting = 0
    private var runStates: [(AgentRunner.Target, AgentRunner.State)] {
        runners.sorted { $0.key.rawValue < $1.key.rawValue }.map { ($0.key, $0.value.state) }
    }
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
        prBar.isHidden = true
        prBar.onToggle = { [weak self] in self?.needsLayout = true }
        addSubview(prBar)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.cell?.truncatesLastVisibleLine = true
        progressLabel.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
        progressLabel.textColor = .secondaryLabelColor
        progress.toolTip = "Files marked Viewed"
        agentButton.target = self
        agentButton.action = #selector(agentButtonClicked)
        followButton.setText("Follow")
        followButton.target = self
        followButton.action = #selector(toggleFollow)
        followButton.toolTip = "Follow the agent: jump to what it's editing as it goes (⌥⌘F). Scroll to stop."
        followButton.isHidden = true
        document.onFollowChanged = { [weak self] _ in self?.updateFollowButton() }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            // You scrolled: you're driving now.
            if let self, self.document.following, event.window === self.window,
               self.scrollView.frame.contains(self.convert(event.locationInWindow, from: nil)) { self.document.following = false }
            return event
        }
        reviewButton.setText("Review changes")
        reviewButton.target = self
        reviewButton.action = #selector(showReview)
        foldAllButton.isBordered = false
        foldAllButton.imagePosition = .imageOnly
        foldAllButton.target = self
        foldAllButton.action = #selector(toggleFoldAll)
        updateButton.target = self
        updateButton.action = #selector(updateClicked)
        updateButton.isHidden = true
        NotificationCenter.default.addObserver(self, selector: #selector(updaterChanged), name: .updaterChanged, object: nil)
        gitButton.target = self
        gitButton.action = #selector(gitClicked)
        gitButton.isHidden = true
        prBar.onMerge = { [weak self] in self?.showMerge() }
        for v in [foldAllButton, progress, progressLabel, statusLabel, updateButton, gitButton, reviewButton, followButton, agentButton] as [NSView] { statusBar.addSubview(v) }
        // Agents come and go (sessions start/end); poll cheaply.
        agentTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.updateAgents()
                self.agentChecks += 1
                if self.agentChecks % 30 == 0 { self.refreshConfiguredAgents() } // once a minute
                if self.agentChecks % 5 == 0 { self.refreshGit() } // every 10 s (commits made elsewhere)
            }
        }
        refreshConfiguredAgents()

        document.onChange = { [weak self] in self?.updateStatus(); self?.updateAgents(); self?.refreshGit() }
        document.onFileChanged = { [weak self] i in self?.onFileChanged?(i) }
        document.onCurrentFile = { [weak self] i in self?.onCurrentFile?(i) }
        document.onNotice = { [weak self] text in
            guard let window = self?.window else { return }
            let alert = NSAlert()
            alert.messageText = text
            alert.beginSheetModal(for: window)
        }
        QuickSend.onChange = { [weak self] in self?.updateAgents() }
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
        let barHeight = prBar.isHidden ? 0 : prBar.height(max: (bounds.height - h) * 0.45)
        prBar.frame = NSRect(x: 0, y: bounds.height - barHeight, width: bounds.width, height: barHeight)
        scrollView.frame = NSRect(x: 0, y: h, width: bounds.width, height: bounds.height - h - barHeight)
        loadingView?.frame = scrollView.frame
        emptyView?.frame = scrollView.frame
        document.width = scrollView.contentSize.width
        DiffStyle.paintWidth = document.width

        // Everything centered on the bar's midline; 12pt between groups.
        func center(_ v: NSView, x: CGFloat) {
            v.frame.origin = NSPoint(x: x, y: round((h - v.frame.height) / 2) + 0.5)
        }
        var right = bounds.width - 8 // 8pt all around: the capsule follows the window's corner
        for v in [agentButton, followButton, reviewButton, gitButton, updateButton] where !v.isHidden {
            v.fit()
            right -= v.frame.width
            v.frame.origin = NSPoint(x: right, y: round((h - v.frame.height) / 2))
            right -= 8
        }
        right -= 4
        var left: CGFloat = 10
        foldAllButton.frame = NSRect(x: left, y: round((h - 22) / 2), width: 22, height: 22)
        left = foldAllButton.frame.maxX + 8
        progressLabel.sizeToFit()
        // Narrow window: the right-hand buttons win; progress goes before it would overlap.
        let fitsProgress = left + 72 + 8 + progressLabel.frame.width + 12 <= right
        progress.isHidden = !fitsProgress
        progressLabel.isHidden = !fitsProgress
        if fitsProgress {
            progress.frame = NSRect(x: left, y: round((h - 6) / 2), width: 72, height: 6)
            left = progress.frame.maxX + 8
            center(progressLabel, x: left)
            left = progressLabel.frame.maxX + 18
        }
        statusLabel.attributedStringValue = fittedStatus(width: right - 6 - left)
        statusLabel.sizeToFit()
        statusLabel.frame.size.width = max(0, min(statusLabel.frame.width, right - 6 - left))
        statusLabel.isHidden = statusLabel.frame.width < 40
        center(statusLabel, x: left)
    }

    func reload() {
        let start = CACurrentMediaTime()
        do {
            publishChoice() // the core reads the repo's saved choice
            let base = try reviewBase(repoRoot: repoPath)
            self.base = base
            document.baseRev = base.rev
            document.readOnly = base.target != nil // a commit or PR isn't on disk: nothing to edit
            let pr = base.mode == .pullRequest ? choice.pr.flatMap { GitHub.cached(repo: repoPath, number: Int($0)) } : nil
            prBar.set(pr)
            prBar.isHidden = pr == nil
            needsLayout = true
            document.setFiles(TreeOrder.sorted(try loadReview(repoRoot: repoPath, baseRev: base.rev, target: base.target).map(ReviewFile.init)))
            onBaseChanged?(base)
            refreshGit()
            refreshMerge()
            syncCI()
        } catch {
            statusLabel.stringValue = "Error: \(error)"
            return
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
        loadMs = (CACurrentMediaTime() - start) * 1000
        onLoad?(document.files)
        updateAgents()
        document.onFilesReplaced = { [weak self] files in self?.onLoad?(files); self?.updateStatus(); self?.updateEmpty() }
        updateEmpty()
        document.watchWorkingTree()
        updateStatus()
        SelfTest.run(review: self)
        Demo.run(review: self)
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
            (0, part([("+\(added)", DiffStyle.addedAccent, digits), (" −\(removed)", DiffStyle.deletedAccent, digits)])),
        ]
        switch base?.mode {
        case .branch?:
            parts.append((2, part([(base?.branch.map { "vs \($0)" } ?? "vs HEAD (no main branch found)", .secondaryLabelColor, font)])))
            if let n = base?.commits, n > 0 { parts.append((4, part([("\(n) commit\(n == 1 ? "" : "s")", .secondaryLabelColor, font)]))) }
        case .commit?:
            parts.append((2, part([("one commit · read-only", .secondaryLabelColor, font)])))
        case .pullRequest?:
            parts.append((2, part([("pull request vs \(base?.branch ?? "base") · read-only", .secondaryLabelColor, font)])))
            if let n = base?.commits, n > 0 { parts.append((4, part([("\(n) commit\(n == 1 ? "" : "s")", .secondaryLabelColor, font)]))) }
        default:
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

    func clickAgentForTests() { agentButtonClicked() }
    var gitButtonTitleForTests: String { gitButton.attributedTitle.string }
    var gitButtonHiddenForTests: Bool { gitButton.isHidden }
    func showCommitForTests() { showCommit() }
    func showMergeForTests() {
        mergeInfo = GitHub.MergeInfo(author: "timmywheels", isMine: true, state: "OPEN", isDraft: false, mergeable: "MERGEABLE", mergeState: "CLEAN",
                                     review: .approved, checks: .passing, methods: [.squash, .merge, .rebase], deleteBranchDefault: true)
        choice.pr = 7
        prBar.set(GitHub.PR(number: 7, title: "Partial payments", body: "", author: "timmywheels", headRefName: "feat/partial-payments", baseRefName: "main",
                            url: "https://github.com", state: "OPEN", isDraft: false, additions: 126, deletions: 26, changedFiles: 13, labels: []))
        prBar.isHidden = false
        prBar.showMerge(true)
        needsLayout = true
        layoutSubtreeIfNeeded()
        showMerge()
    }
    func expandPullRequestBarForTests() { if !prBar.expanded { prBar.mouseDown(with: NSEvent.mouseEvent(with: .leftMouseDown, location: prBar.convert(NSPoint(x: 20, y: 10), to: nil), modifierFlags: [], timestamp: 0, windowNumber: window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!) } }
    var agentLabelForTests: String { agentButton.attributedTitle.string.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\u{2007}"))) + " [" + (agentButton.toolTip ?? "") + "]" }

    func setMode(_ mode: ReviewMode) {
        choice.mode = mode
        reload()
    }

    /// Fetch a pull request (read-only) and review it. `done` gets an error to show, or nil.
    @objc func toggleFollow() { document.following.toggle(); followSawWork = false }
    private var followSawWork = false

    /// Shown while an agent works (or while you're following); lit while following.
    private func updateFollowButton() {
        let working = agentButton.isWorking
        let show = working || document.following
        if followButton.isHidden == show { followButton.isHidden = !show; needsLayout = true }
        let title = document.following ? "Following" : "Follow"
        if followButton.title != title { followButton.setText(title); needsLayout = true }
        followButton.contentTintColor = document.following ? DiffStyle.accent : nil
        followButton.image = NSImage(systemSymbolName: document.following ? "eye.fill" : "eye", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
        // Stop following once the work you were watching is done (not before any has started).
        if working || QuickSend.anyRunning { followSawWork = true }
        else if document.following, followSawWork { followSawWork = false; document.following = false }
    }

    /// Browse Pull Requests, from the empty state (the window opens the sidebar).
    var onBrowsePullRequests: (() -> Void)?
    private var emptyView: EmptyReviewView?

    /// Nothing changed: say so, and point at pull requests.
    private func updateEmpty() {
        let empty = document.files.isEmpty && loadingView == nil
        if empty, emptyView == nil {
            let v = EmptyReviewView()
            v.onBrowse = { [weak self] in self?.onBrowsePullRequests?() }
            v.frame = scrollView.frame
            addSubview(v, positioned: .above, relativeTo: scrollView)
            emptyView = v
        } else if !empty {
            emptyView?.removeFromSuperview()
            emptyView = nil
        }
        emptyView?.set(comparing: base.map { b in
            switch b.mode {
            case .branch: b.branch
            case .uncommitted: "your last commit"
            default: nil
            }
        } ?? nil)
    }

    /// Over the diff while a PR is fetched and loaded: diff-shaped placeholders and what's happening.
    private var loadingView: SkeletonView?

    private func showLoading(_ caption: String) {
        if loadingView == nil {
            let v = SkeletonView(.diff)
            v.layer?.backgroundColor = DiffStyle.background.cgColor
            v.frame = scrollView.frame
            addSubview(v, positioned: .above, relativeTo: scrollView)
            loadingView = v
        }
        loadingView?.set(caption: caption)
    }

    private func hideLoading() {
        loadingView?.removeFromSuperview()
        loadingView = nil
        updateEmpty()
    }

    func openPullRequest(_ number: Int, done: @escaping (String?) -> Void = { _ in }) {
        guard document.dirtyCount == 0 else { return done("Save your edits first (⌘S).") }
        let repo = repoPath
        showLoading("Getting #\(number) from GitHub…")
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                try GitHub.fetch(repo: repo, number: number) { step in
                    DispatchQueue.main.async { [weak self] in self?.showLoading(step) }
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                switch result {
                case let .success(pr):
                    self.choice.mode = .pullRequest
                    self.choice.pr = UInt32(number)
                    self.choice.baseBranch = "origin/" + pr.baseRefName
                    self.showLoading("Building the diff…")
                    DispatchQueue.main.async { // let that caption draw before the (synchronous) load
                        self.reload()
                        self.hideLoading()
                        done(nil)
                    }
                case let .failure(e):
                    self.hideLoading()
                    self.updateStatus()
                    done(message(for: e))
                }
            }
        }
    }

    // MARK: Updates

    @objc private func updaterChanged() {
        let u = Updater.shared
        let show = u.state == .available || u.state == .downloading || u.state == .installing
        updateButton.isHidden = !show
        if show {
            let title = u.state == .available ? "Update to \(u.latest?.version ?? "")" : u.state == .downloading ? "Downloading…" : "Installing…"
            updateButton.setText(title)
            updateButton.contentTintColor = DiffStyle.accent
            updateButton.toolTip = "Onramp \(u.latest?.version ?? "") is available (you have \(u.currentVersion))"
        }
        needsLayout = true
    }

    @objc private func updateClicked() {
        guard Updater.shared.state == .available, let latest = Updater.shared.latest, let window else { return }
        let alert = NSAlert()
        alert.messageText = "Install Onramp \(latest.version) and relaunch?"
        alert.informativeText = "You have \(Updater.shared.currentVersion). It takes a few seconds."
        alert.addButton(withTitle: "Install and Relaunch")
        alert.addButton(withTitle: "Release Notes")
        alert.addButton(withTitle: "Later")
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                if response == .alertFirstButtonReturn { Task { await Updater.shared.confirmedInstall() } }
                if response == .alertSecondButtonReturn { NSWorkspace.shared.open(latest.pageURL) }
            }
        }
    }

    // MARK: CI failures as threads

    private var ciSyncedAt: [String: Date] = [:]

    /// The commit whose CI we mirror: the PR's head, or your branch as pushed.
    private func ciCommit() -> String? {
        if base?.mode == .pullRequest { return base?.target }
        if base?.mode == .commit { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git", "-C", repoPath, "rev-parse", "--verify", "-q", "@{u}"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        let sha = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return p.terminationStatus == 0 && !sha.isEmpty ? sha : nil
    }

    /// Mirror failing CI annotations as review threads (at most once a minute per commit; `force` on ⌘R).
    func syncCI(force: Bool = false) {
        guard Style.shared.settings.ciComments, let sha = ciCommit() else { return }
        if !force, let last = ciSyncedAt[sha], Date().timeIntervalSince(last) < 60 { return }
        ciSyncedAt[sha] = Date()
        let repo = repoPath
        DispatchQueue.global(qos: .utility).async {
            guard let (findings, complete) = try? GitHub.ciFindings(repo: repo, sha: sha),
                  let sync = try? syncCiThreads(repoRoot: repo, findings: findings, complete: complete) else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, sync.added + sync.reopened + sync.resolved > 0 else { return }
                self.document.reloadThreads()
            }
        }
    }

    // MARK: Git (your branch) and merging (your PR)

    /// What the Git button shows: the next thing to do with your branch.
    func refreshGit() {
        guard !document.readOnly else { gitButton.isHidden = true; needsLayout = true; return }
        let repo = repoPath
        DispatchQueue.global(qos: .utility).async {
            let status = try? branchStatus(repoRoot: repo)
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.document.readOnly else { return }
                self.gitStatus = status
                guard let s = status, s.branch != nil else { self.gitButton.isHidden = true; self.needsLayout = true; return }
                let title = s.changed > 0 ? "Commit…" : s.upstream == nil ? "Publish Branch" : s.ahead > 0 ? "↑\(s.ahead) Push" : nil
                self.gitButton.isHidden = title == nil
                if let title, self.gitButton.title != title { self.gitButton.setText(title) }
                self.gitButton.toolTip = [s.branch.map { "On \($0)" }, s.upstream.map { "tracking \($0)" },
                                          s.ahead > 0 ? "\(s.ahead) to push" : nil, s.behind > 0 ? "\(s.behind) behind" : nil,
                                          s.changed > 0 ? "\(s.changed) changed files" : nil].compactMap { $0 }.joined(separator: " · ")
                self.needsLayout = true
            }
        }
    }

    @objc private func gitClicked() {
        guard let s = gitStatus else { return }
        let menu = NSMenu()
        func item(_ title: String, _ enabled: Bool, _ action: Selector) {
            let i = menu.addItem(withTitle: title, action: enabled ? action : nil, keyEquivalent: "")
            i.target = self
            i.isEnabled = enabled
        }
        item(s.changed > 0 ? "Commit \(s.changed) Changed File\(s.changed == 1 ? "" : "s")…" : "Nothing to Commit", s.changed > 0, #selector(showCommit))
        if s.upstream == nil {
            item("Publish \(s.branch ?? "Branch") to origin…", s.branch != nil, #selector(confirmPush))
        } else {
            item(s.ahead > 0 ? "Push \(s.ahead) Commit\(s.ahead == 1 ? "" : "s") to \(s.upstream!)…" : "Up to Date with \(s.upstream!)", s.ahead > 0, #selector(confirmPush))
        }
        if s.behind > 0 { item("\(s.behind) Commit\(s.behind == 1 ? "" : "s") Behind (pull in a terminal)", false, #selector(confirmPush)) }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: gitButton.bounds.height + 4), in: gitButton)
    }

    @objc private func showCommit() {
        guard let s = gitStatus else { return }
        let vc = CommitViewController(status: s)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = vc
        vc.onCommit = { [weak self, weak popover] message, push in
            guard let self else { return nil }
            do {
                let sha = try commitAll(repoRoot: self.repoPath, message: message)
                if push { _ = try pushBranch(repoRoot: self.repoPath) }
                popover?.close()
                self.statusLabel.stringValue = push ? "Committed \(sha) and pushed" : "Committed \(sha)"
                self.reload()
                return nil
            } catch {
                return onramp.message(for: error)
            }
        }
        gitPopover = popover
        popover.show(relativeTo: gitButton.bounds, of: gitButton, preferredEdge: .maxY)
    }

    /// Ask, then push (or publish) the branch. Never forces.
    @objc private func confirmPush() {
        guard let s = gitStatus, let branch = s.branch, let window else { return }
        let alert = NSAlert()
        if let up = s.upstream {
            alert.messageText = "Push \(s.ahead) commit\(s.ahead == 1 ? "" : "s") to \(up)?"
            alert.informativeText = "From your branch \(branch)."
        } else {
            alert.messageText = "Publish \(branch) to origin?"
            alert.informativeText = "Creates the branch on origin and pushes \(branch) to it."
        }
        alert.addButton(withTitle: s.upstream == nil ? "Publish" : "Push")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            MainActor.assumeIsolated { self.push() }
        }
    }

    private func push() {
        let repo = repoPath
        statusLabel.stringValue = "Pushing…"
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try pushBranch(repoRoot: repo) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                switch result {
                case let .success(branch): self.statusLabel.stringValue = "Pushed \(branch)"
                case let .failure(e):
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = "Push failed"
                    alert.informativeText = onramp.message(for: e)
                    if let w = self.window { alert.beginSheetModal(for: w) } else { alert.runModal() }
                    self.updateStatus()
                }
                self.refreshGit()
            }
        }
    }

    /// "Merge…" in the PR bar: only for your own open PR.
    private var mergeInfo: GitHub.MergeInfo?

    private func refreshMerge() {
        guard base?.mode == .pullRequest, let n = choice.pr.map(Int.init) else { prBar.showMerge(false); return }
        let repo = repoPath
        DispatchQueue.global(qos: .utility).async {
            let info = try? GitHub.mergeInfo(repo: repo, number: n)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.choice.pr.map(Int.init) == n else { return }
                self.mergeInfo = info
                self.prBar.showMerge(info.map { $0.isMine && $0.state == "OPEN" } ?? false)
            }
        }
    }

    private func showMerge() {
        guard let n = choice.pr.map(Int.init), let info = mergeInfo else { return }
        let vc = MergeViewController(number: n, info: info)
        let popover = NSPopover()
        popover.behavior = .semitransient
        popover.contentViewController = vc
        vc.onMerge = { [weak self, weak popover] method, delete, done in
            guard let self else { return }
            let repo = self.repoPath
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result { try GitHub.merge(repo: repo, number: n, method: method, deleteBranch: delete) }
                DispatchQueue.main.async {
                    switch result {
                    case .success:
                        popover?.close()
                        self.openPullRequest(n) // re-fetch: it's merged now
                        done(nil)
                    case let .failure(e): done(onramp.message(for: e))
                    }
                }
            }
        }
        gitPopover = popover
        popover.show(relativeTo: prBar.mergeButton.bounds, of: prBar.mergeButton, preferredEdge: .minY)
    }

    /// Show something else (from the toolbar's Changes menu).
    func setChoice(_ choice: ReviewChoice) {
        guard document.dirtyCount == 0 else { return NSSound.beep() } // save first: switching drops editors
        self.choice = choice
        reload()
    }

    /// Stop timers and file watchers before this view goes away (switching projects).
    func close() {
        agentTimer?.invalidate()
        agentTimer = nil
        document.stopWatching()
    }

    var statusText: String { statusLabel.stringValue }

    func saveAll() {
        document.saveAll()
        updateStatus()
    }

    /// The Agent button. Most urgent state wins: working (blue, pulsing) →
    /// needs you (yellow) → a run that ended (✓/✗) → connected (green) → none (grey).
    /// Review runs started from this tab that have ended: which agent, whether it succeeded, and when.
    var finishedRuns: [(agent: String, ok: Bool, at: Date)] {
        runners.values.compactMap { r in
            guard case let .finished(target, ok) = r.state, let at = r.finishedAt else { return nil }
            return (target.rawValue, ok, at)
        }
    }

    private func updateAgents() {
        let sessions = ConnectedAgents.sessions(repoRoot: repoPath)
        let live = Array(Set(sessions.map(\.agent))).sorted()
        let claims = document.activeClaims
        let working = Array(Set(sessions.filter(\.isWorking).map(\.agent) + claims.map(\.agent))).sorted()
        let waiting = document.awaitingYou.count
        let count = max(configuredAgents.count, live.count)

        var color = count > 0 ? DiffStyle.addedAccent : .tertiaryLabelColor
        var label = count > 1 ? "Agents (\(count))" : "Agent"
        var pulsing = false
        var tip = count == 0 ? "No agent connected. Click to connect one over MCP."
            : ["Set up: " + (configuredAgents.isEmpty ? "—" : configuredAgents.joined(separator: ", ")),
               "In a session now: " + (live.isEmpty ? "none" : live.joined(separator: ", "))].joined(separator: "\n")
        let running = runStates.filter { if case .running = $0.1 { return true } else { return false } }.map(\.0)
        let finished = runStates.compactMap { t, s -> (AgentRunner.Target, Bool)? in if case let .finished(_, ok) = s { return (t, ok) } else { return nil } }
        if !running.isEmpty {
            color = DiffStyle.accent; pulsing = true
            label = running.count == 1 ? "\(running[0].title) working…" : "\(running.count) agents working…"
            tip = running.map { "\($0.title) is working on your review" }.joined(separator: "\n")
        } else if !working.isEmpty {
            color = DiffStyle.accent; pulsing = true
            label = working.count == 1 ? "\(working[0]) working…" : "\(working.count) agents working…"
            tip = working.map { a in "\(a): \(claims.filter { $0.agent == a }.count) comment(s)" }.joined(separator: "\n")
        } else if waiting > 0 {
            color = .systemYellow
            label = waiting == 1 ? "1 reply for you" : "\(waiting) replies for you"
            tip = "An agent answered a comment instead of resolving it. Click to see."
        } else if !finished.isEmpty {
            let failed = finished.filter { !$0.1 }.map(\.0)
            color = failed.isEmpty ? DiffStyle.addedAccent : DiffStyle.deletedAccent
            label = failed.isEmpty ? (finished.count == 1 ? "Agent done" : "Agents done") : (failed.count == 1 ? "\(failed[0].title) failed" : "Agents failed")
            tip = finished.map { "\($0.0.title) \($0.1 ? "finished" : "failed")" }.joined(separator: "\n") + "\nClick for the log."
        }
        let pending = document.pendingCount
        let reviewTitle = pending > 0 ? "Finish review (\(pending))" : "Review changes"
        if reviewButton.title != reviewTitle { reviewButton.setText(reviewTitle); needsLayout = true }
        let key = "\(label)|\(color)|\(pulsing)"
        guard agentButton.identifier?.rawValue != key else { return }
        agentButton.identifier = NSUserInterfaceItemIdentifier(key)
        agentButton.set(label: label, color: color, pulsing: pulsing)
        updateFollowButton()
        agentButton.toolTip = tip
        needsLayout = true
    }

    @objc private func agentButtonClicked() {
        let busy = runStates.contains { if case .running = $0.1 { return true } else { return false } }
        let waiting = document.awaitingYou
        if !waiting.isEmpty, !busy { // yellow: go to the next reply waiting for you
            nextWaiting = nextWaiting % waiting.count
            document.scrollToThread(waiting[nextWaiting])
            nextWaiting += 1
            return
        }
        let logs = runStates.compactMap { t, s -> URL? in if case .finished = s { return runners[t]?.logURL } else { return nil } }
        if !busy, !logs.isEmpty { logs.forEach { NSWorkspace.shared.open($0) }; return }
        showConnect()
    }

    @objc func showReview() {
        let vc = ReviewSubmitViewController(pending: document.pendingCount, open: document.openCommentCount, repo: repoPath, readOnly: document.readOnly)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = vc
        vc.onSubmit = { [weak self, weak vc] body, verdict, targets in
            guard let self else { return }
            if let error = self.submit(body: body, verdict: verdict, targets: targets) { vc?.show(error: error) } else { popover.close() }
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
    /// Publish the review (and start the agent). Returns an error to show, or nil.
    @discardableResult
    func submit(body: String, verdict: Verdict, targets: [AgentRunner.Target]) -> String? {
        // A PR / commit view: agents work read-only in a private checkout of it.
        var checkout: String?
        if document.readOnly, !targets.filter({ $0 != .none }).isEmpty {
            do { checkout = try reviewCheckout(repoRoot: repoPath) } catch { return message(for: error) }
        }
        let pr = choice.pr.map(Int.init)
        do {
            _ = try submitReview(repoRoot: repoPath, author: document.reviewAuthor, body: body, verdict: verdict)
        } catch let CoreError.Io(message), let CoreError.Git(message) {
            return message
        } catch {
            return "\(error)"
        }
        document.reloadThreads()
        for target in targets where target != .none {
            let runner = runners[target] ?? AgentRunner()
            runner.onChange = { [weak self] in self?.updateAgents() }
            runners[target] = runner
            runner.run(target, repo: repoPath, checkout: checkout, pr: pr)
        }
        updateAgents()
        return nil
    }

    var agentState: AgentRunner.State { runStates.first?.1 ?? .idle }

    @objc func showConnect() {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = AgentConnectViewController()
        popover.delegate = self
        popover.show(relativeTo: agentButton.bounds, of: agentButton, preferredEdge: .maxY)
    }

    /// Connecting/disconnecting happens in the popover: re-check when it closes.
    func popoverDidClose(_ notification: Notification) { refreshConfiguredAgents() }

    private func refreshConfiguredAgents() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let names = AgentIntegration.all.filter { $0.check().isConnected }.map(\.name)
            DispatchQueue.main.async {
                guard let self, self.configuredAgents != names else { return }
                self.configuredAgents = names
                self.updateAgents()
            }
        }
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
    /// Threads an agent is working on right now.
    var activeClaims: [(agent: String, path: String)] {
        allThreads.compactMap { t in activeClaim(thread: t).map { ($0.agent, t.path) } }
    }
    /// Open threads where someone else (an agent) spoke last: they're waiting on you.
    var awaitingYou: [Thread] {
        allThreads.filter { t in
            guard t.status == .open, t.source == nil, activeClaim(thread: t) == nil, let last = t.entries.last(where: { !$0.pending }) else { return false }
            return last.author != author
        }
    }

    /// Bring a comment thread into view (unfolding its file) and flash it.
    func scrollToThread(_ t: Thread) {
        guard let i = files.firstIndex(where: { $0.path == t.path }) else {
            // Its file has no changes in this diff any more (e.g. the fix undid them): say so, don't do nothing.
            onNotice?("\((t.path as NSString).lastPathComponent) isn't in this diff any more, so there's nowhere to show this comment. Its thread is still in the side panel.")
            return
        }
        if files[i].collapsed { setCollapsed(i, false) }
        if t.status != .open, !ReviewFile.showResolved, !ReviewFile.revealed.contains(t.id) {
            ReviewFile.revealed.insert(t.id) // show just this one resolved thread, in place
            files[i].invalidateLayout()
            if editors[i] != nil { syncEditor(i) }
            layoutChanged()
        }
        guard files[i].threads.contains(where: { $0.thread.id == t.id && $0.line != nil }) else {
            scrollToFile(i)
            onNotice?("The line this comment was on has changed, so it can't be placed in the diff. Its thread is still in the side panel.")
            return
        }
        guard let row = files[i].layout.rows.first(where: { if case let .thread(id) = $0.kind { return id == t.id } else { return false } }),
              let clip = superview as? NSClipView else { return scrollToFile(i) }
        // Land with the commented line and a little context visible above the box.
        let y = tops[i] + row.y - FileLayout.headerHeight - 3 * DiffStyle.lineHeight
        clip.scroll(to: NSPoint(x: 0, y: max(0, min(y, frame.height - clip.bounds.height))))
        (clip.superview as? NSScrollView)?.reflectScrolledClipView(clip)
        layoutSubtreeIfNeeded()
        threadView(t.id)?.flash()
    }

    private func setCollapsed(_ i: Int, _ collapsed: Bool) {
        guard files[i].collapsed != collapsed else { return }
        files[i].collapsed = collapsed
        recomputeTops()
        if let clip = superview as? NSClipView { setFrameSize(NSSize(width: width, height: contentHeight(clip.bounds.height))) }
        needsLayout = true
        onChange?()
    }
    /// Your comments/replies waiting in a review you haven't submitted.
    private(set) var pendingCount = 0
    var reviewAuthor: String { author }

    var onChange: (() -> Void)?
    var onFilesReplaced: (([ReviewFile]) -> Void)?
    private var treeWatcher: TreeWatcher?
    private var reloading = false
    /// Commit the review diffs against (see `reviewBase`); set by ReviewView.reload.
    var baseRev = "HEAD"
    var repoRootForTests: String { repoPath }
    /// Showing a commit: files aren't on disk, so no editing and no live reload.
    var readOnly = false
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
        guard file.kind == .text, !file.collapsed, !readOnly else { return nil }
        var marks: [(String, CFTimeInterval)] = [("start", CACurrentMediaTime())]
        func mark(_ n: String) { marks.append((n, CACurrentMediaTime())) }
        defer {
            if ProcessInfo.processInfo.environment["ONRAMP_SELFTEST"] == "open-time" {
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

    func stopWatching() {
        treeWatcher?.stop()
        treeWatcher = nil
        commentsWatcher?.cancel()
        commentsWatcher = nil
    }

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
        guard !readOnly else { return } // a commit doesn't change with the working tree
        guard !reloading else { reloadAgain = true; return }
        reloading = true
        let repo = repoPath, rev = baseRev
        let current = Dictionary(files.map { ($0.path, $0.newText as String) }, uniquingKeysWith: { a, _ in a })
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let diffs = try? loadReview(repoRoot: repo, baseRev: rev, target: nil)
            // Colour files that changed and are on screen *before* they're swapped in: they'd
            // otherwise draw plain for a moment, and an agent editing file after file strobes.
            var colored: [String: SyntaxSpans] = [:]
            for d in diffs ?? [] {
                guard case let .text(_, newText, _, _) = d.body, current[d.path] != newText, Syntax.isOnScreen(d.path) else { continue }
                if let spans = Syntax.highlightNow(path: d.path, text: newText) { colored[d.path] = spans }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.reloading = false
                if let diffs { self.merge(TreeOrder.sorted(diffs.map(ReviewFile.init)), colored: colored) }
                if self.reloadAgain { self.reloadAgain = false; self.reloadFromDisk() }
            }
        }
    }

    // MARK: Following the agent

    /// Zed-style: the view goes where the agent is working (the file it just wrote,
    /// the thread it just took). Scrolling yourself stops it.
    var following = false { didSet { if following != oldValue { onFollowChanged?(following) } } }
    var onFollowChanged: ((Bool) -> Void)?
    private var claimed: Set<String> = []

    /// Scroll so line `line` of file `i` is in view with a little context above, and flash it.
    private func follow(file i: Int, line: Int) {
        if files[i].collapsed { setCollapsed(i, false) }
        guard let clip = superview as? NSClipView else { return }
        let rows = files[i].layout.rows
        let row = rows.first { if case let .line(l, _) = $0.kind { return l >= line } else { return false } } ?? rows.first
        guard let row else { return }
        let y = tops[i] + row.y - 4 * DiffStyle.lineHeight
        clip.animator().setBoundsOrigin(NSPoint(x: 0, y: max(0, min(y, frame.height - clip.bounds.height))))
        (clip.superview as? NSScrollView)?.reflectScrolledClipView(clip)
        flash(NSRect(x: 0, y: tops[i] + row.y, width: bounds.width, height: row.height))
    }

    /// A soft highlight that fades: "this just changed".
    private func flash(_ rect: NSRect) {
        let v = NSView(frame: rect)
        v.wantsLayer = true
        v.layer?.backgroundColor = DiffStyle.accent.withAlphaComponent(0.22).cgColor
        addSubview(v, positioned: .below, relativeTo: hover)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 1.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            v.animator().alphaValue = 0
        }, completionHandler: { v.removeFromSuperview() })
    }

    /// First line where `b` differs from `a`.
    private static func firstChangedLine(_ a: String, _ b: String) -> Int {
        var line = 0
        for (x, y) in zip(a.utf16, b.utf16) {
            if x != y { return line }
            if x == 10 { line += 1 }
        }
        return line
    }

    /// Swap in freshly loaded files, keeping per-file UI state, open editors
    /// (unsaved edits always win), comments, and the scroll position.
    private func merge(_ fresh: [ReviewFile], colored: [String: SyntaxSpans] = [:]) {
        // A file whose text didn't change keeps its object: layout, colours, everything.
        // (An agent usually touches one file; the rest must not so much as blink.)
        var changed: (path: String, line: Int)? // where to follow: the first file the agent changed
        let newFiles = fresh.map { f -> ReviewFile in
            guard let old = indexByPath[f.path].map({ files[$0] }) else { return f }
            if old.newText.isEqual(to: f.newText as String), old.oldText == f.oldText, old.hunks == f.hunks { return old }
            if changed == nil, editors[indexByPath[f.path]!]?.isDirty != true, editors[indexByPath[f.path]!]?.text != f.newText as String {
                changed = (f.path, Self.firstChangedLine(old.newText as String, f.newText as String)) // not your own save
            }
            if let spans = colored[f.path] { f.adoptSyntax(spans, for: f.newText as String) }
            if old.oldText == f.oldText { f.adoptOldSyntax(old.oldSyntax) }
            return f
        }
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
        if following, let c = changed, let i = indexByPath[c.path] {
            layoutSubtreeIfNeeded()
            follow(file: i, line: c.line)
        }
    }

    // MARK: Comments

    static func gitUserName(_ repo: String) -> String? {
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
        pendingCount = Int((try? onramp.pendingCount(repoRoot: repoPath, author: author)) ?? 0)
        let byPath = Dictionary(grouping: allThreads, by: \.path)
        for (i, file) in files.enumerated() {
            let mine = byPath[file.path] ?? []
            if mine.isEmpty, file.threads.isEmpty { continue }
            file.threads = mine.isEmpty ? [] : locateThreads(threads: mine, path: file.path, text: file.newText as String, oldText: file.oldText)
            if let r = file.replyingTo, !mine.contains(where: { $0.id == r }) { file.replyingTo = nil }
            editors[i]?.setReveal(expanded: file.revealed, commentSpace: file.commentSpace, deletedCommentSpace: file.deletedCommentSpace)
        }
        layoutChanged()
        onThreadsChanged?()
        // Following: a thread an agent just took comes into view.
        let now = Set(allThreads.filter { activeClaim(thread: $0) != nil }.map(\.id))
        if following, let t = allThreads.first(where: { now.contains($0.id) && !claimed.contains($0.id) }) { scrollToThread(t) }
        claimed = now
    }

    /// Called whenever comments change (the comments panel follows).
    var onThreadsChanged: (() -> Void)?

    /// Every thread for the comments panel: review order, then line; with status.
    var panelItems: [CommentsPanel.Item] {
        var items: [CommentsPanel.Item] = []
        var seen = Set<String>()
        func status(_ t: Thread) -> CommentsPanel.Status {
            if t.status == .resolved { return .resolved }
            if let c = activeClaim(thread: t) { return .working(agent: c.agent) }
            if t.source?.hasPrefix("ci:") == true { return .ci }
            if t.entries.allSatisfy(\.pending) { return .pending }
            if let last = t.entries.last(where: { !$0.pending }), last.author != author { return .needsYou }
            return .open
        }
        for f in files {
            for lt in f.threads.sorted(by: { ($0.line ?? 0) < ($1.line ?? 0) }) {
                seen.insert(lt.thread.id)
                items.append(.init(thread: lt.thread, line: lt.line.map { Int($0) + 1 }, status: status(lt.thread)))
            }
        }
        for t in allThreads where !seen.contains(t.id) { // on files no longer in this review
            items.append(.init(thread: t, line: nil, status: status(t)))
        }
        return items
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

    private func submitComment(_ i: Int, _ body: String, pending: Bool, send sendNow: Bool = false) {
        let file = files[i]
        guard let target = file.composer else { return }
        do {
            let thread = try addThread(repoRoot: repoPath, path: file.path, text: target.old ? file.oldText : file.newText as String,
                                       line: UInt32(target.line), oldSide: target.old, author: author, body: body, pending: pending)
            file.composer = nil
            reloadThreads()
            if sendNow { send(thread, file: i, line: target.line) }
        } catch { NSSound.beep() }
    }

    /// "Send to Claude" is offered while the diff is your working tree (the agent edits these files).
    private var sendAgentName: String? {
        guard !readOnly else { return nil }
        return QuickSend.target(repo: repoPath) == .codex ? "Codex" : "Claude"
    }

    /// Something to tell you (a quick send that couldn't start or finish).
    var onNotice: ((String) -> Void)?

    /// Hand one thread to your agent now; its fix and answer show up live.
    private func send(_ thread: Thread, file i: Int, line: Int) {
        following = true // you just asked for it: watch it happen
        QuickSend.send(thread: thread, path: files[i].path, line: line, text: files[i].newText as String, repo: repoPath) { [weak self] error in
            self?.reloadThreads()
            if let error { self?.onNotice?(error) }
        }
        reloadThreads() // its claim: the thread shows "working" now
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
        view.sendAgent = sendAgentName
        let id = located.thread.id
        let path = files[i].path
        view.onReplyAndSend = { [weak self] text in
            self?.withFile(path) { i in
                guard let self else { return }
                self.files[i].replyingTo = nil
                self.threadAction(i) { _ = try reply(repoRoot: self.repoPath, id: id, author: self.author, body: text, pending: false) }
                if let t = self.files[i].threads.first(where: { $0.thread.id == id }) { self.send(t.thread, file: i, line: Int(t.line ?? 0)) }
            }
        }
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
        view.input.setSend(sendAgentName)
        view.input.onSend = { [weak self] text in self?.withFile(path) { self?.submitComment($0, text, pending: false, send: true) } }
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

/// A user-facing message for errors from the core or gh.
func message(for error: Error) -> String {
    if let e = error as? CoreError { switch e { case let .Git(m), let .Io(m): return m } }
    return "\(error)"
}
