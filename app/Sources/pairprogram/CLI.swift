import Foundation

/// `pairprogram <command>`: how agents (any agent) read and answer review
/// comments. Returns nil when the arguments mean "open the app".
enum CLI {
    static let usage = """
    pairprogram                        open the review for the current repo (returns right away)
    pairprogram <path>                 open the review for the repo containing <path>
    pairprogram --wait [path]          open it and wait until the window closes

    pairprogram comments [--json] [--all]
                                       print open comments (--all includes resolved)
    pairprogram reply <id> <text>      add a reply to a comment thread
    pairprogram resolve <id> [--note <text>]
                                       mark a thread resolved, optionally with a note
    pairprogram reopen <id>            reopen a resolved thread
    pairprogram extensions             list installed extensions and any problems loading them
    pairprogram prompt                 print instructions to paste into any agent
    pairprogram mcp                    run as an MCP server (stdio) for agents that speak MCP,
                                       e.g. `claude mcp add pairprogram -- pairprogram mcp`

    Options: -C <dir> (repo, default: current dir)  --author <name> (default: $PAIRPROGRAM_AUTHOR or "agent")
    """

    static let commands: Set<String> = ["comments", "reply", "resolve", "reopen", "prompt", "extensions", "mcp", "help", "--help", "-h"]

    static func run(_ argv: [String]) -> Int32? {
        guard let command = argv.first, commands.contains(command) else { return nil }
        var args = Array(argv.dropFirst())
        let dir = take(&args, "-C") ?? FileManager.default.currentDirectoryPath
        let explicitAuthor = take(&args, "--author") ?? ProcessInfo.processInfo.environment["PAIRPROGRAM_AUTHOR"]
        let author = explicitAuthor ?? "agent"
        let note = take(&args, "--note")
        let json = flag(&args, "--json")
        let all = flag(&args, "--all")

        do {
            switch command {
            case "help", "--help", "-h":
                print(usage)
            case "extensions":
                let scan = MainActor.assumeIsolated { Extensions.scan() }
                for e in scan.extensions {
                    var parts = [e.builtin ? "built-in" : "user"]
                    if !e.fonts.isEmpty { parts.append("\(e.fonts.count) font file\(e.fonts.count == 1 ? "" : "s")") }
                    if !e.themes.isEmpty { parts.append("\(e.themes.count) theme\(e.themes.count == 1 ? "" : "s")") }
                    print("\(e.id) \(e.version)  \(e.name)  (\(parts.joined(separator: ", ")))")
                }
                for p in scan.problems { print("✗ \(p.dir): \(p.message)") }
                print("user extensions: \(MainActor.assumeIsolated { Extensions.userDir.path })")
                if !scan.problems.isEmpty { return 1 }
            case "prompt":
                print(prompt)
            case "mcp":
                return MCPServer.run(repoRoot: try repoRoot(dir), author: explicitAuthor)
            case "comments":
                let root = try repoRoot(dir)
                print(json ? try exportJson(repoRoot: root, includeResolved: all) : try exportMarkdown(repoRoot: root, includeResolved: all))
            case "reply":
                guard args.count >= 2 else { return fail("usage: pairprogram reply <id> <text>") }
                let t = try reply(repoRoot: try repoRoot(dir), id: args[0], author: author, body: args.dropFirst().joined(separator: " "), pending: false)
                print("replied to \(t.id)")
            case "resolve", "reopen":
                guard let id = args.first else { return fail("usage: pairprogram \(command) <id>") }
                let t = try setResolved(repoRoot: try repoRoot(dir), id: id, resolved: command == "resolve", author: author, note: note)
                print("\(command == "resolve" ? "resolved" : "reopened") \(t.id)")
            default:
                return nil
            }
            return 0
        } catch let error as CoreError {
            switch error {
            case let .Git(message), let .Io(message): return fail("pairprogram: \(message)")
            }
        } catch {
            return fail("pairprogram: \(error)")
        }
    }

    static let prompt = """
    I left review comments on your changes using pairprogram.
    1. Run `pairprogram comments` to see every open comment, with the code it refers to.
    2. Address each one by editing the code.
    3. After fixing one, run `pairprogram resolve <id> --note "<what you changed>"`.
       If you disagree or need a decision from me, run `pairprogram reply <id> "<question>"` instead of resolving.
    4. When done, run `pairprogram comments` again to confirm nothing is left open.
    """

    enum Open { case run(repo: String), exit(Int32) }

    /// `pairprogram [path]`: find the repo, then (from a terminal) relaunch the
    /// app detached and return, like `code .`.
    static func prepareOpen(_ argv: [String]) -> Open {
        let wait = argv.contains("--wait")
        let path = argv.first { !$0.hasPrefix("-") && $0 != "YES" && $0 != "NO" } ?? FileManager.default.currentDirectoryPath
        let root: String
        do { root = try repoRoot(URL(fileURLWithPath: path).standardizedFileURL.path) } catch {
            FileHandle.standardError.write("pairprogram: not inside a git repository: \(path)\n".data(using: .utf8)!)
            return .exit(1)
        }
        let env = ProcessInfo.processInfo.environment
        // Always detach (terminals, Claude Code's `!`, scripts), unless asked to wait.
        guard !wait, env["PP_DETACHED"] == nil, env["PP_SELFTEST"] == nil else { return .run(repo: root) }

        // Relaunch detached (own session, no terminal I/O) and return.
        let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let passthrough = argv.filter { $0.hasPrefix("-") && $0 != "--wait" }
        let args: [String] = [exe, root] + passthrough
        let vars: [String] = env.map { "\($0.key)=\($0.value)" } + ["PP_DETACHED=1"]
        var argvC: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
        var envC: [UnsafeMutablePointer<CChar>?] = vars.map { strdup($0) } + [nil]
        defer { (argvC + envC).forEach { free($0) } }
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
        var files: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&files)
        posix_spawn_file_actions_addopen(&files, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&files, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&files, 2, "/dev/null", O_WRONLY, 0)
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, exe, &files, &attr, &argvC, &envC)
        posix_spawnattr_destroy(&attr)
        posix_spawn_file_actions_destroy(&files)
        guard rc == 0 else { return .run(repo: root) } // couldn't detach: just run here
        print("Opening pairprogram for \((root as NSString).lastPathComponent)")
        return .exit(0)
    }

    private static func repoRoot(_ dir: String) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git", "-C", dir, "rev-parse", "--show-toplevel"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try p.run()
        p.waitUntilExit()
        let root = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard p.terminationStatus == 0, !root.isEmpty else { throw CoreError.Git(message: "not a git repository: \(dir)") }
        return root
    }

    private static func take(_ args: inout [String], _ name: String) -> String? {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        let v = args[i + 1]
        args.removeSubrange(i...(i + 1))
        return v
    }

    private static func flag(_ args: inout [String], _ name: String) -> Bool {
        guard let i = args.firstIndex(of: name) else { return false }
        args.remove(at: i)
        return true
    }

    private static func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
        return 1
    }
}
