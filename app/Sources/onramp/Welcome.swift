import AppKit

/// First launch (nothing recent): what Onramp is, your repos, and a place to
/// paste a pull request link. Replaces a bare file picker.
@MainActor
final class WelcomeWindowController: NSWindowController {
    private let prField = NSTextField()
    private let error = NSTextField(labelWithString: "")
    var onOpenRepo: ((String) -> Void)?

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 560), styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        super.init(window: window)
        build()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        let icon = NSImageView()
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        let title = label("Welcome to Onramp", size: 22, weight: .semibold)
        let subtitle = label("Review your agent's changes and pull requests, and talk them through on the diff.", size: 13, color: .secondaryLabelColor)
        subtitle.alignment = .center
        subtitle.maximumNumberOfLines = 2
        subtitle.preferredMaxLayoutWidth = 400

        // 1. A pull request, by link.
        prField.placeholderString = "github.com/owner/repo/pull/123"
        prField.bezelStyle = .roundedBezel
        prField.controlSize = .large
        prField.font = .systemFont(ofSize: 13)
        prField.target = self
        prField.action = #selector(openPR)
        let open = NSButton(title: "Open", target: self, action: #selector(openPR))
        open.bezelStyle = .push
        open.controlSize = .large
        open.bezelColor = DiffStyle.primaryButton
        open.keyEquivalent = "\r"
        let prRow = NSStackView(views: [prField, open])
        prRow.spacing = 8
        error.font = .systemFont(ofSize: 11.5)
        error.textColor = .systemRed
        error.isHidden = true

        // 2. A repo you already have.
        let repos = NSStackView()
        repos.orientation = .vertical
        repos.alignment = .leading
        repos.spacing = 2
        let found = Clones.localRepos()
        for path in found {
            let b = RepoButton(path: path)
            b.target = self
            b.action = #selector(openRepo(_:))
            repos.addArrangedSubview(b)
            b.widthAnchor.constraint(equalToConstant: 420).isActive = true
        }
        if found.isEmpty { repos.addArrangedSubview(label("No repos found in ~/dev, ~/code or ~/src.", size: 12, color: .tertiaryLabelColor)) }
        let folder = NSButton(title: "Open Folder…", target: self, action: #selector(openFolder))
        folder.bezelStyle = .push

        let stack = NSStackView(views: [icon, title, subtitle,
                                        section("Review a pull request"), prRow, error,
                                        section("Or a repo on this Mac"), repos, folder])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.setCustomSpacing(12, after: icon)
        stack.setCustomSpacing(4, after: title)
        stack.setCustomSpacing(28, after: subtitle)
        stack.setCustomSpacing(26, after: prRow)
        stack.setCustomSpacing(26, after: error)
        stack.setCustomSpacing(12, after: repos)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 72), icon.heightAnchor.constraint(equalToConstant: 72),
            prRow.widthAnchor.constraint(equalToConstant: 420),
            prField.heightAnchor.constraint(equalToConstant: 28),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 44),
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -28),
        ])
        window?.contentView = content
        window?.setContentSize(NSSize(width: 520, height: min(720, 408 + CGFloat(max(1, found.count)) * 32)))
        window?.initialFirstResponder = prField
    }

    private func label(_ s: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: s)
        l.font = .systemFont(ofSize: size, weight: weight)
        l.textColor = color
        l.alignment = .center
        return l
    }

    /// A small uppercase heading, left-aligned with the content under it.
    private func section(_ s: String) -> NSView {
        let l = NSTextField(labelWithString: s.uppercased())
        l.font = .systemFont(ofSize: 10.5, weight: .semibold)
        l.textColor = .tertiaryLabelColor
        let row = NSStackView(views: [l])
        row.widthAnchor.constraint(equalToConstant: 420).isActive = true
        row.alignment = .leading
        row.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 0) // lines up with the repo names
        return row
    }

    /// github.com/owner/repo/pull/123 (with or without https://, or #fragments) → owner/repo, 123.
    static func parsePR(_ text: String) -> (slug: String, number: Int)? {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "/").map(String.init)
        guard let i = parts.firstIndex(where: { $0 == "pull" || $0 == "pulls" }), i >= 2, i + 1 < parts.count,
              let n = Int(parts[i + 1].prefix { $0.isNumber }) else { return nil }
        return ("\(parts[i - 2])/\(parts[i - 1])", n)
    }

    @objc private func openPR() {
        guard let (slug, n) = Self.parsePR(prField.stringValue),
              var c = URLComponents(string: "onramp://pr") else {
            error.stringValue = "Paste a pull request link, like github.com/owner/repo/pull/123"
            error.isHidden = false
            return
        }
        c.queryItems = [URLQueryItem(name: "repo", value: slug), URLQueryItem(name: "number", value: String(n))]
        guard let url = c.url, let app = NSApp.delegate as? AppDelegate else { return }
        close()
        DeepLinks.handle(url, app: app)
        if !app.hasWindows { showWindow(nil) } // it couldn't find or open the clone: back to here
    }

    @objc private func openRepo(_ sender: RepoButton) {
        close()
        onOpenRepo?(sender.path)
    }

    @objc private func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Review"
        panel.message = "Choose a git repository (or any folder inside one)"
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                guard let root = RecentProjects.repoRoot(of: url.path) else {
                    self?.error.stringValue = "That folder isn't in a git repository."
                    self?.error.isHidden = false
                    return
                }
                self?.close()
                self?.onOpenRepo?(root)
            }
        }
    }
}

/// A repo row: its name, and where it lives in grey. Hover highlights.
private final class RepoButton: NSButton {
    let path: String
    private var hovering = false { didSet { needsDisplay = true } }

    init(path: String) {
        self.path = path
        super.init(frame: .zero)
        isBordered = false
        title = ""
        let name = (path as NSString).lastPathComponent
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let place = (path as NSString).deletingLastPathComponent.replacingOccurrences(of: home, with: "~")
        let truncate = NSMutableParagraphStyle()
        truncate.lineBreakMode = .byTruncatingMiddle // a long folder shortens; it never runs off the row
        let s = NSMutableAttributedString(string: name, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.labelColor, .paragraphStyle: truncate])
        s.append(NSAttributedString(string: "  " + place, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: truncate]))
        attributedTitle = s
        alignment = .left
        heightAnchor.constraint(equalToConstant: 30).isActive = true
        toolTip = path
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func draw(_ dirtyRect: NSRect) {
        if hovering {
            DiffStyle.selection.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
        let h = attributedTitle.size().height
        attributedTitle.draw(with: NSRect(x: 10, y: (bounds.height - h) / 2, width: bounds.width - 20, height: h), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}
