import AppKit

/// Commit: a message, everything staged, optionally pushed right after.
final class CommitViewController: NSViewController {
    private let message = NSTextView()
    private let pushAfter = NSButton(checkboxWithTitle: "Push after committing", target: nil, action: nil)
    private let errorLabel = PopoverUI.note("", size: 11.5)
    private let status: BranchStatus
    /// Commit (and push?) — returns an error to show, or nil.
    var onCommit: ((_ message: String, _ push: Bool) -> String?)?

    init(status: BranchStatus) {
        self.status = status
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let stack = PopoverUI.stack([])
        PopoverUI.add(PopoverUI.title("Commit"), to: stack, spacingAfter: 4)
        let files = status.changed == 1 ? "1 changed file" : "\(status.changed) changed files"
        PopoverUI.add(PopoverUI.note("All \(files) on \(status.branch ?? "a detached HEAD"). Your git hooks run as usual."), to: stack, spacingAfter: 12)

        message.isRichText = false
        message.allowsUndo = true
        message.font = .systemFont(ofSize: 13)
        message.textContainerInset = NSSize(width: 6, height: 8)
        message.isVerticallyResizable = true
        message.autoresizingMask = [.width]
        message.textContainer?.widthTracksTextView = true
        message.drawsBackground = false
        message.setValue(NSAttributedString(string: "Commit message", attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.placeholderTextColor]),
                         forKey: "placeholderAttributedString")
        let scroll = NSScrollView()
        scroll.documentView = message
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 6
        scroll.layer?.borderWidth = 1
        scroll.layer?.borderColor = NSColor.separatorColor.cgColor
        scroll.heightAnchor.constraint(equalToConstant: 84).isActive = true
        PopoverUI.add(scroll, to: stack, spacingAfter: 10)

        pushAfter.state = (UserDefaults.standard.object(forKey: "onramp.pushAfterCommit") as? Bool ?? true) ? .on : .off
        pushAfter.title = status.upstream == nil ? "Publish the branch after committing" : "Push after committing"
        PopoverUI.add(pushAfter, to: stack, spacingAfter: 10)
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true
        PopoverUI.add(errorLabel, to: stack, spacingAfter: 10)

        let commit = NSButton(title: "Commit", target: self, action: #selector(commitClicked))
        commit.bezelStyle = .push
        commit.keyEquivalent = "\r"
        commit.bezelColor = DiffStyle.primaryButton
        commit.keyEquivalentModifierMask = [.command]
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancel.bezelStyle = .push
        cancel.keyEquivalent = "\u{1b}"
        PopoverUI.add(PopoverUI.row([PopoverUI.note("⌘↩ to commit", size: 11)], [cancel, commit]), to: stack)
        view = PopoverUI.container(stack)
        preferredContentSize = view.frame.size
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(message)
    }

    @objc private func commitClicked() {
        let text = message.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return show("Write a commit message first.") }
        UserDefaults.standard.set(pushAfter.state == .on, forKey: "onramp.pushAfterCommit")
        if let error = onCommit?(text, pushAfter.state == .on) { show(error) }
    }

    private func show(_ error: String) {
        errorLabel.stringValue = error
        errorLabel.isHidden = false
        view.layoutSubtreeIfNeeded()
        preferredContentSize = view.fittingSize
    }

    @objc private func cancelClicked() { view.window?.performClose(nil) }
}

/// Merge your own pull request: its checks, reviews and mergeability, the
/// merge method, and whether to delete the branch.
final class MergeViewController: NSViewController {
    private let info: GitHub.MergeInfo
    private let number: Int
    private let method = NSPopUpButton()
    private let deleteBranch = NSButton(checkboxWithTitle: "Delete the branch after merging", target: nil, action: nil)
    private let errorLabel = PopoverUI.note("", size: 11.5)
    private let mergeButton = NSButton(title: "Merge Pull Request", target: nil, action: nil)
    /// Merge — `done` gets an error to show, or nil.
    var onMerge: ((_ method: GitHub.MergeMethod, _ deleteBranch: Bool, _ done: @escaping (String?) -> Void) -> Void)?

