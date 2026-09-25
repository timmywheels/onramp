import AppKit

/// "Send to Claude" (⌘⇧↩) on a comment: one thread, one quick agent run.
///
/// A full review run makes the agent find its own work (review context, list,
/// claim, list again): ~25 s and 11 turns for a one-line fix. Here the app
/// does that part: it claims the thread, and hands the agent the comment, the
/// code around it and your review context in the prompt. The agent just reads,
/// edits and answers in one line, which the app posts to the thread.
@MainActor
final class QuickSend {
    /// Runs in flight, by thread id (so a thread isn't sent twice at once).
    private static var running: [String: Process] = [:]
    static var onChange: (() -> Void)?

    static func isRunning(_ thread: String) -> Bool { running[thread] != nil }
    static var anyRunning: Bool { !running.isEmpty }

    /// Claude Code, or Codex if that's who you request reviews from.
    static func target(repo: String) -> AgentRunner.Target {
        AgentRunner.savedTargets(repo: repo).first ?? .claude
    }

    /// The name it answers as (the same as over MCP, so its badge and colour match).
    static func agentName(_ target: AgentRunner.Target) -> String { target == .codex ? "codex" : "claude-code" }

    /// Start a run for `thread` (on `path`, line `line`, in `text`). `done` gets an error to show, or nil.
    static func send(thread: Thread, path: String, line: Int, text: String, repo: String, done: @escaping (String?) -> Void = { _ in }) {
        guard running[thread.id] == nil else { return done(nil) }
        let target = target(repo: repo)
        let tool = target == .codex ? "codex" : "claude"
        let name = agentName(target)
        guard let exe = AgentTools.quoted(tool) else {
            return done("Couldn't find the \(tool) command. Click Agent in the bottom bar, then Choose… next to \(target.title).")
        }
        _ = try? claimThread(repoRoot: repo, id: thread.id, agent: name) // shows "working" right away

        let prompt = Self.prompt(thread: thread, path: path, line: line, text: text, repo: repo)
        let q = "'" + prompt.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let dir = (try? commentsPath(repoRoot: repo)).map { ($0 as NSString).deletingLastPathComponent } ?? NSTemporaryDirectory()
        let log = URL(fileURLWithPath: dir).appendingPathComponent("agent-send-\(thread.id).log")
        let answer = URL(fileURLWithPath: dir).appendingPathComponent("agent-send-\(thread.id).answer")
        try? FileManager.default.removeItem(at: answer)
        let command: String
        switch target {
        case .codex:
            command = "\(exe) exec \(AgentTools.codexWriteFlags()) -o '\(answer.path)' \(q)"
        default:
            // Only what the job needs: no Bash (it tried, was refused, and lost turns), no MCP lookups.
            let flags = AgentTools.args["claude"].flatMap { $0.isEmpty ? nil : $0 }
                ?? "--permission-mode acceptEdits --allowedTools 'Read,Edit,Write,Glob,Grep' --disallowedTools 'Bash'"
            let model = AgentTools.model("claude").map { " --model '\($0)'" } ?? ""
            command = "\(exe) -p \(q) \(flags)\(model) --output-format json"
        }
        FileManager.default.createFile(atPath: log.path, contents: Data("$ \(command)\n\n".utf8))
        let handle = try? FileHandle(forWritingTo: log)
        handle?.seekToEndOfFile()

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", command]
        p.currentDirectoryURL = URL(fileURLWithPath: repo)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = AgentIntegration.userPath
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = handle
        p.standardError = handle
        let started = Date()
        p.terminationHandler = { proc in
            let ok = proc.terminationStatus == 0
            Task { @MainActor in
                try? handle?.close()
                running[thread.id] = nil
                let final = target == .codex ? (try? String(contentsOf: answer, encoding: .utf8)) : claudeResult(log)
                finish(thread: thread.id, repo: repo, agent: name, answer: final, ok: ok, seconds: Date().timeIntervalSince(started), log: log, done: done)
            }
        }
        do {
            try p.run()
            running[thread.id] = p
            onChange?()
        } catch {
            _ = try? releaseThread(repoRoot: repo, id: thread.id, agent: name)
            done("Couldn't start \(tool): \(error.localizedDescription)")
        }
    }

    /// Everything the agent needs, so it doesn't spend turns looking for it.
    static func prompt(thread: Thread, path: String, line: Int, text: String, repo: String) -> String {
        let lines = text.components(separatedBy: "\n")
        let from = max(0, line - 8), to = min(lines.count, line + 8)
        let width = String(to).count
        let excerpt = (from..<to).map { i in
            let n = String(i + 1)
            return String(repeating: " ", count: width - n.count) + n + (i == line ? " > " : " | ") + lines[i]
        }.joined(separator: "\n")
        let conversation = thread.entries.filter { !$0.pending }.map { e in
            "\(e.author): " + e.body.replacingOccurrences(of: "\n", with: "\n  ")
        }.joined(separator: "\n")
        let context = reviewContext(repoRoot: repo, configDir: onrampConfigDir.path).text
        return """
        You're answering one code review comment in Onramp. It's assigned to you; don't look for other comments.

        The comment thread, on \(path) line \(line + 1):
        \(conversation)

        The code there (line \(line + 1) marked >):
        ```
        \(excerpt)
        ```
        \(context.isEmpty ? "" : "\nThe reviewer's standards and background (follow them):\n\(context.prefix(12_000))\n")
        Do what the latest message asks, and nothing beyond it. Then end your reply with exactly one line:
        RESOLVED: <one line on what you changed>
        or, if you need a decision from the reviewer (or it's a question you can answer without changing code):
        QUESTION: <your question or answer>
        """
    }

    /// Claude's `--output-format json` result text, from the end of the log.
    private static func claudeResult(_ log: URL) -> String? {
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return nil }
        for line in text.components(separatedBy: "\n").reversed() where line.hasPrefix("{") { // the result is the last JSON line
            if let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], let result = json["result"] as? String {
                return result
            }
        }
        return nil
    }

    /// Post the agent's answer: RESOLVED → resolve with its note; QUESTION or anything else → a reply.
    private static func finish(thread id: String, repo: String, agent: String, answer: String?, ok: Bool, seconds: TimeInterval, log: URL, done: (String?) -> Void) {
        _ = try? releaseThread(repoRoot: repo, id: id, agent: agent) // before anyone looks: it's not "working" any more
        defer { onChange?() }
        let text = (answer ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard ok, !text.isEmpty else {
            return done("\(agent) didn't finish (after \(Int(seconds)) s). Its log: \(log.path)")
        }
        let last = text.components(separatedBy: "\n").last { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        if last.hasPrefix("RESOLVED:") {
            let note = last.dropFirst("RESOLVED:".count).trimmingCharacters(in: .whitespaces)
            _ = try? setResolved(repoRoot: repo, id: id, resolved: true, author: agent, note: note.isEmpty ? nil : note)
        } else {
            let body = last.hasPrefix("QUESTION:") ? last.dropFirst("QUESTION:".count).trimmingCharacters(in: .whitespaces) : String(text.suffix(4000))
            _ = try? reply(repoRoot: repo, id: id, author: agent, body: body, pending: false)
        }
        done(nil)
    }
}
