import AppKit

/// The window toolbar: which project/worktree (left) and which changes
/// (right: the branch vs its base, uncommitted work, or one commit), like
/// Xcode's scheme picker. Menus are built when opened, so they're current.
@MainActor
final class SourceToolbar: NSObject, NSToolbarDelegate, NSMenuDelegate {
    private static let projectID = NSToolbarItem.Identifier("pairprogram.project")
    private static let changesID = NSToolbarItem.Identifier("pairprogram.changes")
    private static let commentsID = NSToolbarItem.Identifier("pairprogram.comments")
    private let commentsButton = CapsuleButton()
    private lazy var commentsWidth = commentsButton.widthAnchor.constraint(equalToConstant: 32)
    var onToggleComments: (() -> Void)?
    private static let edgePadding: CGFloat = 6

    private let projectButton = PickerButton()
    private let changesButton = PickerButton()

    var repoPath: String { didSet { refreshTitles() } }
    weak var review: ReviewView? { didSet { refreshTitles() } }
    /// Open another project or worktree in this window.
    var onOpenRepo: ((String) -> Void)?

    init(repoPath: String) {
        self.repoPath = repoPath
        super.init()
        for (button, width) in [(projectButton, 300.0), (changesButton, 340.0)] {
            button.pickerMenu.delegate = self
            button.maxWidth = width
        }
        commentsButton.target = self
        commentsButton.action = #selector(commentsClicked)
        commentsButton.horizontalPadding = 9
        commentsButton.toolTip = "Show or hide the comments panel (⌥⌘0)"
        setCommentCount(0)
        projectButton.toolTip = "Project or worktree (⌘O opens another folder)"
        changesButton.toolTip = "What to review: the whole branch, uncommitted changes, or one commit"
    }

