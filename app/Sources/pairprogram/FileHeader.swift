import AppKit

/// Draws a file's header bar (in the canvas, and pinned at the top as the
/// sticky header):
///
///     ⌄  [M]  src/modules/ billing.ts   +12 −3   💬 2             ☐ Viewed
@MainActor
enum FileHeader {
    private static let checkbox: CGFloat = 14
    private static let rightPadding: CGFloat = 16

    private static var labelFont: NSFont { .systemFont(ofSize: max(10.5, DiffStyle.font.pointSize - 1)) }
    private static var viewedLabel: NSAttributedString {
        NSAttributedString(string: "Viewed", attributes: [.font: labelFont, .foregroundColor: DiffStyle.headerText.withAlphaComponent(0.85)])
    }

    /// The "☐ Viewed" control, in header coordinates (it takes clicks).
    static func viewedRect(width: CGFloat) -> CGRect {
        let labelWidth = ceil(viewedLabel.size().width)
        let w = checkbox + 6 + labelWidth
        return CGRect(x: width - rightPadding - w, y: 0, width: w, height: FileLayout.headerHeight)
    }

    static func draw(_ file: ReviewFile, dirty: Bool, y: CGFloat, width: CGFloat) {
        let h = FileLayout.headerHeight
        DiffStyle.headerBackground.setFill()
        CGRect(x: 0, y: y, width: width, height: h).fill()
        DiffStyle.separator.setFill()
        CGRect(x: 0, y: y, width: width, height: 1).fill()
        CGRect(x: 0, y: y + h - 1, width: width, height: 1).fill()
        let mid = y + h / 2

        // Chevron: down when open, right when folded.
        let c = NSBezierPath()
        let cx: CGFloat = 17, s: CGFloat = 3.5
        if file.collapsed {
            c.move(to: NSPoint(x: cx - s / 2, y: mid - s)); c.line(to: NSPoint(x: cx + s / 2, y: mid)); c.line(to: NSPoint(x: cx - s / 2, y: mid + s))
        } else {
            c.move(to: NSPoint(x: cx - s, y: mid - s / 2)); c.line(to: NSPoint(x: cx, y: mid + s / 2)); c.line(to: NSPoint(x: cx + s, y: mid - s / 2))
        }
        c.lineWidth = 1.6
        c.lineCapStyle = .round
        c.lineJoinStyle = .round
        DiffStyle.headerText.withAlphaComponent(0.55).setStroke()
        c.stroke()

        // Status pill.
        let (letter, color): (String, NSColor) = switch file.status {
        case .modified: ("M", .systemOrange)
        case .added: ("A", .systemGreen)
        case .deleted: ("D", .systemRed)
        case .untracked: ("U", .systemTeal)
        }
        let pill = CGRect(x: 30, y: mid - 8, width: 18, height: 16)
        color.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 4, yRadius: 4).fill()
        let badge = NSAttributedString(string: letter, attributes: [.font: NSFont.systemFont(ofSize: 10, weight: .bold), .foregroundColor: color])
        let bs = badge.size()
        badge.draw(at: CGPoint(x: pill.midX - bs.width / 2, y: pill.midY - bs.height / 2))

        // Right side first, so the path knows how much room it has.
        let viewed = viewedRect(width: width).offsetBy(dx: 0, dy: y)
        drawCheckbox(checked: file.viewed, in: viewed, mid: mid)

