import AppKit

/// Highlight spans for one text from the core's tree-sitter highlighter:
/// flat `[start, end, kind, ...]` triples in UTF-16 offsets, sorted and
/// non-overlapping. `kind` indexes `Syntax.names`.
final class SyntaxSpans: @unchecked Sendable {
    let spans: [UInt32]
    var count: Int { spans.count / 3 }

    init(_ spans: [UInt32]) { self.spans = spans }

    /// Index of the first span ending after `offset`.
    private func first(after offset: Int) -> Int {
        var lo = 0, hi = count
        while lo < hi {
            let mid = (lo + hi) / 2
            if Int(spans[mid * 3 + 1]) <= offset { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// Calls `body(range in line, color)` for each colored span in the line
    /// that starts at `start` and is `length` long.
    func forEach(inLineAt start: Int, length: Int, _ body: (NSRange, NSColor) -> Void) {
        let end = start + length
        var k = first(after: start)
        while k < count, Int(spans[k * 3]) < end {
            if let color = DiffStyle.syntaxColor(Int(spans[k * 3 + 2])) {
                let a = max(Int(spans[k * 3]), start), b = min(Int(spans[k * 3 + 1]), end)
                if b > a { body(NSRange(location: a - start, length: b - a), color) }
            }
            k += 1
        }
    }

    /// `line` (starting at `start` in the highlighted text) with colors applied over `attrs`.
    func attributed(_ line: String, at start: Int, attrs: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let s = NSMutableAttributedString(string: line, attributes: attrs)
        forEach(inLineAt: start, length: s.length) { range, color in s.addAttribute(.foregroundColor, value: color, range: range) }
        return s
    }
}

/// Runs the core highlighter off the main thread. Files are highlighted the
/// first time they're drawn, a few at a time, so a big review costs nothing
/// until you scroll to it.
enum Syntax {
    static let names: [String] = highlightNames()

    // Utility priority and two workers: highlighting must never compete with
    // scrolling for the CPU.
    private static let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "onramp.syntax"
        q.maxConcurrentOperationCount = 2
        q.qualityOfService = .utility
        return q
    }()

    /// Files on screen right now (set by the canvas every frame). Dragging the
    /// scrollbar passes hundreds of files; their jobs skip themselves if the
    /// file is gone by the time a worker gets to them.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var onScreen: Set<String> = []

    static func setOnScreen(_ paths: Set<String>) {
        lock.lock(); onScreen = paths; lock.unlock()
    }

    /// Mark one file on screen now: its job may start before the frame that
    /// asked for it finishes and publishes the full set.
    private static func markOnScreen(_ path: String) {
        lock.lock(); onScreen.insert(path); lock.unlock()
    }

    /// Highlight right now, on this (background) thread: for files about to be swapped in on screen.
    static func highlightNow(path: String, text: String) -> SyntaxSpans? {
        onramp.highlight(path: path, text: text).map(SyntaxSpans.init)
    }

    static func isOnScreen(_ path: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return onScreen.contains(path)
    }

    enum Result { case spans(SyntaxSpans), noLanguage, skipped }

    /// Highlight `text` as the file at `path`; `done` runs on the main thread.
    /// With `onlyIfOnScreen`, the job is skipped when the file scrolled away.
    static func highlight(path: String, text: String, onlyIfOnScreen: Bool = false, done: @escaping @MainActor (Result) -> Void) {
        if onlyIfOnScreen { markOnScreen(path) }
        queue.addOperation {
            let result: Result
            if onlyIfOnScreen, !isOnScreen(path) {
                result = .skipped
            } else {
                result = onramp.highlight(path: path, text: text).map { .spans(SyntaxSpans($0)) } ?? .noLanguage
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { done(result) } }
        }
    }
}
