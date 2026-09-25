import AppKit

/// Sizes of comment boxes. Layout rows and the views use the same functions,
/// so a box always fits its row exactly.
enum CommentMetrics {
    /// Set by the review to fit its width.
    nonisolated(unsafe) static var boxWidth: CGFloat = 700
    static let margin: CGFloat = 6   // space above/below a box inside its row
    static let padding: CGFloat = 10
    static let footerHeight: CGFloat = 30
    static let inputHeight: CGFloat = 64

    static var bodyFont: NSFont { .systemFont(ofSize: DiffStyle.font.pointSize) }
    static var metaFont: NSFont { .systemFont(ofSize: DiffStyle.font.pointSize - 1.5, weight: .semibold) }
    static var metaHeight: CGFloat { ceil(metaFont.ascender - metaFont.descender) + 3 }
    static var textWidth: CGFloat { boxWidth - 2 * padding }

    static var composerRowHeight: CGFloat { 2 * margin + 2 * padding + inputHeight + 6 + footerHeight }
    static var replyHeight: CGFloat { inputHeight + 6 + footerHeight }

    static func body(_ s: String) -> NSAttributedString {
        NSAttributedString(string: s.trimmingCharacters(in: .whitespacesAndNewlines), attributes: [.font: bodyFont, .foregroundColor: DiffStyle.text])
    }

    static func bodyHeight(_ s: String) -> CGFloat {
        ceil(body(s).boundingRect(with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
                                  options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
    }

    static func hasBanner(_ t: LocatedThread) -> Bool { t.line == nil || t.thread.status == .resolved }

    static func threadRowHeight(_ t: LocatedThread, replying: Bool, editing: Int? = nil) -> CGFloat {
        var h = 2 * margin + 2 * padding
        if hasBanner(t) { h += metaHeight + 4 }
        for (k, e) in t.thread.entries.enumerated() { h += metaHeight + (k == editing ? replyHeight : bodyHeight(e.body)) + 8 }
        return h + (replying ? replyHeight : editing != nil ? 0 : footerHeight) // no buttons while editing
    }
}

/// Text input for comments: ⌘↩ submits, Esc cancels.
final class CommentTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onCancel: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36, event.modifierFlags.contains(.command) { return onSubmit?() ?? () } // ⌘↩
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// A rounded box with a text input and Cancel / submit buttons.
final class CommentInput: NSView {
    let textView = CommentTextView()
    private let scroll = NSScrollView()
    private let cancel = NSButton(title: "Cancel", target: nil, action: nil)
    private let submit: NSButton
    private let secondary = NSButton(title: "", target: nil, action: nil)
    private let hint = NSTextField(labelWithString: "⌘↩ to save · Esc to cancel")
    var onSubmit: ((String) -> Void)?
    var onSecondary: ((String) -> Void)?
    var onCancel: (() -> Void)?

    /// Primary (⌘↩) and optional second action, e.g. "Comment" + "Start a review".
    func setActions(primary: String, secondary title: String?) {
        submit.title = primary
        secondary.title = title ?? ""
        secondary.isHidden = title == nil
        hint.stringValue = "⌘↩ \(primary.lowercased()) · Esc to cancel"
        needsLayout = true
    }

    override var isFlipped: Bool { true }

    init(submitTitle: String, placeholder: String) {
        submit = NSButton(title: submitTitle, target: nil, action: nil)
        super.init(frame: .zero)
        textView.isRichText = false
        textView.font = CommentMetrics.bodyFont
        textView.textColor = DiffStyle.text
        textView.insertionPointColor = DiffStyle.caret
        textView.drawsBackground = true
        textView.backgroundColor = DiffStyle.background
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.setAccessibilityPlaceholderValue(placeholder)
        textView.onSubmit = { [weak self] in self?.fireSubmit() }
        textView.onCancel = { [weak self] in self?.onCancel?() }
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 4
        scroll.layer?.borderWidth = 1
        scroll.layer?.borderColor = DiffStyle.commentBorder.cgColor
        addSubview(scroll)

        for b in [cancel, secondary, submit] {
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.target = self
            addSubview(b)
        }
        cancel.action = #selector(cancelClicked)
        submit.action = #selector(submitClicked)
        secondary.action = #selector(secondaryClicked)
        secondary.isHidden = true
        submit.bezelColor = DiffStyle.accent
        submit.keyEquivalent = "" // ⌘↩ is handled by the text view
        hint.font = .systemFont(ofSize: 10.5)
        hint.textColor = DiffStyle.foldText
        addSubview(hint)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        scroll.frame = NSRect(x: 0, y: 0, width: bounds.width, height: CommentMetrics.inputHeight)
        textView.frame.size.width = scroll.contentSize.width
        let y = CommentMetrics.inputHeight + 6
        submit.sizeToFit(); cancel.sizeToFit(); secondary.sizeToFit()
        submit.frame.origin = NSPoint(x: bounds.width - submit.frame.width, y: y + 2)
        var left = submit.frame.minX
        if !secondary.isHidden {
            secondary.frame.origin = NSPoint(x: left - secondary.frame.width - 6, y: y + 2)
            left = secondary.frame.minX
        }
        cancel.frame.origin = NSPoint(x: left - cancel.frame.width - 6, y: y + 2)
        hint.sizeToFit()
        hint.frame.origin = NSPoint(x: 0, y: y + 7)
    }

    func focus() { window?.makeFirstResponder(textView) }

    @objc private func cancelClicked() { onCancel?() }
    @objc private func submitClicked() { fireSubmit() }
    @objc private func secondaryClicked() {
        let text = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return NSSound.beep() }
        onSecondary?(text)
    }

    private func fireSubmit() {
        let text = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return NSSound.beep() }
        onSubmit?(text)
    }
}

