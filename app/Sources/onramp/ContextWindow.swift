import AppKit
import UniformTypeIdentifiers

/// Review context: files and folders agents read before working on your
/// comments (standards, guidelines, background). Each source is either this
/// repo's (kept in the git dir, never committed) or yours for all repos.
@MainActor
final class ContextWindowController: NSWindowController, NSWindowDelegate {
    private struct Entry {
        var source: ContextSource
        var scope: ContextScope
    }

    private let repo: String
    private var entries: [Entry] = []
    private let list = DropList()
    private let scroll = NSScrollView()
    private let summary = NSTextField(labelWithString: "")
    private let empty = NSTextField(wrappingLabelWithString: "")
    /// Called after every change (the toolbar shows the count).
    var onChange: ((Int) -> Void)?

    init(repo: String) {
        self.repo = repo
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 440),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = "Review Context — \((repo as NSString).lastPathComponent)"
        panel.minSize = NSSize(width: 460, height: 300)
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        panel.delegate = self
        buildUI()
        load()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Enabled sources in both scopes (for the toolbar count).
    static func enabledCount(repo: String) -> Int {
        let config = onrampConfigDir.path
        return (contextSources(repoRoot: repo, configDir: config, scope: .repo) + contextSources(repoRoot: repo, configDir: config, scope: .global))
            .filter(\.enabled).count
    }

    // MARK: UI

    private func buildUI() {
        guard let content = window?.contentView else { return }
        let title = NSTextField(labelWithString: "Review context")
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        let note = NSTextField(wrappingLabelWithString:
            "Files agents read before working on your comments: review standards, guidelines, background. Folders include their text files. “This repo” sources stay in the repo's git folder (never committed); “All repos” ones apply everywhere.")
        note.font = .systemFont(ofSize: 12)
        note.textColor = .secondaryLabelColor

        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.documentView = list
        list.onDrop = { [weak self] urls in self?.add(urls) }
        // Rows are sized to the list's width: lay out again whenever it has one (first show, resize).
        scroll.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layoutRows() }
        }
        empty.stringValue = "No context yet. Add a file or folder, or drop some here."
        empty.font = .systemFont(ofSize: 12)
        empty.textColor = .tertiaryLabelColor
        empty.alignment = .center

        let add = NSButton(title: "Add Files or Folders…", target: self, action: #selector(addClicked))
        add.bezelStyle = .push
        add.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        add.imagePosition = .imageLeading
        summary.font = .systemFont(ofSize: 11.5)
        summary.textColor = .secondaryLabelColor
        summary.lineBreakMode = .byTruncatingTail

        let box = NSBox()
        box.boxType = .custom
        box.cornerRadius = 8
        box.borderColor = .separatorColor
        box.fillColor = .textBackgroundColor.withAlphaComponent(0.4)
        box.contentViewMargins = .zero

        for v in [title, note, box, scroll, empty, add, summary] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        summary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            note.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
            note.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            note.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            box.topAnchor.constraint(equalTo: note.bottomAnchor, constant: 14),
            box.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            box.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            box.bottomAnchor.constraint(equalTo: add.topAnchor, constant: -14),
            scroll.topAnchor.constraint(equalTo: box.topAnchor, constant: 1),
            scroll.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 1),
            scroll.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -1),
            scroll.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -1),
            empty.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            empty.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 20),
            empty.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -20),
            add.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            add.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            summary.leadingAnchor.constraint(greaterThanOrEqualTo: add.trailingAnchor, constant: 12),
            summary.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            summary.centerYAnchor.constraint(equalTo: add.centerYAnchor),
        ])
    }

    func windowDidResize(_ notification: Notification) { layoutRows() }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.contentView?.layoutSubtreeIfNeeded()
        layoutRows()
    }

    private func rebuild() {
        list.subviews.forEach { $0.removeFromSuperview() }
        for (i, e) in entries.enumerated() {
            let row = ContextRow(entry: e.source, scope: e.scope, displayPath: display(e), isDirectory: isDirectory(e))
            row.onToggle = { [weak self] on in self?.entries[i].source.enabled = on; self?.save() }
            row.onScope = { [weak self] scope in self?.setScope(i, scope) }
            row.onRemove = { [weak self] in self?.entries.remove(at: i); self?.save(); self?.rebuild() }
            list.addSubview(row)
        }
        empty.isHidden = !entries.isEmpty
        layoutRows()
        updateSummary()
    }

    private func layoutRows() {
        let width = scroll.contentSize.width
        var y: CGFloat = 0
        for row in list.subviews {
            row.frame = NSRect(x: 0, y: y, width: width, height: ContextRow.height)
            y += ContextRow.height
        }
        list.frame = NSRect(x: 0, y: 0, width: width, height: max(y, scroll.contentSize.height))
    }

    private func updateSummary() {
        let b = reviewContext(repoRoot: repo, configDir: onrampConfigDir.path)
        let kb = Double(b.files.reduce(0) { $0 + $1.bytes }) / 1000
        var text = b.files.isEmpty ? "Agents get nothing yet." : "Agents get \(b.files.count) file\(b.files.count == 1 ? "" : "s") · \(kb < 10 ? String(format: "%.1f", kb) : String(Int(kb))) KB"
        if !b.skipped.isEmpty { text += " · skipped \(b.skipped.count)" }
        summary.stringValue = text
        summary.toolTip = b.skipped.isEmpty ? b.files.map(\.path).joined(separator: "\n") : "Skipped:\n" + b.skipped.joined(separator: "\n")
        onChange?(entries.filter { $0.source.enabled }.count)
    }

    // MARK: Model

    private func load() {
        let config = onrampConfigDir.path
        entries = contextSources(repoRoot: repo, configDir: config, scope: .repo).map { Entry(source: $0, scope: .repo) }
            + contextSources(repoRoot: repo, configDir: config, scope: .global).map { Entry(source: $0, scope: .global) }
        rebuild()
    }

    private func save() {
        let config = onrampConfigDir.path
        for scope in [ContextScope.repo, .global] {
            try? setContextSources(repoRoot: repo, configDir: config, scope: scope, sources: entries.filter { $0.scope == scope }.map(\.source))
        }
        updateSummary()
    }

    private func absolute(_ e: Entry) -> String {
        e.source.path.hasPrefix("/") ? e.source.path : (repo as NSString).appendingPathComponent(e.source.path)
    }

    private func isDirectory(_ e: Entry) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: absolute(e), isDirectory: &dir) && dir.boolValue
    }

    private func display(_ e: Entry) -> String {
        let path = absolute(e)
        if path.hasPrefix(repo + "/") { return String(path.dropFirst(repo.count + 1)) }
        return (path as NSString).abbreviatingWithTildeInPath
    }

    /// Repo sources inside the repo are stored relative to it (they move with the checkout).
    private func stored(_ absolutePath: String, scope: ContextScope) -> String {
        scope == .repo && absolutePath.hasPrefix(repo + "/") ? String(absolutePath.dropFirst(repo.count + 1)) : absolutePath
    }

    private func setScope(_ i: Int, _ scope: ContextScope) {
        let path = absolute(entries[i])
        entries[i].scope = scope
        entries[i].source.path = stored(path, scope: scope)
        save()
        rebuild()
    }

    private func add(_ urls: [URL]) {
        let known = Set(entries.map(absolute))
        for url in urls where !known.contains(url.path) {
            // Inside the repo → this repo's; elsewhere (a private file) → yours for all repos.
            let scope: ContextScope = url.path.hasPrefix(repo + "/") ? .repo : .global
            entries.append(Entry(source: ContextSource(path: stored(url.path, scope: scope), enabled: true), scope: scope))
        }
        save()
        rebuild()
    }

    @objc private func addClicked() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose files or folders agents should read (e.g. review guidelines, architecture notes)"
        panel.directoryURL = URL(fileURLWithPath: repo)
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK else { return }
            MainActor.assumeIsolated { self?.add(panel.urls) }
        }
    }
}

