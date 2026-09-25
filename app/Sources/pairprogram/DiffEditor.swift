import AppKit

// The editor holds the *real* file text. The diff is layered on top without
// touching that text:
//   - unchanged stretches are hidden (NSTextContentManagerDelegate.shouldEnumerate)
//   - deleted lines + fold markers are drawn in paragraph spacing (DiffLayoutFragment)
//   - added lines get a background (DiffLayoutFragment)
// So typing edits the file directly, and undo is the file's undo.

/// Current look: font, metrics and theme colors. Set by `Style` (settings +
/// theme); everything that draws reads from here.
enum DiffStyle {
    nonisolated(unsafe) static var font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
    nonisolated(unsafe) static var headerFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
    /// Measured from real TextKit layout (see `calibrate`), so heights computed
    /// without an editor match what the editor lays out.
    nonisolated(unsafe) static var lineHeight: CGFloat = 15
    /// How far line backgrounds paint to the right; set to the review's width.
    nonisolated(unsafe) static var paintWidth: CGFloat = 2000
    nonisolated(unsafe) static var foldHeight: CGFloat = 22
    static let contextLines = 3
    nonisolated(unsafe) static var gutterWidth: CGFloat = 52
    /// Base paragraph style for editor text.
    nonisolated(unsafe) static var baseParagraph = NSParagraphStyle()
    nonisolated(unsafe) static var lineNumberAttrs: [NSAttributedString.Key: Any] = [:]

    nonisolated(unsafe) static var background = NSColor.textBackgroundColor
    nonisolated(unsafe) static var text = NSColor.textColor
    nonisolated(unsafe) static var lineNumber = NSColor.tertiaryLabelColor
    nonisolated(unsafe) static var addedBackground = NSColor.systemGreen.withAlphaComponent(0.14)
    nonisolated(unsafe) static var deletedBackground = NSColor.systemRed.withAlphaComponent(0.14)
    nonisolated(unsafe) static var deletedText = NSColor.labelColor
    nonisolated(unsafe) static var foldBackground = NSColor.quaternaryLabelColor
    nonisolated(unsafe) static var foldText = NSColor.secondaryLabelColor
    nonisolated(unsafe) static var headerBackground = NSColor.windowBackgroundColor
    nonisolated(unsafe) static var headerText = NSColor.labelColor
    nonisolated(unsafe) static var separator = NSColor.separatorColor
    nonisolated(unsafe) static var caret = NSColor.controlAccentColor
    nonisolated(unsafe) static var currentLine = NSColor.clear
    nonisolated(unsafe) static var hover = NSColor.clear
    nonisolated(unsafe) static var commentBackground = NSColor.controlBackgroundColor
    nonisolated(unsafe) static var commentBorder = NSColor.separatorColor
    nonisolated(unsafe) static var accent = NSColor.controlAccentColor
    nonisolated(unsafe) static var isDark = true
    /// Resolved color per highlight kind (index into `Syntax.names`); nil = plain text.
    nonisolated(unsafe) static var syntaxColors: [NSColor?] = []
    static func syntaxColor(_ kind: Int) -> NSColor? { kind < syntaxColors.count ? syntaxColors[kind] : nil }

    @MainActor static func apply(theme: Theme, font newFont: NSFont, headerFont newHeaderFont: NSFont) {
        font = newFont
        headerFont = newHeaderFont
        let size = newFont.pointSize
        gutterWidth = ceil(size * 5) // room for the hover "+" left of the line number
        foldHeight = ceil(size * 1.76)
        baseParagraph = NSParagraphStyle() // no indent: the text view sits right of the gutter (EditorHost)

        isDark = theme.isDark
        background = theme.color("background")
        text = theme.color("text")
        lineNumber = theme.color("line_number")
        addedBackground = theme.color("added_background")
        deletedBackground = theme.color("deleted_background")
        deletedText = theme.color("deleted_text")
        foldBackground = theme.color("fold_background")
        foldText = theme.color("fold_text")
        headerBackground = theme.color("header_background")
        headerText = theme.color("header_text")
        separator = theme.color("separator")
        caret = theme.color("caret")
        currentLine = theme.color("current_line")
        hover = theme.color("hover")
        commentBackground = theme.color("comment_background")
        commentBorder = theme.color("comment_border")
        accent = theme.color("accent")
        syntaxColors = Syntax.names.map { theme.syntaxColor($0) }
        lineNumberAttrs = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: max(9, size - 1.5), weight: .regular),
            .foregroundColor: lineNumber,
        ]
        calibrate()
    }

    @MainActor static func calibrate() {
        let tlm = NSTextLayoutManager()
        tlm.textContainer = NSTextContainer(size: NSSize(width: 1000, height: 1_000_000))
        let storage = NSTextContentStorage()
        storage.addTextLayoutManager(tlm)
        storage.textStorage?.setAttributedString(NSAttributedString(string: "a\nb\nc\n", attributes: [.font: font, .paragraphStyle: baseParagraph]))
        var tops: [CGFloat] = []
        tlm.enumerateTextLayoutFragments(from: tlm.documentRange.location, options: [.ensuresLayout]) { f in
            tops.append(f.layoutFragmentFrame.minY)
            return tops.count < 3
        }
        if tops.count == 3, tops[2] > tops[1] { lineHeight = tops[2] - tops[1] }
    }
}

