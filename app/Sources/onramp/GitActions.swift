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

        pushAfter.state = UserDefaults.standard.bool(forKey: "onramp.pushAfterCommit") ? .on : .off
        pushAfter.title = status.upstream == nil ? "Publish the branch after committing" : "Push after committing"
        PopoverUI.add(pushAfter, to: stack, spacingAfter: 10)
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true
        PopoverUI.add(errorLabel, to: stack, spacingAfter: 10)

        let commit = NSButton(title: "Commit", target: self, action: #selector(commitClicked))
        commit.bezelStyle = .push
        commit.keyEquivalent = "\r"
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
