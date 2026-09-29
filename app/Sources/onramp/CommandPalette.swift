import AppKit

/// ⌘P: go anywhere by typing. "#123" or "123" opens a pull request, a hash opens a
/// commit, "@name" lists someone's PRs and commits, anything else searches PRs,
/// commits, branches and commands. ↑↓ to choose, ↩ to go, Esc to close.
@MainActor
final class CommandPalette: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    struct Item {
        enum Kind: Int { case command, pr, commit, branch }
        let kind: Kind
        let title: String
        let subtitle: String
        let symbol: String
        /// Lowercased text the query matches against.
        let haystack: String
        let run: () -> Void
    }

    /// What the palette can do in the window it opened over.
    struct Actions {
        var openPR: (Int) -> Void
        var openCommit: (String) -> Void
        var switchBranch: (String) -> Void
        var commands: [(title: String, symbol: String, keys: String, run: () -> Void)]
    }

    static let shared = CommandPalette()

    private let panel: PalettePanel
    private let field = NSTextField()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let hint = NSTextField(labelWithString: "")
    private var items: [Item] = []
    private var repo = ""
    private var actions: Actions?
    private var prs: [GitHub.PRItem] = []
    private var commits: [CommitInfo] = []
    private var branches: [String] = []
    private var current: String?
    /// Why open PRs couldn't be listed (commits, branches and "#123" still work).
    private var prError: String?
    /// Open PRs per repo, fetched at most once a minute (the palette opens often).
    private var prCache: [String: (at: Date, prs: [GitHub.PRItem])] = [:]
    private static let width: CGFloat = 620, rowHeight: CGFloat = 42, maxRows = 9, fieldHeight: CGFloat = 48

    private override init() {
        panel = PalettePanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.fieldHeight),
                             styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: true)
        super.init()
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hidesOnDeactivate = true
        panel.onResign = { [weak self] in self?.close() }

        let bg = NSVisualEffectView()
        bg.material = .popover
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 12
        bg.layer?.masksToBounds = true
        bg.layer?.borderWidth = 1
        bg.layer?.borderColor = NSColor.separatorColor.cgColor
        panel.contentView = bg

        let glass = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)!)
        glass.symbolConfiguration = .init(pointSize: 15, weight: .regular)
        glass.contentTintColor = .secondaryLabelColor
        glass.frame = NSRect(x: 16, y: 0, width: 20, height: Self.fieldHeight)
        glass.autoresizingMask = [.minYMargin]
        bg.addSubview(glass)

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 18)
        field.placeholderString = "PR #, commit hash, @author, branch or command"
        field.delegate = self
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        bg.addSubview(field)

        let column = NSTableColumn(identifier: .init("item"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.style = .plain
        table.selectionHighlightStyle = .regular
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        bg.addSubview(scroll)

        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        bg.addSubview(hint)
    }

    var isShown: Bool { panel.isVisible }

    /// Open over `window` for `repo`. `current`: the PR on screen, if any.
    func show(over window: NSWindow, repo: String, current pr: Int?, actions: Actions) {
        self.repo = repo
        self.actions = actions
        current = pr.map { "#\($0)" }
        commits = (try? recentCommits(repoRoot: repo, limit: 400)) ?? []
        let status = try? branchStatus(repoRoot: repo)
        branches = ((try? listBranches(repoRoot: repo)) ?? []).filter { !$0.hasPrefix("origin/") && $0 != status?.branch }
        prs = prCache[repo]?.prs ?? []
        if prCache[repo].map({ Date().timeIntervalSince($0.at) > 60 }) ?? true { loadPRs() }
        field.stringValue = ""
        refilter()
        let top = window.frame.maxY - min(140, window.frame.height * 0.18)
        panel.setFrameTopLeftPoint(NSPoint(x: window.frame.midX - Self.width / 2, y: top))
        window.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    func close() {
        guard panel.isVisible else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    private func loadPRs() {
        let repo = self.repo
        prError = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                try GitHub.listAll(repo: repo, max: 100) { soFar in // each page as it lands: the first in ~2 s
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.repo == repo, soFar.count > self.prs.count else { return }
                        self.prs = soFar
                        if self.panel.isVisible { self.refilter() }
                    }
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                switch result {
                case let .success(list):
                    self.prCache[repo] = (Date(), list)
                    guard self.repo == repo else { return }
                    self.prs = list
                case let .failure(e):
                    guard self.repo == repo else { return }
                    self.prError = "\(e)"
                }
                if self.panel.isVisible { self.refilter() }
            }
        }
    }

    // MARK: Matching

    private static let ago: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    private func prItem(_ p: GitHub.PRItem) -> Item {
        Item(kind: .pr, title: "#\(p.number)  \(p.title)", subtitle: "@\(p.author) · \(p.headRefName) · \(Self.ago.localizedString(for: p.updatedAt, relativeTo: Date()))",
             symbol: p.isDraft ? "circle.dashed" : "arrow.triangle.pull", haystack: "#\(p.number) \(p.title) @\(p.author) \(p.headRefName)".lowercased()) { [weak self] in
            self?.actions?.openPR(p.number)
        }
    }

    private func commitItem(_ c: CommitInfo) -> Item {
        let when = Self.ago.localizedString(for: Date(timeIntervalSince1970: TimeInterval(c.time)), relativeTo: Date())
        return Item(kind: .commit, title: "\(c.short)  \(c.summary)", subtitle: "\(c.author) · \(when)", symbol: "smallcircle.filled.circle",
                    haystack: "\(c.sha) \(c.summary) @\(c.author)".lowercased()) { [weak self] in self?.actions?.openCommit(c.sha) }
    }

    private func branchItem(_ b: String) -> Item {
        Item(kind: .branch, title: b, subtitle: "Switch to this branch", symbol: "arrow.triangle.branch", haystack: "\(b) branch switch".lowercased()) { [weak self] in
            self?.actions?.switchBranch(b)
        }
    }

    private var commandItems: [Item] {
        (actions?.commands ?? []).map { c in
            Item(kind: .command, title: c.title, subtitle: c.keys, symbol: c.symbol, haystack: c.title.lowercased(), run: c.run)
        }
    }

    private func refilter() {
        let q = field.stringValue.trimmingCharacters(in: .whitespaces)
        items = Self.results(for: q, prs: prs, commits: commits, find: { [repo] in findCommit(repoRoot: repo, rev: $0) },
                             make: (prItem, commitItem, branchItem), branches: branches, commands: commandItems,
                             openNumber: { [weak self] n in Item(kind: .pr, title: "Open pull request #\(n)", subtitle: "Fetch it from GitHub",
                                                                   symbol: "arrow.triangle.pull", haystack: "") { self?.actions?.openPR(n) } })
        table.reloadData()
        if !items.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
        hint.stringValue = prError.map { "Pull requests: \($0)" }
            ?? (items.isEmpty ? (q.isEmpty ? "" : "Nothing matches \u{201C}\(q)\u{201D}") : "↑↓ to choose · ↩ to open · Esc to close")
        resize()
    }

    /// What to show for `q`. Pure apart from `find` (a git lookup), so it can be reasoned about on its own.
    static func results(for q: String, prs: [GitHub.PRItem], commits: [CommitInfo], find: (String) -> CommitInfo?,
                        make: ((GitHub.PRItem) -> Item, (CommitInfo) -> Item, (String) -> Item),
                        branches: [String], commands: [Item], openNumber: (Int) -> Item) -> [Item] {
        let lower = q.lowercased()
        if q.isEmpty {
            return Array(prs.prefix(6).map(make.0)) + Array(commits.prefix(4).map(make.1)) + commands
        }
        var out: [Item] = []
        // "#123" / "123": that PR, even if it isn't in the open list.
        if let n = Int(lower.hasPrefix("#") ? String(lower.dropFirst()) : lower), n > 0 {
            out += prs.first(where: { $0.number == n }).map { [make.0($0)] } ?? [openNumber(n)]
        }
        // A hash: that commit, wherever it is.
        if lower.range(of: "^[0-9a-f]{4,40}$", options: .regularExpression) != nil, let c = commits.first(where: { $0.sha.hasPrefix(lower) }) ?? find(lower) {
            out.append(make.1(c))
        }
        // "@name": their PRs, then their commits.
        if lower.hasPrefix("@") {
            let who = String(lower.dropFirst())
            out += prs.filter { who.isEmpty || $0.author.lowercased().hasPrefix(who) }.map(make.0)
            out += commits.filter { !who.isEmpty && $0.author.lowercased().contains(who) }.prefix(20).map(make.1)
            return out
        }
        // Everything else: every word has to appear; earlier and word-start matches rank higher.
        let words = lower.split(separator: " ").map(String.init)
        func score(_ item: Item) -> Int? {
            var total = 0
            for w in words {
                guard let r = item.haystack.range(of: w) else { return nil }
                let at = item.haystack.distance(from: item.haystack.startIndex, to: r.lowerBound)
                let wordStart = at == 0 || " #@/-_".contains(item.haystack[item.haystack.index(before: r.lowerBound)])
                total += (wordStart ? 20 : 5) + max(0, 10 - at / 8)
            }
            return total
        }
        let pool = commands + prs.map(make.0) + branches.map(make.2) + commits.map(make.1)
        let ranked = pool.compactMap { item in score(item).map { (item, $0) } }
            .enumerated().sorted { ($0.element.1, -$0.offset) > ($1.element.1, -$1.offset) }.map(\.element.0)
        let seen = Set(out.map(\.title))
        return out + ranked.filter { !seen.contains($0.title) }.prefix(40)
    }

    private func resize() {
        let rows = CGFloat(min(items.count, Self.maxRows))
        let listHeight = rows * Self.rowHeight + (items.isEmpty ? 0 : 4)
        let hintHeight: CGFloat = hint.stringValue.isEmpty ? 0 : 24
        let h = Self.fieldHeight + listHeight + hintHeight
        var f = panel.frame
        f.origin.y += f.height - h
        f.size.height = h
        panel.setFrame(f, display: true)
        field.frame = NSRect(x: 44, y: h - Self.fieldHeight + 12, width: Self.width - 60, height: 26)
        scroll.frame = NSRect(x: 6, y: hintHeight, width: Self.width - 12, height: listHeight)
        scroll.isHidden = items.isEmpty
        hint.frame = NSRect(x: 16, y: 5, width: Self.width - 32, height: 16)
        table.tableColumns.first?.width = scroll.contentSize.width
    }

    /// Self-test: type `text`, get the titles shown.
    func typeForTests(_ text: String) -> [String] {
        field.stringValue = text
        refilter()
        return items.map(\.title)
    }

    // MARK: Keys

    func controlTextDidChange(_ obj: Notification) { refilter() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): move(1)
        case #selector(NSResponder.moveUp(_:)): move(-1)
        case #selector(NSResponder.insertNewline(_:)): runSelected()
        case #selector(NSResponder.cancelOperation(_:)): close()
        default: return false
        }
        return true
    }

    private func move(_ by: Int) {
        guard !items.isEmpty else { return }
        let row = max(0, min(items.count - 1, table.selectedRow + by))
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    private func runSelected() {
        guard items.indices.contains(table.selectedRow) else { return NSSound.beep() }
        let item = items[table.selectedRow]
        close()
        item.run()
    }

    @objc private func clicked() { runSelected() }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = (tableView.makeView(withIdentifier: .init("row"), owner: nil) as? PaletteRow) ?? PaletteRow()
        cell.identifier = .init("row")
        let item = items[row]
        cell.set(item, current: item.kind == .pr && current.map { item.title.hasPrefix($0 + " ") } == true)
        return cell
    }
}

/// One result: a symbol, the title, and a quieter line under it.
private final class PaletteRow: NSTableCellView {
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        icon.symbolConfiguration = .init(pointSize: 13, weight: .medium)
        icon.contentTintColor = .secondaryLabelColor
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingMiddle
        for v in [icon, title, subtitle] { addSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(_ item: CommandPalette.Item, current: Bool) {
        icon.image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil)
        title.stringValue = item.title
        subtitle.stringValue = current ? "On screen now · " + item.subtitle : item.subtitle
        subtitle.isHidden = item.subtitle.isEmpty
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        icon.frame = NSRect(x: 12, y: (bounds.height - 18) / 2, width: 18, height: 18)
        if subtitle.isHidden {
            title.frame = NSRect(x: 40, y: (bounds.height - 17) / 2, width: w - 52, height: 17)
        } else {
            title.frame = NSRect(x: 40, y: bounds.height / 2, width: w - 52, height: 17)
            subtitle.frame = NSRect(x: 40, y: bounds.height / 2 - 16, width: w - 52, height: 15)
        }
    }
}

/// A borderless panel that can take typing, and closes when you click away.
private final class PalettePanel: NSPanel {
    var onResign: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func resignKey() {
        super.resignKey()
        onResign?()
    }
}
