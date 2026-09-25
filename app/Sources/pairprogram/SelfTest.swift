import AppKit

/// PP_SELFTEST=1: types into the biggest file and scrolls the whole review.
/// PP_SELFTEST=jump: simulates dragging the scroll thumb far down and back.
/// Prints timings. Uses the same input path as the keyboard.
@MainActor
enum SelfTest {
    private static var started = false

    static func run(review: ReviewView) {
        guard !started, ProcessInfo.processInfo.environment["PP_SELFTEST"] != nil else { return }
        started = true // reloads (mode switches, ⌘R) call this again; tests run once
        let scrollView = review.scrollView
        let mode = ProcessInfo.processInfo.environment["PP_SELFTEST"]
        if mode == "jump" { return runJump(scrollView: scrollView) }
        if mode == "expand" || mode == "expand-edit" {
            // Click the first two fold rows of STTextView.swift, as a user would.
            let doc = review.document
            guard let i = doc.files.firstIndex(where: { $0.path == "STTextView.swift" }) else { return log("no file") }
            for _ in 0..<2 {
                let layout = doc.files[i].layout
                guard let row = layout.rows.first(where: { if case .fold = $0.kind { return true } else { return false } }) else { break }
                if case let .fold(s, e) = row.kind { log("click fold \(s)..<\(e)") }
                // second click: next fold after the first expansion
                let rows = layout.rows.filter { if case .fold = $0.kind { return true } else { return false } }
                let target = doc.files[i].expanded.isEmpty ? rows[0] : rows[min(1, rows.count - 1)]
                doc.click(atDocumentY: doc.frame(ofFile: i).minY + target.y + 2, x: 100)
            }
            log("expanded \(doc.files[i].expanded)")
            _ = frame(review.scrollView, to: doc.frame(ofFile: i).minY)
            if mode == "expand-edit" { doc.activateEditor(i, offset: 0); log("editor open") }
            return
        }
        if mode == "expand-in-editor" {
            Task { @MainActor in
                let doc = review.document
                guard let i = doc.files.firstIndex(where: { $0.path == "STTextView.swift" }),
                      let editor = doc.activateEditor(i, offset: 0) else { return log("no editor") }
                _ = frame(review.scrollView, to: doc.frame(ofFile: i).minY)
                try? await Task.sleep(nanoseconds: 200_000_000)
                let tv = editor.textView
                var target: CGPoint?
                tv.layout.enumerateTextLayoutFragments(from: tv.layout.documentRange.location, options: [.ensuresLayout]) { f in
                    if let d = f as? DiffLayoutFragment, (d.band?.foldAbove ?? 0) > 0 {
                        target = CGPoint(x: 200, y: f.layoutFragmentFrame.minY + 5); return false
                    }
                    return true
                }
                guard let p = target else { return log("no fold band in editor") }
                let before = doc.files[i].expanded
                let event = NSEvent.mouseEvent(with: .leftMouseDown, location: tv.convert(p, to: nil), modifierFlags: [],
                                               timestamp: 0, windowNumber: tv.window!.windowNumber, context: nil,
                                               eventNumber: 0, clickCount: 1, pressure: 1)!
                tv.mouseDown(with: event)
                log("before \(before) after \(doc.files[i].expanded)  editor height \(tv.fixedHeight)")
            }
            return
        }
        if mode == "sticky" {
            // The reported bug: with an editor open in a file, clicking its pinned header must fold it,
            // and clicking "Viewed" there must mark it (both used to go to the editor underneath).
            Task { @MainActor in
                let doc = review.document
                guard doc.files.count > 1, doc.activateEditor(1, offset: 0) != nil else { return log("no editor") }
                _ = frame(review.scrollView, to: doc.frame(ofFile: 1).minY + 120)
                try? await Task.sleep(nanoseconds: 300_000_000)
                let sticky = doc.stickyHeader
                @MainActor func click(_ p: CGPoint) {
                    let e = NSEvent.mouseEvent(with: .leftMouseDown, location: sticky.convert(p, to: nil), modifierFlags: [], timestamp: 0,
                                               windowNumber: sticky.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                    let hit = sticky.window!.contentView!.hitTest(sticky.window!.contentView!.convert(e.locationInWindow, from: nil))
                    log("click \(p) → \(hit.map { String(describing: type(of: $0)) } ?? "nil") sticky.frame \(sticky.frame) hidden \(sticky.isHidden)")
                    sticky.window!.sendEvent(e) // real hit testing: whatever view is on top gets it
                }
                log("sticky shown \(!sticky.isHidden) for file \(sticky.fileIndex)")
                click(CGPoint(x: 200, y: 10))
                log("after header click: collapsed \(doc.files[1].collapsed)")
                doc.toggleCollapse(1) // open again
                _ = frame(review.scrollView, to: doc.frame(ofFile: 1).minY + 120)
                try? await Task.sleep(nanoseconds: 200_000_000)
                let v = FileHeader.viewedRect(width: sticky.bounds.width)
                click(CGPoint(x: v.minX + 5, y: 10))
                log("after Viewed click: viewed \(doc.files[1].viewed) collapsed \(doc.files[1].collapsed)")
                doc.toggleViewed(1) // leave it as it was
                log("done")
            }
            return
        }
        if mode == "ui" {
            // Screenshot setup: file 0 viewed, scrolled into file 1 (sticky header), then a popover.
            Task { @MainActor in
                let doc = review.document
                if doc.files.count > 1, !doc.files[0].viewed, ProcessInfo.processInfo.environment["PP_NO_VIEW"] == nil { doc.toggleViewed(0) }
                if doc.files.count > 1 { _ = frame(review.scrollView, to: doc.frame(ofFile: 1).minY + 140) }
                try? await Task.sleep(nanoseconds: 300_000_000)
                if let w = review.window, let screen = w.screen {
                    let f = w.frame
                    log("window \(Int(f.minX)),\(Int(screen.frame.height - f.maxY)),\(Int(f.width)),\(Int(f.height)) id \(w.windowNumber)")
                }
                if ProcessInfo.processInfo.environment["PP_TYPE"] != nil, let e = doc.activateEditor(1, offset: doc.files[1].lineStarts[min(17, doc.files[1].lineCount - 1)]) {
                    e.textView.insertText("const greeting = \"typed in the editor\"; // re-highlighted\n", replacementRange: e.textView.selectedRange())
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    var info = ""
                    e.textView.layout.enumerateTextLayoutFragments(from: e.textView.layout.documentRange.location, options: [.ensuresLayout]) { f in
                        info = "fragment.minX \(f.layoutFragmentFrame.minX) line.minX \(f.textLineFragments.first?.typographicBounds.minX ?? -1)"
                        return false
                    }
                    log("editor: host.x \(e.host.frame.minX) textView.x \(e.textView.frame.minX) padding \(e.textView.textContainer!.lineFragmentPadding) inset \(e.textView.textContainerInset.width) \(info) · canvas textX \(DiffStyle.gutterWidth + 5)")
                }
                log("ready")
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                let popover = ProcessInfo.processInfo.environment["PP_POPOVER"]
                if popover == "review" { review.showReview() }
                if popover == "connect" { review.showConnect() }
                try? await Task.sleep(nanoseconds: 500_000_000)
                let ids = NSApp.windows.filter { $0 !== review.window && $0.isVisible }.map { "\($0.windowNumber)" }
                log("popover ids \(ids.joined(separator: ","))")
            }
            return
        }
        if mode == "base" {
            // Branch vs uncommitted toggle: log what each mode shows, then restore branch mode.
            Task { @MainActor in
                log("branch: \(review.document.files.count) files · \(review.statusText)")
                review.setMode(.uncommitted)
                log("uncommitted: \(review.document.files.count) files · \(review.statusText)")
                review.setMode(.branch)
                log("branch again: \(review.document.files.count) files")
            }
            return
        }
        if mode == "fonts" {
            // Default font comes from the lilex extension; ligatures toggle changes the glyphs for "->".
            let style = Style.shared
            func glyphs(_ font: NSFont) -> [CGGlyph] {
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: "a -> b != c", attributes: [.font: font]))
                return (CTLineGetGlyphRuns(line) as! [CTRun]).flatMap { run in
                    var g = [CGGlyph](repeating: 0, count: CTRunGetGlyphCount(run))
                    CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &g)
                    return g
                }
            }
            let on = glyphs(DiffStyle.font)
            log("font \(DiffStyle.font.familyName ?? "?") \(DiffStyle.font.pointSize)  header \(DiffStyle.headerFont.fontName)")
            style.update { $0.fontLigatures = false }
            let off = glyphs(DiffStyle.font)
            style.update { $0.fontLigatures = true }
            log("ligatures change glyphs: \(on != off)  line height \(DiffStyle.lineHeight)")
            log("themes: \(style.themes.map(\.name).joined(separator: ", "))")
            log("families: \(style.monospaceFamilies.prefix(6).joined(separator: ", ")) … (\(style.monospaceFamilies.count))")
            log("problems: \(Extensions.problems.map(\.message))")
            return
        }
        if mode == "sidebar" {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 300_000_000)
                let doc = review.document
                log("before: clip \(review.scrollView.contentView.bounds) docH \(doc.frame.height) top12 \(doc.frame(ofFile: 12).minY)")
                doc.scrollToFile(12) // like clicking file 12 in the tree
                log("after: clip \(review.scrollView.contentView.bounds)")
                try? await Task.sleep(nanoseconds: 500_000_000)
                log("later: clip \(review.scrollView.contentView.bounds)")
            }
            return
        }
        if mode == "comment" {
            Task { @MainActor in
                let doc = review.document
                guard let i = doc.files.firstIndex(where: { $0.path == "STTextView.swift" }) else { return log("no file") }
                doc.scrollToFile(i)
                doc.startComment(i, CommentTarget(line: 40, old: ProcessInfo.processInfo.environment["PP_OLD"] == "1"))
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard let composer = doc.composerView(i) else { return log("no composer") }
                let focused = composer.window?.firstResponder === composer.input.textView
                composer.input.textView.insertText("This comment is misleading. Say what the line actually does.", replacementRange: NSRange(location: NSNotFound, length: 0))
                try? await Task.sleep(nanoseconds: 300_000_000)
                composer.input.textView.onSubmit?() // ⌘↩
                try? await Task.sleep(nanoseconds: 200_000_000)
                log("composer focused=\(focused); threads on file: \(doc.files[i].threads.map { "\($0.thread.id)@\($0.line.map { String($0 + 1) } ?? "?")" })")
                if ProcessInfo.processInfo.environment["PP_OPEN_EDITOR"] == "1" {
                    if let e = doc.activateEditor(i, offset: doc.files[i].lineStarts[42]) {
                        let st = e.textView.folding.textStorage!
                        let at = e.lineStarts[45]
                        let ps = st.attribute(.paragraphStyle, at: at, effectiveRange: nil) as? NSParagraphStyle
                        log("editor open; line 46 indent=\(ps?.headIndent ?? -1) font=\((st.attribute(.font, at: at, effectiveRange: nil) as? NSFont)?.pointSize ?? -1) typingIndent=\((e.textView.typingAttributes[.paragraphStyle] as? NSParagraphStyle)?.headIndent ?? -1) rich=\(e.textView.isRichText)")
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        let ps2 = st.attribute(.paragraphStyle, at: at, effectiveRange: nil) as? NSParagraphStyle
                        log("after 300ms: indent=\(ps2?.headIndent ?? -1)")
                    }
                }
                guard ProcessInfo.processInfo.environment["PP_EDIT"] == "1", let t = doc.files[i].threads.first else { return }
                // Hover a line (pointer over the code), then edit the comment in place.
                let layout = doc.files[i].layout
                if let row = layout.rows.first(where: { if case .line(44, _) = $0.kind { return true } else { return false } }) {
                    let p = doc.convert(NSPoint(x: 400, y: doc.frame(ofFile: i).minY + row.y + 3), to: nil)
                    doc.mouseMoved(with: NSEvent.mouseEvent(with: .mouseMoved, location: p, modifierFlags: [], timestamp: 0,
                                                            windowNumber: doc.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!)
                }
                doc.threadView(t.thread.id)?.onStartEdit?(0)
                try? await Task.sleep(nanoseconds: 300_000_000)
                log("editing: \(doc.threadView(t.thread.id)?.editInput?.textView.string ?? "nil")")
                if ProcessInfo.processInfo.environment["PP_EDIT_SAVE"] == "1" {
                    doc.threadView(t.thread.id)?.onSaveEdit?(0, "Edited: say what the plugins list is for.")
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    log("after save: \(doc.files[i].threads.first?.thread.entries.first?.body ?? "nil")")
                }
            }
            return
        }
        if mode == "connect" { return review.showConnect() }
        if mode == "gutter-comment" {
            // Open the editor, then click line 44's number inside it (the host's gutter).
            Task { @MainActor in
                let doc = review.document
                guard let i = doc.files.firstIndex(where: { $0.path == "STTextView.swift" }),
                      let e = doc.activateEditor(i, offset: doc.files[i].lineStarts[44]) else { return log("no editor") }
                try? await Task.sleep(nanoseconds: 300_000_000)
                var y: CGFloat?
                e.textView.layout.enumerateTextLayoutFragments(from: e.textView.layout.documentRange.location, options: [.ensuresLayout]) { f in
                    if e.lineIndex(forOffset: e.textView.folding.offset(from: e.textView.folding.documentRange.location, to: f.rangeInElement.location)) == 43 {
                        y = f.layoutFragmentFrame.minY + (f.textLineFragments.first?.typographicBounds.minY ?? 0) + 3; return false
                    }
                    return true
                }
                guard let y else { return log("line not laid out") }
                let p = e.host.convert(NSPoint(x: 20, y: y), to: nil)
                e.host.mouseDown(with: NSEvent.mouseEvent(with: .leftMouseDown, location: p, modifierFlags: [], timestamp: 0,
                                                         windowNumber: e.host.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
                try? await Task.sleep(nanoseconds: 300_000_000)
                log("composer: \(doc.files[i].composer.map { "line \($0.line + 1) old=\($0.old)" } ?? "none")")
            }
            return
        }
        if mode == "open-time" {
            // Click-to-edit latency: build the editor, lay it out, and draw it.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 300_000_000)
                let doc = review.document
                let order = doc.files.indices.sorted { doc.files[$0].lineCount > doc.files[$1].lineCount }.prefix(5)
                for i in order {
                    doc.scrollToFile(i)
                    doc.window?.displayIfNeeded()
                    let t0 = CACurrentMediaTime()
                    _ = doc.activateEditor(i, offset: 0)
                    doc.window?.layoutIfNeeded()
                    doc.window?.displayIfNeeded()
                    CATransaction.flush()
                    log(String(format: "open %@ (%d lines): %.1fms", doc.files[i].path, doc.files[i].lineCount, (CACurrentMediaTime() - t0) * 1000))
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                log("done")
            }
            return
        }
        if mode == "review" {
            // Start a review with two comments, check agents can't see them, then submit + hand off.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 400_000_000)
                let doc = review.document
                @MainActor func comment(_ path: String, _ line: Int, _ text: String) async {
                    guard let i = doc.files.firstIndex(where: { $0.path == path }) else { return log("no \(path)") }
                    doc.scrollToFile(i)
                    doc.startComment(i, CommentTarget(line: line, old: false))
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    guard let c = doc.composerView(i) else { return log("no composer") }
                    c.input.textView.string = text
                    // First comment: "Start a review" (secondary); later ones: "Add to review" (primary).
                    if doc.pendingCount == 0 { c.input.onSecondary?(text) } else { c.input.onSubmit?(text) }
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
                await comment("tests/todos.test.ts", 0, "updateTodo is used in the last test but never imported, so this file won't compile.")
                await comment("src/api/rate-limit.ts", 2, "This map never shrinks: every user who ever made a request stays in memory forever. Evict users with no recent hits.")
                log("pending after 2 comments: \(doc.pendingCount)")
                if let i = doc.files.firstIndex(where: { $0.path == "tests/todos.test.ts" }) { doc.scrollToFile(i) }
                try? await Task.sleep(nanoseconds: 300_000_000)
                log("ready for screenshot")
                guard let target = ProcessInfo.processInfo.environment["PP_SEND"].flatMap(AgentRunner.Target.init(rawValue:)) else { return }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                review.submit(body: "Two issues before this can merge.", verdict: .requestChanges, target: target)
                log("submitted; pending now \(doc.pendingCount); agent \(review.agentState)")
                while case .running = review.agentState { try? await Task.sleep(nanoseconds: 1_000_000_000) }
                log("agent done: \(review.agentState)")
            }
            return
        }
        if mode == "fold" {
            // Click the first two file headers, as a user would.
            let doc = review.document
            for i in [0, 1] where i < doc.files.count {
                doc.click(atDocumentY: doc.frame(ofFile: i).minY + 5, x: 20)
            }
            return log("folded \(doc.files.prefix(2).map(\.path)); collapsed=\(doc.files.prefix(3).map(\.collapsed))")
        }
        guard mode == "1" else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            let doc = review.document
            // Biggest text file: scroll to it and open its editor, like a click would.
            guard let target = doc.files.indices.max(by: { doc.files[$0].lineCount < doc.files[$1].lineCount }),
                  let hunk = doc.files[target].hunks.first else { return log("no text files") }
            _ = frame(scrollView, to: doc.frame(ofFile: target).minY)
            let file = doc.files[target]
            guard let editor = doc.activateEditor(target, offset: file.lineStarts[min(Int(hunk.newStart), file.lineCount - 1)]) else {
                return log("no editor for target file")
            }
            let section = (file: file, editor: editor)
            log("typing into \(section.file.path) (\(editor.lineStarts.count) lines)")

            var samples: [String] = []
            let keys = Array("fast") + ["\n"] + Array("typing")
            for key in keys {
                let line = Int(hunk.newStart)
                let at = editor.lineStarts[min(line, editor.lineStarts.count - 1)]
                let t0 = CACurrentMediaTime()
                editor.textView.insertText(String(key), replacementRange: NSRange(location: at, length: 0))
                let insertMs = (CACurrentMediaTime() - t0) * 1000
                try? await Task.sleep(nanoseconds: 30_000_000)
                samples.append(String(format: "%@ insert %.1fms + re-diff %.1fms (%d lines restyled) [%@]",
                                      key == "\n" ? "⏎" : String(key), insertMs, editor.lastRefreshMs, editor.lastRestyledLines, editor.lastBreakdown))
            }
            samples.forEach { log("  " + $0) }
            log("done")
        }
    }

    /// One frame's worth of work, including the Core Animation commit.
    /// Accumulated per-phase time: scroll (builds sections), layout, display, commit.
    static var phases: [Double] = [0, 0, 0, 0]

    static func frame(_ scrollView: NSScrollView, to y: CGFloat) -> Double {
        let t0 = CACurrentMediaTime()
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        let t1 = CACurrentMediaTime()
        scrollView.window?.layoutIfNeeded()
        let t2 = CACurrentMediaTime()
        scrollView.window?.displayIfNeeded()
        let t3 = CACurrentMediaTime()
        CATransaction.flush()
        let t4 = CACurrentMediaTime()
        for (i, d) in [t1 - t0, t2 - t1, t3 - t2, t4 - t3].enumerated() { phases[i] += d * 1000 }
        return (t4 - t0) * 1000
    }

    static func runJump(scrollView: NSScrollView) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            let height = scrollView.documentView!.frame.height - scrollView.contentSize.height
            log(String(format: "document height %.0fpt", height))
            for pass in ["cold", "warm"] {
                var ms: [Double] = []
                // Thumb drag: 0 → 75% in 40 frames, then back to 10% in 40 frames.
                // Frames are paced at 120 Hz like real scrolling; back-to-back frames
                // otherwise measure waiting for the window server, not our work.
                var targets: [CGFloat] = []
                if ProcessInfo.processInfo.environment["PP_WHEEL"] == "1" {
                    // Fast trackpad flick: 40pt per frame for 240 frames (~2 s at 120 Hz).
                    targets = (0..<240).map { height * 0.4 + CGFloat($0) * 40 }
                } else {
                    targets = (0...40).map { height * 0.75 * CGFloat($0) / 40 }
                        + (0...40).map { height * (0.75 - 0.65 * CGFloat($0) / 40) }
                }
                for y in targets {
                    ms.append(frame(scrollView, to: y))
                    try? await Task.sleep(nanoseconds: 8_333_000)
                }
                let sorted = ms.sorted()
                let slow = ms.filter { $0 > 8.3 }.count
                let n = Double(ms.count)
                log(String(format: "  phases avg: build %.1fms  layout %.1fms  display %.1fms  commit %.1fms",
                           phases[0] / n, phases[1] / n, phases[2] / n, phases[3] / n))
                phases = [0, 0, 0, 0]
                log(String(format: "%@ drag: avg %.1fms  p50 %.1fms  p95 %.1fms  worst %.1fms  frames>8.3ms: %d/%d",
                           pass, ms.reduce(0, +) / Double(ms.count), sorted[ms.count / 2], sorted[ms.count * 95 / 100], sorted.last!, slow, ms.count))
                if ProcessInfo.processInfo.environment["PP_STAY"] == nil { _ = frame(scrollView, to: 0) }
            }
            log("done")
        }
    }

    static func log(_ s: String) {
        FileHandle.standardError.write(("[selftest] " + s + "\n").data(using: .utf8)!)
    }
}
