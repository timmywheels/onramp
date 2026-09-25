import AppKit

/// A folder or changed file in the sidebar tree.
final class TreeNode {
    let name: String
    let fileIndex: Int?
    weak var parent: TreeNode?
    var children: [TreeNode] = []
    var added = 0
    var removed = 0

    init(name: String, fileIndex: Int?) {
        self.name = name
        self.fileIndex = fileIndex
    }

    /// Folders from paths, with single-child folder chains merged ("src/app/ui").
    static func build(_ files: [ReviewFile]) -> (root: TreeNode, leaves: [TreeNode]) {
        let root = TreeNode(name: "", fileIndex: nil)
        var leaves = [TreeNode?](repeating: nil, count: files.count)
        for (i, file) in files.enumerated() {
            var node = root
            let parts = file.path.split(separator: "/").map(String.init)
            for dir in parts.dropLast() {
                if let next = node.children.first(where: { $0.fileIndex == nil && $0.name == dir }) {
                    node = next
                } else {
                    let next = TreeNode(name: dir, fileIndex: nil)
                    next.parent = node
                    node.children.append(next)
                    node = next
                }
            }
            let leaf = TreeNode(name: parts.last ?? file.path, fileIndex: i)
            leaf.parent = node
            node.children.append(leaf)
            leaves[i] = leaf
        }
        root.compress()
        root.sort()
        return (root, leaves.map { $0! })
    }

    private func compress() {
        for child in children { child.compress() }
        children = children.map { child in
            var c = child
            while c.fileIndex == nil, c.children.count == 1, c.children[0].fileIndex == nil {
                let only = c.children[0]
                let merged = TreeNode(name: c.name + "/" + only.name, fileIndex: nil)
                merged.children = only.children
                merged.children.forEach { $0.parent = merged }
                c = merged
            }
            c.parent = self
            return c
        }
    }

    private func sort() {
        children.sort { a, b in
            if (a.fileIndex == nil) != (b.fileIndex == nil) { return a.fileIndex == nil } // folders first
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        children.forEach { $0.sort() }
    }

    /// Recompute +/− totals for this subtree.
    @discardableResult
    func total(_ files: [ReviewFile]) -> (Int, Int) {
        if let i = fileIndex {
            added = files[i].added; removed = files[i].removed
        } else {
            let sums = children.map { $0.total(files) }
            added = sums.reduce(0) { $0 + $1.0 }; removed = sums.reduce(0) { $0 + $1.1 }
        }
        return (added, removed)
    }
}

/// Changed files as a tree. Click to jump; follows the file you're scrolled to.
///
/// Drawn like the diff canvas: one view the size of the sidebar paints only the
/// visible rows. NSOutlineView built row views when jumping far (~11ms), which
/// made following a fast scrub stutter; this redraws ~40 rows in about 1ms.
final class FileTreeSidebar: NSViewController {
    private let scroll = NSScrollView()
    private let document = FlippedView()
    private let canvas = TreeCanvas()

    private var root = TreeNode(name: "", fileIndex: nil)
    private var leaves: [TreeNode] = []
    private(set) var files: [ReviewFile] = []
    /// Rows currently shown (folders collapse/expand), with their depth.
    private(set) var rows: [(node: TreeNode, depth: Int)] = []
    private var collapsed = Set<ObjectIdentifier>()
    private(set) var selected: TreeNode?

    var onSelectFile: (@MainActor (Int) -> Void)?
    var isDirty: (@MainActor (Int) -> Bool)?

    static let rowHeight: CGFloat = 24

    @objc private func styleChanged() { canvas.needsDisplay = true } // theme colors are baked into rows