        // Trailing details: +/− counts, comments, state notes.
        let details = NSMutableAttributedString()
        let small = labelFont
        let numbers = NSFont.monospacedDigitSystemFont(ofSize: small.pointSize, weight: .medium)
        func add(_ s: String, _ color: NSColor, _ font: NSFont = small) {
            details.append(NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color]))
        }
        if file.kind == .text || file.status == .deleted {
            add("+\(file.added)", .systemGreen, numbers)
            add("  −\(file.removed)", .systemRed, numbers)
        }
        if file.openThreadCount > 0 { add("   ● \(file.openThreadCount) open", DiffStyle.accent) }
        if dirty { add("   ● unsaved", DiffStyle.accent) }
        if file.changedOnDisk { add("   changed on disk", .systemOrange) }
        if file.changedSinceViewed { add("   changed since viewed", .systemOrange) }
        let detailsWidth = ceil(details.size().width)

        // Path: folder dimmed, file name emphasized; long paths lose the folder's start.
        let slash = file.path.lastIndex(of: "/").map { file.path.index(after: $0) } ?? file.path.startIndex
        let path = NSMutableAttributedString(string: String(file.path[..<slash]), attributes: [
            .font: DiffStyle.font.withSize(DiffStyle.headerFont.pointSize), .foregroundColor: DiffStyle.headerText.withAlphaComponent(0.6),
        ])
        path.append(NSAttributedString(string: String(file.path[slash...]), attributes: [.font: DiffStyle.headerFont, .foregroundColor: DiffStyle.headerText]))
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingHead
        path.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: path.length))
        let pathX: CGFloat = 58
        let room = viewed.minX - 24 - detailsWidth - 16 - pathX
        let pathWidth = min(ceil(path.size().width), max(40, room))
        let ph = path.size().height
        path.draw(with: CGRect(x: pathX, y: mid - ph / 2, width: pathWidth, height: ph), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        let dh = details.size().height
        details.draw(at: CGPoint(x: pathX + pathWidth + 16, y: mid - dh / 2))
    }

    private static func drawCheckbox(checked: Bool, in rect: CGRect, mid: CGFloat) {
        let box = CGRect(x: rect.minX, y: mid - checkbox / 2, width: checkbox, height: checkbox)
        let path = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: 3.5, yRadius: 3.5)
        if checked {
            DiffStyle.accent.setFill()
            path.fill()
            let tick = NSBezierPath()
            tick.move(to: NSPoint(x: box.minX + 3.5, y: box.midY + 0.5))
            tick.line(to: NSPoint(x: box.minX + 6, y: box.maxY - 3.5))
            tick.line(to: NSPoint(x: box.maxX - 3.5, y: box.minY + 4))
            tick.lineWidth = 1.8
            tick.lineCapStyle = .round
            tick.lineJoinStyle = .round
            NSColor.white.setStroke()
            tick.stroke()
        } else {
            DiffStyle.background.setFill()
            path.fill()
            DiffStyle.headerText.withAlphaComponent(0.35).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        let label = viewedLabel
        let ls = label.size()
        label.draw(at: CGPoint(x: box.maxX + 6, y: mid - ls.height / 2))
    }
}

/// The header of the file at the top of the viewport, pinned above everything
/// (editors and comment boxes included) so it always takes its clicks.
final class StickyHeaderView: NSView {
    weak var document: ReviewDocumentView?
    var fileIndex = -1

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    /// Folding or checking "Viewed" works even while pairprogram isn't the active app.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let doc = document, fileIndex >= 0, fileIndex < doc.files.count else { return }
        let file = doc.files[fileIndex]
        FileHeader.draw(file, dirty: doc.isDirty(file), y: 0, width: bounds.width)
    }

    override func mouseDown(with event: NSEvent) {
        guard let doc = document, fileIndex >= 0 else { return }
        let p = convert(event.locationInWindow, from: nil)
        if FileHeader.viewedRect(width: bounds.width).insetBy(dx: -8, dy: 0).contains(p) {
            doc.toggleViewed(fileIndex)
        } else if event.modifierFlags.contains(.option) {
            doc.setAllCollapsed(!doc.files[fileIndex].collapsed) // ⌥-click: all files follow this one
        } else {
            doc.toggleCollapse(fileIndex)
        }
    }

    override func resetCursorRects() {
        addCursorRect(FileHeader.viewedRect(width: bounds.width).insetBy(dx: -8, dy: 0), cursor: .pointingHand)
    }
}

/// Files you've marked viewed, like GitHub: remembered per repo against a
/// fingerprint of the file, so a file that changes afterwards (say, the agent
/// edits it) comes back unviewed.
enum ViewedStore {
    private static func url(_ repo: String) -> URL? {
        (try? commentsPath(repoRoot: repo)).map { URL(fileURLWithPath: $0).deletingLastPathComponent().appendingPathComponent("viewed.json") }
    }

    static func load(_ repo: String) -> [String: String] {
        guard let url = url(repo), let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    static func save(_ repo: String, _ viewed: [String: String]) {
        guard let url = url(repo) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(viewed).write(to: url, options: .atomic)
    }

    /// FNV-1a over the file's status and current text (stable across launches, unlike Hasher).
    static func fingerprint(_ file: ReviewFile) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        func mix(_ bytes: some Sequence<UInt8>) { for b in bytes { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 } }
        mix("\(file.status)|\(file.removed)|".utf8)
        mix((file.newText as String).utf8)
        return String(h, radix: 16)
    }
}
