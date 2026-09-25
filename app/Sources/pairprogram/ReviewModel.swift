import AppKit

/// One changed file, mutable as the user (or agent) edits it.
final class ReviewFile {
    enum Kind: Equatable {
        case text
        case deleted(lines: Int)
        case binary
        case tooLarge(bytes: UInt64)
    }

    let path: String
    let status: FileStatus
    let kind: Kind
    let oldText: String
    private(set) var newText: NSString
    private(set) var hunks: [DiffHunk]
    private(set) var lineStarts: [Int] = []
    var collapsed = false
    /// The file changed on disk while you had unsaved edits in it.
    var changedOnDisk = false
    /// Unchanged line ranges the user expanded, like GitHub's "show more lines".
    var expanded: [Range<Int>] = [] {
        didSet { cachedLayout = nil }
    }

    /// Comment threads on this file, located in its current text.
    var threads: [LocatedThread] = [] {
        didSet { cachedLayout = nil }
    }
    /// Where a new-comment box is open: a current line, or a deleted (old) line.
    var composer: CommentTarget? {
        didSet { cachedLayout = nil }
    }
    /// Thread with its reply box open.
    var replyingTo: String? {
        didSet { cachedLayout = nil }
    }
    /// Entry being edited in place.
    var editingEntry: (id: String, index: Int)? {
        didSet { cachedLayout = nil }
    }

    func threadHeight(_ t: LocatedThread) -> CGFloat {
        CommentMetrics.threadRowHeight(t, replying: replyingTo == t.thread.id,
                                       editing: editingEntry?.id == t.thread.id ? editingEntry?.index : nil)
    }

    var visibleThreads: [LocatedThread] {
        threads.filter { ReviewFile.showResolved || $0.thread.status == .open }
    }
    nonisolated(unsafe) static var showResolved = false

    var openThreadCount: Int { threads.filter { $0.thread.status == .open }.count }

    /// Where a comment box goes.
    enum Placement: Equatable {
        case line(Int)          // under a current line
        case deletedBlock(Int)  // under the red block of this hunk
        case outdated           // its line is gone: top of the file
    }

    /// Hunk whose deleted lines include old (HEAD) line `l`.
    func hunk(forOldLine l: Int) -> Int? {
        hunks.firstIndex { !$0.deleted.isEmpty && l >= Int($0.oldStart) && l < Int($0.oldStart) + $0.deleted.count }
    }

    private func place(line: Int?, old: Bool) -> Placement {
        guard let l = line else { return .outdated }
        if old { return hunk(forOldLine: l).map { .deletedBlock($0) } ?? .outdated }
        return l < lineCount ? .line(l) : .outdated
    }

    func placement(_ t: LocatedThread) -> Placement { place(line: t.line.map(Int.init), old: t.thread.anchor.oldSide) }
    var composerPlacement: Placement? { composer.map { place(line: $0.line, old: $0.old) } }

    /// Lines kept visible: expanded context plus commented lines (and one line around them).
    var revealed: [Range<Int>] {
        var r = expanded
        for t in visibleThreads { if case let .line(l) = placement(t) { r.append(max(0, l - 1)..<(l + 2)) } }
        if case let .line(c)? = composerPlacement { r.append(max(0, c - 1)..<(c + 2)) }
        return r
    }

    /// Height of comment boxes under each current line (the editor makes room).
    var commentSpace: [Int: CGFloat] {
        var space: [Int: CGFloat] = [:]
        for t in visibleThreads { if case let .line(l) = placement(t) { space[l, default: 0] += threadHeight(t) } }
        if case let .line(c)? = composerPlacement { space[c, default: 0] += CommentMetrics.composerRowHeight }
        return space
    }

    /// Height of comment boxes under each red block, keyed by the new line the
    /// block sits above (== line count for a block at the end of the file).
    var deletedCommentSpace: [Int: CGFloat] {
        var space: [Int: CGFloat] = [:]
        for t in visibleThreads { if case let .deletedBlock(h) = placement(t) { space[Int(hunks[h].newStart), default: 0] += threadHeight(t) } }
        if case let .deletedBlock(h)? = composerPlacement { space[Int(hunks[h].newStart), default: 0] += CommentMetrics.composerRowHeight }
        return space
    }

