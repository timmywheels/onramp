import AppKit

/// Runs a reviewer (the red team…) over the whole change: a read-only agent run
/// of its own, never your partner session, so it doesn't anchor on your
/// comments. It gets the diff and the PR's context in the prompt, reads what it
/// needs, and answers with its findings as JSON; they become threads waiting
/// for your triage (Keep or Dismiss).
@MainActor
final class ReviewerRun {
    enum State: Equatable { case running, done(added: Int, skipped: Int), failed(String) }

    let reviewer: Reviewer
    private(set) var state: State = .running { didSet { onChange?() } }
    private(set) var activity: String?
    var onChange: (() -> Void)?

    private var process: Process?
    private var buffer = Data()
    private var resultText: String?
    private let repo: String
    private let workDir: String
    private let texts: [String: String] // path → the new text, to anchor findings

    /// Reviewers, built-in and yours and the repo's (a later one with the same id wins).
    static func all(repo: String) -> [Reviewer] {
        let builtin = Extensions.resource("Reviewers")?.path ?? ""
        return listReviewers(repoRoot: repo, configDir: onrampConfigDir.path, builtinDir: builtin).reviewers
    }

    init(reviewer: Reviewer, repo: String, workDir: String, files: [ReviewFile], title: String?, description: String?) {
        self.reviewer = reviewer
        self.repo = repo
        self.workDir = workDir
        texts = Dictionary(files.map { ($0.path, $0.newText as String) }, uniquingKeysWith: { a, _ in a })
        start(prompt: Self.prompt(reviewer, files: files, title: title, description: description, repo: repo))
    }

    func stop() { process?.terminate() }