    override func loadView() {
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = document
        scroll.contentView.postsBoundsChangedNotifications = true
        canvas.sidebar = self
        document.addSubview(canvas)
        NotificationCenter.default.addObserver(self, selector: #selector(followViewport), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(followViewport), name: NSView.frameDidChangeNotification, object: scroll.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(styleChanged), name: .styleChanged, object: nil)
        view = scroll
    }

    func setFiles(_ newFiles: [ReviewFile]) {
        files = newFiles
        let selectedFile = selected?.fileIndex.map { files.indices.contains($0) ? files[$0].path : "" }
        (root, leaves) = TreeNode.build(files)
        root.total(files)
        selected = selectedFile.flatMap { p in leaves.first { $0.fileIndex.map { files[$0].path } == p } }
        rebuildRows()
    }

    private func rebuildRows() {
        var out: [(TreeNode, Int)] = []
        func walk(_ n: TreeNode, _ depth: Int) {
            for c in n.children {
                out.append((c, depth))
                if c.fileIndex == nil, !collapsed.contains(ObjectIdentifier(c)) { walk(c, depth + 1) }
            }
        }
        walk(root, 0)
        rows = out
        document.frame.size = NSSize(width: scroll.contentSize.width, height: CGFloat(rows.count) * Self.rowHeight + 8)
        followViewport()
    }

    @objc private func followViewport() {
        let v = scroll.contentView.bounds
        document.frame.size.width = v.width
        canvas.frame = NSRect(x: 0, y: v.minY, width: v.width, height: v.height)
        canvas.needsDisplay = true
    }

    /// A file's counts or unsaved state changed.
    func refresh(_ i: Int) {
        root.total(files)
        canvas.needsDisplay = true
    }

    /// Highlight the file currently at the top of the review, and keep it in view. Cheap enough to do live.
    func reveal(_ i: Int) {
        guard i < leaves.count else { return }
        let leaf = leaves[i]
        guard leaf !== selected else { return }
        selected = leaf
        // Show it even inside a collapsed folder.
        var p = leaf.parent
        var expanded = false
        while let n = p { if collapsed.remove(ObjectIdentifier(n)) != nil { expanded = true }; p = n.parent }
        if expanded { rebuildRows() }
        scrollToVisible(leaf)
        canvas.needsDisplay = true
    }

    private func scrollToVisible(_ node: TreeNode) {
        guard let r = rows.firstIndex(where: { $0.node === node }) else { return }
        let y = CGFloat(r) * Self.rowHeight + 4
        let v = scroll.contentView.bounds
        guard y < v.minY || y + Self.rowHeight > v.maxY else { return }
        let target = max(0, min(y - v.height / 2, document.frame.height - v.height)) // center it
        scroll.contentView.scroll(to: NSPoint(x: 0, y: target))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    // MARK: Interaction (from the canvas)

    func row(atDocumentY y: CGFloat) -> Int? {
        let r = Int((y - 4) / Self.rowHeight)
        return rows.indices.contains(r) ? r : nil
    }

    func activate(row r: Int) {
        let node = rows[r].node
        if let i = node.fileIndex {
            selected = node
            canvas.needsDisplay = true
            onSelectFile?(i)
        } else {
            let id = ObjectIdentifier(node)
            if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
            rebuildRows()
        }
    }

    func moveSelection(_ delta: Int) {
        let current = selected.flatMap { s in rows.firstIndex { $0.node === s } } ?? -1
        var r = current + delta
        while rows.indices.contains(r) {
            if rows[r].node.fileIndex != nil { break }
            r += delta // skip folders
        }
        guard rows.indices.contains(r) else { return }
        activate(row: r)
        scrollToVisible(rows[r].node)
    }

    func isCollapsed(_ node: TreeNode) -> Bool { collapsed.contains(ObjectIdentifier(node)) }

    func setCollapsed(_ collapse: Bool) {
        guard let s = selected, let folder = s.parent, folder !== root else { return }
        let id = ObjectIdentifier(folder)
        if collapse { collapsed.insert(id) } else { collapsed.remove(id) }
        rebuildRows()
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Paints the visible sidebar rows.
private final class TreeCanvas: NSView {
    weak var sidebar: FileTreeSidebar?
    private var hoverRow: Int?
    private var icons: [String: NSImage] = [:]

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let r = sidebar?.row(atDocumentY: frame.minY + convert(event.locationInWindow, from: nil).y)
        if r != hoverRow { hoverRow = r; needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) { hoverRow = nil; needsDisplay = true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let sb = sidebar, let r = sb.row(atDocumentY: frame.minY + convert(event.locationInWindow, from: nil).y) else { return }
        sb.activate(row: r)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 125: sidebar?.moveSelection(1)     // ↓
        case 126: sidebar?.moveSelection(-1)    // ↑
        case 123: sidebar?.setCollapsed(true)   // ←
        case 124: sidebar?.setCollapsed(false)  // →
        default: super.keyDown(with: event)
        }
    }

    private func icon(_ symbol: String, _ tint: NSColor) -> NSImage? {
        let key = symbol + tint.description
        if let i = icons[key] { return i }
        guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular)) else { return nil }
        let tinted = NSImage(size: base.size, flipped: false) { rect in
            base.draw(in: rect)
            tint.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        icons[key] = tinted
        return tinted
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let sb = sidebar else { return }
        let h = FileTreeSidebar.rowHeight
        let top = frame.minY
        let first = max(0, Int((top + dirtyRect.minY - 4) / h))
        let last = min(sb.rows.count - 1, Int((top + dirtyRect.maxY - 4) / h))
        guard first <= last else { return }
        let keyWindow = window?.isKeyWindow ?? false
        let nameFont = NSFont.systemFont(ofSize: 12)
        let countFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        let truncating = NSMutableParagraphStyle()
        truncating.lineBreakMode = .byTruncatingMiddle

        for r in first...last {
            let (node, depth) = sb.rows[r]
            let y = CGFloat(r) * h + 4 - top
            let rowRect = NSRect(x: 8, y: y + 1, width: bounds.width - 16, height: h - 2)
            let isSelected = node === sb.selected
            if isSelected {
                (keyWindow ? NSColor.controlAccentColor : NSColor.unemphasizedSelectedContentBackgroundColor).setFill()
                NSBezierPath(roundedRect: rowRect, xRadius: 5, yRadius: 5).fill()
            } else if r == hoverRow {
                NSColor.labelColor.withAlphaComponent(0.06).setFill()
                NSBezierPath(roundedRect: rowRect, xRadius: 5, yRadius: 5).fill()
            }
            let onAccent = isSelected && keyWindow
            var x = 14 + CGFloat(depth) * 14

            // Disclosure + icon
            let file = node.fileIndex.map { sb.files[$0] }
            if file == nil {
                let chevron = sb.isCollapsed(node) ? "chevron.right" : "chevron.down"
                icon(chevron, onAccent ? .white : .tertiaryLabelColor)?.draw(in: NSRect(x: x, y: y + 7, width: 9, height: 10))
            }
            x += 12
            let viewed = file?.viewed == true
            var (symbol, tint): (String, NSColor) = switch file?.status {
            case nil: ("folder", .secondaryLabelColor)
            case .added?, .untracked?: ("doc.badge.plus", DiffStyle.addedAccent)
            case .deleted?: ("doc.badge.minus", DiffStyle.deletedAccent)
            case .modified?: ("doc", DiffStyle.modifiedAccent)
            }
            if viewed { (symbol, tint) = ("checkmark.circle.fill", .tertiaryLabelColor) }
            icon(symbol, onAccent ? .white : tint)?.draw(in: NSRect(x: x, y: y + 5, width: 14, height: 14))
            x += 20

            // Counts (right), then the name truncated to fit.
            let counts = NSMutableAttributedString()
            if node.added > 0 { counts.append(NSAttributedString(string: "+\(node.added)", attributes: [.font: countFont, .foregroundColor: onAccent ? NSColor.white : DiffStyle.addedAccent])) }
            if node.removed > 0 {
                if node.added > 0 { counts.append(NSAttributedString(string: " ", attributes: [.font: countFont])) }
                counts.append(NSAttributedString(string: "−\(node.removed)", attributes: [.font: countFont, .foregroundColor: onAccent ? NSColor.white : DiffStyle.deletedAccent]))
            }
            let cw = ceil(counts.size().width)
            counts.draw(at: NSPoint(x: rowRect.maxX - 6 - cw, y: y + 6))

            let dirty = file != nil && (sb.isDirty?(node.fileIndex!) ?? false)
            let nameColor: NSColor = onAccent ? .white : (viewed ? .secondaryLabelColor : file?.status == .deleted ? .secondaryLabelColor : .labelColor)
            let name = NSAttributedString(string: (dirty ? "● " : "") + node.name,
                                          attributes: [.font: nameFont, .foregroundColor: nameColor, .paragraphStyle: truncating])
            name.draw(with: NSRect(x: x, y: y + 4, width: max(0, rowRect.maxX - 12 - cw - x), height: 16), options: [.usesLineFragmentOrigin])
        }
    }
}
