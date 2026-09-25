import AppKit

/// A warm agent session for one review (a tab): started when the review opens,
/// primed with the changed files and your context, and fed each comment you
/// send. No process start and no re-reading per comment: measured on the demo
/// repo, a one-line fix answered in 5.5 s (11.8 s as a fresh run, 25.8 s as a
/// full review run), with the first sign of activity after 1.5 s.
///
/// Claude Code only (its streaming mode keeps one session open over stdin).
/// It closes with the tab and can be resumed: the session id is remembered per
/// review, and reopening that review continues it instead of priming again.
@MainActor
final class AgentSession {
    enum State: Equatable { case off, starting, priming, ready, busy, failed(String) }

    /// What the agent is doing right now, from its live event stream.
    struct Activity: Equatable {
        enum Kind: Equatable { case thinking, reading, editing, searching, answering }
        let kind: Kind
        let path: String?   // relative to the repo
        let line: Int?      // 0-based, for edits once the file is on disk
        /// The code it's writing, as it streams in (before the file is saved).
        var preview: String? = nil
        var label: String {
            let where_ = path.map { " " + ($0 as NSString).lastPathComponent + (line.map { ":\($0 + 1)" } ?? "") } ?? ""
            switch kind {
            case .thinking: return "thinking…"
            case .reading: return "reading" + where_
            case .editing: return "editing" + where_
            case .searching: return "searching" + where_
            case .answering: return "answering…"
            }
        }
    }

    let repo: String            // where comments live (the review)
    let workDir: String         // where the agent runs (the repo, or a PR's read-only checkout)
    let readOnly: Bool
    let key: String             // names this review: repo + PR/branch, for resuming
    let agentName = "claude-code"

    private(set) var state: State = .off { didSet { onChange?() } }
    private(set) var activity: Activity? { didSet { if activity != oldValue { onActivity?(activity) } } }
    /// The thread being worked on now (its status line shows the activity).
    private(set) var currentThread: String?
    var onChange: (() -> Void)?
    var onActivity: ((Activity?) -> Void)?
    var onFinished: ((_ thread: String, _ error: String?) -> Void)?

    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var queue: [(thread: String, message: String)] = []
    private var sessionID: String?
    private var log: FileHandle?
    // Streaming state for the current turn.
    private var toolName: String?
    private var toolJSON = ""
    private var replyText = ""
    private var replyEntry: UInt32?     // the entry its answer is streaming into
    private var lastFlush = Date.distantPast
    private var lastPreview = Date.distantPast

    init(repo: String, workDir: String, readOnly: Bool, key: String) {
        self.repo = repo
        self.workDir = workDir
        self.readOnly = readOnly
        self.key = key
    }

    // MARK: Resuming

    private static func savedKey(_ key: String) -> String { "onramp.agentSession." + key }
    static func savedSession(_ key: String) -> String? { UserDefaults.standard.string(forKey: savedKey(key)) }
    static func forget(_ key: String) { UserDefaults.standard.removeObject(forKey: savedKey(key)) }

    // MARK: Lifecycle