    private func start(prompt: String) {
        guard let claude = AgentTools.path("claude") else { return state = .failed("Couldn't find the claude command") }
        var args = ["-p", prompt, "--output-format", "stream-json", "--verbose",
                    "--allowedTools", "Read,Glob,Grep", "--disallowedTools", "Edit,Write,NotebookEdit,Bash"] // it reports; it never edits
        if let model = reviewer.model ?? AgentTools.model("claude") { args += ["--model", model] }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: claude)
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: workDir)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = AgentIntegration.userPath
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        let dir = (try? commentsPath(repoRoot: repo)).map { ($0 as NSString).deletingLastPathComponent } ?? NSTemporaryDirectory()
        let logURL = URL(fileURLWithPath: dir).appendingPathComponent("reviewer-\(reviewer.id).log")
        FileManager.default.createFile(atPath: logURL.path, contents: Data("$ claude -p <prompt> \(args.dropFirst(2).joined(separator: " "))\n\n".utf8))
        let log = try? FileHandle(forWritingTo: logURL)
        log?.seekToEndOfFile()
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            log?.write(data)
            Task { @MainActor in self?.received(data) }
        }
        p.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                out.fileHandleForReading.readabilityHandler = nil
                try? log?.close()
                self?.finished(ok: proc.terminationStatus == 0, log: logURL)
            }
        }
        do { try p.run(); process = p } catch { state = .failed(error.localizedDescription) }
    }

    private func received(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 10) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let m = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            if m["type"] as? String == "result" { resultText = m["result"] as? String }
            if m["type"] as? String == "assistant" {
                for c in ((m["message"] as? [String: Any])?["content"] as? [[String: Any]]) ?? [] where c["type"] as? String == "tool_use" {
                    let input = c["input"] as? [String: Any] ?? [:]
                    let file = ((input["file_path"] as? String) ?? (input["path"] as? String)).map { ($0 as NSString).lastPathComponent }
                    activity = (c["name"] as? String == "Read" ? "reading" : "searching") + (file.map { " " + $0 } ?? "")
                    onChange?()
                }
            }
        }
    }

    private func finished(ok: Bool, log: URL) {
        process = nil
        activity = nil
        guard ok, let text = resultText, let findings = Self.findings(in: text) else {
            return state = .failed("\(reviewer.name) didn't report its findings. Its log: \(log.path)")
        }
        let threshold = severityRank(severity: reviewer.minSeverity)
        let kept = findings
            .filter { severityRank(severity: $0.severity) >= threshold }
            .sorted { severityRank(severity: $0.severity) > severityRank(severity: $1.severity) }
            .prefix(Int(reviewer.maxFindings))
            .compactMap { f -> Finding? in
                guard let text = texts[f.path] else { return nil } // not in this review
                let lines = text.components(separatedBy: "\n").count
                return Finding(path: f.path, line: UInt32(max(0, min(f.line - 1, lines - 1))), text: text,
                               severity: f.severity.lowercased(), title: f.title, body: f.body)
            }
        do {
            let r = try addFindings(repoRoot: repo, reviewer: reviewer.id, author: reviewer.name, findings: Array(kept))
            state = .done(added: Int(r.added), skipped: Int(r.skipped))
        } catch {
            state = .failed(message(for: error))
        }
    }

    /// The JSON object at the end of its answer (tolerating a code fence or prose around it).
    struct Raw: Decodable { let path: String; let line: Int; let severity: String; let title: String; let body: String }
    static func findings(in text: String) -> [Raw]? {
        guard let start = text.range(of: "{\"findings\"")?.lowerBound ?? text.range(of: "{", options: .backwards)?.lowerBound,
              let end = text.range(of: "}", options: .backwards)?.upperBound, start < end else { return nil }
        struct Wrapper: Decodable { let findings: [Raw] }
        return try? JSONDecoder().decode(Wrapper.self, from: Data(text[start..<end].utf8)).findings
    }

    static func prompt(_ r: Reviewer, files: [ReviewFile], title: String?, description: String?, repo: String) -> String {
        let context = reviewContext(repoRoot: repo, configDir: onrampConfigDir.path).text
        // What it reported before (still open, kept or dismissed): not to be repeated in new words.
        let before = ((try? loadThreads(repoRoot: repo)) ?? []).filter { $0.source?.hasPrefix("reviewer:\(r.id):") == true }.map { t in
            let title = t.entries.first?.body.components(separatedBy: "\n").first?.replacingOccurrences(of: "**", with: "") ?? ""
            let status = t.triage == "dismissed" ? "dismissed by the reviewer: don't raise it again" : t.status == .resolved ? "resolved" : "already reported"
            return "- \(t.path):\(t.anchor.line + 1) \(title) (\(status))"
        }
        return """
        \(r.prompt.trimmingCharacters(in: .whitespacesAndNewlines))

        \(r.focus.isEmpty ? "" : "Look hardest at:\n" + r.focus.map { "- \($0)" }.joined(separator: "\n") + "\n")
        \(title.map { "The change: \($0)\n" } ?? "")\(description.map { $0.isEmpty ? "" : "What the author says it does:\n\($0.prefix(6000))\n" } ?? "")\(context.isEmpty ? "" : "\nThe team's standards and background:\n\(context.prefix(10_000))\n")
        The diff (new-file line numbers on added and unchanged lines). The full files are in the current directory: read them and whatever they call.

        \(diffText(files))

        \(before.isEmpty ? "" : "Already on this review from your earlier runs (don't report these again, however you'd word them):\n" + before.joined(separator: "\n") + "\n")
        When you're done, reply with only this JSON object and nothing else:
        {"findings":[{"path":"<path as in the diff>","line":<line in the new file>,"severity":"critical|high|medium|low","title":"<one line>","body":"<what's wrong, and a concrete case where it breaks>"}]}
        An empty list is a fine answer if the change holds up.
        """
    }

    /// A compact unified diff with new-file line numbers, capped so the prompt stays small.
    static func diffText(_ files: [ReviewFile], limit: Int = 60_000) -> String {
        var out = ""
        for f in files where !f.hunks.isEmpty || f.hunks.isEmpty && f.status == .added {
            let lines = (f.newText as String).components(separatedBy: "\n")
            out += "--- \(f.path)\n"
            for h in f.hunks {
                for d in h.deleted { out += "     - \(d)\n" }
                for i in Int(h.newStart)..<min(lines.count, Int(h.newStart + h.newLen)) { out += String(format: "%5d + ", i + 1) + lines[i] + "\n" }
                out += "\n"
            }
            if out.count > limit { return out + "… (diff truncated; read the files)\n" }
        }
        return out
    }
}
