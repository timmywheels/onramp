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
    // No blues: warm and green tones that read on both appearances.
    private static let palette: [NSColor] = [.systemPurple, .systemPink, .systemMint, .systemOrange, .systemBrown, .systemGreen]
    /// Agents you'll know by colour: Claude's clay, Codex's green.
    private static let known: [String: NSColor] = [
        "claude-code": NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1), "claude": NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1),
        "codex": NSColor(srgbRed: 0.06, green: 0.64, blue: 0.50, alpha: 1),
    ]

    static func of(_ agent: String) -> NSColor {
        if let c = known[agent.lowercased()] { return c }
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in agent.lowercased().utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
        return palette[Int(h % UInt64(palette.count))]
    }
}

/// Where each agent's command is, and how to run it. Nothing assumed that can be
/// asked: your settings first (agent_paths / agent_args in settings.json, or
/// Choose… in the Agent panel), then your terminal's PATH; flags come from the
/// installed version's own --help.
enum AgentTools {
    nonisolated(unsafe) static var paths: [String: String] = [:]
    nonisolated(unsafe) static var args: [String: String] = [:]
    /// agent_model: which model each agent runs with ("sonnet" is quicker than the default for most).
    nonisolated(unsafe) static var models: [String: String] = [:]
    static func model(_ tool: String) -> String? { models[tool].flatMap { $0.isEmpty ? nil : $0 } }

    /// The command's absolute path, or nil if it's nowhere to be found.
    static func path(_ tool: String) -> String? {
        let fm = FileManager.default
        if let set = paths[tool], !set.isEmpty {
            let p = (set as NSString).expandingTildeInPath
            return fm.isExecutableFile(atPath: p) ? p : nil // what you chose, or nothing: never a guess instead
        }
        return AgentIntegration.userPath.split(separator: ":").lazy
            .map { "\($0)/\(tool)" }.first { fm.isExecutableFile(atPath: $0) }
    }

    /// For a shell command line: the path, single-quoted.
    static func quoted(_ tool: String) -> String? { path(tool).map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" } }

    /// `codex exec` flags for "may edit files in the repo, without stopping to ask",
    /// from what this codex supports: newer ones have --approve-for-me (which
    /// already means workspace-write, and refuses --sandbox alongside it).
    nonisolated(unsafe) private static var codexFlags: [String: String] = [:]
    static func codexWriteFlags() -> String {
        if let custom = args["codex"], !custom.isEmpty { return custom }
        guard let codex = quoted("codex") else { return "--sandbox workspace-write" }
        if let cached = codexFlags[codex] { return cached }
        let help = AgentIntegration.shell("\(codex) exec --help").output
        let flags = help.contains("--approve-for-me") ? "--approve-for-me"
            : help.contains("--full-auto") ? "--full-auto" : "--sandbox workspace-write"
        codexFlags[codex] = flags
        return flags
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
    /// The command it runs as ("claude"), if it's a CLI you can point Onramp at.
    var tool: String? = nil
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
            tool: "claude",
            check: {
                guard let claude = AgentTools.quoted("claude") else { return .notInstalled }
                // Either way counts: the plugin (what Connect installs), or a plain `claude mcp add onramp`.
                if shell("\(claude) plugin list").output.contains("onramp@onramp") { return .connected("plugin") }
                if shell("\(claude) mcp get onramp").status == 0 { return .connected("MCP server") }
                return .notConnected
            },
            connect: {
                guard let claude = AgentTools.quoted("claude") else { throw CoreError.Io(message: "Couldn't find the claude command") }
                if !shell("\(claude) plugin marketplace list").output.contains("onramp") {
                    try shell("\(claude) plugin marketplace add '\(claudePlugin)'").orThrow()
                }
                try shell("\(claude) plugin install onramp@onramp").orThrow()
            },
            disconnect: {
                // Undo whichever way it was connected (both, if both).
                guard let claude = AgentTools.quoted("claude") else { return }
                let plugin = shell("\(claude) plugin list").output.contains("onramp@onramp") ? shell("\(claude) plugin uninstall onramp@onramp") : nil
                let server = shell("\(claude) mcp get onramp").status == 0 ? shell("\(claude) mcp remove onramp") : nil
                try plugin?.orThrow()
                try server?.orThrow()
            }
        ),
        cli(name: "Codex", tool: "codex",
            add: "mcp add onramp -- '\(command)' mcp",
            remove: "mcp remove onramp"),
        cursor,
    ]

    /// Agents with an `mcp add/get/remove` CLI. Run through a login shell so a
    /// Finder-launched app sees the same PATH as your terminal.
    private static func cli(name: String, tool: String, add: String, remove: String) -> AgentIntegration {
        AgentIntegration(
            name: name,
            tool: tool,
            check: {
                guard let exe = AgentTools.quoted(tool) else { return .notInstalled }
                return shell("\(exe) mcp get onramp").status == 0 ? .connected("MCP server") : .notConnected
            },
            connect: {
                guard let exe = AgentTools.quoted(tool) else { throw CoreError.Io(message: "Couldn't find the \(tool) command") }
                try shell("\(exe) \(add)").orThrow()
            },
            disconnect: { if let exe = AgentTools.quoted(tool) { try shell("\(exe) \(remove)").orThrow() } }
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
            if let tool = row.agent.tool {
                let chosen = AgentTools.paths[tool].flatMap { $0.isEmpty ? nil : $0 }
                row.status.stringValue = chosen.map { "\($0) isn't there or can't run" } ?? "Couldn't find the \(tool) command"
                row.status.toolTip = "Looked in your shell's PATH and the usual install folders:\n" + AgentIntegration.userPath.replacingOccurrences(of: ":", with: "\n")
                    + "\n\nChoose… to point Onramp at it (saved as agent_paths in settings.json)."
                row.button.isEnabled = true; row.button.title = "Choose…" // where is it? you say, we don't guess
            } else {
                row.status.stringValue = "Not installed"
                row.button.isEnabled = false; row.button.title = "Connect"
            }
            row.status.textColor = .secondaryLabelColor
        case let .connected(how):
            row.status.stringValue = "✓ Connected (\(how))"; row.status.textColor = .systemGreen; row.button.isEnabled = true; row.button.title = "Disconnect"
            row.status.toolTip = row.agent.tool.flatMap(AgentTools.path).map { "Runs \($0)" }
        case .notConnected: row.status.stringValue = "Not connected"; row.status.textColor = .secondaryLabelColor; row.button.isEnabled = true; row.button.title = "Connect"
        }
    }

    /// Point Onramp at an agent's command (saved as agent_paths in settings.json), then check again.
    private func choose(_ i: Int) {
        guard let tool = rows[i].agent.tool, let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = true
        panel.showsHiddenFiles = true
        panel.message = "Where is the \(tool) command? (Run `which \(tool)` in your terminal to see.)"
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                Style.shared.update { $0.agentPaths[tool] = url.path }
                self?.show(.checking, at: i)
                self?.refresh()
            }
        }
    }

    @objc private func toggle(_ sender: NSButton) {
        let i = sender.tag
        if states[i] == .notInstalled { return choose(i) }
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