extension NSAttributedString.Key {
    static let ppBand = NSAttributedString.Key("pp.band")
    static let ppAdded = NSAttributedString.Key("pp.added")
    static let ppHidden = NSAttributedString.Key("pp.hidden")
}

/// Read-only content drawn around a paragraph.
final class Band: NSObject {
    var foldAbove = 0           // hidden unchanged lines before this line
    var deletedAbove: [String] = []
    var deletedBelow: [String] = [] // deletions at end of file
    var deletedAboveOld = 0     // base-version line of deletedAbove[0] (for syntax colors)
    var deletedBelowOld = 0
    var foldBelow = 0           // hidden unchanged lines after the last visible line
    var commentsBelow: CGFloat = 0 // comment boxes under this line (drawn by overlay views)
    var commentsAfterDeletedAbove: CGFloat = 0 // comment boxes under the red block above this line
    var commentsAfterDeletedBelow: CGFloat = 0 // … under the red block at the end of the file

    override func isEqual(_ object: Any?) -> Bool {
        guard let o = object as? Band else { return false }
        return foldAbove == o.foldAbove && foldBelow == o.foldBelow && commentsBelow == o.commentsBelow
            && commentsAfterDeletedAbove == o.commentsAfterDeletedAbove && commentsAfterDeletedBelow == o.commentsAfterDeletedBelow
            && deletedAbove == o.deletedAbove && deletedBelow == o.deletedBelow
    }

    var heightAbove: CGFloat {
        (foldAbove > 0 ? DiffStyle.foldHeight : 0) + CGFloat(deletedAbove.count) * DiffStyle.lineHeight + commentsAfterDeletedAbove
    }

    var heightBelow: CGFloat {
        commentsBelow + CGFloat(deletedBelow.count) * DiffStyle.lineHeight + commentsAfterDeletedBelow
            + (foldBelow > 0 ? DiffStyle.foldHeight : 0)
    }
}

final class DiffLayoutFragment: NSTextLayoutFragment {
    var band: Band?
    var added = false
    weak var editor: DiffEditor?

    private var fullWidth: CGFloat { DiffStyle.paintWidth }

    /// Everything around the text: gutter number, diff backgrounds, deleted
    /// lines and fold rows, drawn by EditorHost underneath the text view (whose
    /// left edge is the gutter's right edge). Coordinates are the host's.
    func drawDecorations(in context: CGContext) {
        let point = CGPoint(x: DiffStyle.gutterWidth + layoutFragmentFrame.minX, y: layoutFragmentFrame.minY)
        let first = textLineFragments.first
        let textTop = first?.typographicBounds.minY ?? 0
        let textBottom = textLineFragments.last?.typographicBounds.maxY ?? textTop
        let textX: CGFloat = 0 // point is the text origin; the gutter is left of it
        let lineLeft: CGFloat = 0 // the host's left edge (gutter included)

        if added {
            context.setFillColor(DiffStyle.addedBackground.cgColor)
            context.fill(CGRect(x: lineLeft, y: point.y + textTop, width: fullWidth, height: textBottom - textTop))
        }

        if let band {
            var y = point.y + textTop - band.heightAbove
            if band.foldAbove > 0 {
                drawFold(count: band.foldAbove, y: y, point: point, textX: textX, left: lineLeft, in: context)
                y += DiffStyle.foldHeight
            }
            drawDeleted(band.deletedAbove, oldLine: band.deletedAboveOld, y: y, point: point, textX: textX, left: lineLeft, in: context)

            y = point.y + textBottom + band.commentsBelow
            drawDeleted(band.deletedBelow, oldLine: band.deletedBelowOld, y: y, point: point, textX: textX, left: lineLeft, in: context)
            y += CGFloat(band.deletedBelow.count) * DiffStyle.lineHeight + band.commentsAfterDeletedBelow
            if band.foldBelow > 0 {
                drawFold(count: band.foldBelow, y: y, point: point, textX: textX, left: lineLeft, in: context)
            }
        }

        drawLineNumber(left: lineLeft, at: point, textTop: textTop, lineHeight: first?.typographicBounds.height ?? DiffStyle.lineHeight)
    }

