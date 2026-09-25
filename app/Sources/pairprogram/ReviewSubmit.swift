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
        "mcp__plugin_pairprogram_pairprogram__resolve_comment", "mcp__plugin_pairprogram_pairprogram__claim_comment",
        "mcp__plugin_pairprogram_pairprogram__release_comment",
        "mcp__pairprogram__list_comments", "mcp__pairprogram__reply_to_comment", "mcp__pairprogram__resolve_comment",
        "mcp__pairprogram__claim_comment", "mcp__pairprogram__release_comment", "mcp__pairprogram__get_review_context",
        "mcp__plugin_pairprogram_pairprogram__get_review_context",
    ].joined(separator: ",")

    /// The shell command for a run. `resume`: the session to continue (the
    /// one a previous run of ours recorded, never one of your own sessions).
    static func command(_ target: Target, prompt: String, resume: String?, newSession: String) -> String? {
        let q = "'" + prompt.replacingOccurrences(of: "'", with: "'\\''") + "'"
        switch target {
        case .claude:
            let session = resume.map { "--resume \($0)" } ?? "--session-id \(newSession)"
            return "claude -p \(q) \(session) --permission-mode acceptEdits --allowedTools '\(claudeTools)'"
        case .codex:
            if let resume { return "codex exec resume \(resume) -c sandbox_mode='\"workspace-write\"' \(q)" }
            return "codex exec --sandbox workspace-write --approve-for-me \(q)"
        case .none: return nil
        }
    }

    // MARK: Sessions

    /// "Continue each agent's last session" (per repo).
    static func continuesSession(repo: String) -> Bool { UserDefaults.standard.bool(forKey: "pairprogram.continueSession." + repo) }
    static func setContinuesSession(_ on: Bool, repo: String) { UserDefaults.standard.set(on, forKey: "pairprogram.continueSession." + repo) }

    private static func sessionKey(_ target: Target, _ repo: String) -> String { "pairprogram.session.\(target.rawValue)." + repo }
    static func lastSession(_ target: Target, repo: String) -> String? { UserDefaults.standard.string(forKey: sessionKey(target, repo)) }
    private static func remember(_ id: String, _ target: Target, repo: String) { UserDefaults.standard.set(id, forKey: sessionKey(target, repo)) }

    func run(_ target: Target, repo: String) {
        guard process == nil else { return }
        let wanted = Self.continuesSession(repo: repo) ? Self.lastSession(target, repo: repo) : nil
        let fresh = UUID().uuidString.lowercased()
        guard let command = Self.command(target, prompt: MCPServer.addressPrompt, resume: wanted, newSession: fresh) else { return }
        if target == .claude { Self.remember(wanted ?? fresh, target, repo: repo) } // we chose the id up front
        let log = (try? commentsPath(repoRoot: repo)).map { URL(fileURLWithPath: $0).deletingLastPathComponent().appendingPathComponent("agent-run-\(target.rawValue).log") }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("pairprogram-agent-run-\(target.rawValue).log")
        logURL = log
        let note = Self.continuesSession(repo: repo) && wanted == nil ? "# no earlier session to continue: starting a new one\n" : ""
        FileManager.default.createFile(atPath: log.path, contents: Data("\(note)$ \(command)\n\n".utf8))
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
                // Codex picks its own session id and prints it; keep it for "continue".
                if target == .codex, let text = try? String(contentsOf: log, encoding: .utf8),
                   let m = text.range(of: #"session id: [0-9a-f-]{36}"#, options: [.regularExpression, .caseInsensitive]) {
                    Self.remember(String(text[m].suffix(36)), target, repo: repo)
                }
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

    /// Agents to request a review from, remembered per repo (Claude Code the first time).
    static func savedTargets(repo: String) -> [Target] {
        guard let saved = UserDefaults.standard.string(forKey: "pairprogram.sendTo." + repo) else { return [.claude] }
        return saved.split(separator: ",").compactMap { Target(rawValue: String($0)) }.filter { $0 != .none }
    }

    static func save(_ targets: [Target], repo: String) {
        UserDefaults.standard.set(targets.map(\.rawValue).joined(separator: ","), forKey: "pairprogram.sendTo." + repo)
    }
}

