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
        var args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose"]
        if let custom = AgentTools.args["claude"], !custom.isEmpty {
            args += custom.split(separator: " ").map(String.init) // yours win (simple space-separated flags)
        } else if readOnly {
            args += ["--allowedTools", "Read,Glob,Grep", "--disallowedTools", "Edit,Write,NotebookEdit,Bash"]
        } else {
            args += ["--permission-mode", "acceptEdits", "--allowedTools", "Read,Edit,Write,Glob,Grep", "--disallowedTools", "Bash"]
        }
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
                    case "Edit", "Write", "MultiEdit": activity = Activity(kind: .editing, path: path, line: editLine(path, input))
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
        default: break
        }
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
        if last.hasPrefix("RESOLVED:"), !readOnly {
            let note = last.dropFirst("RESOLVED:".count).trimmingCharacters(in: .whitespaces)
            _ = try? setResolved(repoRoot: repo, id: thread, resolved: true, author: agentName, note: note.isEmpty ? nil : note)
        } else {
            let body = last.hasPrefix("QUESTION:") ? last.dropFirst("QUESTION:".count).trimmingCharacters(in: .whitespaces)
                : last.hasPrefix("RESOLVED:") ? last.dropFirst("RESOLVED:".count).trimmingCharacters(in: .whitespaces) // read-only: you resolve
                : String(trimmed.suffix(4000))
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