    /// Only laid-out (on-screen) lines are decorated, so this costs nothing for
    /// the thousands of lines out of view.
    private func drawLineNumber(left: CGFloat, at point: CGPoint, textTop: CGFloat, lineHeight: CGFloat) {
        guard let editor, let tcm = textLayoutManager?.textContentManager else { return }
        let offset = tcm.offset(from: tcm.documentRange.location, to: rangeInElement.location)
        let line = MainActor.assumeIsolated { editor.lineIndex(forOffset: offset) } // AppKit draws on main
        let label = NSAttributedString(string: "\(line + 1)", attributes: DiffStyle.lineNumberAttrs)
        let size = label.size()
        label.draw(at: CGPoint(x: left + DiffStyle.gutterWidth - 8 - size.width,
                               y: point.y + textTop + (lineHeight - size.height) / 2))
    }

    private func drawDeleted(_ lines: [String], oldLine: Int, y: CGFloat, point: CGPoint, textX: CGFloat, left: CGFloat, in context: CGContext) {
        guard !lines.isEmpty else { return }
        context.setFillColor(DiffStyle.deletedBackground.cgColor)
        context.fill(CGRect(x: left, y: y, width: fullWidth, height: CGFloat(lines.count) * DiffStyle.lineHeight))
        let attrs: [NSAttributedString.Key: Any] = [.font: DiffStyle.font, .foregroundColor: DiffStyle.deletedText]
        for (i, line) in lines.enumerated() {
            (editor?.deletedLine(line, oldLine: oldLine + i, attrs: attrs) ?? NSAttributedString(string: line, attributes: attrs))
                .draw(at: CGPoint(x: point.x + textX, y: y + CGFloat(i) * DiffStyle.lineHeight))
        }
    }

    private func drawFold(count: Int, y: CGFloat, point: CGPoint, textX: CGFloat, left: CGFloat, in context: CGContext) {
        context.setFillColor(DiffStyle.foldBackground.cgColor)
        context.fill(CGRect(x: left, y: y + 3, width: fullWidth, height: DiffStyle.foldHeight - 6))
        let label = "⋯  \(count) unchanged line\(count == 1 ? "" : "s")"
        NSAttributedString(string: label, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: DiffStyle.foldText,
        ]).draw(at: CGPoint(x: point.x + textX, y: y + 4))
    }
}

/// Lays out every paragraph with our fragment (bands, backgrounds, line numbers).
final class DiffLayoutDelegate: NSObject, NSTextLayoutManagerDelegate {
    weak var editor: DiffEditor?

    func textLayoutManager(_ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: NSTextLocation, in textElement: NSTextElement) -> NSTextLayoutFragment {
        let fragment = DiffLayoutFragment(textElement: textElement, range: textElement.elementRange)
        fragment.editor = editor
        if let paragraph = textElement as? NSTextParagraph, paragraph.attributedString.length > 0 {
            let s = paragraph.attributedString
            fragment.band = s.attribute(.ppBand, at: 0, effectiveRange: nil) as? Band
            fragment.added = s.attribute(.ppAdded, at: 0, effectiveRange: nil) != nil
        }
        return fragment
    }
}

/// Apple's NSTextView in TextKit 2 mode, on our own content storage (which
/// skips folded lines) and with a size the review controls.
final class DiffTextView: NSTextView {
    let folding: FoldingContentStorage

    init() {
        let container = NSTextContainer(size: NSSize(width: 10_000_000, height: 10_000_000))
        container.widthTracksTextView = false // no soft wrap, like Zed's default
        container.heightTracksTextView = false
        let layout = NSTextLayoutManager()
        layout.textContainer = container
        folding = FoldingContentStorage()
        folding.addTextLayoutManager(layout)
        folding.primaryTextLayoutManager = layout
        super.init(frame: .zero, textContainer: container)
        // Rich-text mode: plain-text mode re-applies one uniform style when it
        // displays, dropping our per-line styling (gutter indent, diff bands).
        // Paste still inserts plain text (see paste(_:)).
        isRichText = true
        importsGraphics = false
        allowsUndo = true
        drawsBackground = false // the canvas paints the background
        isHorizontallyResizable = false
        isVerticallyResizable = false
        textContainerInset = .zero
        usesFontPanel = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        smartInsertDeleteEnabled = false
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        fatalError("use init()")
    }

    required init?(coder: NSCoder) { fatalError() }

    var layout: NSTextLayoutManager { textLayoutManager! }

    override func paste(_ sender: Any?) { pasteAsPlainText(sender) }