    /// Rendered text lines for the canvas, by row key. Dropped when the text changes.
    var lineCache: [Int: CTLine] = [:]
    private var cachedLayout: FileLayout?

    init(_ diff: FileDiff) {
        path = diff.path
        status = diff.status
        switch diff.body {
        case let .text(old, new, hunks, _):
            kind = .text; oldText = old; newText = new as NSString; self.hunks = hunks
            lineStarts = Self.lineStarts(of: newText)
        case let .deleted(n):
            kind = .deleted(lines: Int(n)); oldText = ""; newText = ""; hunks = []
        case .binary:
            kind = .binary; oldText = ""; newText = ""; hunks = []
        case let .tooLarge(bytes):
            kind = .tooLarge(bytes: bytes); oldText = ""; newText = ""; hunks = []
        }
    }

    var lineCount: Int { lineStarts.count }
    var added: Int { hunks.reduce(0) { $0 + Int($1.newLen) } }
    var removed: Int {
        if case let .deleted(n) = kind { return n }
        return hunks.reduce(0) { $0 + $1.deleted.count }
    }

    /// The editor changed the text: adopt it so the canvas draws the same thing.
    func update(text: String, hunks: [DiffHunk]) {
        newText = text as NSString
        self.hunks = hunks
        lineStarts = Self.lineStarts(of: newText)
        lineCache = [:]
        cachedLayout = nil
    }

    /// Font changed: row heights and rendered lines are stale.
    func invalidateLayout() {
        cachedLayout = nil
        lineCache = [:]
    }

    var layout: FileLayout {
        if let cachedLayout, cachedLayout.collapsed == collapsed { return cachedLayout }
        let l = FileLayout(self)
        cachedLayout = l
        return l
    }

    var height: CGFloat { layout.height }

    /// Text of line `i` without its newline.
    func line(_ i: Int) -> String {
        let start = lineStarts[i]
        var end = i + 1 < lineStarts.count ? lineStarts[i + 1] : newText.length
        while end > start, let c = Optional(newText.character(at: end - 1)), c == 10 || c == 13 { end -= 1 }
        return newText.substring(with: NSRange(location: start, length: end - start))
    }

    static func lineStarts(of s: NSString) -> [Int] {
        let length = s.length
        guard length > 0 else { return [] }
        var starts = [0]
        let buffer = UnsafeMutablePointer<unichar>.allocate(capacity: length)
        defer { buffer.deallocate() }
        s.getCharacters(buffer, range: NSRange(location: 0, length: length))
        for i in 0..<(length - 1) where buffer[i] == 10 { starts.append(i + 1) }
        return starts
    }
}

/// A line you can comment on: current text, or a deleted line (HEAD numbering).
struct CommentTarget: Equatable {
    let line: Int
    let old: Bool
}

/// What the canvas draws for one file, top to bottom.
struct Row {
    enum Kind {
        case header
        case fold(start: Int, end: Int) // hidden unchanged lines start..<end
        case deleted(hunk: Int, index: Int)
        case line(Int, added: Bool)
        case note(String)
        case thread(String) // comment thread id (drawn by a CommentThreadView)
        case composer(Int)  // new-comment box under this line
        case spacer
    }

    let kind: Kind
    let y: CGFloat // relative to the file's top
    let height: CGFloat

    /// Stable key for caching this row's rendered text.
    var cacheKey: Int? {
        switch kind {
        case let .line(i, _): i
        case let .deleted(h, k): -1 - (h << 16 | k)
        default: nil
        }
    }
}

/// Rows for one file. Body rows follow DiffPlan exactly, so the height here is
/// the height the editor lays out when you click into the file.
struct FileLayout {
    static var headerHeight: CGFloat { ceil(DiffStyle.font.pointSize * 2.4) }
    static var spacing: CGFloat { ceil(DiffStyle.font.pointSize * 1.1) }
    static var noteHeight: CGFloat { ceil(DiffStyle.font.pointSize * 1.9) }

    let rows: [Row]
    let height: CGFloat
    let collapsed: Bool

    /// Offset of the body from the file's top.
    static var bodyTop: CGFloat { headerHeight }

