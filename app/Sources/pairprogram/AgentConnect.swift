import AppKit

/// Agents connected to this repo through `pairprogram mcp` (each MCP session
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

/// One agent pairprogram can register its MCP server with. Nothing is
/// registered until the user clicks Connect (opt-in, reversible).
struct AgentIntegration {
    enum State: Equatable { case checking, notInstalled, connected, notConnected }

    let name: String
    let check: () -> State
    let connect: () throws -> Void
    let disconnect: () throws -> Void

    /// The command agents launch: the installed symlink if present, else this binary.
    static var command: String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let link = [".local/bin/onramp", ".local/bin/pair", ".local/bin/pairprogram"].map { home.appendingPathComponent($0).path }
            .first { FileManager.default.isExecutableFile(atPath: $0) } ?? home.appendingPathComponent(".local/bin/onramp").path
        if FileManager.default.isExecutableFile(atPath: link) { return link }
        return URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
    }

    /// Claude Code gets a plugin (so the command is /pairprogram:address-comments)
    /// that bundles the MCP server; install.sh puts it here.
    static let claudePlugin = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/pairprogram/integrations/claude-code").path

    static let all: [AgentIntegration] = [
        AgentIntegration(
            name: "Claude Code",
            check: {
                guard shell("command -v claude").status == 0 else { return .notInstalled }
                return shell("claude plugin list").output.contains("pairprogram@pairprogram") ? .connected : .notConnected
            },
            connect: {
                if !shell("claude plugin marketplace list").output.contains("pairprogram") {
                    try shell("claude plugin marketplace add '\(claudePlugin)'").orThrow()
                }
                try shell("claude plugin install pairprogram@pairprogram").orThrow()
            },
            disconnect: { try shell("claude plugin uninstall pairprogram@pairprogram").orThrow() }
        ),
        cli(name: "Codex", tool: "codex",
            add: "codex mcp add pairprogram -- '\(command)' mcp",
            remove: "codex mcp remove pairprogram"),
        cursor,
    ]

    /// Agents with an `mcp add/get/remove` CLI. Run through a login shell so a
    /// Finder-launched app sees the same PATH as your terminal.
    private static func cli(name: String, tool: String, add: String, remove: String) -> AgentIntegration {
        AgentIntegration(
            name: name,
            check: {
                guard shell("command -v \(tool)").status == 0 else { return .notInstalled }
                return shell("\(tool) mcp get pairprogram").status == 0 ? .connected : .notConnected
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
            return servers["pairprogram"] != nil ? .connected : .notConnected
        },
        connect: {
            var json = readJSON(cursorConfig)
            var servers = (json["mcpServers"] as? [String: Any]) ?? [:]
            servers["pairprogram"] = ["command": command, "args": ["mcp"]]
            json["mcpServers"] = servers
            try writeJSON(json, cursorConfig)
        },
        disconnect: {
            var json = readJSON(cursorConfig)
            var servers = (json["mcpServers"] as? [String: Any]) ?? [:]
            servers["pairprogram"] = nil
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

    static func shell(_ command: String) -> ShellResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", command]
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

/// Opt-in: connect (or disconnect) each installed agent to pairprogram's MCP server.
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
            let status = NSTextField(labelWithString: "Checking…")
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
        PopoverUI.add(PopoverUI.note("Then ask your agent to “address my Onramp comments”. In Claude Code: /pairprogram:address-comments", size: 11.5), to: stack)
        view = PopoverUI.container(stack)
        preferredContentSize = view.frame.size
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
        case .notInstalled: row.status.stringValue = "Not installed"; row.button.isEnabled = false; row.button.title = "Connect"
        case .connected: row.status.stringValue = "✓ Connected"; row.status.textColor = .systemGreen; row.button.isEnabled = true; row.button.title = "Disconnect"
        case .notConnected: row.status.stringValue = "Not connected"; row.status.textColor = .secondaryLabelColor; row.button.isEnabled = true; row.button.title = "Connect"
        }
    }

    @objc private func toggle(_ sender: NSButton) {
        let i = sender.tag
        let agent = rows[i].agent
        let connecting = states[i] != .connected
        show(.checking, at: i)
        rows[i].status.stringValue = connecting ? "Connecting…" : "Disconnecting…"
        DispatchQueue.global(qos: .userInitiated).async {
            var failure: String?
            do { try connecting ? agent.connect() : agent.disconnect() } catch { failure = "\(error)" }
            let state = agent.check()
            DispatchQueue.main.async { [weak self] in
                self?.show(state, at: i)
                if let failure { self?.rows[i].status.stringValue = "Failed"; self?.rows[i].status.toolTip = failure }
            }
        }
    }
}