    /// Redraw lines whose drawing depends on more than their own text (line
    /// numbers shift when a line is added or removed above). Covers lines off
    /// screen too, or they'd scroll in showing stale numbers.
    func redisplayVisibleFragments() {
        layout.invalidateLayout(for: layout.documentRange)
        layout.textViewportLayoutController.layoutViewport()
        // NSTextView renders fragments in its own subviews/layers; repaint them all.
        func repaint(_ v: NSView) { v.needsDisplay = true; v.subviews.forEach(repaint) }
        repaint(self)
        superview?.needsDisplay = true // the host's decorations
    }

    /// Clicked a fold marker: expand hidden lines start..<end (all: ⌥-click).
    var onFoldClick: ((_ start: Int, _ end: Int, _ all: Bool) -> Void)?
    /// File line index of a fragment (set by the editor).
    var lineOf: ((NSTextLayoutFragment) -> Int)?
    /// Clicked a line number: start a comment on that line.
    var onGutterClick: ((_ line: Int) -> Void)?

    /// A click in the gutter (from EditorHost): comment on that line, or expand a fold row.
    func gutterClick(at y: CGFloat, event: NSEvent) {
        let p = CGPoint(x: 1, y: y)
        guard let fragment = layout.textLayoutFragment(for: p), let line = lineOf?(fragment) else { return }
        let f = fragment.layoutFragmentFrame
        let textTop = f.minY + (fragment.textLineFragments.first?.typographicBounds.minY ?? 0)
        if y >= textTop, y < textTop + DiffStyle.lineHeight { return onGutterClick?(line) ?? () }
        _ = foldClick(at: p, event: event)
    }

    /// Expand a fold row at `p`, if there is one. Returns whether it handled the click.
    private func foldClick(at p: CGPoint, event: NSEvent) -> Bool {
        guard let fragment = layout.textLayoutFragment(for: p) as? DiffLayoutFragment,
              let band = fragment.band, let line = lineOf?(fragment) else { return false }
        let f = fragment.layoutFragmentFrame
        let all = event.modifierFlags.contains(.option)
        if band.foldAbove > 0, p.y < f.minY + DiffStyle.foldHeight {
            onFoldClick?(line - band.foldAbove, line, all); return true
        }
        if band.foldBelow > 0, p.y > f.maxY - DiffStyle.foldHeight, p.y > f.minY + band.heightAbove + DiffStyle.lineHeight + band.commentsBelow {
            onFoldClick?(line + 1, line + 1 + band.foldBelow, all); return true
        }
        return false
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if foldClick(at: p, event: event) { return }
        super.mouseDown(with: event)
    }

    var fixedWidth: CGFloat = 800
    /// Height from DiffPlan (folded lines make any estimate wrong).
    var fixedHeight: CGFloat = 0

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(NSSize(width: fixedWidth, height: fixedHeight))
    }
}

/// Holds one open editor: draws the gutter and diff decorations across the
/// full width, with the text view inside it starting at the gutter's edge.
final class EditorHost: NSView {
    let textView: DiffTextView

    init(_ textView: DiffTextView) {
        self.textView = textView
        super.init(frame: .zero)
        addSubview(textView)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        // Glyphs must land where the canvas draws them (gutter + 5pt), or text
        // jumps sideways on click-to-edit. Where TextKit puts a line's first
        // glyph inside the text view (fragment origin + line offset) has varied,
        // so measure it instead of assuming.
        var inset = textView.textContainer!.lineFragmentPadding
        textView.layout.enumerateTextLayoutFragments(from: textView.layout.documentRange.location, options: []) { f in
            inset = f.layoutFragmentFrame.minX + (f.textLineFragments.first?.typographicBounds.minX ?? 0)
            return false
        }
        let x = DiffStyle.gutterWidth + 5 - inset
        textView.fixedWidth = max(0, bounds.width - x)
        textView.frame = NSRect(x: x, y: 0, width: textView.fixedWidth, height: textView.fixedHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let layout = textView.layout
        var from = layout.textViewportLayoutController.viewportRange?.location ?? layout.documentRange.location
        if let f = layout.textLayoutFragment(for: CGPoint(x: 0, y: max(0, dirtyRect.minY))) { from = f.rangeInElement.location }
        layout.enumerateTextLayoutFragments(from: from, options: []) { f in
            if f.layoutFragmentFrame.minY > dirtyRect.maxY { return false }
            (f as? DiffLayoutFragment)?.drawDecorations(in: ctx)
            return true
        }
    }

    override func mouseDown(with event: NSEvent) {
        textView.gutterClick(at: convert(event.locationInWindow, from: nil).y, event: event)
    }
}

@MainActor
protocol DiffEditorDelegate: AnyObject {
    func diffEditorDidChange(_ editor: DiffEditor)
    /// Fresh syntax colors for the editor's current text (so the canvas can reuse them).
    func diffEditorDidHighlight(_ editor: DiffEditor, spans: SyntaxSpans, text: String)
}

/// What one line should look like. Compared against what the text storage
/// already has, so an edit only restyles the handful of lines that changed.
private struct LineLook: Equatable {
    var hidden = false
    var added = false
    var band: Band?
}

@MainActor
final class DiffEditor: NSObject, NSTextViewDelegate {
    let textView = DiffTextView()
    /// What the review places on screen: gutter + decorations + the text view.
    lazy var host = EditorHost(textView)
    weak var delegate: DiffEditorDelegate?