    /// Start (or resume) the session and prime it. `prime` is the review's context.
    func start(prime: String, fresh: Bool = false) {
        guard process == nil else { return }
        guard let claude = AgentTools.path("claude") else { return state = .failed("Couldn't find the claude command") }
        let resume = fresh ? nil : Self.savedSession(key)
        // Partial messages: the code it writes and its answer arrive as they're typed (from ~1.5 s), not at the end.
        var args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--include-partial-messages"]
        if let custom = AgentTools.args["claude"], !custom.isEmpty {
            args += custom.split(separator: " ").map(String.init) // yours win (simple space-separated flags)
        } else if readOnly {
            args += ["--allowedTools", "Read,Glob,Grep", "--disallowedTools", "Edit,Write,NotebookEdit,Bash"]
        } else {
            args += ["--permission-mode", "acceptEdits", "--allowedTools", "Read,Edit,Write,Glob,Grep", "--disallowedTools", "Bash"]
        }
        if let model = AgentTools.model("claude") { args += ["--model", model] }
        if let resume { args += ["--resume", resume] }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: claude)
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: workDir)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = AgentIntegration.userPath
        p.environment = env
        let stdin = Pipe(), stdout = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = stdout
        let dir = (try? commentsPath(repoRoot: repo)).map { ($0 as NSString).deletingLastPathComponent } ?? NSTemporaryDirectory()
        let logURL = URL(fileURLWithPath: dir).appendingPathComponent("agent-session.log")
        FileManager.default.createFile(atPath: logURL.path, contents: Data("$ claude \(args.joined(separator: " "))\n\n".utf8))
        log = try? FileHandle(forWritingTo: logURL)
        log?.seekToEndOfFile()
        stdout.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            Task { @MainActor in self?.received(data) }
        }
        p.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                guard let self else { return }
                stdout.fileHandleForReading.readabilityHandler = nil
                self.process = nil
                self.input = nil
                if let t = self.currentThread { self.finish(t, error: "The agent session ended (\(proc.terminationStatus)).") }
                self.activity = nil
                if case .failed = self.state {} else { self.state = .off }
            }
        }
        do { try p.run() } catch { return state = .failed(error.localizedDescription) }
        process = p
        input = stdin.fileHandleForWriting
        state = .starting
        if resume == nil {
            state = .priming
            write(prime)
        } else {
            state = .ready // it already knows the review
        }
    }

    func stop() {
        input?.closeFile() // ends the session; resumable by id
        process?.terminate()
        process = nil
        input = nil
        queue = []
        activity = nil
        state = .off
    }

    var isRunning: Bool { process != nil }

    // MARK: Comments

    /// Hand one thread to the session. Queued if it's busy with another.
    func send(thread: String, message: String) {
        _ = try? claimThread(repoRoot: repo, id: thread, agent: agentName) // "working" right away
        queue.append((thread, message))
        pump()
    }

    private func pump() {
        guard state == .ready, currentThread == nil, !queue.isEmpty else { return }
        let next = queue.removeFirst()
        currentThread = next.thread
        state = .busy
        activity = Activity(kind: .thinking, path: nil, line: nil)
        write(next.message)
    }

    private func write(_ text: String) {
        let msg: [String: Any] = ["type": "user", "message": ["role": "user", "content": text]]
        guard let data = try? JSONSerialization.data(withJSONObject: msg) else { return }
        input?.write(data + Data("\n".utf8))
    }

    // MARK: The event stream

    private func received(_ data: Data) {
        guard !data.isEmpty else { return }
        log?.write(data)
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 10) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let json = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            handle(json)
        }
    }

    private func handle(_ m: [String: Any]) {
        switch m["type"] as? String {
        case "stream_event":
            streamed(m["event"] as? [String: Any] ?? [:])
        case "system":
            if let id = m["session_id"] as? String, sessionID != id {
                sessionID = id
                UserDefaults.standard.set(id, forKey: Self.savedKey(key)) // resume this review's session next time
            }
        case "assistant":
            let content = ((m["message"] as? [String: Any])?["content"] as? [[String: Any]]) ?? []
            for c in content {
                if c["type"] as? String == "tool_use", let name = c["name"] as? String {
                    let input = c["input"] as? [String: Any] ?? [:]
                    let path = (input["file_path"] as? String).map(relative)
                    switch name {
                    case "Edit", "Write", "MultiEdit":
                        // Once it's saved the old text is gone: keep the line (and preview) we already had for this file.
                        let same = activity?.path == path
                        activity = Activity(kind: .editing, path: path, line: editLine(path, input) ?? (same ? activity?.line : nil),
                                            preview: same ? activity?.preview : nil)
                    case "Read": activity = Activity(kind: .reading, path: path, line: nil)
                    case "Grep", "Glob": activity = Activity(kind: .searching, path: (input["path"] as? String).map(relative), line: nil)
                    default: break
                    }
                } else if c["type"] as? String == "text", currentThread != nil {
                    activity = Activity(kind: .answering, path: nil, line: nil)
                }
            }
        case "result":
            let text = (m["result"] as? String) ?? ""
            if state == .priming {
                state = .ready
                activity = nil
                pump()
            } else if let t = currentThread {
                post(text, to: t)
                finish(t, error: (m["is_error"] as? Bool == true) ? "The agent stopped with an error." : nil)
            }
            replyText = ""; replyEntry = nil; toolName = nil
        default: break
        }
    }

    // MARK: Streaming (partial messages)

    private func streamed(_ e: [String: Any]) {
        switch e["type"] as? String {
        case "content_block_start":
            let block = e["content_block"] as? [String: Any] ?? [:]
            if block["type"] as? String == "tool_use" { toolName = block["name"] as? String; toolJSON = "" }
        case "content_block_delta":
            let d = e["delta"] as? [String: Any] ?? [:]
            if d["type"] as? String == "input_json_delta", let part = d["partial_json"] as? String {
                toolJSON += part
                if ["Edit", "Write", "MultiEdit"].contains(toolName ?? ""), Date().timeIntervalSince(lastPreview) > 0.05 {
                    lastPreview = Date()
                    livePreview()
                }
            } else if d["type"] as? String == "text_delta", let text = d["text"] as? String, currentThread != nil, state == .busy {
                replyText += text
                activity = Activity(kind: .answering, path: nil, line: nil)
                if Date().timeIntervalSince(lastFlush) > 0.25 { flushReply() }
            }
        case "content_block_stop":
            if toolName != nil, ["Edit", "Write", "MultiEdit"].contains(toolName!) { livePreview() }
            toolName = nil
        default: break
        }
    }

    /// The edit it's typing, shown at its cursor before it's saved.
    private func livePreview() {
        guard let path = Self.partialString(toolJSON, "file_path").flatMap({ $0.complete ? $0.value : nil }).map(relative) else { return }
        let old = Self.partialString(toolJSON, "old_string")
        let new = Self.partialString(toolJSON, "new_string") ?? Self.partialString(toolJSON, "content")
        var line: Int?
        if let old, old.complete { line = editLine(path, ["old_string": old.value]) } else if toolName == "Write" { line = 0 }
        activity = Activity(kind: .editing, path: path, line: line ?? activity?.line, preview: new?.value)
    }

    /// Its answer, typed into the thread as it arrives (a reply entry, updated in place).
    private func flushReply() {
        guard let t = currentThread, !replyText.isEmpty else { return }
        lastFlush = Date()
        if let i = replyEntry {
            _ = try? editEntry(repoRoot: repo, id: t, index: i, body: replyText)
        } else if let thread = try? reply(repoRoot: repo, id: t, author: agentName, body: replyText, pending: false) {
            replyEntry = UInt32(thread.entries.count - 1)
            _ = try? claimThread(repoRoot: repo, id: t, agent: agentName) // still at it: a reply hands the thread back, so take it again
        }
    }

    /// A JSON string value that may still be streaming in: its text so far, and whether it's closed.
    static func partialString(_ json: String, _ key: String) -> (value: String, complete: Bool)? {
        guard let k = json.range(of: "\"\(key)\"") else { return nil }
        var i = k.upperBound
        while i < json.endIndex, json[i] == " " || json[i] == ":" { i = json.index(after: i) }
        guard i < json.endIndex, json[i] == "\"" else { return nil }
        i = json.index(after: i)
        var out = ""
        while i < json.endIndex {
            let c = json[i]
            if c == "\"" { return (out, true) }
            if c == "\\" {
                let n = json.index(after: i)
                guard n < json.endIndex else { break }
                switch json[n] {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "\"": out.append("\"")
                case "\\": out.append("\\")
                case "/": out.append("/")
                case "u":
                    let hex = json.index(n, offsetBy: 5, limitedBy: json.endIndex).map { json[json.index(after: n)..<$0] }
                    if let hex, hex.count == 4, let v = UInt32(hex, radix: 16), let s = Unicode.Scalar(v) { out.unicodeScalars.append(s); i = json.index(n, offsetBy: 4) } else { return (out, false) }
                default: out.append(json[n])
                }
                i = json.index(after: n)
                continue
            }
            out.append(c)
            i = json.index(after: i)
        }
        return (out, false)
    }

    private func relative(_ path: String) -> String {
        let root = workDir.hasSuffix("/") ? workDir : workDir + "/"
        return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path
    }

    /// Where an edit lands: the line of `old_string` in the file as it is now (before the write).
    private func editLine(_ path: String?, _ input: [String: Any]) -> Int? {
        guard let path, let old = input["old_string"] as? String, !old.isEmpty,
              let text = try? String(contentsOfFile: (workDir as NSString).appendingPathComponent(path), encoding: .utf8),
              let r = text.range(of: old) else { return nil }
        return text[..<r.lowerBound].filter { $0 == "\n" }.count
    }

    /// RESOLVED resolves with its note; QUESTION or anything else becomes a reply.
    private func post(_ text: String, to thread: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let last = trimmed.components(separatedBy: "\n").last { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        let resolves = last.hasPrefix("RESOLVED:") && !readOnly
        let body = last.hasPrefix("QUESTION:") ? last.dropFirst("QUESTION:".count).trimmingCharacters(in: .whitespaces)
            : last.hasPrefix("RESOLVED:") ? last.dropFirst("RESOLVED:".count).trimmingCharacters(in: .whitespaces) // read-only: you resolve
            : String(trimmed.suffix(4000))
        if let i = replyEntry { // it was typed in live: settle that entry on the final words
            _ = try? editEntry(repoRoot: repo, id: thread, index: i, body: body)
            if resolves { _ = try? setResolved(repoRoot: repo, id: thread, resolved: true, author: agentName, note: nil) }
        } else if resolves {
            _ = try? setResolved(repoRoot: repo, id: thread, resolved: true, author: agentName, note: body.isEmpty ? nil : body)
        } else {
            _ = try? reply(repoRoot: repo, id: thread, author: agentName, body: body, pending: false)
        }
    }

    private func finish(_ thread: String, error: String?) {
        _ = try? releaseThread(repoRoot: repo, id: thread, agent: agentName)
        currentThread = nil
        activity = nil
        if process != nil, state == .busy { state = .ready }
        onFinished?(thread, error)
        pump()
    }

    // MARK: Prompts

    /// The first message: what we're reviewing, your standards, and "read it now".
    static func primePrompt(files: [String], title: String?, description: String?, context: String, readOnly: Bool) -> String {
        """
        You're my code review partner in Onramp\(title.map { " for \($0)" } ?? ""). \
        \(readOnly ? "This is someone else's pull request, checked out here read-only: investigate and answer, don't edit files." : "The changes are in this working tree; you may edit them when I ask.")
        \(description.map { $0.isEmpty ? "" : "\nThe description:\n\($0.prefix(6000))\n" } ?? "")
        The changed files:
        \(files.prefix(200).map { "- \($0)" }.joined(separator: "\n"))
        \(context.isEmpty ? "" : "\nMy standards and background (follow them):\n\(context.prefix(12_000))\n")
        Read the changed files now (the most important ones if there are many) so you're ready. \
        Then I'll send review comments one at a time. For each: do what it asks and nothing more, then end with exactly one line: \
        "RESOLVED: <what you changed>" or "QUESTION: <your question, or your answer>". Reply "ready" when you're primed.
        """
    }

    /// One comment, with the code around it (the session already knows the review).
    static func commentPrompt(thread: Thread, path: String, line: Int, text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        let from = max(0, line - 6), to = min(lines.count, line + 7)
        let excerpt = (from..<to).map { i in "\(i + 1)\(i == line ? " > " : " | ")\(lines[i])" }.joined(separator: "\n")
        let conversation = thread.entries.filter { !$0.pending }.map { "\($0.author): \($0.body)" }.joined(separator: "\n")
        return """
        Comment on \(path) line \(line + 1):
        \(conversation)

        ```
        \(excerpt)
        ```
        """
    }
}