/// Box for writing a new comment under a line.
final class CommentComposerView: NSView {
    let input = CommentInput(submitTitle: "Comment", placeholder: "Leave a comment")

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(input)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let p = CommentMetrics.padding
        input.frame = bounds.insetBy(dx: p, dy: p)
    }

    override func draw(_ dirtyRect: NSRect) {
        drawBox(bounds, focused: true)
    }
}

/// A comment thread: entries, then Reply / Resolve / Delete (or a reply box).
final class CommentThreadView: NSView {
    private(set) var located: LocatedThread
    private(set) var replying: Bool
    private(set) var editing: Int?
    private let me: String
    private var pencils: [NSButton] = []
    private(set) var editInput: CommentInput?

    var onStartEdit: ((Int) -> Void)?
    var onSaveEdit: ((Int, String) -> Void)?
    var onCancelEdit: (() -> Void)?
    private let reply = NSButton(title: "Reply", target: nil, action: nil)
    private let resolve = NSButton(title: "Resolve", target: nil, action: nil)
    private let delete = NSButton(title: "", target: nil, action: nil)
    private(set) var replyInput: CommentInput?

    /// (text, pending): pending = part of the review in progress.
    var onReply: ((String, Bool) -> Void)?
    /// A review is in progress: new replies default to joining it.
    var inReview = false
    var onStartReply: (() -> Void)?
    var onCancelReply: (() -> Void)?
    var onToggleResolved: (() -> Void)?
    var onDelete: (() -> Void)?

    override var isFlipped: Bool { true }

