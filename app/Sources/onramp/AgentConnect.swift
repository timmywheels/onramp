import AppKit

/// Agents connected to this repo through `onramp mcp` (each MCP session
/// writes `agent-<pid>.json` next to comments.json while it runs).
enum ConnectedAgents {
    /// A live agent session and what it did last (its MCP server records each tool call).
    struct Session {
        let agent: String
        let lastActivity: Date?
        let lastAction: String?
        /// Called a tool in the last 20 seconds.
        var isWorking: Bool { lastActivity.map { Date().timeIntervalSince($0) < 20 } ?? false }
    }

    static func sessions(repoRoot: String) -> [Session] {
        guard let comments = try? commentsPath(repoRoot: repoRoot) else { return [] }
        let dir = (comments as NSString).deletingLastPathComponent
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        var sessions: [Session] = []
        for name in names where name.hasPrefix("agent-") && name.hasSuffix(".json") {
            let path = (dir as NSString).appendingPathComponent(name)
            guard let data = FileManager.default.contents(atPath: path),
                  let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = info["pid"] as? Int, let agent = info["agent"] as? String else { continue }
            guard kill(pid_t(pid), 0) == 0 else { try? FileManager.default.removeItem(atPath: path); continue } // stale
            sessions.append(Session(agent: agent, lastActivity: (info["last_activity"] as? Int).map { Date(timeIntervalSince1970: TimeInterval($0)) },
                                    lastAction: info["last_action"] as? String))
        }
        return sessions.sorted { $0.agent < $1.agent }
    }

    static func list(repoRoot: String) -> [String] {
        Array(Set(sessions(repoRoot: repoRoot).map(\.agent))).sorted()
    }
}

/// Each agent's color, the same everywhere it appears (stable across launches).
enum AgentColor {
    private static let palette: [NSColor] = [.systemPurple, .systemTeal, .systemPink, .systemIndigo, .systemMint, .systemOrange, .systemCyan, .systemBrown]

    static func of(_ agent: String) -> NSColor {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in agent.lowercased().utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
        return palette[Int(h % UInt64(palette.count))]
    }
}

/// One agent onramp can register its MCP server with. Nothing is
/// registered until the user clicks Connect (opt-in, reversible).
struct AgentIntegration {
    /// `connected` says how ("plugin", "MCP server"), since there's more than one way.
    enum State: Equatable {
        case checking, notInstalled, connected(String), notConnected
        var isConnected: Bool { if case .connected = self { true } else { false } }
    }

    let name: String
    let check: () -> State
    let connect: () throws -> Void
    let disconnect: () throws -> Void