    private let oldText: String
    private let path: String

    // Syntax colors live in the text storage as foreground colors. After an
    // edit the file is re-highlighted in the background and only the region
    // whose colors changed is rewritten (usually a line or two).
    private var syntax: SyntaxSpans?
    private let oldSyntax: SyntaxSpans?
    private let oldLineStarts: [Int]
    private var editVersion = 0
    private var highlightedLength = 0
    private let layoutDelegate = DiffLayoutDelegate()
    private(set) var hunks: [DiffHunk] = []
    private(set) var isDirty = false

    private(set) var lineStarts: [Int] = [] // UTF-16 offset of each line
    private var refreshScheduled = false

    /// Cost of the last refresh and how many lines it restyled, for the speed readout.
    private(set) var lastRefreshMs: Double = 0
    private(set) var lastRestyledLines = 0
    private(set) var lastBreakdown = ""

    /// Unchanged line ranges the user expanded (shown instead of folded).
    private(set) var expanded: [Range<Int>]
    /// Height of comment boxes under each line; the editor leaves that much room.
    private(set) var commentSpace: [Int: CGFloat] = [:]
    /// Same for comments on deleted lines, keyed by the line the red block sits above.
    private(set) var deletedCommentSpace: [Int: CGFloat] = [:]

    /// Update what's revealed / how much room comments need; refreshes once.
    func setReveal(expanded newExpanded: [Range<Int>], commentSpace newSpace: [Int: CGFloat], deletedCommentSpace newDeleted: [Int: CGFloat]) {
        guard newExpanded != expanded || newSpace != commentSpace || newDeleted != deletedCommentSpace else { return }
        expanded = newExpanded
        commentSpace = newSpace
        deletedCommentSpace = newDeleted
        refresh(hunks: hunks)
    }

    init(path: String, oldText: String, newText: String, hunks: [DiffHunk], expanded: [Range<Int>] = [],
         syntax: SyntaxSpans? = nil, oldSyntax: SyntaxSpans? = nil) {
        self.path = path
        self.syntax = syntax
        self.oldSyntax = oldSyntax
        self.oldLineStarts = oldSyntax == nil ? [] : ReviewFile.lineStarts(of: oldText as NSString)
        self.oldText = oldText
        self.hunks = hunks
        self.expanded = expanded
        super.init()

        let t0 = CACurrentMediaTime()
        layoutDelegate.editor = self
        textView.layout.delegate = layoutDelegate
        applyStyle(relayout: false)
        setStyledText(newText)
        let t1 = CACurrentMediaTime()
        defer {
            if ProcessInfo.processInfo.environment["PP_SELFTEST"] == "open-time" {
                FileHandle.standardError.write(String(format: "[open]   init: setText %.1f, refresh %.1f (%@)\n", (t1 - t0) * 1000, (CACurrentMediaTime() - t1) * 1000, lastBreakdown).data(using: .utf8)!)
            }
        }
        textView.lineOf = { [weak self] fragment in
            guard let self else { return 0 }
            let tcm = self.textView.folding
            return self.lineIndex(forOffset: tcm.offset(from: tcm.documentRange.location, to: fragment.rangeInElement.location))
        }
        textView.delegate = self
        textView.undoManager?.removeAllActions() // loading isn't an edit

        refresh(hunks: hunks)
        textView.redisplayVisibleFragments() // lines laid out before styling landed would keep the old layout
    }

    var text: String { textView.string }

