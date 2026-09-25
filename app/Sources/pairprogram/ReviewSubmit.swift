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
    private let verdict = NSSegmentedControl(labels: ["Comment", "Approve", "Request changes"], trackingMode: .selectOne, target: nil, action: nil)
    private let sendTo = NSPopUpButton()
    private let pending: Int
    private let repo: String

    var onSubmit: ((_ body: String, _ verdict: Verdict, _ target: AgentRunner.Target) -> Void)?
    var onDiscard: (() -> Void)?

    init(pending: Int, repo: String) {
        self.pending = pending
        self.repo = repo
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let width: CGFloat = 420
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)

        let title = NSTextField(labelWithString: "Finish your review")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        stack.addArrangedSubview(title)

        let info = NSTextField(labelWithString: pending == 1 ? "1 pending comment will be published." : "\(pending) pending comments will be published.")
        info.font = .systemFont(ofSize: 11.5)
        info.textColor = .secondaryLabelColor
        stack.addArrangedSubview(info)

        summary.isRichText = false
        summary.font = .systemFont(ofSize: 12.5)
        summary.textContainerInset = NSSize(width: 4, height: 6)
        summary.isVerticallyResizable = true
        summary.autoresizingMask = [.width]
        summary.setAccessibilityPlaceholderValue("Leave a summary (optional)")
        let scroll = NSScrollView()
        scroll.documentView = summary
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.widthAnchor.constraint(equalToConstant: width).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 90).isActive = true
        stack.addArrangedSubview(scroll)

        verdict.selectedSegment = pending > 0 ? 2 : 0
        stack.addArrangedSubview(verdict)

        let sendLabel = NSTextField(labelWithString: "Send to agent:")
        sendLabel.font = .systemFont(ofSize: 12)
        sendTo.addItems(withTitles: AgentRunner.Target.allCases.map(\.title))
        sendTo.selectItem(at: AgentRunner.Target.allCases.firstIndex(of: AgentRunner.savedTarget(repo: repo)) ?? 0)
        let sendRow = NSStackView(views: [sendLabel, sendTo])
        sendRow.spacing = 8
        stack.addArrangedSubview(sendRow)

        let discard = NSButton(title: "Discard pending", target: self, action: #selector(discardClicked))
        discard.bezelStyle = .rounded
        discard.isHidden = pending == 0
        let submit = NSButton(title: "Submit review", target: self, action: #selector(submitClicked))
        submit.bezelStyle = .rounded
        submit.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [discard, spacer, submit])
        buttons.widthAnchor.constraint(equalToConstant: width).isActive = true
        stack.addArrangedSubview(buttons)

        view = stack
        preferredContentSize = stack.fittingSize
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(summary)
    }

    @objc private func submitClicked() {
        let v: Verdict = switch verdict.selectedSegment {
        case 1: .approve
        case 2: .requestChanges
        default: .comment
        }
        let target = AgentRunner.Target.allCases[max(0, sendTo.indexOfSelectedItem)]
        AgentRunner.save(target, repo: repo)
        onSubmit?(summary.string.trimmingCharacters(in: .whitespacesAndNewlines), v, target)
    }

    @objc private func discardClicked() { onDiscard?() }
}