    /// The command agents launch: the installed symlink if present, else this binary.
    static var command: String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let link = [".local/bin/onramp", ".local/bin/ramp"].map { home.appendingPathComponent($0).path }
            .first { FileManager.default.isExecutableFile(atPath: $0) } ?? home.appendingPathComponent(".local/bin/onramp").path
        if FileManager.default.isExecutableFile(atPath: link) { return link }
        return URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
    }

    /// Claude Code gets a plugin (so the command is /onramp:address-comments)
    /// that bundles the MCP server; install.sh puts it here.
    static let claudePlugin = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/onramp/integrations/claude-code").path

    static let all: [AgentIntegration] = [
        AgentIntegration(
            name: "Claude Code",
            check: {
                guard shell("command -v claude").status == 0 else { return .notInstalled }
                // Either way counts: the plugin (what Connect installs), or a plain `claude mcp add onramp`.
                if shell("claude plugin list").output.contains("onramp@onramp") { return .connected("plugin") }
                if shell("claude mcp get onramp").status == 0 { return .connected("MCP server") }
                return .notConnected
            },
            connect: {
                if !shell("claude plugin marketplace list").output.contains("onramp") {
                    try shell("claude plugin marketplace add '\(claudePlugin)'").orThrow()
                }
                try shell("claude plugin install onramp@onramp").orThrow()
            },
            disconnect: {
                // Undo whichever way it was connected (both, if both).
                let plugin = shell("claude plugin list").output.contains("onramp@onramp") ? shell("claude plugin uninstall onramp@onramp") : nil
                let server = shell("claude mcp get onramp").status == 0 ? shell("claude mcp remove onramp") : nil
                try plugin?.orThrow()
                try server?.orThrow()
            }
        ),
        cli(name: "Codex", tool: "codex",
            add: "codex mcp add onramp -- '\(command)' mcp",
            remove: "codex mcp remove onramp"),
        cursor,
    ]

    /// Agents with an `mcp add/get/remove` CLI. Run through a login shell so a
    /// Finder-launched app sees the same PATH as your terminal.
    private static func cli(name: String, tool: String, add: String, remove: String) -> AgentIntegration {
        AgentIntegration(
            name: name,
            check: {
                guard shell("command -v \(tool)").status == 0 else { return .notInstalled }
                return shell("\(tool) mcp get onramp").status == 0 ? .connected("MCP server") : .notConnected
            },
            connect: { try shell(add).orThrow() },
            disconnect: { try shell(remove).orThrow() }
        )
    }

    private static let cursorConfig = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cursor/mcp.json")

    private static let cursor = AgentIntegration(
        name: "Cursor",
        check: {
            let dir = cursorConfig.deletingLastPathComponent().path
            guard FileManager.default.fileExists(atPath: dir) else { return .notInstalled }
            let servers = (readJSON(cursorConfig)["mcpServers"] as? [String: Any]) ?? [:]
            return servers["onramp"] != nil ? .connected("~/.cursor/mcp.json") : .notConnected
        },
        connect: {
            var json = readJSON(cursorConfig)
            var servers = (json["mcpServers"] as? [String: Any]) ?? [:]
            servers["onramp"] = ["command": command, "args": ["mcp"]]
            json["mcpServers"] = servers
            try writeJSON(json, cursorConfig)
        },
        disconnect: {
            var json = readJSON(cursorConfig)
            var servers = (json["mcpServers"] as? [String: Any]) ?? [:]
            servers["onramp"] = nil
            json["mcpServers"] = servers
            try writeJSON(json, cursorConfig)
        }
    )

    private static func readJSON(_ url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private static func writeJSON(_ json: [String: Any], _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    struct ShellResult {
        let status: Int32
        let output: String
        func orThrow() throws {
            if status != 0 { throw CoreError.Io(message: output.isEmpty ? "command failed (\(status))" : output) }
        }
    }

    /// Your terminal's PATH (read once from an interactive login shell, so ~/.zshrc
    /// counts), plus where agent CLIs usually install. Apps started from Finder or
    /// the Dock only get /usr/bin:/bin, and a login-only shell skips ~/.zshrc:
    /// that's how `claude` went missing while `codex` (Homebrew) was found.
    static let userPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let marker = "__ONRAMP_PATH__"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-ilc", "print -r -- \"\(marker)${PATH}\(marker)\""]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        var shellPath = ""
        if (try? p.run()) != nil {
            let deadline = DispatchTime.now() + 5 // a slow or stuck ~/.zshrc can't hang us
            DispatchQueue.global().asyncAfter(deadline: deadline) { if p.isRunning { p.terminate() } }
            let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            p.waitUntilExit()
            // Between the markers: prompts and terminal escape codes around it are ignored.
            let parts = text.components(separatedBy: marker)
            if parts.count >= 3 { shellPath = parts[parts.count - 2] }
        }
        let usual = ["\(home)/.claude/local", "\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.npm-global/bin",
                     "\(home)/.bun/bin", "\(home)/.volta/bin", "\(home)/.cargo/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var seen = Set<String>()
        return (shellPath.split(separator: ":").map(String.init) + usual).filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
    }()

    static func shell(_ command: String) -> ShellResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", command]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = userPath
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return ShellResult(status: -1, output: "\(error)") }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return ShellResult(status: p.terminationStatus, output: String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
    }
}

/// Opt-in: connect (or disconnect) each installed agent to onramp's MCP server.
final class AgentConnectViewController: NSViewController {
    private var rows: [(agent: AgentIntegration, status: NSTextField, button: NSButton)] = []
    private var states: [AgentIntegration.State] = []