    func install(in window: NSWindow) {
        let toolbar = NSToolbar(identifier: "pairprogram.toolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.titleVisibility = .hidden // the project menu says which repo this is
        refreshTitles()
    }

    @objc private func commentsClicked() { onToggleComments?() }

    /// The comments button: an icon, plus the open count when there is one.
    func setCommentCount(_ n: Int) {
        let s = NSMutableAttributedString()
        if let icon = PickerButton.padded("text.bubble", left: 0, right: n > 0 ? 5 : 0, color: .secondaryLabelColor) {
            let a = NSTextAttachment()
            a.image = icon
            a.bounds = NSRect(x: 0, y: -2, width: icon.size.width, height: icon.size.height)
            s.append(NSAttributedString(attachment: a))
        }
        if n > 0 { s.append(NSAttributedString(string: "\(n)", attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)])) }
        commentsButton.attributedTitle = s
        // Toolbars measure an item once; keep the width in step with the count.
        commentsWidth.constant = ceil(commentsButton.cell!.cellSize.width) + 2 * commentsButton.horizontalPadding
        commentsWidth.isActive = true
    }

    // MARK: Titles

    func refreshTitles() {
        let name = (repoPath as NSString).lastPathComponent
        let branch = (try? listWorktrees(repoRoot: repoPath))?.first { $0.isCurrent }?.branch
        setTitle(projectButton, symbol: "folder", title: branch.map { "\(name)  ·  \($0)" } ?? name)

        let title: String
        switch review?.base?.mode {
        case .branch?: title = "All changes vs \(review?.base?.branch ?? "HEAD")"
        case .commit?: title = "Commit \(review?.base?.title ?? "")"
        case .uncommitted?: title = "Uncommitted changes"
        case nil: title = "Changes"
        }
        setTitle(changesButton, symbol: review?.base?.mode == .commit ? "smallcircle.filled.circle" : "arrow.triangle.branch", title: title)
    }

    private func setTitle(_ button: PickerButton, symbol: String, title: String) {
        button.set(symbol: symbol, title: title)
    }

    // MARK: Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.projectID, .flexibleSpace, Self.changesID, Self.commentsID]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        if id == Self.projectID {
            item.view = projectButton
        } else if id == Self.changesID {
            item.view = changesButton
        } else {
            // The toolbar leaves 8pt at the window's right edge; pad to 14 so the
            // gap there matches the gap above the pill.
            let box = NSView()
            commentsButton.translatesAutoresizingMaskIntoConstraints = false
            box.addSubview(commentsButton)
            NSLayoutConstraint.activate([
                commentsButton.leadingAnchor.constraint(equalTo: box.leadingAnchor),
                commentsButton.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -Self.edgePadding),
                commentsButton.centerYAnchor.constraint(equalTo: box.centerYAnchor),
                commentsButton.heightAnchor.constraint(equalToConstant: CapsuleButton.height),
                box.heightAnchor.constraint(equalTo: commentsButton.heightAnchor),
            ])
            item.view = box
        }
        item.label = id == Self.projectID ? "Project" : id == Self.changesID ? "Changes" : "Comments"
        item.isBordered = false // no system glass capsule around it: the button's own, shorter pill is the look
        return item
    }

    // MARK: Menus

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if menu === projectButton.pickerMenu { buildProjectMenu(menu) } else { buildChangesMenu(menu) }
    }

    private func buildProjectMenu(_ menu: NSMenu) {
        let worktrees = (try? listWorktrees(repoRoot: repoPath)) ?? []
        if worktrees.count > 1 {
            menu.addItem(.sectionHeader(title: "Worktrees"))
            for wt in worktrees {
                let name = (wt.path as NSString).lastPathComponent
                add(to: menu, title: wt.branch.map { "\(name)  —  \($0)" } ?? name, action: #selector(openRepo(_:)), object: wt.path, on: wt.isCurrent)
            }
        }
        let shown = Set(worktrees.map(\.path) + [repoPath])
        let recent = RecentProjects.list.filter { !shown.contains($0) }
        if !recent.isEmpty {
            menu.addItem(.sectionHeader(title: "Recent"))
            for path in recent.prefix(8) {
                let item = add(to: menu, title: (path as NSString).lastPathComponent, action: #selector(openRepo(_:)), object: path)
                item.toolTip = path
            }
        }
        menu.addItem(.separator())
        let open = add(to: menu, title: "Open Folder…", action: #selector(openFolder(_:)), object: nil)
        open.keyEquivalent = "o"
    }

    private func buildChangesMenu(_ menu: NSMenu) {
        let choice = reviewChoice(repoRoot: repoPath)
        let base = review?.base

        add(to: menu, title: "All changes on this branch", action: #selector(pickBranchMode(_:)), object: nil, on: choice.mode == .branch)
            .toolTip = "Committed and uncommitted, against where this branch left its base (like a pull request)"

        let against = NSMenuItem(title: "Compare Against", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        add(to: sub, title: "Default branch" + (choice.baseBranch == nil && base?.mode == .branch ? " (\(base?.branch ?? "none"))" : ""),
            action: #selector(pickBase(_:)), object: "", on: choice.baseBranch == nil)
        sub.addItem(.separator())
        for b in ((try? listBranches(repoRoot: repoPath)) ?? []).prefix(80) {
            add(to: sub, title: b, action: #selector(pickBase(_:)), object: b, on: choice.baseBranch == b)
        }
        against.submenu = sub
        menu.addItem(against)

        add(to: menu, title: "Uncommitted changes", action: #selector(pickUncommitted(_:)), object: nil, on: choice.mode == .uncommitted)
            .toolTip = "Only what isn't committed yet"

        if let picked = try? reviewCommits(repoRoot: repoPath, limit: 40), !picked.commits.isEmpty {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: picked.onBranch ? "Commits on this branch" : "Recent commits"))
            let dates = RelativeDateTimeFormatter()
            for c in picked.commits {
                let summary = c.summary.count > 64 ? c.summary.prefix(63) + "…" : Substring(c.summary)
                let item = add(to: menu, title: "\(c.short)  \(summary)", action: #selector(pickCommit(_:)), object: c.sha,
                               on: choice.mode == .commit && base?.target == c.sha)
                item.toolTip = "\(c.author), \(dates.localizedString(for: Date(timeIntervalSince1970: TimeInterval(c.time)), relativeTo: Date()))"
            }
        }
    }

    @discardableResult
    private func add(to menu: NSMenu, title: String, action: Selector, object: Any?, on: Bool = false) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = object
        item.state = on ? .on : .off
        return item
    }

    /// Button frames (self-tests).
    var debugFrames: String {
        guard let w = changesButton.window, let c = w.contentView?.superview else { return "no window" }
        let f = changesButton.convert(changesButton.bounds, to: c) // frame view: origin bottom-left, includes title bar
        return "changes pill: top gap \(c.bounds.maxY - f.maxY), right gap \(c.bounds.maxX - f.maxX), height \(f.height)"
    }

    /// Menu contents as text (self-tests).
    func debugMenus() -> (project: [String], changes: [String], titles: (String, String)) {
        func lines(_ button: PickerButton) -> [String] {
            menuNeedsUpdate(button.pickerMenu)
            return button.pickerMenu.items.map { $0.isSeparatorItem ? "—" : ($0.state == .on ? "✓ " : "  ") + $0.title }
        }
        return (lines(projectButton), lines(changesButton), (projectButton.plainTitle, changesButton.plainTitle))
    }

    // MARK: Actions

    private func choose(_ change: (inout ReviewChoice) -> Void) {
        var c = reviewChoice(repoRoot: repoPath)
        change(&c)
        review?.setChoice(c)
        refreshTitles()
    }

    @objc private func pickBranchMode(_ sender: NSMenuItem) { choose { $0.mode = .branch } }
    @objc private func pickUncommitted(_ sender: NSMenuItem) { choose { $0.mode = .uncommitted } }

    @objc private func pickBase(_ sender: NSMenuItem) {
        let b = sender.representedObject as? String ?? ""
        choose { $0.mode = .branch; $0.baseBranch = b.isEmpty ? nil : b }
    }

    @objc private func pickCommit(_ sender: NSMenuItem) {
        guard let sha = sender.representedObject as? String else { return }
        choose { $0.mode = .commit; $0.commit = sha }
    }

    @objc private func openRepo(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String, path != repoPath else { return }
        onOpenRepo?(path)
    }

    @objc func openFolder(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Review"
        panel.message = "Choose a git repository (or any folder inside one)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let root = RecentProjects.repoRoot(of: url.path) else { return NSSound.beep() }
        onOpenRepo?(root)
    }
}

/// Projects opened recently, most recent first.
enum RecentProjects {
    private static let key = "pairprogram.recentProjects"

    static var list: [String] {
        (UserDefaults.standard.stringArray(forKey: key) ?? []).filter { FileManager.default.fileExists(atPath: $0) }
    }

    static func add(_ path: String) {
        UserDefaults.standard.set(([path] + list.filter { $0 != path }).prefix(12).map { $0 }, forKey: key)
    }

    /// The repo containing `path`, via git.
    static func repoRoot(of path: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git", "-C", path, "rev-parse", "--show-toplevel"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        let root = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return p.terminationStatus == 0 ? root : nil
    }
}

/// A toolbar pill that opens a menu: icon, title (truncates), chevron — each
/// with room to breathe. NSPopUpButton's pull-down style has fixed insets and
/// ignores its font, so this draws its own content.
final class PickerButton: CapsuleButton {
    let pickerMenu = NSMenu()
    private(set) var plainTitle = ""
    var maxWidth: CGFloat = 300
    /// Toolbars measure an item once; the width follows the title from here.
    private lazy var width = widthAnchor.constraint(equalToConstant: 100)

    private static let font = NSFont.systemFont(ofSize: 11)
    private static let symbolConfig = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)

    init() {
        super.init(frame: .zero)
        // Draws its own capsule (CapsuleButton): the system toolbar capsule is
        // always full toolbar height, whatever the button's size.
        heightAnchor.constraint(equalToConstant: Self.height).isActive = true
        imagePosition = .imageTrailing
        imageHugsTitle = true
        lineBreakMode = .byTruncatingTail
        setContentCompressionResistancePriority(.defaultHigh, for: .horizontal) // full title, up to the width cap
        image = Self.padded("chevron.down", left: 5, right: 7, pointSize: 8.5) // chevron, clear of the pill's edge
        target = self
        action = #selector(open)
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(symbol: String, title: String) {
        plainTitle = title
        let s = NSMutableAttributedString()
        if let icon = Self.padded(symbol, left: 7, right: 5, color: .secondaryLabelColor) {
            let a = NSTextAttachment()
            a.image = icon
            a.bounds = NSRect(x: 0, y: -2, width: icon.size.width, height: icon.size.height) // on the text's midline
            s.append(NSAttributedString(attachment: a))
        }
        s.append(NSAttributedString(string: title, attributes: [.font: Self.font]))
        attributedTitle = s
        width.constant = min(maxWidth, ceil(cell!.cellSize.width) + 4)
        width.isActive = true
    }

    @objc private func open() {
        pickerMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 4), in: self)
    }

    /// An SF Symbol with `left`/`right` points of space around it, tinted like text.
    /// `color`: draw in that color (images inside a title aren't tinted by the button).
    static func padded(_ name: String, left: CGFloat, right: CGFloat, pointSize: CGFloat = 10.5, color: NSColor? = nil) -> NSImage? {
        var config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        if let color { config = config.applying(.init(paletteColors: [color])) }
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return nil }
        let size = NSSize(width: symbol.size.width + left + right, height: symbol.size.height)
        let image = NSImage(size: size, flipped: false) { _ in
            symbol.draw(in: NSRect(x: left, y: 0, width: symbol.size.width, height: symbol.size.height))
            return true
        }
        image.isTemplate = color == nil // the colored one resolves light/dark when drawn
        return image
    }
}
