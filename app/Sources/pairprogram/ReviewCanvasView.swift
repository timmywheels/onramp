import AppKit

/// Draws the visible part of the whole review, Zed-style: one view the size of
/// the viewport, rows computed from the model, text drawn from cached CTLines.
/// No per-line or per-file views, so jumping anywhere costs one screen of drawing.
/// Files being edited are covered by a real editor; the canvas skips their bodies.
final class ReviewCanvasView: NSView {
    weak var document: ReviewDocumentView?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    /// Whatever redraws headers here must redraw the pinned one too.
    override var needsDisplay: Bool {
        didSet { if needsDisplay { document?.stickyHeader.needsDisplay = true } }
    }

    private var textX: CGFloat { DiffStyle.gutterWidth + 5 } // matches the editor: indent + line fragment padding
    private var baseline: CGFloat { DiffStyle.font.ascender }

    private var numberCache: [Int: CTLine] = [:]
    private var foldCache: [Int: CTLine] = [:]
    private static var textAttrs: [NSAttributedString.Key: Any] { [.font: DiffStyle.font, .foregroundColor: DiffStyle.text] }
    private static var deletedAttrs: [NSAttributedString.Key: Any] { [.font: DiffStyle.font, .foregroundColor: DiffStyle.deletedText] }
    private static var headerAttrs: [NSAttributedString.Key: Any] {
        [.font: DiffStyle.headerFont, .foregroundColor: DiffStyle.headerText]
    }
    private static var foldAttrs: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: DiffStyle.font.pointSize - 1.5), .foregroundColor: DiffStyle.foldText]
    }
    private static var noteAttrs: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: DiffStyle.font.pointSize - 0.5), .foregroundColor: DiffStyle.foldText]
    }

    /// Font or theme changed: rendered lines have the old font/colors baked in.
    func styleChanged() {
        numberCache = [:]
        foldCache = [:]
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let doc = document, let ctx = NSGraphicsContext.current?.cgContext else { return }
        DiffStyle.background.setFill()
        dirtyRect.fill()
        guard !doc.files.isEmpty else { return }

        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1) // flipped view
        let top = frame.minY // our origin in document coordinates
        let width = bounds.width

        var i = doc.index(at: top + dirtyRect.minY)
        while i < doc.files.count, doc.tops[i] < top + dirtyRect.maxY {
            let file = doc.files[i]
            let layout = file.layout
            let fileY = doc.tops[i] - top
            let hasEditor = doc.hasEditor(i)
            let editorTop = FileLayout.bodyTop + DiffPlan.leadingDeletedHeight(file.hunks, lineCount: file.lineCount)
            var r = layout.rowIndex(at: top + dirtyRect.minY - doc.tops[i])
            while r < layout.rows.count {
                let row = layout.rows[r]
                let y = fileY + row.y
                if y > dirtyRect.maxY { break }
                switch row.kind {
                case .header: drawHeader(file, y: y, width: width, in: ctx)
                case .spacer: break
                default: if !hasEditor || row.y < editorTop { drawBodyRow(row, file: file, y: y, width: width, in: ctx) }
                }
                r += 1
            }
            i += 1
        }
    }

    // MARK: Rows

    private func drawBodyRow(_ row: Row, file: ReviewFile, y: CGFloat, width: CGFloat, in ctx: CGContext) {
        switch row.kind {
        case let .line(i, added):
            if added { fill(DiffStyle.addedBackground, CGRect(x: 0, y: y, width: width, height: row.height), ctx) }
            drawNumber(i + 1, y: y, in: ctx)
            draw(cachedLine(row, file) { NSAttributedString(string: file.line(i), attributes: Self.textAttrs) }, x: textX, y: y, in: ctx)
        case let .deleted(h, k):
            fill(DiffStyle.deletedBackground, CGRect(x: 0, y: y, width: width, height: row.height), ctx)
            draw(cachedLine(row, file) { NSAttributedString(string: file.hunks[h].deleted[k], attributes: Self.deletedAttrs) }, x: textX, y: y, in: ctx)
        case let .fold(start, end):
            let count = end - start
            fill(DiffStyle.foldBackground, CGRect(x: 0, y: y + 3, width: width, height: row.height - 6), ctx)
            let label = foldCache[count] ?? {
                let l = CTLineCreateWithAttributedString(NSAttributedString(
                    string: count <= ReviewDocumentView.expandAllUpTo
                        ? "⋯  Show \(count) unchanged line\(count == 1 ? "" : "s")"
                        : "⋯  \(count) unchanged lines  ·  click for \(ReviewDocumentView.expandStep) more, ⌥-click for all",
                    attributes: Self.foldAttrs))
                foldCache[count] = l
                return l
            }()
            let ff = NSFont.systemFont(ofSize: DiffStyle.font.pointSize - 1.5)
            draw(label, x: textX, y: y + (row.height - ff.ascender + ff.descender) / 2, baseline: ff.ascender, in: ctx)
        case let .note(text):
            draw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: Self.noteAttrs)), x: 16, y: y + 4, baseline: 12, in: ctx)
        case .header, .spacer, .thread, .composer:
            break // comment boxes are views on top of the canvas
        }
    }

    private func drawHeader(_ file: ReviewFile, y: CGFloat, width: CGFloat, in ctx: CGContext) {
        FileHeader.draw(file, dirty: document?.isDirty(file) == true, y: y, width: width)
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1) // AppKit text drawing resets it; CTLineDraw needs it
    }

    // MARK: Drawing helpers

    private func cachedLine(_ row: Row, _ file: ReviewFile, make: () -> NSAttributedString) -> CTLine {
        if let key = row.cacheKey, let line = file.lineCache[key] { return line }
        let line = CTLineCreateWithAttributedString(make())
        if let key = row.cacheKey { file.lineCache[key] = line }
        return line
    }

    private func drawNumber(_ n: Int, y: CGFloat, in ctx: CGContext) {
        let line = numberCache[n] ?? {
            let l = CTLineCreateWithAttributedString(NSAttributedString(string: "\(n)", attributes: DiffStyle.lineNumberAttrs))
            numberCache[n] = l
            return l
        }()
        let w = CTLineGetTypographicBounds(line, nil, nil, nil)
        draw(line, x: DiffStyle.gutterWidth - 8 - w, y: y, in: ctx)
    }

    private func draw(_ line: CTLine, x: CGFloat, y: CGFloat, baseline: CGFloat? = nil, in ctx: CGContext) {
        ctx.textPosition = CGPoint(x: x, y: y + (baseline ?? self.baseline))
        CTLineDraw(line, ctx)
    }

    private func fill(_ color: NSColor, _ rect: CGRect, _ ctx: CGContext) {
        ctx.setFillColor(color.cgColor)
        ctx.fill(rect)
    }

    // MARK: Hit testing

    /// Character offset in the file for a click at x on a text line.
    func column(in file: ReviewFile, line i: Int, x: CGFloat) -> Int {
        let row = Row(kind: .line(i, added: false), y: 0, height: 0)
        let ct = cachedLine(row, file) { NSAttributedString(string: file.line(i), attributes: Self.textAttrs) }
        let idx = CTLineGetStringIndexForPosition(ct, CGPoint(x: max(0, x - textX), y: 0))
        return idx == kCFNotFound ? 0 : idx
    }

    override func mouseDown(with event: NSEvent) {
        guard let doc = document else { return }
        let p = convert(event.locationInWindow, from: nil)
        doc.click(atDocumentY: frame.minY + p.y, x: p.x)
    }
}