/// GitHub's "Finish your review": summary, verdict, and who to send it to.
final class ReviewSubmitViewController: NSViewController {
    private let summary = NSTextView()
    private var verdictButtons: [NSButton] = []
    private var agentBoxes: [(AgentRunner.Target, NSButton)] = []
    private let continueBox = NSButton(checkboxWithTitle: "Continue each agent's last session", target: nil, action: nil)
    private let pending: Int
    private let open: Int
    private let repo: String
    private let errorLabel = PopoverUI.note("", size: 11.5)

    var onSubmit: ((_ body: String, _ verdict: Verdict, _ targets: [AgentRunner.Target]) -> Void)?
    var onDiscard: (() -> Void)?

    private static let verdicts: [(Verdict, String, String)] = [
        (.comment, "Comment", "General feedback, nothing blocking."),
        (.approve, "Approve", "Good to go to a human reviewer."),
        (.requestChanges, "Request changes", "The agent should address these before this moves on."),
    ]

    init(pending: Int, open: Int, repo: String) {
        self.pending = pending
        self.open = open
        self.repo = repo
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let comments = { (n: Int) in n == 1 ? "1 comment" : "\(n) comments" }
        let subtitle = switch (pending, open) {
        case (0, 0): "No comments yet. You can still send a summary."
        case (0, _): "Your \(comments(open)) open go to the agent."
        default: "Publishes your \(pending) pending \(pending == 1 ? "comment" : "comments")" + (open > pending ? ", along with the \(comments(open - pending)) already posted." : ".")
        }
        let stack = PopoverUI.stack([])
        PopoverUI.add(PopoverUI.title("Finish your review"), to: stack, spacingAfter: 4)
        PopoverUI.add(PopoverUI.note(subtitle), to: stack, spacingAfter: 14)
        PopoverUI.add(summaryField(), to: stack, spacingAfter: 16)

        let initial = pending > 0 || open > 0 ? 2 : 0 // there's something to fix: request changes
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

        let sendLabel = NSTextField(labelWithString: "Request review from")
        sendLabel.font = .systemFont(ofSize: 13)
        let saved = AgentRunner.savedTargets(repo: repo)
        let boxes: [NSView] = AgentRunner.Target.allCases.filter { $0 != .none }.map { target in
            let box = NSButton(checkboxWithTitle: target.title, target: nil, action: nil)
            box.state = saved.contains(target) ? .on : .off
            agentBoxes.append((target, box))
            return box
        }
        PopoverUI.add(PopoverUI.row([sendLabel], boxes, spacing: 14), to: stack, spacingAfter: 4)
        PopoverUI.add(PopoverUI.note("Checked agents start on it right away, side by side; each claims different comments.", size: 11), to: stack, spacingAfter: 10)
        continueBox.state = AgentRunner.continuesSession(repo: repo) ? .on : .off
        continueBox.font = .systemFont(ofSize: 12)
        continueBox.toolTip = "On: each agent picks up its previous review session, keeping what it learned. Off: a fresh session every time."
        PopoverUI.add(continueBox, to: stack, spacingAfter: 18)

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
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true
        PopoverUI.add(errorLabel, to: stack, spacingAfter: 10)
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
        let targets = agentBoxes.filter { $0.1.state == .on }.map(\.0)
        AgentRunner.save(targets, repo: repo)
        AgentRunner.setContinuesSession(continueBox.state == .on, repo: repo)
        onSubmit?(summary.string.trimmingCharacters(in: .whitespacesAndNewlines), Self.verdicts[i].0, targets)
    }

    /// Show why submitting didn't work, in the popover.
    func show(error: String) {
        errorLabel.stringValue = error
        errorLabel.isHidden = false
        view.layoutSubtreeIfNeeded()
        preferredContentSize = view.fittingSize
    }

    @objc private func cancelClicked() { view.window?.performClose(nil) }
    @objc private func discardClicked() { onDiscard?() }
}