    /// Base look (font, color, gutter indent) for all text. NSTextView's plain
    /// text mode doesn't apply the paragraph style to text set via `string`.
    private var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: DiffStyle.font, .foregroundColor: DiffStyle.text, .paragraphStyle: DiffStyle.baseParagraph]
    }

    /// Opening a file: build the fully styled text (folds, bands, backgrounds)
    /// first, then hand it to TextKit once. Styling it after loading made TextKit
    /// reprocess every line again (~95 ms for a 2,000-line file).
    private func setStyledText(_ s: String) {
        guard let storage = textView.folding.textStorage else { return }
        let text = NSMutableAttributedString(string: s, attributes: baseAttributes)
        computeLineStarts(s)
        let looks = desiredLooks()
        writeLooks(looks, changed: Array(looks.indices), into: text, length: text.length)
        if let syntax { color(text, with: syntax, in: NSRange(location: 0, length: text.length)) }
        highlightedLength = text.length
        if syntax == nil { scheduleHighlight(delay: 0) }
        textView.folding.hiddenRanges = hiddenRanges(looks, length: text.length)
        textView.folding.performEditingTransaction {
            storage.setAttributedString(text)
        }
    }

    /// Font/theme changed: restyle the text, then recompute bands and height.
    func applyStyle(relayout: Bool = true) {
        textView.font = DiffStyle.font
        textView.defaultParagraphStyle = DiffStyle.baseParagraph
        textView.textColor = DiffStyle.text
        textView.insertionPointColor = DiffStyle.caret
        textView.typingAttributes = baseAttributes
        guard relayout else { return }
        if let storage = textView.folding.textStorage { // restyle existing text (bands are re-applied below)
            textView.folding.performEditingTransaction {
                storage.addAttributes(baseAttributes, range: NSRange(location: 0, length: storage.length))
            }
        }
        refresh(hunks: hunks, forceRestyle: true)
        if let syntax, let storage = textView.folding.textStorage {
            textView.folding.performEditingTransaction { color(storage, with: syntax, in: NSRange(location: 0, length: storage.length)) }
        }
        textView.redisplayVisibleFragments()
    }

    func markSaved() {
        isDirty = false
    }

    // MARK: Diff → presentation

    private func refresh(hunks known: [DiffHunk]? = nil, forceRestyle: Bool = false) {
        if forceRestyle, let storage = textView.folding.textStorage {
            let all = NSRange(location: 0, length: storage.length)
            textView.folding.performEditingTransaction {
                storage.removeAttribute(.ppBand, range: all)
                storage.removeAttribute(.ppHidden, range: all)
                storage.removeAttribute(.ppAdded, range: all)
            }
        }
        let start = CACurrentMediaTime()
        var marks: [(String, Double)] = []
        func mark(_ n: String) { marks.append((n, CACurrentMediaTime())) }
        let current = text; mark("text")
        hunks = known ?? diffLines(old: oldText, new: current); mark("diff")
        let previousLineCount = lineStarts.count
        computeLineStarts(current); mark("lines")
        if lineStarts.count != previousLineCount { textView.redisplayVisibleFragments() }
        let looks = desiredLooks(); mark("looks")
        applyLooks(looks, mark: mark)
        host.needsDisplay = true // decorations (backgrounds, numbers) follow the new diff
        let comments = commentSpace.filter { $0.key < lineStarts.count }.values.reduce(0, +)
            + deletedCommentSpace.filter { $0.key > 0 }.values.reduce(0, +)
        let height = comments + DiffPlan.height(hunks, lineCount: lineStarts.count, expanded: expanded) - DiffPlan.leadingDeletedHeight(hunks, lineCount: lineStarts.count)
        if height != textView.fixedHeight {
            textView.fixedHeight = height
            textView.setFrameSize(textView.frame.size)
            host.setFrameSize(NSSize(width: host.frame.width, height: height))
        }
        lastRefreshMs = (CACurrentMediaTime() - start) * 1000
        if ProcessInfo.processInfo.environment["PP_SELFTEST"] == "1" {
            var prev = start
            lastBreakdown = marks.map { m in defer { prev = m.1 }; return String(format: "%@ %.2f", m.0, (m.1 - prev) * 1000) }.joined(separator: ", ")
        }
    }

    private func computeLineStarts(_ s: String) {
        var starts: [Int] = []
        starts.reserveCapacity(lineStarts.count + 16)
        var offset = 0
        var atLineStart = true
        for unit in s.utf16 {
            if atLineStart { starts.append(offset); atLineStart = false }
            if unit == 10 { atLineStart = true }
            offset += 1
        }
        lineStarts = starts
    }

    private func desiredLooks() -> [LineLook] {
        let lineCount = lineStarts.count
        var looks = [LineLook](repeating: LineLook(hidden: true), count: lineCount)
        guard lineCount > 0 else { return looks }
        for r in DiffPlan.visibleRanges(hunks, lineCount: lineCount, expanded: expanded) {
            for i in r { looks[i].hidden = false }
        }

        var bands: [Int: Band] = [:]
        func band(_ line: Int) -> Band {
            if let b = bands[line] { return b }
            let b = Band(); bands[line] = b; return b
        }

        for h in hunks {
            let s = Int(h.newStart), n = Int(h.newLen)
            for i in s..<min(s + n, lineCount) { looks[i].added = true }
            guard !h.deleted.isEmpty else { continue }
            if s == 0 { continue } // drawn by the canvas above the editor (see FileLayout.editorTop)
            if s < lineCount {
                band(s).deletedAbove = h.deleted
                band(s).deletedAboveOld = Int(h.oldStart)
            } else {
                band(lineCount - 1).deletedBelow = h.deleted
                band(lineCount - 1).deletedBelowOld = Int(h.oldStart)
            }
        }

        // Fold markers go on the first visible line after a hidden run (or the last visible line for a trailing run).
        var hiddenRun = 0
        var lastVisible = -1
        for i in 0..<lineCount {
            if looks[i].hidden { hiddenRun += 1; continue }
            if hiddenRun > 0 { band(i).foldAbove = hiddenRun }
            hiddenRun = 0
            lastVisible = i
        }
        if hiddenRun > 0, lastVisible >= 0 { band(lastVisible).foldBelow = hiddenRun }

        for (line, h) in commentSpace where line < lineCount { band(line).commentsBelow = h }
        for (line, h) in deletedCommentSpace where line > 0 { // line 0's block is drawn by the canvas
            if line < lineCount { band(line).commentsAfterDeletedAbove = h } else if lineCount > 0 { band(lineCount - 1).commentsAfterDeletedBelow = h }
        }
        for (line, b) in bands { looks[line].band = b }
        return looks
    }

    private func lineRange(_ line: Int, length: Int) -> NSRange {
        let start = lineStarts[line]
        let end = line + 1 < lineStarts.count ? lineStarts[line + 1] : length
        return NSRange(location: start, length: end - start)
    }

    private func hiddenRanges(_ looks: [LineLook], length: Int) -> [NSRange] {
        var hidden: [NSRange] = []
        var runStart: Int?
        for line in 0...looks.count {
            let isHidden = line < looks.count && looks[line].hidden
            if isHidden, runStart == nil { runStart = line }
            if !isHidden, let s = runStart {
                let start = lineStarts[s]
                let end = line < lineStarts.count ? lineStarts[line] : length
                hidden.append(NSRange(location: start, length: end - start))
                runStart = nil
            }
        }
        return hidden
    }

    /// Write the looks of `changed` lines into `target` (the live storage, or a
    /// string being prepared before it's handed to TextKit).
    private func writeLooks(_ looks: [LineLook], changed: [Int], into target: NSMutableAttributedString, length: Int) {
        // Apply runs of adjacent lines with the same look as one range: opening a
        // file hides ~all of its lines, and per-line writes dominated editor creation.
        var i = 0
        while i < changed.count {
            var j = i
            while j + 1 < changed.count, changed[j + 1] == changed[j] + 1,
                  looks[changed[j + 1]] == looks[changed[i]], looks[changed[i]].band == nil { j += 1 }
            let look = looks[changed[i]]
            let start = lineStarts[changed[i]]
            let end = NSMaxRange(lineRange(changed[j], length: length))
            let r = NSRange(location: start, length: end - start)
            if look.hidden { target.addAttribute(.ppHidden, value: true, range: r) } else { target.removeAttribute(.ppHidden, range: r) }
            if look.added { target.addAttribute(.ppAdded, value: true, range: r) } else { target.removeAttribute(.ppAdded, range: r) }
            if let b = look.band {
                target.addAttribute(.ppBand, value: b, range: r)
                let p = DiffStyle.baseParagraph.mutableCopy() as! NSMutableParagraphStyle
                p.paragraphSpacingBefore = b.heightAbove
                p.paragraphSpacing = b.heightBelow
                target.addAttribute(.paragraphStyle, value: p, range: r)
            } else {
                target.removeAttribute(.ppBand, range: r)
                target.addAttribute(.paragraphStyle, value: DiffStyle.baseParagraph, range: r)
            }
            i = j + 1
        }
    }

    private func applyLooks(_ looks: [LineLook], mark: (String) -> Void = { _ in }) {
        guard let storage = textView.folding.textStorage else { return }
        let length = storage.length
        textView.folding.hiddenRanges = hiddenRanges(looks, length: length)

        var changed: [Int] = []
        for (line, look) in looks.enumerated() {
            let at = lineStarts[line]
            guard at < length else { continue }
            let current = LineLook(
                hidden: storage.attribute(.ppHidden, at: at, effectiveRange: nil) != nil,
                added: storage.attribute(.ppAdded, at: at, effectiveRange: nil) != nil,
                band: storage.attribute(.ppBand, at: at, effectiveRange: nil) as? Band
            )
            if current != look { changed.append(line) }
        }
        lastRestyledLines = changed.count
        mark("compare")
        guard !changed.isEmpty else { return }

        textView.folding.performEditingTransaction {
            storage.beginEditing()
            writeLooks(looks, changed: changed, into: storage, length: length)
            storage.endEditing()
        }

        mark("write")
        // Editing the storage invalidated exactly the touched paragraphs; the text view
        // re-lays out what's on screen on its next layout pass.
        textView.needsLayout = true
    }

    /// 0-based file line for a UTF-16 offset.
    func lineIndex(forOffset offset: Int) -> Int {
        var lo = 0, hi = max(0, lineStarts.count - 1)
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStarts[mid] <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    // MARK: Syntax

    /// A deleted line colored like the base version of the file.
    nonisolated func deletedLine(_ text: String, oldLine: Int, attrs: [NSAttributedString.Key: Any]) -> NSAttributedString? {
        guard let oldSyntax, oldLine < oldLineStarts.count else { return nil }
        return oldSyntax.attributed(text, at: oldLineStarts[oldLine], attrs: attrs)
    }

    /// Set foreground colors in `range` of `target` from `spans` (plain text color elsewhere).
    private func color(_ target: NSMutableAttributedString, with spans: SyntaxSpans, in range: NSRange) {
        guard range.length > 0 else { return }
        target.addAttribute(.foregroundColor, value: DiffStyle.text, range: range)
        spans.forEach(inLineAt: range.location, length: range.length) { r, color in
            target.addAttribute(.foregroundColor, value: color, range: NSRange(location: range.location + r.location, length: r.length))
        }
    }

    private func scheduleHighlight(delay: TimeInterval) {
        let version = editVersion
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.editVersion == version else { return } // still typing: the next one will run
            let text = self.text
            Syntax.highlight(path: self.path, text: text) { [weak self] result in
                guard let self, case let .spans(spans) = result, self.editVersion == version else { return }
                self.applyHighlight(spans, length: (text as NSString).length)
                self.delegate?.diffEditorDidHighlight(self, spans: spans, text: text)
            }
        }
    }

    /// Rewrite colors only where the new spans differ from the old ones.
    private func applyHighlight(_ new: SyntaxSpans, length: Int) {
        guard let storage = textView.folding.textStorage, storage.length == length else { return }
        let range = syntax.map { Self.changedRange(old: $0.spans, new: new.spans, delta: length - highlightedLength, length: length) }
            ?? NSRange(location: 0, length: length)
        syntax = new
        highlightedLength = length
        guard let range, range.length > 0 else { return }
        textView.folding.performEditingTransaction {
            storage.beginEditing()
            color(storage, with: new, in: range)
            storage.endEditing()
        }
    }

    /// The UTF-16 range whose colors differ between two highlights of a text
    /// that grew by `delta` in one place: skip equal spans from the front, and
    /// from the back (shifted by `delta`); what's left changed.
    static func changedRange(old: [UInt32], new: [UInt32], delta: Int, length: Int) -> NSRange? {
        let on = old.count / 3, nn = new.count / 3
        var p = 0
        while p < on, p < nn, old[p * 3] == new[p * 3], old[p * 3 + 1] == new[p * 3 + 1], old[p * 3 + 2] == new[p * 3 + 2] { p += 1 }
        if p == on, p == nn { return nil }
        var s = 0
        while s < on - p, s < nn - p {
            let o = (on - 1 - s) * 3, n = (nn - 1 - s) * 3
            guard Int(old[o]) + delta == Int(new[n]), Int(old[o + 1]) + delta == Int(new[n + 1]), old[o + 2] == new[n + 2] else { break }
            s += 1
        }
        var lo = Int.max, hi = 0
        if p < on - s { lo = min(lo, Int(old[p * 3])); hi = max(hi, Int(old[(on - s - 1) * 3 + 1]) + delta) }
        if p < nn - s { lo = min(lo, Int(new[p * 3])); hi = max(hi, Int(new[(nn - s - 1) * 3 + 1])) }
        lo = max(0, min(lo, length)); hi = max(lo, min(hi, length))
        return NSRange(location: lo, length: hi - lo)
    }

    // MARK: Editing

    func textDidChange(_ notification: Notification) {
        isDirty = true
        editVersion += 1
        scheduleHighlight(delay: 0.03)
        // Coalesce bursts (paste, multi-cursor) into one refresh per runloop turn.
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refresh()
            self.delegate?.diffEditorDidChange(self)
        }
    }
}
