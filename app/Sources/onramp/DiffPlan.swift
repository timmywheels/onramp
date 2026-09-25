import AppKit

/// How a file's diff is presented, computed from hunks alone, before any
/// editor exists. The review uses it to size every file in the endless scroll
/// without building 600 editors; the editor uses it to decide what to hide.
/// Both must agree, so this is the single source of truth.
enum DiffPlan {
    /// Merged, sorted ranges of lines that are shown: changes + context, plus
    /// any unchanged lines the user expanded.
    static func visibleRanges(_ hunks: [DiffHunk], lineCount: Int, expanded: [Range<Int>] = []) -> [Range<Int>] {
        guard lineCount > 0 else { return [] }
        guard !hunks.isEmpty else { return [0..<lineCount] }
        let ctx = DiffStyle.contextLines
        var wanted = hunks.map { max(0, Int($0.newStart) - ctx)..<min(lineCount, Int($0.newStart + $0.newLen) + ctx) }
        wanted += expanded.map { max(0, $0.lowerBound)..<min(lineCount, $0.upperBound) }
        wanted.sort { $0.lowerBound < $1.lowerBound }
        var ranges: [Range<Int>] = []
        for r in wanted where r.lowerBound < r.upperBound {
            if let last = ranges.last, r.lowerBound <= last.upperBound {
                ranges[ranges.count - 1] = last.lowerBound..<max(last.upperBound, r.upperBound)
            } else {
                ranges.append(r)
            }
        }
        return ranges
    }

    /// Deleted lines above the file's first line. TextKit ignores spacing before a
    /// document's first paragraph, so the canvas draws these and the editor starts below.
    static func leadingDeletedHeight(_ hunks: [DiffHunk], lineCount: Int) -> CGFloat {
        guard lineCount > 0, let h = hunks.first, h.newStart == 0 else { return 0 }
        return CGFloat(h.deleted.count) * DiffStyle.lineHeight
    }

    /// Exact height of the diff body (canvas rows; the editor covers all but the leading deletions).
    static func height(_ hunks: [DiffHunk], lineCount: Int, expanded: [Range<Int>] = []) -> CGFloat {
        let ranges = visibleRanges(hunks, lineCount: lineCount, expanded: expanded)
        guard !ranges.isEmpty else { return 0 }
        let visible = ranges.reduce(0) { $0 + $1.count }
        var folds = ranges.count - 1
        if ranges.first!.lowerBound > 0 { folds += 1 }
        if ranges.last!.upperBound < lineCount { folds += 1 }
        let deleted = hunks.reduce(0) { $0 + $1.deleted.count }
        return CGFloat(visible + deleted) * DiffStyle.lineHeight + CGFloat(folds) * DiffStyle.foldHeight
    }
}