/// The list: flipped, and accepts dropped files and folders.
private final class DropList: NSView {
    var onDrop: (([URL]) -> Void)?
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        onDrop?(urls)
        return !urls.isEmpty
    }
}

/// ☑ [icon] name / path          [This repo ▾]  ⊖
private final class ContextRow: NSView {
    static let height: CGFloat = 46
    var onToggle: ((Bool) -> Void)?
    var onScope: ((ContextScope) -> Void)?
    var onRemove: (() -> Void)?

    override var isFlipped: Bool { true }

    init(entry: ContextSource, scope: ContextScope, displayPath: String, isDirectory: Bool) {
        super.init(frame: .zero)
        let check = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggled(_:)))
        check.state = entry.enabled ? .on : .off
        let icon = NSImageView(image: NSImage(systemSymbolName: isDirectory ? "folder" : "doc.text", accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        let name = NSTextField(labelWithString: (displayPath as NSString).lastPathComponent)
        name.font = .systemFont(ofSize: 13, weight: .medium)
        name.lineBreakMode = .byTruncatingMiddle
        let path = NSTextField(labelWithString: displayPath)
        path.font = .systemFont(ofSize: 11)
        path.textColor = .secondaryLabelColor
        path.lineBreakMode = .byTruncatingHead
        let scopeMenu = NSPopUpButton(frame: .zero, pullsDown: false)
        scopeMenu.addItems(withTitles: ["This repo", "All repos"])
        scopeMenu.selectItem(at: scope == .repo ? 0 : 1)
        scopeMenu.controlSize = .small
        scopeMenu.font = .systemFont(ofSize: 11.5)
        scopeMenu.target = self
        scopeMenu.action = #selector(scopeChanged(_:))
        let remove = NSButton(image: NSImage(systemSymbolName: "minus.circle", accessibilityDescription: "Remove") ?? NSImage(), target: self, action: #selector(removed))
        remove.isBordered = false
        remove.contentTintColor = .secondaryLabelColor
        remove.toolTip = "Remove"

        let text = NSStackView(views: [name, path])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        for v in [check, icon, text, scopeMenu, remove] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            check.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            check.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.leadingAnchor.constraint(equalTo: check.trailingAnchor, constant: 6),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.trailingAnchor.constraint(lessThanOrEqualTo: scopeMenu.leadingAnchor, constant: -10),
            remove.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            remove.centerYAnchor.constraint(equalTo: centerYAnchor),
            scopeMenu.trailingAnchor.constraint(equalTo: remove.leadingAnchor, constant: -8),
            scopeMenu.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        alphaValue = entry.enabled ? 1 : 0.55
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: 12, y: bounds.height - 1, width: bounds.width - 24, height: 1).fill()
    }

    @objc private func toggled(_ sender: NSButton) {
        alphaValue = sender.state == .on ? 1 : 0.55
        onToggle?(sender.state == .on)
    }

    @objc private func scopeChanged(_ sender: NSPopUpButton) { onScope?(sender.indexOfSelectedItem == 0 ? .repo : .global) }
    @objc private func removed() { onRemove?() }
}
