import AppKit

/// Starts a coding agent in the background, in the repo, to address the review
/// you just submitted. Its fixes, replies and resolutions show up live in the
/// app (file watcher + comments watcher), and output goes to a log file.
@MainActor
final class AgentRunner {
    enum Target: String, CaseIterable {
        case claude, codex, none

        var title: String {
            switch self {
            case .claude: "Claude Code"
            case .codex: "Codex"
            case .none: "Don't send"
            }
        }
    }

    enum State: Equatable {
        case idle
        case running(Target)
        case finished(Target, ok: Bool)
    }

    private(set) var state: State = .idle { didSet { onChange?() } }
    private(set) var logURL: URL?
    var onChange: (() -> Void)?
    private var process: Process?

    /// The tools a headless Claude Code run may use without asking: read/edit
    /// code and answer comments. (Both plugin and plain MCP registrations.)
    private static let claudeTools = [
        "Read", "Edit", "Write", "Glob", "Grep",
        "mcp__plugin_pairprogram_pairprogram__list_comments", "mcp__plugin_pairprogram_pairprogram__reply_to_comment",
        "mcp__plugin_pairprogram_pairprogram__resolve_comment",
        "mcp__pairprogram__list_comments", "mcp__pairprogram__reply_to_comment", "mcp__pairprogram__resolve_comment",
    ].joined(separator: ",")

    static func command(_ target: Target, prompt: String) -> String? {
        let q = "'" + prompt.replacingOccurrences(of: "'", with: "'\\''") + "'"
        switch target {
        case .claude: return "claude -p \(q) --permission-mode acceptEdits --allowedTools '\(claudeTools)'"
        case .codex: return "codex exec --sandbox workspace-write --approve-for-me \(q)"
        case .none: return nil
        }
    }

    func run(_ target: Target, repo: String) {
        guard let command = Self.command(target, prompt: MCPServer.addressPrompt), process == nil else { return }
        let log = (try? commentsPath(repoRoot: repo)).map { URL(fileURLWithPath: $0).deletingLastPathComponent().appendingPathComponent("agent-run.log") }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("pairprogram-agent-run.log")
        logURL = log
        FileManager.default.createFile(atPath: log.path, contents: Data("$ \(command)\n\n".utf8))
        let handle = try? FileHandle(forWritingTo: log)
        handle?.seekToEndOfFile()

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", command] // login shell: same PATH as your terminal
        p.currentDirectoryURL = URL(fileURLWithPath: repo)
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = handle
        p.standardError = handle
        p.terminationHandler = { [weak self] proc in
            let ok = proc.terminationStatus == 0
            Task { @MainActor in
                try? handle?.close()
                self?.process = nil
                self?.state = .finished(target, ok: ok)
            }
        }
        do {
            try p.run()
            process = p
            state = .running(target)
        } catch {
            state = .finished(target, ok: false)
        }
    }

    static func savedTarget(repo: String) -> Target {
        Target(rawValue: UserDefaults.standard.string(forKey: "pairprogram.sendTo." + repo) ?? "") ?? .claude
    }

    static func save(_ target: Target, repo: String) {
        UserDefaults.standard.set(target.rawValue, forKey: "pairprogram.sendTo." + repo)
    }
}

/// GitHub's "Finish your review": summary, verdict, and who to send it to.
final class ReviewSubmitViewController: NSViewController {
    private let summary = NSTextView()
    private var verdictButtons: [NSButton] = []
    private let sendTo = NSPopUpButton()
    private let pending: Int
    private let repo: String

    var onSubmit: ((_ body: String, _ verdict: Verdict, _ target: AgentRunner.Target) -> Void)?
    var onDiscard: (() -> Void)?

    private static let verdicts: [(Verdict, String, String)] = [
        (.comment, "Comment", "General feedback, nothing blocking."),
        (.approve, "Approve", "Good to go to a human reviewer."),
        (.requestChanges, "Request changes", "The agent should address these before this moves on."),
    ]

