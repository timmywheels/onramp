import AppKit

/// ONRAMP_SELFTEST=1: types into the biggest file and scrolls the whole review.
/// ONRAMP_SELFTEST=jump: simulates dragging the scroll thumb far down and back.
/// Prints timings. Uses the same input path as the keyboard.
@MainActor
enum SelfTest {
    private static var started = false

    static func run(review: ReviewView) {
        guard !started, ProcessInfo.processInfo.environment["ONRAMP_SELFTEST"] != nil else { return }
        started = true // reloads (mode switches, ⌘R) call this again; tests run once
        let scrollView = review.scrollView
        let mode = ProcessInfo.processInfo.environment["ONRAMP_SELFTEST"]
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
        if mode == "menus" {
            Task { @MainActor in
                for title in ["View", "File", "Edit"] {
                    guard let menu = NSApp.mainMenu?.item(withTitle: title)?.submenu ?? NSApp.mainMenu?.items.first(where: { $0.submenu?.title == title })?.submenu else { log("no \(title) menu"); continue }
                    for pass in 1...2 {
                        let t0 = CACurrentMediaTime()
                        menu.delegate?.menuNeedsUpdate?(menu)
                        menu.update()
                        log("\(title) menu, pass \(pass): \(String(format: "%.1f", (CACurrentMediaTime() - t0) * 1000)) ms")
                    }
                }
                log("app icon: \(Extensions.resource("AppIcon.icns")?.lastPathComponent ?? "MISSING"), \(Int(NSApp.applicationIconImage.size.width))pt, \(NSApp.applicationIconImage.representations.count) sizes")
                let t0 = CACurrentMediaTime()
                _ = Style.shared.monospaceFamilies
                log("font list (cached now): \(String(format: "%.1f", (CACurrentMediaTime() - t0) * 1000)) ms")
                log("done")
            }
            return
        }
        if mode == "commands" {
            for t in [AgentRunner.Target.claude, .codex] {
                for resume in [nil, "0199aaaa-bbbb-cccc-dddd-eeeeffff0000"] {
                    let c = AgentRunner.command(t, prompt: "PROMPT", resume: resume, newSession: "11111111-2222-3333-4444-555555555555", readOnly: true)!
                    log("\(t.rawValue) \(resume == nil ? "fresh" : "continue"): " + c.replacingOccurrences(of: #"--allowedTools '[^']*'"#, with: "--allowedTools '…'", options: .regularExpression))
                }
            }
            log("done")
            return
        }
        if mode == "git" {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                log("git button: '\(review.gitButtonTitleForTests)'")
                let stage = ProcessInfo.processInfo.environment["ONRAMP_STAGE"] ?? ""
                if stage == "commit" { review.showCommitForTests() }
                if stage == "merge" { review.showMergeForTests() }
                if stage == "run" {
                    let repo = review.document.repoRootForTests
                    let sha = try! commitAll(repoRoot: repo, message: "WIP from the self-test")
                    _ = try! pushBranch(repoRoot: repo)
                    review.refreshGit()
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    log("committed \(sha), pushed; git button now: '\(review.gitButtonTitleForTests)' hidden=\(review.gitButtonHiddenForTests)")
                }
                try? await Task.sleep(nanoseconds: 800_000_000)
                let ids = NSApp.windows.filter { $0 !== review.window && $0.isVisible }.map { "\($0.windowNumber)" }
                log("window id \(review.window!.windowNumber)")
                log("popover ids \(ids.joined(separator: ","))")
                log("ready")
            }
            return
        }
        if mode == "ci" {
            Task { @MainActor in
                let doc = review.document, repo = doc.repoRootForTests
                if let slug = ProcessInfo.processInfo.environment["ONRAMP_CI_SHA"] {
                    do {
                        let r = try GitHub.ciFindings(repo: repo, sha: slug)
                        log("real CI: \(r.findings.count) findings (complete \(r.complete))")
                    } catch { log("real CI error: \(error)") }
                    log("ready"); return
                }
                let f = doc.files.first { $0.path.hasSuffix("invoice.routes.ts") }!
                let finding = CiFinding(check: "lint", path: f.path, line: 17, text: f.newText as String, level: "failure",
                                        title: "@typescript-eslint/no-floating-promises",
                                        message: "Promises must be awaited, end with a call to .catch, or be explicitly marked as ignored with the `void` operator.")
                let s = try! syncCiThreads(repoRoot: repo, findings: [finding], complete: true)
                log("synced: +\(s.added) reopened \(s.reopened) resolved \(s.resolved)")
                doc.reloadThreads()
                AppDelegate.current?.front?.showComments(nil)
                let i = doc.files.firstIndex { $0.path == f.path }!
                _ = frame(review.scrollView, to: max(0, doc.frame(ofFile: i).minY + 200))
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                log("agent button: '\(review.agentLabelForTests)'")
                log("window id \(review.window!.windowNumber)")
                log("ready")
            }
            return
        }
        if mode == "link" {
            Task { @MainActor in
                guard let app = AppDelegate.current else { return log("setup") }
                let repo = review.document.repoRootForTests
                log("clone match: sharkdp/hexyl → \(Clones.matches(repo, "sharkdp/hexyl")), other/repo → \(Clones.matches(repo, "other/repo"))")
                UserDefaults.standard.set(repo, forKey: "onramp.clone.sharkdp/hexyl") // as if found before
                DeepLinks.handle(URL(string: "onramp://pr?repo=sharkdp/hexyl&number=286")!, app: app)
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                log("after link: \(app.tabCount) tabs · front '\(app.front?.window?.title ?? "")' · \(app.front?.review.document.files.count ?? 0) files")
                UserDefaults.standard.removeObject(forKey: "onramp.clone.sharkdp/hexyl")
                log("ready")
            }
            return
        }
        if mode == "prtabs" {
            Task { @MainActor in
                guard let app = AppDelegate.current, let first = app.front else { return log("setup") }
                let repo = first.repoPath
                for n in [149, 286, 149] {
                    app.viewPullRequest(n, repo: repo) { e in if let e { MainActor.assumeIsolated { log("error \(e)") } } }
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    log("after #\(n): \(app.tabCount) tabs · front '\(app.front?.window?.title ?? "")'")
                }
                log("first tab still: '\(first.window?.title ?? "")' · \(first.review.choice.mode)")
                log("window id \(app.front!.window!.windowNumber)")
                log("ready")
            }
            return
        }
        if mode == "prs" {
            Task { @MainActor in
                guard let app = AppDelegate.current, let tab = app.front else { return log("setup") }
                tab.showPullRequests(nil)
                try? await Task.sleep(nanoseconds: 5_000_000_000) // gh round trip
                tab.review.openPullRequest(149) { _ in }
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                log("window id \(tab.window!.windowNumber)")
                log("ready")
            }
            return
        }
        if mode == "tabs" {
            Task { @MainActor in
                guard let app = AppDelegate.current, let other = ProcessInfo.processInfo.environment["ONRAMP_OTHER"] else { return log("setup") }
                let first = app.front!
                let second = app.openTab(repo: other)
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                second.review.openPullRequest(149) { _ in }
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                let tabs = first.window?.tabbedWindows?.count ?? 1
                log("tabs: \(app.tabCount) controllers, \(tabs) tabs in one window")
                log("tab 1: '\(first.window?.title ?? "")' · \(first.review.document.files.count) files")
                log("tab 2: '\(second.window?.title ?? "")' · \(second.review.document.files.count) files")
                log("front is tab 2: \(app.front === second)")
                log("window id \(second.window!.windowNumber)")
                log("ready")
            }
            return
        }
        if mode == "pr" {
            Task { @MainActor in
                let repo = review.document.repoRootForTests
                let open = (try? GitHub.list(repo: repo, filter: .open)) ?? []
                log("picker: \(open.count) open PRs, first: #\(open.first?.number ?? 0) \(open.first?.title ?? "")")
                let n = Int(ProcessInfo.processInfo.environment["ONRAMP_PR"] ?? "149")!
                review.openPullRequest(n) { error in
                    MainActor.assumeIsolated {
                        if let error { log("error: \(error)"); log("ready"); return }
                        let doc = review.document
                        log("PR #\(n): \(doc.files.map(\.path).joined(separator: ", ")) · \(review.statusText)")
                        log("toolbar: \(AppDelegate.current?.sourceToolbar.debugMenus().titles.1 ?? "?")")
                        log("editor refused: \(doc.activateEditor(0, offset: 0) == nil)")
                        review.expandPullRequestBarForTests()
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 700_000_000)
                            log("window id \(review.window!.windowNumber)")
                            log("ready")
                        }
                    }
                }
            }
            return
        }
        if mode == "context" {
            Task { @MainActor in
                AppDelegate.current?.openContext(nil)
                try? await Task.sleep(nanoseconds: 600_000_000)
                if let w = NSApp.windows.first(where: { $0.title.hasPrefix("Review Context") }) { log("context window id \(w.windowNumber)") }
                log("window id \(review.window!.windowNumber)")
                log("ready")
            }
            return
        }
        if mode == "panel" {
            Task { @MainActor in
                let doc = review.document, repo = doc.repoRootForTests, me = doc.reviewAuthor
                func file(_ suffix: String) -> ReviewFile { doc.files.first { $0.path.hasSuffix(suffix) }! }
                func add(_ f: ReviewFile, _ line: UInt32, _ body: String, pending: Bool = false) -> Thread {
                    try! addThread(repoRoot: repo, path: f.path, text: f.newText as String, line: line, oldSide: false, author: me, body: body, pending: pending)
                }
                _ = add(file("invoice.routes.ts"), 18, "Validate `amount > 0` here too; negative payments would *increase* the balance.")
                let asked = add(file("invoice.service.ts"), 40, "Why store a precomputed balance at all?")
                _ = try! reply(repoRoot: repo, id: asked.id, author: "claude-code", body: "Good question: **it doesn't need to be stored.** Want me to drop it?", pending: false)
                let claimed = add(file("money.ts"), 15, "allocate() should reject an empty weights array.")
                _ = try! claimThread(repoRoot: repo, id: claimed.id, agent: "codex")
                _ = add(file("main.rs"), 20, "Log the job id on each retry.", pending: true)
                let done = add(file("worker.yaml"), 5, "Two replicas is fine, but set a PodDisruptionBudget.")
                _ = try! setResolved(repoRoot: repo, id: done.id, resolved: true, author: "claude-code", note: "Added a PDB with minAvailable: 1.")
                doc.reloadThreads()
                try? await Task.sleep(nanoseconds: 500_000_000)
                log("window id \(review.window!.windowNumber)")
                log("ready")
            }
            return
        }
        if mode == "agents" {
            // Claims and "needs you": a comment, an agent claims it, then answers with a question.
            Task { @MainActor in
                let doc = review.document, repo = doc.repoRootForTests
                let fi = doc.files.firstIndex { $0.path.hasSuffix("invoice.routes.ts") } ?? 0; let f = doc.files[fi]
                let t = try! addThread(repoRoot: repo, path: f.path, text: f.newText as String, line: 17, oldSide: false,
                                       author: doc.reviewAuthor, body: "Validate amount > 0 here too.", pending: false)
                _ = try! claimThread(repoRoot: repo, id: t.id, agent: "codex")
                doc.reloadThreads()
                try? await Task.sleep(nanoseconds: 2_500_000_000) // agent timer tick
                log("claimed: button '\(review.agentLabelForTests)'")
                _ = frame(review.scrollView, to: max(0, doc.frame(ofFile: fi).minY + 200))
                try? await Task.sleep(nanoseconds: 300_000_000)
                if ProcessInfo.processInfo.environment["ONRAMP_STAGE"] == "claimed" { log("window id \(review.window!.windowNumber)"); log("ready"); return }
                _ = try! releaseThread(repoRoot: repo, id: t.id, agent: "codex")
                _ = try! reply(repoRoot: repo, id: t.id, author: "codex", body: """
                Intent: store a precomputed `balance` for every open invoice, so readers don't need to recompute it. Looking at it again, I don't think it holds up:

                1. **The columns might not exist.** The service never reads `invoices.total` or `invoices.paid`; it derives total from line items (`total()`, invoice.service.ts:27).
                2. **The stored value would go stale.** `recordPayment` (:70) never updates `invoices.balance`.

                Your call, pick one:
                - **(a) Delete the script** (my recommendation). Balance stays *derived*, one source of truth.
                - **(b) Keep a stored balance.** About 30 min plus a migration.

                ```
                update invoices set balance = total - paid
                ```
                """, pending: false)
                doc.reloadThreads()
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                _ = frame(review.scrollView, to: max(0, doc.frame(ofFile: fi).minY + 200))
                try? await Task.sleep(nanoseconds: 300_000_000)
                log("replied: button '\(review.agentLabelForTests)'")
                if ProcessInfo.processInfo.environment["ONRAMP_CLICK"] != nil {
                    doc.setAllCollapsed(true)
                    _ = frame(review.scrollView, to: 0)
                    review.clickAgentForTests()
                    let v = review.scrollView.contentView.bounds
                    let box = doc.threadView(t.id).map { doc.convert($0.bounds, from: $0) }
                    log("after click: file folded \(doc.files[fi].collapsed), thread box \(box.map { v.intersection($0).height == $0.height ? "fully visible" : "partly/not visible" } ?? "missing")")
                }
                log("window id \(review.window!.windowNumber)")
                log("ready")
            }
            return
        }
        if mode == "source" {
            Task { @MainActor in
                guard let app = AppDelegate.current else { return log("no app") }
                @MainActor func show(_ label: String) {
                    let m = app.sourceToolbar.debugMenus()
                    let r = app.currentReview
                    log("\(label): [\(m.titles.0)] [\(m.titles.1)] · \(r.document.files.count) files · \(r.statusText)")
                }
                show("start")
                let m = app.sourceToolbar.debugMenus()
                log("project menu:\n    " + m.project.joined(separator: "\n    "))
                log("changes menu:\n    " + m.changes.joined(separator: "\n    "))
                let commits = try! reviewCommits(repoRoot: app.currentReview.document.repoRootForTests, limit: 40).commits
                var c = reviewChoice(repoRoot: app.currentReview.document.repoRootForTests)
                c.mode = .commit; c.commit = commits[1].sha
                app.currentReview.setChoice(c)
                show("one commit")
                let editor = app.currentReview.document.activateEditor(0, offset: 0)
                log("editor in commit mode: \(editor == nil ? "refused (read-only)" : "OPENED — bug")")
                c.mode = .branch
                app.currentReview.setChoice(c)
                show("branch again")
                if let other = try? listWorktrees(repoRoot: app.currentReview.document.repoRootForTests).first(where: { !$0.isCurrent }) {
                    app.open(repo: other.path)
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    show("switched worktree")
                }
                log("done")
            }
            return
        }
        if mode == "bottom" {
            // Scrolled all the way down, the last file must be the current one;
            // jumping to it from the sidebar must put its header at the top.
            Task { @MainActor in
                let doc = review.document, clip = review.scrollView.contentView
                let last = doc.files.count - 1
                _ = frame(review.scrollView, to: doc.frame.height - clip.bounds.height)
                log("at bottom: current \(doc.files[doc.index(at: clip.bounds.minY + FileLayout.headerHeight)].path) (last is \(doc.files[last].path))")
                _ = frame(review.scrollView, to: 0)
                doc.scrollToFile(last)
                log("jump to last: viewport top \(clip.bounds.minY) file top \(doc.frame(ofFile: last).minY)")
                doc.scrollToFile(3)
                doc.setAllCollapsed(true)
                log("collapse all: \(doc.files.filter(\.collapsed).count)/\(doc.files.count) collapsed, top file still \(doc.files[doc.index(at: clip.bounds.minY + 1)].path) (was \(doc.files[3].path))")
                doc.setAllCollapsed(false)
                log("expand all: \(doc.files.filter(\.collapsed).count) collapsed")
                log("done")
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
                if doc.files.count > 1, !doc.files[0].viewed, ProcessInfo.processInfo.environment["ONRAMP_NO_VIEW"] == nil { doc.toggleViewed(0) }
                if let target = ProcessInfo.processInfo.environment["ONRAMP_SCROLL_TO"], let i = doc.files.firstIndex(where: { $0.path == target }) {
                    _ = frame(review.scrollView, to: max(0, doc.frame(ofFile: i).minY - 60))
                } else if doc.files.count > 1 { _ = frame(review.scrollView, to: doc.frame(ofFile: 1).minY + 140) }
                try? await Task.sleep(nanoseconds: 300_000_000)
                if let w = review.window, let screen = w.screen {
                    let f = w.frame
                    log("window \(Int(f.minX)),\(Int(screen.frame.height - f.maxY)),\(Int(f.width)),\(Int(f.height)) id \(w.windowNumber)")
                }
                if ProcessInfo.processInfo.environment["ONRAMP_TYPE"] != nil, let e = doc.activateEditor(1, offset: doc.files[1].lineStarts[min(17, doc.files[1].lineCount - 1)]) {
                    e.textView.insertText("const greeting = \"typed in the editor\"; // re-highlighted\n", replacementRange: e.textView.selectedRange())
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    var info = ""
                    e.textView.layout.enumerateTextLayoutFragments(from: e.textView.layout.documentRange.location, options: [.ensuresLayout]) { f in
                        info = "fragment.minX \(f.layoutFragmentFrame.minX) line.minX \(f.textLineFragments.first?.typographicBounds.minX ?? -1)"
                        return false
                    }
                    log("editor: host.x \(e.host.frame.minX) textView.x \(e.textView.frame.minX) padding \(e.textView.textContainer!.lineFragmentPadding) inset \(e.textView.textContainerInset.width) \(info) · canvas textX \(DiffStyle.gutterWidth + 5)")
                }
                if let t = AppDelegate.current?.sourceToolbar { log("toolbar: \(t.debugFrames)") }
                log("ready")
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                let popover = ProcessInfo.processInfo.environment["ONRAMP_POPOVER"]
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
        if mode == "snap" { // a picture of the window (ONRAMP_SNAP_OUT), for checking looks
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 800_000_000)
                let env = ProcessInfo.processInfo.environment, files = review.document.files
                let target = env["ONRAMP_SNAP_FILE"].flatMap { f in files.firstIndex { $0.path.hasSuffix(f) } } ?? min(2, max(0, files.count - 1))
                review.document.scrollToFile(target)
                if env["ONRAMP_SNAP_PANEL"] == "prs" { (NSApp.delegate as? AppDelegate)?.showPullRequests(nil) }
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                guard let out = ProcessInfo.processInfo.environment["ONRAMP_SNAP_OUT"], let window = review.window else { return log("no window") }
                // screencapture draws it exactly as on screen (vibrancy included), even behind other windows.
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                p.arguments = ["-x", "-o", "-l", String(window.windowNumber), out]
                try? p.run()
                p.waitUntilExit()
                log("snap \(out) (\(p.terminationStatus))")
                NSApp.terminate(nil)
            }
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
                doc.startComment(i, CommentTarget(line: 40, old: ProcessInfo.processInfo.environment["ONRAMP_OLD"] == "1"))
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard let composer = doc.composerView(i) else { return log("no composer") }
                let focused = composer.window?.firstResponder === composer.input.textView
                composer.input.textView.insertText("This comment is misleading. Say what the line actually does.", replacementRange: NSRange(location: NSNotFound, length: 0))
                try? await Task.sleep(nanoseconds: 300_000_000)
                composer.input.textView.onSubmit?() // ⌘↩
                try? await Task.sleep(nanoseconds: 200_000_000)
                log("composer focused=\(focused); threads on file: \(doc.files[i].threads.map { "\($0.thread.id)@\($0.line.map { String($0 + 1) } ?? "?")" })")
                if ProcessInfo.processInfo.environment["ONRAMP_OPEN_EDITOR"] == "1" {
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
                guard ProcessInfo.processInfo.environment["ONRAMP_EDIT"] == "1", let t = doc.files[i].threads.first else { return }
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
                if ProcessInfo.processInfo.environment["ONRAMP_EDIT_SAVE"] == "1" {
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
                guard let target = ProcessInfo.processInfo.environment["ONRAMP_SEND"].flatMap(AgentRunner.Target.init(rawValue:)) else { return }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                review.submit(body: "Two issues before this can merge.", verdict: .requestChanges, targets: [target])
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
                if ProcessInfo.processInfo.environment["ONRAMP_WHEEL"] == "1" {
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
                if ProcessInfo.processInfo.environment["ONRAMP_STAY"] == nil { _ = frame(scrollView, to: 0) }
            }
            log("done")
        }
    }

    static func log(_ s: String) {
        FileHandle.standardError.write(("[selftest] " + s + "\n").data(using: .utf8)!)
    }
}