    init(number: Int, info: GitHub.MergeInfo) {
        self.number = number
        self.info = info
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let stack = PopoverUI.stack([])
        PopoverUI.add(PopoverUI.title("Merge #\(number)"), to: stack, spacingAfter: 10)
        for (text, color) in statusLines() {
            let line = NSMutableAttributedString(string: "●  ", attributes: [.foregroundColor: color, .font: NSFont.systemFont(ofSize: 10)])
            line.append(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: NSColor.labelColor]))
            let label = NSTextField(labelWithAttributedString: line)
            PopoverUI.add(label, to: stack, spacingAfter: 6)
        }
        stack.setCustomSpacing(14, after: stack.arrangedSubviews.last!)
        method.addItems(withTitles: info.methods.map(\.title))
        let saved = UserDefaults.standard.string(forKey: "onramp.mergeMethod").flatMap(GitHub.MergeMethod.init(rawValue:))
        if let saved, let i = info.methods.firstIndex(of: saved) { method.selectItem(at: i) }
        let methodLabel = NSTextField(labelWithString: "Method")
        methodLabel.font = .systemFont(ofSize: 13)
        PopoverUI.add(PopoverUI.row([methodLabel], [method]), to: stack, spacingAfter: 10)
        deleteBranch.state = info.deleteBranchDefault || UserDefaults.standard.bool(forKey: "onramp.deleteBranchOnMerge") ? .on : .off
        PopoverUI.add(deleteBranch, to: stack, spacingAfter: 2)
        PopoverUI.add(PopoverUI.note("On GitHub, and locally too if you're on it (you're switched to the base branch).", size: 11), to: stack, spacingAfter: 12)
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true
        PopoverUI.add(errorLabel, to: stack, spacingAfter: 10)
        mergeButton.bezelStyle = .push
        mergeButton.keyEquivalent = "\r"
        mergeButton.bezelColor = DiffStyle.primaryButton
        mergeButton.target = self
        mergeButton.action = #selector(mergeClicked)
        mergeButton.isEnabled = canMerge && !info.methods.isEmpty
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancel.bezelStyle = .push
        cancel.keyEquivalent = "\u{1b}"
        PopoverUI.add(PopoverUI.row([], [cancel, mergeButton]), to: stack)
        view = PopoverUI.container(stack)
        preferredContentSize = view.frame.size
    }

    private var canMerge: Bool { info.state == "OPEN" && !info.isDraft && info.mergeable != "CONFLICTING" }

    private func statusLines() -> [(String, NSColor)] {
        var lines: [(String, NSColor)] = []
        if info.state != "OPEN" { lines.append(("This pull request is \(info.state.lowercased()).", .secondaryLabelColor)) }
        if info.isDraft { lines.append(("It's a draft: mark it ready for review on GitHub first.", .systemYellow)) }
        switch info.checks {
        case .passing: lines.append(("All checks passed", DiffStyle.addedAccent))
        case .failing: lines.append(("Some checks failed", DiffStyle.deletedAccent))
        case .pending: lines.append(("Checks are still running", .systemYellow))
        case .none: lines.append(("No checks", .tertiaryLabelColor))
        }
        switch info.review {
        case .approved: lines.append(("Approved", DiffStyle.addedAccent))
        case .changesRequested: lines.append(("Changes requested", DiffStyle.deletedAccent))
        case .required: lines.append(("Review required", .systemYellow))
        case .none: lines.append(("No review required", .tertiaryLabelColor))
        }
        switch info.mergeable {
        case "CONFLICTING": lines.append(("Has conflicts with the base branch", DiffStyle.deletedAccent))
        case "MERGEABLE" where info.mergeState == "BLOCKED": lines.append(("Blocked by branch protection (GitHub may refuse)", .systemYellow))
        case "MERGEABLE" where info.mergeState == "BEHIND": lines.append(("Behind the base branch", .systemYellow))
        case "MERGEABLE": lines.append(("No conflicts", DiffStyle.addedAccent))
        default: lines.append(("GitHub is still checking for conflicts", .tertiaryLabelColor))
        }
        return lines
    }

    @objc private func mergeClicked() {
        guard let window = view.window, method.indexOfSelectedItem >= 0 else { return }
        let m = info.methods[method.indexOfSelectedItem]
        let delete = deleteBranch.state == .on
        let alert = NSAlert()
        alert.messageText = "\(m.title) pull request #\(number)?"
        alert.informativeText = "This merges it on GitHub" + (delete ? " and deletes its branch." : ".") + " It can't be undone from here."
        alert.addButton(withTitle: "Merge")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            MainActor.assumeIsolated {
                UserDefaults.standard.set(m.rawValue, forKey: "onramp.mergeMethod")
                UserDefaults.standard.set(delete, forKey: "onramp.deleteBranchOnMerge")
                self.mergeButton.isEnabled = false
                self.mergeButton.title = "Merging…"
                self.onMerge?(m, delete) { [weak self] error in
                    guard let self, let error else { return }
                    self.mergeButton.isEnabled = true
                    self.mergeButton.title = "Merge Pull Request"
                    self.errorLabel.stringValue = error
                    self.errorLabel.isHidden = false
                    self.view.layoutSubtreeIfNeeded()
                    self.preferredContentSize = self.view.fittingSize
                }
            }
        }
    }

    @objc private func cancelClicked() { view.window?.performClose(nil) }
}

