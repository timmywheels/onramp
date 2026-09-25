import AppKit

/// App-wide: menus, settings, and the project windows (tabs). Window actions
/// go to the front tab's ProjectWindowController.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var initialRepo: String?
    private var didLaunch = false
    /// Links that arrived while launching (e.g. Stoplight opened us): handled once the app is up.
    private var pendingLinks: [URL] = []
    private var controllers: [ProjectWindowController] = []

    /// nil: opened from Finder / the Dock without a repo.
    init(repoPath: String?) {
        self.initialRepo = repoPath
    }

    /// The front tab (or the last one opened).
    var front: ProjectWindowController? {
        if let c = NSApp.keyWindow?.windowController as? ProjectWindowController { return c }
        if let c = NSApp.mainWindow?.windowController as? ProjectWindowController { return c }
        // Not active (e.g. in the background): the selected tab of the window group.
        let selected = controllers.first?.window?.tabGroup?.selectedWindow
        return controllers.first { $0.window === selected } ?? controllers.last
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        didLaunch = true
        NSApp.mainMenu = makeMainMenu()
        // The Dock / ⌘-Tab icon (the binary isn't inside a .app, so set it here).
        if let icon = Extensions.resource("AppIcon.icns").flatMap(NSImage.init(contentsOf:)) { NSApp.applicationIconImage = icon }
        Style.shared.start()
        Installation.syncIntegrations()
        Updater.shared.start()
        MenuBarItem.shared.start()
        if ProcessInfo.processInfo.environment["ONRAMP_SELFTEST"] == "link-cold" { // launched by a link, nothing recent
            FileHandle.standardError.write("[selftest] didFinishLaunching: \(controllers.count) tabs\n".data(using: .utf8)!)
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [self] in
                for c in controllers { FileHandle.standardError.write("[selftest] tab \(c.window?.title ?? "?") visible \(c.window?.isVisible ?? false)\n".data(using: .utf8)!) }
                FileHandle.standardError.write("[selftest] done: \(controllers.count) tabs\n".data(using: .utf8)!)
                NSApp.terminate(nil)
            }
        }
        // `onramp <repo>` while we're running: open it as a tab.
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(openFromCLI(_:)), name: CLI.openNotification, object: nil)
        // Self-tests run while you keep typing elsewhere: never steal focus.
        if ProcessInfo.processInfo.environment["ONRAMP_SELFTEST"] == nil { NSApp.activate(ignoringOtherApps: true) }
        // Opened by a link: that's the first thing to show (the PR as a tab), not the last project.
        if !pendingLinks.isEmpty {
            let links = pendingLinks
            pendingLinks = []
            links.forEach(handleOpen)
            if !controllers.isEmpty { return } // otherwise (you cancelled) start as usual
        }
        let fresh = ProcessInfo.processInfo.environment["ONRAMP_SELFTEST"] == "welcome" // pretend nothing is recent
        guard !fresh, let repo = initialRepo ?? RecentProjects.list.first(where: { RecentProjects.repoRoot(of: $0) != nil }) else {
            return chooseFirstProject()
        }
        initialRepo = repo
        let c = makeController(repoPath: repo, first: true)
        c.window?.makeKeyAndOrderFront(nil)
        c.start()
    }

    /// No repo and nothing recent: ask for one.
    private func chooseFirstProject() {
        if welcome == nil {
            let w = WelcomeWindowController()
            w.onOpenRepo = { [weak self] root in self?.open(tabFor: root) }
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w.window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    // Closed without opening anything, and no menu bar icon to come back from: quit.
                    guard let self, self.controllers.isEmpty, !MenuBarItem.shared.isShown else { return }
                    DispatchQueue.main.async { if self.controllers.isEmpty, self.welcome?.window?.isVisible != true { NSApp.terminate(nil) } }
                }
            }
            welcome = w
        }
        welcome?.showWindow(nil)
        if ProcessInfo.processInfo.environment["ONRAMP_SELFTEST"] == nil { NSApp.activate(ignoringOtherApps: true) }
        if ProcessInfo.processInfo.environment["ONRAMP_SELFTEST"] == "welcome" { SelfTest.snap(window: welcome?.window) }
    }

    /// First launch, nothing recent: repos, a PR link field, Open Folder.
    private var welcome: WelcomeWindowController?
    /// Any project window open (the Welcome window doesn't count).
    var hasWindows: Bool { !controllers.isEmpty }

    /// A tab for `repo`: the first window if there's none yet.
    private func open(tabFor repo: String) {
        if controllers.isEmpty {
            initialRepo = repo
            let c = makeController(repoPath: repo, first: true)
            c.window?.makeKeyAndOrderFront(nil)
            c.start()
        } else if let existing = controllers.first(where: { $0.repoPath == repo }) {
            existing.window?.tabGroup?.selectedWindow = existing.window
            existing.window?.makeKeyAndOrderFront(nil)
        } else {
            openTab(repo: repo)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openFromCLI(_ note: Notification) {
        guard let repo = note.object as? String else { return }
        open(tabFor: repo)
    }

    /// Folders dropped on the Dock icon ("Open With"), and onramp:// links (e.g. from Stoplight).
    func application(_ application: NSApplication, open urls: [URL]) {
        DeepLinks.log("open \(urls) (launched: \(didLaunch))")
        guard didLaunch else { return pendingLinks += urls }
        urls.forEach(handleOpen)
    }

    private func handleOpen(_ url: URL) {
        if url.scheme == "onramp" { return DeepLinks.handle(url, app: self) }
        if let root = RecentProjects.repoRoot(of: url.path) { open(tabFor: root) }
    }

    func openProject(_ root: String) { open(tabFor: root) }

    /// Every open tab's review (the menu bar reads agent runs from these).
    var openReviews: [ReviewView] { controllers.map(\.review) }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if controllers.isEmpty { chooseFirstProject() }
        return true
    }

    @objc func installCommandLineTool(_ sender: Any?) { Installation.installCommandLineTool() }
    @objc func checkForUpdates(_ sender: Any?) { Updater.shared.checkInteractively() }

    /// Any tab with unsaved edits (an update would drop them).
    var hasUnsavedEdits: Bool { controllers.contains { $0.review.document.dirtyCount > 0 } }

    private func makeController(repoPath: String, first: Bool = false) -> ProjectWindowController {
        let c = ProjectWindowController(repoPath: repoPath, first: first)
        c.onClose = { [weak self] closed in self?.controllers.removeAll { $0 === closed } }
        controllers.append(c)
        return c
    }

    // MARK: Tabs

    /// ⌘T and the tab bar's "+": another tab on the same project; switch it from its toolbar.
    @objc func newWindowForTab(_ sender: Any?) {
        guard let repo = front?.repoPath ?? initialRepo else { return chooseFirstProject() }
        openTab(repo: repo)
    }

    @discardableResult
    func openTab(repo: String, start: Bool = true) -> ProjectWindowController {
        let host = front
        let c = makeController(repoPath: repo)
        if let hostWindow = host?.window, let w = c.window {
            hostWindow.addTabbedWindow(w, ordered: .above)
        }
        c.window?.makeKeyAndOrderFront(nil)
        if start { c.start() }
        return c
    }

    /// View a PR in its own tab: the tab already showing it, or a new one.
    func viewPullRequest(_ n: Int, repo: String, done: @escaping (String?) -> Void) {
        if let tab = controllers.first(where: { $0.repoPath == repo && $0.isShowing(pr: n) }), let w = tab.window {
            w.tabGroup?.selectedWindow = w // bring its tab forward
            w.makeKeyAndOrderFront(nil)
            tab.review.openPullRequest(n, done: done) // re-fetch: it may have new commits
            return
        }
        let tab = openTab(repo: repo, start: false)
        tab.review.openPullRequest(n, done: done)
    }

    /// Self-test hook: the front tab's toolbar and review, and switching projects like its menu does.
    static var current: AppDelegate? { NSApp.delegate as? AppDelegate }
    var sourceToolbar: SourceToolbar { front!.sourceToolbar }
    var currentReview: ReviewView { front!.review }
    var tabCount: Int { controllers.count }
    func open(repo path: String) { front?.open(repo: path) }

    // MARK: Window actions → front tab

    @objc func openFolder(_ sender: Any?) { front?.openFolder(sender) }
    @objc func openPullRequest(_ sender: Any?) { front?.openPullRequest(sender) }
    @objc func showComments(_ sender: Any?) { front?.showComments(sender) }
    @objc func showPullRequests(_ sender: Any?) { front?.showPullRequests(sender) }
    @objc func openContext(_ sender: Any?) { front?.openContext(sender) }
    @objc func toggleComments(_ sender: Any?) { front?.toggleComments(sender) }
    @objc func collapseAll(_ sender: Any?) { front?.collapseAll(sender) }
    @objc func expandAll(_ sender: Any?) { front?.expandAll(sender) }
    @objc func toggleResolved(_ sender: Any?) { front?.toggleResolved(sender) }
    @objc func saveDocument(_ sender: Any?) { front?.saveDocument(sender) }
    @objc func reloadReview(_ sender: Any?) { front?.reloadReview(sender) }

    // MARK: Settings

    @objc func openSettings(_ sender: Any?) {
        Style.shared.save() // make sure the file exists with every key
        NSWorkspace.shared.open(Style.settingsURL)
    }

    @objc func openThemes(_ sender: Any?) {
        NSWorkspace.shared.open(Style.themesDir)
    }

    @objc func openExtensions(_ sender: Any?) {
        try? FileManager.default.createDirectory(at: Extensions.userDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Extensions.userDir)
    }

    @objc func setFont(_ sender: NSMenuItem) {
        guard let family = sender.representedObject as? String else { return }
        Style.shared.update { $0.fontFamily = family == Style.defaultFontFamily ? "" : family }
    }

    @objc func toggleLigatures(_ sender: Any?) { Style.shared.update { $0.fontLigatures.toggle() } }
    @objc func toggleFollow(_ sender: Any?) { front?.review.toggleFollow() }
    /// The review's primed Claude session: start (or resume), start over, or end it.
    @objc func startAgentSession(_ sender: Any?) { front?.review.startSession(force: true) }
    @objc func runReviewer(_ sender: NSMenuItem) {
        guard let r = sender.representedObject as? Reviewer else { return }
        front?.review.runReviewer(r)
    }
    /// A new reviewer of yours, from the red team as a template, opened in your editor.
    @objc func newReviewer(_ sender: Any?) {
        let dir = onrampConfigDir.appendingPathComponent("reviewers")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var url = dir.appendingPathComponent("my-reviewer.toml")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) { url = dir.appendingPathComponent("my-reviewer-\(n).toml"); n += 1 }
        let template = Extensions.resource("Reviewers")?.appendingPathComponent("red-team.toml")
        var text = template.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "id = \"my-reviewer\"\nname = \"My reviewer\"\nprompt = \"\"\"\n\"\"\"\n"
        let id = url.deletingPathExtension().lastPathComponent
        text = text.replacingOccurrences(of: "id = \"red-team\"", with: "id = \"\(id)\"").replacingOccurrences(of: "name = \"Red team\"", with: "name = \"\(id)\"")
        try? text.write(to: url, atomically: true, encoding: .utf8)
        NSWorkspace.shared.open(url)
    }
    @objc func newAgentSession(_ sender: Any?) { front?.review.startSession(fresh: true, force: true) }
    @objc func endAgentSession(_ sender: Any?) { front?.review.stopSession() }
    @objc func toggleMenuBar(_ sender: Any?) { Style.shared.update { $0.menuBar.toggle() } }

    @objc func zoomIn(_ sender: Any?) { Style.shared.update { $0.fontSize = min(32, $0.fontSize + 1) } }
    @objc func zoomOut(_ sender: Any?) { Style.shared.update { $0.fontSize = max(8, $0.fontSize - 1) } }
    @objc func zoomReset(_ sender: Any?) { Style.shared.update { $0.fontSize = Settings.defaultFontSize } }

    @objc func setAppearance(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? String else { return }
        Style.shared.update { $0.appearance = mode }
    }

    @objc func setTheme(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        Style.shared.selectTheme(name)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu.title == "Run Reviewer" {
            menu.removeAllItems()
            let reviewers = front.map { ReviewerRun.all(repo: $0.repoPath) } ?? []
            for (k, r) in reviewers.enumerated() {
                let item = menu.addItem(withTitle: r.name, action: #selector(runReviewer(_:)), keyEquivalent: k == 0 ? "r" : "")
                item.keyEquivalentModifierMask = [.option, .command]
                item.representedObject = r
                item.toolTip = r.file
            }
            if !reviewers.isEmpty { menu.addItem(.separator()) }
            menu.addItem(withTitle: "New Reviewer…", action: #selector(newReviewer(_:)), keyEquivalent: "")
            return
        }
        menu.item(withTitle: "Show Resolved Comments")?.state = ReviewFile.showResolved ? .on : .off
        menu.item(withTitle: "Show Right Panel")?.state = front?.commentsVisible == true ? .on : .off
        let style = Style.shared
        if let appearance = menu.item(withTitle: "Appearance")?.submenu {
            appearance.removeAllItems()
            for (title, mode) in [("System", "system"), ("Light", "light"), ("Dark", "dark")] {
                let item = appearance.addItem(withTitle: title, action: #selector(setAppearance(_:)), keyEquivalent: "")
                item.representedObject = mode
                item.state = style.settings.appearance == mode ? .on : .off
            }
        }
        menu.item(withTitle: "Font Ligatures")?.state = style.settings.fontLigatures ? .on : .off
        menu.item(withTitle: "Show Agents in Menu Bar")?.state = style.settings.menuBar ? .on : .off
        menu.item(withTitle: "Follow Agent")?.state = front?.review.document.following == true ? .on : .off
        if let fonts = menu.item(withTitle: "Font")?.submenu {
            fonts.removeAllItems()
            for (i, family) in style.monospaceFamilies.enumerated() {
                if i == 2 { fonts.addItem(.separator()) } // default + system mono, then installed fonts
                let title = family == Style.defaultFontFamily ? "\(family) (default)" : family
                let item = fonts.addItem(withTitle: title, action: #selector(setFont(_:)), keyEquivalent: "")
                item.representedObject = family
                item.state = style.fontFamily == family ? .on : .off
            }
        }
        if let themes = menu.item(withTitle: "Theme")?.submenu {
            themes.removeAllItems()
            for t in style.themesForCurrentMode {
                let item = themes.addItem(withTitle: t.name, action: #selector(setTheme(_:)), keyEquivalent: "")
                item.representedObject = t.name
                item.state = style.theme.name == t.name ? .on : .off
            }
        }
    }

    /// With the menu bar item on, Onramp keeps watching your agents after the last window closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !MenuBarItem.shared.isShown }

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings(_:)), keyEquivalent: ",")
        appMenu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        appMenu.addItem(withTitle: "Install Command Line Tool…", action: #selector(installCommandLineTool(_:)), keyEquivalent: "")
        appMenu.addItem(withTitle: "Open Themes Folder", action: #selector(openThemes(_:)), keyEquivalent: "")
        appMenu.addItem(withTitle: "Open Extensions Folder", action: #selector(openExtensions(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Onramp", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "New Tab", action: #selector(newWindowForTab(_:)), keyEquivalent: "t")
        fileMenu.addItem(withTitle: "Open Folder…", action: #selector(openFolder(_:)), keyEquivalent: "o")
        fileMenu.addItem(withTitle: "Close Tab", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Save", action: #selector(saveDocument(_:)), keyEquivalent: "s")
        fileMenu.addItem(withTitle: "Reload", action: #selector(reloadReview(_:)), keyEquivalent: "r")
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        let reviewItem = NSMenuItem()
        let reviewMenu = NSMenu(title: "Review")
        let pr = reviewMenu.addItem(withTitle: "View Pull Request…", action: #selector(openPullRequest(_:)), keyEquivalent: "p")
        pr.keyEquivalentModifierMask = [.command, .shift]
        reviewMenu.addItem(withTitle: "Context…", action: #selector(openContext(_:)), keyEquivalent: "k")
        reviewMenu.addItem(.separator())
        let reviewers = reviewMenu.addItem(withTitle: "Run Reviewer", action: nil, keyEquivalent: "")
        reviewers.submenu = NSMenu(title: "Run Reviewer")
        reviewers.submenu?.delegate = self // lists this repo's reviewers when opened
        reviewMenu.addItem(withTitle: "Start Agent Session", action: #selector(startAgentSession(_:)), keyEquivalent: "")
        reviewMenu.addItem(withTitle: "New Agent Session", action: #selector(newAgentSession(_:)), keyEquivalent: "")
        reviewMenu.addItem(withTitle: "End Agent Session", action: #selector(endAgentSession(_:)), keyEquivalent: "")
        reviewItem.submenu = reviewMenu

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        viewMenu.delegate = self // rebuilds Appearance/Theme submenus with checkmarks
        viewMenu.addItem(withTitle: "Zoom In", action: #selector(zoomIn(_:)), keyEquivalent: "=")
        viewMenu.addItem(withTitle: "Zoom Out", action: #selector(zoomOut(_:)), keyEquivalent: "-")
        viewMenu.addItem(withTitle: "Actual Size", action: #selector(zoomReset(_:)), keyEquivalent: "0")
        viewMenu.addItem(.separator())
        let fontItem = viewMenu.addItem(withTitle: "Font", action: nil, keyEquivalent: "")
        fontItem.submenu = NSMenu(title: "Font")
        viewMenu.addItem(withTitle: "Font Ligatures", action: #selector(toggleLigatures(_:)), keyEquivalent: "")
        viewMenu.addItem(.separator())
        let appearanceItem = viewMenu.addItem(withTitle: "Appearance", action: nil, keyEquivalent: "")
        appearanceItem.submenu = NSMenu(title: "Appearance")
        let themeItem = viewMenu.addItem(withTitle: "Theme", action: nil, keyEquivalent: "")
        themeItem.submenu = NSMenu(title: "Theme")
        viewMenu.addItem(.separator())
        let collapse = viewMenu.addItem(withTitle: "Collapse All Files", action: #selector(collapseAll(_:)), keyEquivalent: String(UnicodeScalar(NSLeftArrowFunctionKey)!))
        collapse.keyEquivalentModifierMask = [.option, .command]
        let expand = viewMenu.addItem(withTitle: "Expand All Files", action: #selector(expandAll(_:)), keyEquivalent: String(UnicodeScalar(NSRightArrowFunctionKey)!))
        expand.keyEquivalentModifierMask = [.option, .command]
        viewMenu.addItem(.separator())
        let comments = viewMenu.addItem(withTitle: "Show Right Panel", action: #selector(toggleComments(_:)), keyEquivalent: "0")
        comments.keyEquivalentModifierMask = [.option, .command]
        viewMenu.addItem(withTitle: "Show Resolved Comments", action: #selector(toggleResolved(_:)), keyEquivalent: "R")
        viewMenu.addItem(withTitle: "Show Agents in Menu Bar", action: #selector(toggleMenuBar(_:)), keyEquivalent: "")
        let follow = viewMenu.addItem(withTitle: "Follow Agent", action: #selector(toggleFollow(_:)), keyEquivalent: "f")
        follow.keyEquivalentModifierMask = [.option, .command]
        viewMenu.addItem(.separator())
        let c1 = viewMenu.addItem(withTitle: "Comments", action: #selector(showComments(_:)), keyEquivalent: "1")
        c1.keyEquivalentModifierMask = [.option, .command]
        let c2 = viewMenu.addItem(withTitle: "Pull Requests", action: #selector(showPullRequests(_:)), keyEquivalent: "2")
        c2.keyEquivalentModifierMask = [.option, .command]
        let toggle = viewMenu.addItem(withTitle: "Toggle Sidebar", action: #selector(NSSplitViewController.toggleSidebar(_:)), keyEquivalent: "s")
        toggle.keyEquivalentModifierMask = [.control, .command]
        viewItem.submenu = viewMenu
        main.addItem(viewItem)
        main.addItem(reviewItem)

        return main
    }
}