    override func loadView() {
        let stack = PopoverUI.stack([])
        PopoverUI.add(PopoverUI.title("Connect your coding agent"), to: stack, spacingAfter: 6)
        PopoverUI.add(PopoverUI.note("""
        Adds Onramp as an MCP server in the agent's settings, so it can read your review \
        comments, reply and resolve them when you ask. Nothing leaves your machine, and you can \
        disconnect anytime.
        """), to: stack, spacingAfter: 14)

        for (i, agent) in AgentIntegration.all.enumerated() {
            let name = NSTextField(labelWithString: agent.name)
            name.font = .systemFont(ofSize: 13, weight: .medium)
            let status = NSTextField(wrappingLabelWithString: "Checking…")
            status.maximumNumberOfLines = 3
            status.preferredMaxLayoutWidth = 250
            status.font = .systemFont(ofSize: 11.5)
            status.textColor = .secondaryLabelColor
            let text = NSStackView(views: [name, status])
            text.orientation = .vertical
            text.alignment = .leading
            text.spacing = 1
            let button = NSButton(title: "Connect", target: self, action: #selector(toggle(_:)))
            button.bezelStyle = .push
            button.isEnabled = false
            button.tag = rows.count
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
            if i > 0 { PopoverUI.add(PopoverUI.separator(), to: stack, spacingAfter: 10) }
            PopoverUI.add(PopoverUI.row([text], [button]), to: stack, spacingAfter: 10)
            rows.append((agent, status, button))
            states.append(.checking)
        }
        stack.setCustomSpacing(16, after: stack.arrangedSubviews.last!)
        PopoverUI.add(PopoverUI.note("Then ask your agent to “address my Onramp comments”. In Claude Code: /onramp:address-comments", size: 11.5), to: stack, spacingAfter: 12)
        let again = NSButton(title: "Check Again", target: self, action: #selector(checkAgain))
        again.bezelStyle = .push
        again.controlSize = .small
        again.toolTip = "Look for each agent and its Onramp connection again (after installing an agent, or setting it up in a terminal)"
        PopoverUI.add(PopoverUI.row([], [again]), to: stack)
        view = PopoverUI.container(stack)
        preferredContentSize = view.frame.size
        refresh()
    }

    @objc private func checkAgain() {
        for i in rows.indices { show(.checking, at: i) }
        refresh()
    }

    /// Status checks spawn each agent's CLI (~0.5 s); run them off the main thread.
    private func refresh() {
        for (i, row) in rows.enumerated() {
            let agent = row.agent
            DispatchQueue.global(qos: .userInitiated).async {
                let state = agent.check()
                DispatchQueue.main.async { [weak self] in self?.show(state, at: i) }
            }
        }
    }

    private func show(_ state: AgentIntegration.State, at i: Int) {
        states[i] = state
        let row = rows[i]
        switch state {
        case .checking: row.status.stringValue = "Checking…"; row.button.isEnabled = false
        case .notInstalled:
            let tool = row.agent.name == "Cursor" ? "Cursor" : "the \(row.agent.name == "Claude Code" ? "claude" : row.agent.name.lowercased()) command"
            row.status.stringValue = "Couldn't find \(tool)"
            row.status.toolTip = "Looked in your shell's PATH and the usual install folders:\n" + AgentIntegration.userPath.replacingOccurrences(of: ":", with: "\n")
            row.status.textColor = .secondaryLabelColor; row.button.isEnabled = false; row.button.title = "Connect"
        case let .connected(how):
            row.status.stringValue = "✓ Connected (\(how))"; row.status.textColor = .systemGreen; row.button.isEnabled = true; row.button.title = "Disconnect"
        case .notConnected: row.status.stringValue = "Not connected"; row.status.textColor = .secondaryLabelColor; row.button.isEnabled = true; row.button.title = "Connect"
        }
    }

    @objc private func toggle(_ sender: NSButton) {
        let i = sender.tag
        let agent = rows[i].agent
        let connecting = !states[i].isConnected
        show(.checking, at: i)
        rows[i].status.stringValue = connecting ? "Connecting…" : "Disconnecting…"
        DispatchQueue.global(qos: .userInitiated).async {
            var failure: String?
            do { try connecting ? agent.connect() : agent.disconnect() } catch { failure = "\(error)" }
            let state = agent.check()
            DispatchQueue.main.async { [weak self] in
                self?.show(state, at: i)
                if let failure { // say what went wrong, right there
                    self?.rows[i].status.stringValue = "Didn't work: " + (failure.components(separatedBy: "\n").first { !$0.isEmpty } ?? failure)
                    self?.rows[i].status.textColor = .systemRed
                    self?.rows[i].status.toolTip = failure
                }
            }
        }
    }
}