/// The bottom bar's Commit / Push button. While it works, a ring fills around
/// its icon (committing, then pushing), like AirDrop; then it turns into a check.
final class ShipButton: CapsuleButton {
    enum Phase: Equatable { case idle, committing, pushing, done, failed }
    private(set) var phase: Phase = .idle
    private let track = CAShapeLayer()
    private let ring = CAShapeLayer()
    private let mark = CAShapeLayer()
    private let badge = CALayer() // holds ring + mark, for the pop at the end
    private var creep: Timer?
    private var settle: DispatchWorkItem?
    private var idleTitle = ""
    private var idleSymbol: String?
    /// Back to showing what there is to do (after the check has had its moment).
    var onSettled: (() -> Void)?
    static let ringSize: CGFloat = 14

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for l in [track, ring, mark] {
            l.fillColor = nil
            l.lineCap = .round
            l.lineJoin = .round
            badge.addSublayer(l)
        }
        track.lineWidth = 2
        ring.lineWidth = 2
        ring.strokeEnd = 0
        mark.lineWidth = 1.8
        mark.strokeEnd = 0
        badge.isHidden = true
        layer?.addSublayer(badge)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let d = Self.ringSize
        badge.frame = CGRect(x: horizontalPadding - 3, y: (bounds.height - d) / 2, width: d, height: d)
        let circle = CGPath(ellipseIn: CGRect(x: 1, y: 1, width: d - 2, height: d - 2), transform: nil)
        track.path = circle
        // This layer's y runs down: from 12 o'clock, angles increasing = clockwise on screen.
        let arc = CGMutablePath()
        arc.addArc(center: CGPoint(x: d / 2, y: d / 2), radius: d / 2 - 1, startAngle: -.pi / 2, endAngle: 1.5 * .pi, clockwise: false)
        ring.path = arc
        let m = CGMutablePath()
        m.move(to: CGPoint(x: d * 0.29, y: d * 0.5))
        m.addLine(to: CGPoint(x: d * 0.44, y: d * 0.65))
        m.addLine(to: CGPoint(x: d * 0.72, y: d * 0.35))
        mark.path = m
    }

    /// Not working: what the click will do ("Commit 3", "Push 2", "Up to date").
    func setIdle(_ title: String, symbol: String?, enabled: Bool) {
        idleTitle = title
        idleSymbol = symbol
        guard phase == .idle else { return }
        isEnabled = enabled
        setText(title, symbol: symbol, color: enabled ? .labelColor : .secondaryLabelColor)
    }

    /// Committing (the ring's first third), pushing (the rest, creeping until git
    /// is done), done (full, then a check), failed (red).
    func run(_ phase: Phase, label: String) {
        self.phase = phase
        settle?.cancel()
        creep?.invalidate()
        isEnabled = true // full-strength label while it works; clicks wait for idle (see gitClicked)
        badge.isHidden = phase == .idle
        // Room for the ring before the label.
        attributedTitle = NSAttributedString(string: "\u{2007}\u{2007}\u{2007}" + label, attributes: [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .medium), .foregroundColor: phase == .failed ? NSColor.systemRed : NSColor.labelColor,
        ])
        let green = NSColor.systemGreen.cgColor
        track.strokeColor = NSColor.labelColor.withAlphaComponent(0.15).cgColor
        ring.strokeColor = phase == .failed ? NSColor.systemRed.cgColor : phase == .done ? green : NSColor.controlAccentColor.cgColor
        mark.strokeColor = green
        switch phase {
        case .idle:
            ring.strokeEnd = 0
            mark.strokeEnd = 0
            setIdle(idleTitle, symbol: idleSymbol, enabled: true)
        case .committing:
            mark.strokeEnd = 0
            fill(to: 0.35, duration: 0.5)
        case .pushing:
            fill(to: 0.5, duration: 0.3)
            // No real percentage from git: creep toward the end, slower and slower, until it answers.
            creep = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let now = self.ring.presentation()?.strokeEnd ?? self.ring.strokeEnd
                    self.fill(to: now + (0.92 - now) * 0.06, duration: 0.1)
                }
            }
        case .done:
            fill(to: 1, duration: 0.25)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.showCheck() }
            later(2.4)
        case .failed:
            ring.strokeEnd = 1
            later(4)
        }
        fit()
        superview?.needsLayout = true
        needsLayout = true
    }

    private func fill(to end: CGFloat, duration: CFTimeInterval) {
        let from = ring.presentation()?.strokeEnd ?? ring.strokeEnd
        let a = CABasicAnimation(keyPath: "strokeEnd")
        a.fromValue = from
        a.toValue = end
        a.duration = duration
        a.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ring.strokeEnd = end
        ring.add(a, forKey: "fill")
    }

    /// The check draws itself, and the badge pops.
    private func showCheck() {
        guard phase == .done else { return }
        let draw = CABasicAnimation(keyPath: "strokeEnd")
        draw.fromValue = 0
        draw.toValue = 1
        draw.duration = 0.25
        mark.strokeEnd = 1
        mark.add(draw, forKey: "draw")
        let pop = CAKeyframeAnimation(keyPath: "transform.scale")
        pop.values = [1, 1.3, 0.95, 1]
        pop.keyTimes = [0, 0.35, 0.7, 1]
        pop.duration = 0.4
        badge.add(pop, forKey: "pop")
    }

    private func later(_ seconds: Double) {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.run(.idle, label: "")
            self.onSettled?()
        }
        settle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}