    init(_ located: LocatedThread, replying: Bool, editing: Int?, me: String) {
        self.located = located
        self.replying = replying
        self.editing = nil
        self.me = me
        super.init(frame: .zero)
        wantsLayer = true
        for b in [reply, resolve] {
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.target = self
            addSubview(b)
        }
        reply.action = #selector(replyClicked)
        resolve.action = #selector(resolveClicked)
        delete.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Delete thread")
        delete.bezelStyle = .inline
        delete.isBordered = false
        delete.contentTintColor = DiffStyle.foldText
        delete.target = self
        delete.action = #selector(deleteClicked)
        delete.toolTip = "Delete thread"
        addSubview(delete)
        update(located, replying: replying, editing: editing)
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(_ located: LocatedThread, replying: Bool, editing: Int?) {
        self.located = located
        // One pencil per entry you wrote.
        pencils.forEach { $0.removeFromSuperview() }
        pencils = located.thread.entries.enumerated().compactMap { k, e in
            guard e.author == me, editing == nil else { return nil }
            let b = NSButton(image: NSImage(systemSymbolName: "pencil", accessibilityDescription: "Edit")!, target: self, action: #selector(pencilClicked(_:)))
            b.isBordered = false
            b.bezelStyle = .inline
            b.contentTintColor = DiffStyle.foldText
            b.tag = k
            b.toolTip = "Edit"
            addSubview(b)
            return b
        }
        if editing != self.editing {
            self.editing = editing
            editInput?.removeFromSuperview()
            editInput = nil
            if let k = editing, k < located.thread.entries.count {
                let input = CommentInput(submitTitle: "Save", placeholder: "Edit comment")
                input.textView.string = located.thread.entries[k].body
                input.onSubmit = { [weak self] text in self?.onSaveEdit?(k, text) }
                input.onCancel = { [weak self] in self?.onCancelEdit?() }
                addSubview(input)
                editInput = input
            }
        }
        resolve.title = located.thread.status == .resolved ? "Reopen" : "Resolve"
        if replying != self.replying || (replying && replyInput == nil) {
            self.replying = replying
            replyInput?.removeFromSuperview()
            replyInput = nil
            if replying {
                let input = CommentInput(submitTitle: "Reply", placeholder: "Reply")
                input.setActions(primary: inReview ? "Add to review" : "Reply", secondary: inReview ? "Reply now" : "Start a review")
                input.onSubmit = { [weak self] text in self?.onReply?(text, self?.inReview ?? false) }
                input.onSecondary = { [weak self] text in self?.onReply?(text, !(self?.inReview ?? false)) }
                input.onCancel = { [weak self] in self?.onCancelReply?() }
                addSubview(input)
                replyInput = input
            }
        }
        reply.isHidden = replying || editing != nil
        resolve.isHidden = replying || editing != nil
        delete.isHidden = replying || editing != nil
        needsLayout = true
        needsDisplay = true
    }

    private var footerTop: CGFloat {
        bounds.height - CommentMetrics.padding - (replying ? CommentMetrics.replyHeight : CommentMetrics.footerHeight)
    }

    /// y of each entry's meta line and body, top to bottom (shared by layout and draw).
    private func entryFrames() -> [(meta: CGFloat, body: CGFloat, height: CGFloat)] {
        var y = CommentMetrics.padding
        if CommentMetrics.hasBanner(located) { y += CommentMetrics.metaHeight + 4 }
        return located.thread.entries.enumerated().map { k, e in
            let meta = y
            let body = y + CommentMetrics.metaHeight
            let h = k == editing ? CommentMetrics.replyHeight : CommentMetrics.bodyHeight(e.body)
            y = body + h + 8
            return (meta, body, h)
        }
    }

    override func layout() {
        super.layout()
        let p = CommentMetrics.padding
        let frames = entryFrames()
        for b in pencils where b.tag < frames.count {
            b.frame = NSRect(x: bounds.width - p - 18, y: frames[b.tag].meta - 1, width: 18, height: 16)
        }
        if let input = editInput, let k = editing, k < frames.count {
            input.frame = NSRect(x: p, y: frames[k].body, width: bounds.width - 2 * p, height: CommentMetrics.replyHeight)
        }
        let y = footerTop
        if let input = replyInput {
            input.frame = NSRect(x: p, y: y, width: bounds.width - 2 * p, height: CommentMetrics.replyHeight)
        } else {
            reply.sizeToFit(); resolve.sizeToFit()
            reply.frame.origin = NSPoint(x: p, y: y + 6)
            resolve.frame.origin = NSPoint(x: reply.frame.maxX + 6, y: y + 6)
            delete.frame = NSRect(x: bounds.width - p - 20, y: y + 7, width: 20, height: 18)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let t = located.thread
        let resolved = t.status == .resolved
        drawBox(bounds, focused: false, dimmed: resolved)

        let p = CommentMetrics.padding
        var y = p
        let meta: [NSAttributedString.Key: Any] = [.font: CommentMetrics.metaFont, .foregroundColor: DiffStyle.foldText]
        if CommentMetrics.hasBanner(located) {
            var banner: [String] = []
            if resolved { banner.append("✓ Resolved" + (t.resolvedBy.map { " by \($0)" } ?? "")) }
            if located.line == nil { banner.append("Outdated: line \(t.anchor.line + 1) changed since this comment") }
            NSAttributedString(string: banner.joined(separator: " · "), attributes: meta).draw(at: NSPoint(x: p, y: y))
            y += CommentMetrics.metaHeight + 4
        }
        let when = RelativeDateTimeFormatter()
        when.unitsStyle = .short
        for (k, e) in t.entries.enumerated() {
            let date = Date(timeIntervalSince1970: TimeInterval(e.createdAt))
            let head = NSMutableAttributedString(string: e.author, attributes: [.font: CommentMetrics.metaFont, .foregroundColor: DiffStyle.text])
            let now = Date()
            let ago = now.timeIntervalSince(date) < 45 ? "just now" : when.localizedString(for: date, relativeTo: now)
            head.append(NSAttributedString(string: "  " + ago, attributes: meta))
            if e.pending {
                head.append(NSAttributedString(string: "  Pending", attributes: [.font: CommentMetrics.metaFont, .foregroundColor: DiffStyle.accent]))
            }
            head.draw(at: NSPoint(x: p, y: y))
            y += CommentMetrics.metaHeight
            if k == editing { y += CommentMetrics.replyHeight + 8; continue } // the edit box is here
            let h = CommentMetrics.bodyHeight(e.body)
            CommentMetrics.body(e.body).draw(with: NSRect(x: p, y: y, width: CommentMetrics.textWidth, height: h),
                                             options: [.usesLineFragmentOrigin, .usesFontLeading])
            y += h + 8
        }
    }

    @objc private func pencilClicked(_ sender: NSButton) { onStartEdit?(sender.tag) }
    @objc private func replyClicked() { onStartReply?() }
    @objc private func resolveClicked() { onToggleResolved?() }
    @objc private func deleteClicked() { onDelete?() }
}

private extension NSView {
    func drawBox(_ rect: NSRect, focused: Bool, dimmed: Bool = false) {
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        DiffStyle.commentBackground.withAlphaComponent(dimmed ? 0.6 : 1).setFill()
        path.fill()
        (focused ? DiffStyle.accent : DiffStyle.commentBorder).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}
