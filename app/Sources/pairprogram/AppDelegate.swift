import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var repoPath: String
    private var window: NSWindow!
    private var reviewView: ReviewView!
    private var sidebar: FileTreeSidebar!
    private var toolbar: SourceToolbar!
    private var commentsPanel = CommentsPanel()
    private var commentsItem: NSSplitViewItem?

    init(repoPath: String) {
        self.repoPath = repoPath
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        Style.shared.start()

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "pairprogram — \((repoPath as NSString).lastPathComponent)"
        toolbar = SourceToolbar(repoPath: repoPath)
        toolbar.onOpenRepo = { [weak self] path in self?.open(repo: path) }
        toolbar.onToggleComments = { [weak self] in self?.toggleComments(nil) }
        toolbar.install(in: window)
        RecentProjects.add(repoPath)

        reviewView = ReviewView(repoPath: repoPath)
        toolbar.review = reviewView
        reviewView.onBaseChanged = { [weak self] _ in self?.toolbar.refreshTitles() }
        sidebar = FileTreeSidebar()
        wireSidebar()
        // A content view controller resizes the window to its fitting size (tiny, since
        // the review has no intrinsic size), so size it after, then restore any saved frame.
        window.contentViewController = makeSplit()
        window.contentMinSize = NSSize(width: 700, height: 400)
        window.setContentSize(NSSize(width: 1300, height: 850))
        window.center()
        window.setFrameAutosaveName("pairprogram.window")
        window.makeKeyAndOrderFront(nil)
        if UserDefaults.standard.object(forKey: "NSSplitView Subview Frames pairprogram.split") == nil,
           let split = window.contentViewController as? NSSplitViewController {
            split.splitView.setPosition(300, ofDividerAt: 0) // first launch; afterwards the saved width wins
        }
        // Self-tests run while you keep typing elsewhere: never steal focus.
        if ProcessInfo.processInfo.environment["PP_SELFTEST"] == nil { NSApp.activate(ignoringOtherApps: true) }

        reviewView.reload()
    }

    /// Show another project or worktree in this window.
    func open(repo path: String) {
        guard path != repoPath else { return }
        guard reviewView.document.dirtyCount == 0 else { return NSSound.beep() } // save first (⌘S)
        reviewView.close()
        repoPath = path
        RecentProjects.add(path)
        window.title = "pairprogram — \((path as NSString).lastPathComponent)"
        reviewView = ReviewView(repoPath: path)
        reviewView.onBaseChanged = { [weak self] _ in self?.toolbar.refreshTitles() }
        sidebar = FileTreeSidebar()
        wireSidebar()
        let frame = window.frame // a new content view controller resizes the window to fit
        window.contentViewController = makeSplit()
        window.setFrame(frame, display: true)
        toolbar.repoPath = path
        toolbar.review = reviewView
        reviewView.reload()
    }

    @objc func openFolder(_ sender: Any?) { toolbar.openFolder(sender) }

    /// Self-test hook: the toolbar, and a way to switch projects like its menu does.
    static var current: AppDelegate? { NSApp.delegate as? AppDelegate }
    var sourceToolbar: SourceToolbar { toolbar }
    var currentReview: ReviewView { reviewView }

    private func makeSplit() -> NSSplitViewController {
        let split = NSSplitViewController()
        let side = NSSplitViewItem(sidebarWithViewController: sidebar)
        side.minimumThickness = 220
        side.maximumThickness = 420
        side.canCollapse = true
        let content = NSViewController()
        content.view = reviewView
        split.addSplitViewItem(side)
        split.addSplitViewItem(NSSplitViewItem(viewController: content))
        commentsPanel = CommentsPanel()
        wireComments()
        let comments = NSSplitViewItem(inspectorWithViewController: commentsPanel)
        comments.minimumThickness = 240
        comments.maximumThickness = 420
        comments.canCollapse = true
        comments.isCollapsed = UserDefaults.standard.bool(forKey: "pairprogram.commentsHidden")
        split.addSplitViewItem(comments)
        commentsItem = comments
        split.splitView.autosaveName = "pairprogram.split"
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

    @objc func toggleComments(_ sender: Any?) {
        guard let item = commentsItem else { return }
        item.animator().isCollapsed.toggle()
        UserDefaults.standard.set(item.isCollapsed, forKey: "pairprogram.commentsHidden")
    }

    private func wireSidebar() {
        sidebar.isDirty = { [weak self] i in self?.reviewView.document.editor(i)?.isDirty ?? false }
        sidebar.onSelectFile = { [weak self] i in self?.reviewView.document.scrollToFile(i) }
        reviewView.onLoad = { [weak self] files in self?.sidebar.setFiles(files) }
        reviewView.onFileChanged = { [weak self] i in self?.sidebar.refresh(i) }
        reviewView.onCurrentFile = { [weak self] i in self?.sidebar.reveal(i) }
    }

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

    @objc func collapseAll(_ sender: Any?) { reviewView.document.setAllCollapsed(true) }
    @objc func expandAll(_ sender: Any?) { reviewView.document.setAllCollapsed(false) }

    @objc func toggleResolved(_ sender: Any?) {
        reviewView.document.setShowResolved(!ReviewFile.showResolved)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.item(withTitle: "Show Resolved Comments")?.state = ReviewFile.showResolved ? .on : .off
        menu.item(withTitle: "Show Comments")?.state = commentsItem?.isCollapsed == false ? .on : .off
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

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    @objc func saveDocument(_ sender: Any?) {
        reviewView.saveAll()
    }

    @objc func reloadReview(_ sender: Any?) {
        reviewView.reload()
    }

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings(_:)), keyEquivalent: ",")
        appMenu.addItem(withTitle: "Open Themes Folder", action: #selector(openThemes(_:)), keyEquivalent: "")
        appMenu.addItem(withTitle: "Open Extensions Folder", action: #selector(openExtensions(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit pairprogram", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Open Folder…", action: #selector(openFolder(_:)), keyEquivalent: "o")
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
        let comments = viewMenu.addItem(withTitle: "Show Comments", action: #selector(toggleComments(_:)), keyEquivalent: "0")
        comments.keyEquivalentModifierMask = [.option, .command]
        viewMenu.addItem(withTitle: "Show Resolved Comments", action: #selector(toggleResolved(_:)), keyEquivalent: "R")
        viewMenu.addItem(.separator())
        let toggle = viewMenu.addItem(withTitle: "Toggle Sidebar", action: #selector(NSSplitViewController.toggleSidebar(_:)), keyEquivalent: "s")
        toggle.keyEquivalentModifierMask = [.control, .command]
        viewItem.submenu = viewMenu
        main.addItem(viewItem)

        return main
    }
}