    /// Where the editor starts: at the first code line. Everything above it
    /// (outdated threads, deletions above line 1 and their comments) is drawn
    /// by the canvas and comment views.
    static func editorTop(_ file: ReviewFile) -> CGFloat {
        file.layout.rows.first { if case .line = $0.kind { return true } else { return false } }?.y ?? bodyTop
    }

    init(_ file: ReviewFile) {
        collapsed = file.collapsed
        var rows: [Row] = []
        var y: CGFloat = 0
        func add(_ kind: Row.Kind, _ h: CGFloat) { rows.append(Row(kind: kind, y: y, height: h)); y += h }

        add(.header, Self.headerHeight)
        if !file.collapsed {
            // Threads whose line no longer exists ("outdated") sit at the top of the file.
            for t in file.visibleThreads where file.placement(t) == .outdated {
                add(.thread(t.thread.id), file.threadHeight(t))
            }
            switch file.kind {
            case .text:
                Self.addBody(file, add)
            case let .deleted(n):
                add(.note("File deleted (\(n) lines)"), Self.noteHeight)
            case .binary:
                add(.note("Binary file"), Self.noteHeight)
            case let .tooLarge(bytes):
                add(.note("Too large to show (\(bytes / 1000) KB)"), Self.noteHeight)
            }
            add(.spacer, Self.spacing)
        }
        self.rows = rows
        self.height = y
    }

    private static func addBody(_ file: ReviewFile, _ add: (Row.Kind, CGFloat) -> Void) {
        let lineCount = file.lineCount
        let ranges = DiffPlan.visibleRanges(file.hunks, lineCount: lineCount, expanded: file.revealed)
        var threadsAt: [Int: [LocatedThread]] = [:]
        var threadsUnderBlock: [Int: [LocatedThread]] = [:] // hunk → threads on its deleted lines
        for t in file.visibleThreads {
            switch file.placement(t) {
            case let .line(l): threadsAt[l, default: []].append(t)
            case let .deletedBlock(h): threadsUnderBlock[h, default: []].append(t)
            case .outdated: break
            }
        }
        func addDeleted(_ h: Int) {
            for k in file.hunks[h].deleted.indices { add(.deleted(hunk: h, index: k), DiffStyle.lineHeight) }
            for t in threadsUnderBlock[h] ?? [] { add(.thread(t.thread.id), file.threadHeight(t)) }
            if file.composerPlacement == .deletedBlock(h), let c = file.composer { add(.composer(c.line), CommentMetrics.composerRowHeight) }
        }
        guard !ranges.isEmpty else { return }
        let L = DiffStyle.lineHeight

        // Deleted lines, keyed by the new line they're drawn above.
        var deletedAbove: [Int: Int] = [:] // line → hunk index
        var deletedAtEnd: Int?
        for (h, hunk) in file.hunks.enumerated() where !hunk.deleted.isEmpty {
            if Int(hunk.newStart) < lineCount { deletedAbove[Int(hunk.newStart)] = h } else { deletedAtEnd = h }
        }
        var addedLines = IndexSet()
        for hunk in file.hunks where hunk.newLen > 0 {
            addedLines.insert(integersIn: Int(hunk.newStart)..<Int(hunk.newStart + hunk.newLen))
        }

        var cursor = 0
        for r in ranges {
            if r.lowerBound > cursor { add(.fold(start: cursor, end: r.lowerBound), DiffStyle.foldHeight) }
            for i in r {
                if let h = deletedAbove[i] { addDeleted(h) }
                add(.line(i, added: addedLines.contains(i)), L)
                for t in threadsAt[i] ?? [] {
                    add(.thread(t.thread.id), file.threadHeight(t))
                }
                if file.composerPlacement == .line(i) { add(.composer(i), CommentMetrics.composerRowHeight) }
            }
            cursor = r.upperBound
        }
        if let h = deletedAtEnd { addDeleted(h) }
        if cursor < lineCount { add(.fold(start: cursor, end: lineCount), DiffStyle.foldHeight) }
    }

    /// Index of the row containing y (relative to the file's top).
    func rowIndex(at y: CGFloat) -> Int {
        var lo = 0, hi = rows.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if rows[mid].y <= y { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }
}
