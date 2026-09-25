import AppKit

/// The yield sign in the menu bar: what your agents are doing across your
/// recent projects. Outline when quiet, filled while an agent works, with a
/// dot when something is waiting on you. Click for the details.
@MainActor
final class MenuBarItem: NSObject, NSMenuDelegate {
    static let shared = MenuBarItem()

    /// One project's agent activity.
    struct Project {
        struct Agent { let name: String; let working: Bool; let file: String? }
        let root: String
        var agents: [Agent] = []
        var waiting = 0
        var finished: [(agent: String, ok: Bool)] = []
        var name: String { (root as NSString).lastPathComponent }
        var isWorking: Bool { agents.contains(where: \.working) }
        var needsYou: Bool { waiting > 0 || !finished.isEmpty }
        var isEmpty: Bool { agents.isEmpty && waiting == 0 && finished.isEmpty }
    }

    private var item: NSStatusItem?
    private var timer: Timer?
    private var projects: [Project] = []
    private var scanning = false
    /// git user.name per repo: threads whose last word isn't yours are waiting on you.
    private var authors: [String: String] = [:]
    /// A finished review run shows for this long.
    private static let finishedFor: TimeInterval = 15 * 60

    var isShown: Bool { item != nil }

    func start() {
        let env = ProcessInfo.processInfo.environment
        if Demo.isOn { return } // the installed app may already have one
        if let mode = env["ONRAMP_SELFTEST"] { if mode == "menubar" { runSelfTest() }; return } // tests don't touch your menu bar
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged), name: .styleChanged, object: nil)
        settingsChanged()
    }

    @objc private func settingsChanged() {
        let s = Style.shared.settings
        s.menuBar ? show() : hide()
        // No Dock icon only while the menu bar icon is there to come back from.
        let policy: NSApplication.ActivationPolicy = (s.dockIcon || !s.menuBar) ? .regular : .accessory
        if NSApp.activationPolicy() != policy {
            NSApp.setActivationPolicy(policy)
            if policy == .regular { NSApp.activate(ignoringOtherApps: true) } // its menus come back in front
        }
    }

    private func show() {
        guard item == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.icon(working: false, dot: false)
        item.button?.toolTip = "Onramp"
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        self.item = item
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            Task { @MainActor in MenuBarItem.shared.refresh() }
        }
    }

    private func hide() {
        guard let item else { return }
        NSStatusBar.system.removeStatusItem(item)
        self.item = nil
        timer?.invalidate()
        timer = nil
    }

    // MARK: Scanning

    /// Re-read every recent project's agent files off the main thread, then redraw the icon.
    func refresh(done: (() -> Void)? = nil) {
        guard !scanning else { return }
        scanning = true
        // Self-tests scan only the scratch repos they're given, never your real ones.
        let roots = ProcessInfo.processInfo.environment["ONRAMP_MENUBAR_REPOS"].map { $0.split(separator: ":").map(String.init) } ?? RecentProjects.list
        // Review runs started from open tabs (only the app knows about those).
        var finished: [String: [(String, Bool)]] = [:]
        for review in (NSApp.delegate as? AppDelegate)?.openReviews ?? [] {
            let recent = review.finishedRuns.filter { Date.now.timeIntervalSince($0.at) < Self.finishedFor }
            if !recent.isEmpty { finished[review.repoPath, default: []] += recent.map { ($0.agent, $0.ok) } }
        }
        let known = authors
        DispatchQueue.global(qos: .utility).async {
            var authors = known
            let projects = roots.map { root -> Project in
                if authors[root] == nil { authors[root] = ReviewDocumentView.gitUserName(root) ?? "you" }
                return Self.scan(root, me: authors[root]!, finished: finished[root] ?? [])
            }
            DispatchQueue.main.async {
                self.authors = authors
                self.projects = projects
                self.scanning = false
                self.redrawIcon()
                done?()
            }
        }
    }

    nonisolated private static func scan(_ root: String, me: String, finished: [(String, Bool)]) -> Project {
        var p = Project(root: root)
        let threads = (try? loadThreads(repoRoot: root)) ?? []
        var claims: [String: String] = [:] // agent → file it claimed
        for t in threads { if let c = activeClaim(thread: t) { claims[c.agent] = (t.path as NSString).lastPathComponent } }
        let sessions = ConnectedAgents.sessions(repoRoot: root)
        for name in Set(sessions.map(\.agent)).union(claims.keys).sorted() {
            let working = claims[name] != nil || sessions.contains { $0.agent == name && $0.isWorking }
            p.agents.append(.init(name: name, working: working, file: claims[name]))
        }
        p.waiting = threads.filter { t in
            guard t.status == .open, t.source == nil, activeClaim(thread: t) == nil,
                  let last = t.entries.last(where: { !$0.pending }) else { return false }
            return last.author != me
        }.count
        p.finished = finished
        return p
    }

    private func redrawIcon() {
        guard let button = item?.button else { return }
        let working = projects.contains(where: \.isWorking), dot = projects.contains(where: \.needsYou)
        button.image = Self.icon(working: working, dot: dot)
        let waiting = projects.reduce(0) { $0 + $1.waiting }
        button.toolTip = working ? "Onramp: an agent is working" : waiting > 0 ? "Onramp: \(waiting) waiting on you" : "Onramp"
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let active = projects.filter { !$0.isEmpty }
        if active.isEmpty {
            let quiet = menu.addItem(withTitle: "No agents working", action: nil, keyEquivalent: "")
            quiet.isEnabled = false
        }
        for (i, p) in active.enumerated() {
            if i > 0 { menu.addItem(.separator()) }
            let header = menu.addItem(withTitle: p.name, action: #selector(openProject(_:)), keyEquivalent: "")
            header.target = self
            header.representedObject = p.root
            header.attributedTitle = NSAttributedString(string: p.name, attributes: [.font: NSFont.menuFont(ofSize: 13).bold])
            header.toolTip = p.root
            for a in p.agents {
                let status = a.working ? (a.file.map { "working on \($0)" } ?? "working") : "connected"
                add(row(dot: AgentColor.of(a.name), a.name, status, dim: !a.working), to: menu, project: p.root)
            }
            if p.waiting > 0 {
                add(row(dot: nil, p.waiting == 1 ? "1 reply waiting on you" : "\(p.waiting) replies waiting on you", nil, dim: false), to: menu, project: p.root)
            }
            for f in p.finished {
                add(row(dot: nil, f.ok ? "✓ \(f.agent) finished its review" : "\(f.agent)'s review didn't finish", nil, dim: false), to: menu, project: p.root)
            }
        }
        menu.addItem(.separator())
        let recent = menu.addItem(withTitle: "Open Recent", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for root in RecentProjects.list {
            let it = sub.addItem(withTitle: (root as NSString).lastPathComponent, action: #selector(openProject(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = root
            it.toolTip = root
        }
        recent.submenu = sub
        recent.isEnabled = !sub.items.isEmpty
        menu.addItem(.separator())
        let updates = menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        updates.target = self
        let dock = menu.addItem(withTitle: "Hide Dock Icon", action: #selector(toggleDock), keyEquivalent: "")
        dock.target = self
        dock.state = Style.shared.settings.dockIcon ? .off : .on
        dock.toolTip = "Onramp lives in the menu bar only. While the Dock icon is hidden, open windows from here; the app menus (File, Edit…) aren't shown."
        let hide = menu.addItem(withTitle: "Hide Menu Bar Icon", action: #selector(hideIcon), keyEquivalent: "")
        hide.target = self
        hide.toolTip = "Show it again from View → Show Agents in Menu Bar (the Dock icon comes back if it was hidden)"
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "Quit Onramp", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
    }

    /// Menu bar only (no Dock icon), or both.
    @objc private func toggleDock() { Style.shared.update { $0.dockIcon.toggle() } }

    func menuWillOpen(_ menu: NSMenu) { refresh() } // fresh for next time; this open uses the last scan (≤ 3 s old)

    private func add(_ title: NSAttributedString, to menu: NSMenu, project: String) {
        let it = menu.addItem(withTitle: title.string, action: #selector(openProject(_:)), keyEquivalent: "")
        it.attributedTitle = title
        it.target = self
        it.representedObject = project
        it.indentationLevel = 1
    }

    /// "● claude  working on invoice.ts": a coloured dot, the agent, then its status in grey.
    private func row(dot: NSColor?, _ name: String, _ status: String?, dim: Bool) -> NSAttributedString {
        let font = NSFont.menuFont(ofSize: 13)
        let s = NSMutableAttributedString()
        if let dot { s.append(NSAttributedString(string: "●  ", attributes: [.font: NSFont.menuFont(ofSize: 9), .foregroundColor: dim ? dot.withAlphaComponent(0.45) : dot, .baselineOffset: 1.5])) }
        s.append(NSAttributedString(string: name, attributes: [.font: font, .foregroundColor: dim ? NSColor.secondaryLabelColor : NSColor.labelColor]))
        if let status { s.append(NSAttributedString(string: "  " + status, attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])) }
        return s
    }

    @objc private func openProject(_ sender: NSMenuItem) {
        guard let root = sender.representedObject as? String else { return }
        (NSApp.delegate as? AppDelegate)?.openProject(root)
    }

    @objc private func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        Updater.shared.checkInteractively()
    }

    @objc private func hideIcon() {
        Style.shared.update { $0.menuBar = false; $0.dockIcon = true } // never both hidden: there'd be no way back in
    }

    // MARK: Icon

    /// A template image (the menu bar tints it): a rounded yield triangle,
    /// filled while an agent works, with a dot when something needs you.
    static func icon(working: Bool, dot: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let top: CGFloat = 15, bottom: CGFloat = 2.5, left: CGFloat = 1.5, right: CGFloat = 16.5
            let pts = [NSPoint(x: left, y: top), NSPoint(x: right, y: top), NSPoint(x: (left + right) / 2, y: bottom)]
            let tri = NSBezierPath()
            tri.move(to: NSPoint(x: (left + right) / 2, y: top))
            for i in [1, 2, 0] { tri.appendArc(from: pts[i], to: pts[(i + 1) % 3], radius: 1.8) }
            tri.close()
            // The sign's inner triangle, like the white one on a real yield sign.
            let c = NSPoint(x: (left + right) / 2, y: 10.4), k: CGFloat = 0.42
            let inner = NSBezierPath()
            let q = pts.map { NSPoint(x: c.x + ($0.x - c.x) * k, y: c.y + ($0.y - c.y) * k) }
            inner.move(to: NSPoint(x: (q[0].x + q[1].x) / 2, y: q[0].y))
            for i in [1, 2, 0] { inner.appendArc(from: q[i], to: q[(i + 1) % 3], radius: 0.8) }
            inner.close()
            NSColor.black.set()
            if working {
                tri.fill() // an agent is working: solid
                if dot { // …and something's waiting on you: the inner triangle cut out
                    NSGraphicsContext.current?.compositingOperation = .clear
                    inner.fill()
                    NSGraphicsContext.current?.compositingOperation = .sourceOver
                }
            } else {
                tri.lineWidth = 1.6; tri.lineJoinStyle = .round; tri.stroke()
                if dot { inner.fill() } // waiting on you: the inner triangle fills in
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = working ? "Onramp: an agent is working" : dot ? "Onramp: waiting on you" : "Onramp"
        return image
    }

    // MARK: Self-test

    /// ONRAMP_SELFTEST=menubar: scan the recent projects (scratch config), log them, and render the icons.
    private func runSelfTest() {
        func log(_ s: String) { FileHandle.standardError.write("[selftest] \(s)\n".data(using: .utf8)!) }
        if let dir = ProcessInfo.processInfo.environment["ONRAMP_ICON_OUT"] {
            for (name, w, d) in [("idle", false, false), ("working", true, false), ("waiting", false, true), ("both", true, true)] {
                let img = Self.icon(working: w, dot: d)
                let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 72, pixelsHigh: 72, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                           isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                rep.size = NSSize(width: 18, height: 18)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                img.draw(in: NSRect(x: 0, y: 0, width: 18, height: 18))
                NSGraphicsContext.restoreGraphicsState()
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("menubar-\(name).png"))
            }
        }
        let t0 = CACurrentMediaTime()
        refresh {
            log(String(format: "scanned %d projects in %.1f ms", self.projects.count, (CACurrentMediaTime() - t0) * 1000))
            for p in self.projects {
                log("\(p.name): agents \(p.agents.map { "\($0.name)\($0.working ? "*" : "")\($0.file.map { "@" + $0 } ?? "")" }) waiting \(p.waiting) finished \(p.finished.count)")
            }
            let menu = NSMenu()
            self.menuNeedsUpdate(menu)
            log("menu: " + menu.items.map { $0.isSeparatorItem ? "—" : ($0.indentationLevel > 0 ? "  " : "") + $0.title }.joined(separator: " | "))
            log("done")
            NSApp.terminate(nil)
        }
    }
}

private extension NSFont {
    var bold: NSFont { NSFontManager.shared.convert(self, toHaveTrait: .boldFontMask) }
}