    init(pending: Int, repo: String) {
        self.pending = pending
        self.repo = repo
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let subtitle = switch pending {
        case 0: "No pending comments. You can still leave a summary."
        case 1: "Publishes your 1 pending comment."
        default: "Publishes your \(pending) pending comments."
        }
        let stack = PopoverUI.stack([])
        PopoverUI.add(PopoverUI.title("Finish your review"), to: stack, spacingAfter: 4)
        PopoverUI.add(PopoverUI.note(subtitle), to: stack, spacingAfter: 14)
        PopoverUI.add(summaryField(), to: stack, spacingAfter: 16)

        let initial = pending > 0 ? 2 : 0
        for (i, (_, title, detail)) in Self.verdicts.enumerated() {
            let radio = NSButton(radioButtonWithTitle: title, target: self, action: #selector(verdictPicked(_:)))
            radio.font = .systemFont(ofSize: 13, weight: .medium)
            radio.tag = i
            radio.state = i == initial ? .on : .off
            verdictButtons.append(radio)
            let detailLabel = PopoverUI.note(detail, size: 11.5)
            let option = NSStackView(views: [radio, detailLabel])
            option.orientation = .vertical
            option.alignment = .leading
            option.spacing = 1
            detailLabel.leadingAnchor.constraint(equalTo: radio.leadingAnchor, constant: 20).isActive = true // under the title, past the circle
            PopoverUI.add(option, to: stack, spacingAfter: i == Self.verdicts.count - 1 ? 16 : 8)
        }

        PopoverUI.add(PopoverUI.separator(), to: stack, spacingAfter: 14)

        let sendLabel = NSTextField(labelWithString: "Then send it to")
        sendLabel.font = .systemFont(ofSize: 13)
        sendTo.addItems(withTitles: AgentRunner.Target.allCases.map(\.title))
        sendTo.selectItem(at: AgentRunner.Target.allCases.firstIndex(of: AgentRunner.savedTarget(repo: repo)) ?? 0)
        PopoverUI.add(PopoverUI.row([sendLabel], [sendTo]), to: stack, spacingAfter: 18)

        let submit = NSButton(title: "Submit review", target: self, action: #selector(submitClicked))
        submit.bezelStyle = .push
        submit.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancel.bezelStyle = .push
        cancel.keyEquivalent = "\u{1b}"
        var leading: [NSView] = []
        if pending > 0 {
            let discard = NSButton(title: "Discard pending", target: self, action: #selector(discardClicked))
            discard.bezelStyle = .push
            discard.contentTintColor = .systemRed
            leading.append(discard)
        }
        PopoverUI.add(PopoverUI.row(leading, [cancel, submit]), to: stack)

        view = PopoverUI.container(stack)
        preferredContentSize = view.frame.size
    }

    private func summaryField() -> NSView {
        summary.isRichText = false
        summary.allowsUndo = true
        summary.font = .systemFont(ofSize: 13)
        summary.textContainerInset = NSSize(width: 6, height: 8)
        summary.isVerticallyResizable = true
        summary.autoresizingMask = [.width]
        summary.textContainer?.widthTracksTextView = true
        summary.drawsBackground = false
        summary.setValue(NSAttributedString(string: "Leave a summary (optional)", attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.placeholderTextColor,
        ]), forKey: "placeholderAttributedString")
        let scroll = NSScrollView()
        scroll.documentView = summary
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 6
        scroll.layer?.borderWidth = 1
        scroll.layer?.borderColor = NSColor.separatorColor.cgColor
        scroll.heightAnchor.constraint(equalToConstant: 84).isActive = true
        return scroll
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(summary)
    }

    @objc private func verdictPicked(_ sender: NSButton) {
        for b in verdictButtons { b.state = b === sender ? .on : .off }
    }

    @objc private func submitClicked() {
        let i = verdictButtons.firstIndex { $0.state == .on } ?? 0
        let target = AgentRunner.Target.allCases[max(0, sendTo.indexOfSelectedItem)]
        AgentRunner.save(target, repo: repo)
        onSubmit?(summary.string.trimmingCharacters(in: .whitespacesAndNewlines), Self.verdicts[i].0, target)
    }

    @objc private func cancelClicked() { view.window?.performClose(nil) }
    @objc private func discardClicked() { onDiscard?() }
}
