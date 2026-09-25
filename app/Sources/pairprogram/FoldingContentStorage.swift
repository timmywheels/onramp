import AppKit

/// Content storage that skips folded (hidden) line ranges in O(1) per range.
///
/// Hiding via `shouldEnumerate` makes TextKit build a paragraph element for
/// every hidden line just to reject it, so each layout of a 2,000-line file
/// with 40 visible lines walked all 2,000. Here, enumeration stops at the first
/// hidden element and restarts on the far side of its range.
final class FoldingContentStorage: NSTextContentStorage {
    /// Sorted, non-overlapping UTF-16 ranges of whole hidden lines.
    var hiddenRanges: [NSRange] = []

    /// The hidden range containing `offset`, if any.
    private func hiddenRange(containing offset: Int) -> NSRange? {
        var lo = 0, hi = hiddenRanges.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let r = hiddenRanges[mid]
            if offset < r.location { hi = mid - 1 } else if offset >= NSMaxRange(r) { lo = mid + 1 } else { return r }
        }
        return nil
    }

    override func enumerateTextElements(
        from textLocation: NSTextLocation?,
        options: NSTextContentManager.EnumerationOptions = [],
        using block: (NSTextElement) -> Bool
    ) -> NSTextLocation? {
        guard !hiddenRanges.isEmpty else {
            return super.enumerateTextElements(from: textLocation, options: options, using: block)
        }
        let reverse = options.contains(.reverse)
        let docStart = documentRange.location
        let length = offset(from: docStart, to: documentRange.endLocation)
        var cursor = textLocation.map { offset(from: docStart, to: $0) } ?? (reverse ? length : 0)
        var result: NSTextLocation?

        while cursor >= 0, cursor <= length {
            // Starting inside a hidden range: jump to its far side.
            if let h = hiddenRange(containing: cursor) {
                cursor = reverse ? h.location - 1 : NSMaxRange(h)
                if cursor < 0 || cursor > length { break }
                continue
            }
            guard let start = location(docStart, offsetBy: cursor) else { break }

            var resumeAt: Int?
            var stoppedByCaller = false
            result = super.enumerateTextElements(from: start, options: options) { element in
                if let range = element.elementRange {
                    let o = self.offset(from: docStart, to: range.location)
                    if let h = self.hiddenRange(containing: o) {
                        resumeAt = reverse ? h.location - 1 : NSMaxRange(h)
                        return false
                    }
                }
                if !block(element) { stoppedByCaller = true; return false }
                return true
            }
            guard let next = resumeAt, !stoppedByCaller else { break }
            cursor = next
        }
        return result
    }

    /// Keep hidden ranges aligned with the text between an edit and the next
    /// diff refresh, so layout in between never hides the wrong lines.
    override func processEditing(
        for textStorage: NSTextStorage,
        edited editMask: NSTextStorageEditActions,
        range newCharRange: NSRange,
        changeInLength delta: Int,
        invalidatedRange invalidatedCharRange: NSRange
    ) {
        if editMask.contains(.editedCharacters), delta != 0 {
            let editStart = newCharRange.location
            let oldEditEnd = NSMaxRange(newCharRange) - delta
            hiddenRanges = hiddenRanges.compactMap { r in
                if NSMaxRange(r) <= editStart { return r }                                 // before the edit
                if r.location >= oldEditEnd { return NSRange(location: r.location + delta, length: r.length) } // after
                return nil                                                                 // overlapped: drop until refresh
            }
        }
        super.processEditing(for: textStorage, edited: editMask, range: newCharRange, changeInLength: delta, invalidatedRange: invalidatedCharRange)
    }
}
