import Foundation

/// `pairprogram mcp`: a Model Context Protocol server over stdio, so any
/// MCP-capable agent can read review comments, reply, and resolve them.
/// Register it once, e.g. `claude mcp add pairprogram -- pairprogram mcp`.
///
/// Same storage as the app and the CLI; the app picks up changes live.
enum MCPServer {
    static func run(repoRoot: String, author fixedAuthor: String?) -> Int32 {
        var author = fixedAuthor ?? "agent"
        var presence: String?
        defer { if let presence { try? FileManager.default.removeItem(atPath: presence) } }
        while let line = readLine(strippingNewline: true) {
            guard let data = line.data(using: .utf8),
                  let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = msg["method"] as? String else { continue }
            let id = msg["id"] // absent for notifications
            let params = msg["params"] as? [String: Any] ?? [:]

            switch method {
            case "initialize":
                // Sign comments with the agent's name ("claude-code", "codex", …) unless told otherwise.
                if fixedAuthor == nil, let client = (params["clientInfo"] as? [String: Any])?["name"] as? String, !client.isEmpty {
                    author = client
                }
                presence = announce(repoRoot: repoRoot, agent: author)
                respond(id, result: [
                    "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                    "capabilities": ["tools": [:], "prompts": [:]],
                    "serverInfo": ["name": "pairprogram", "version": "0.1.0"],
                    "instructions": instructions,
                ])
            case "ping":
                respond(id, result: [:])
            case "tools/list":
                respond(id, result: ["tools": tools])
            case "prompts/list":
                respond(id, result: ["prompts": [[
                    "name": "address_comments",
                    "description": "Work through the review comments left in pairprogram: fix, then resolve or reply.",
                ]]])
            case "prompts/get":
                let md = (try? exportMarkdown(repoRoot: repoRoot, includeResolved: false)) ?? ""
                respond(id, result: [
                    "description": "Address pairprogram review comments",
                    "messages": [["role": "user", "content": ["type": "text", "text": addressPrompt + "\n\n" + md]]],
                ])
            case "tools/call":
                let name = params["name"] as? String ?? ""
                let args = params["arguments"] as? [String: Any] ?? [:]
                if let presence { touch(presence, agent: author, action: name) } // the app shows "working"
                do {
                    respond(id, result: ["content": [["type": "text", "text": try call(name, args, repoRoot: repoRoot, author: author)]]])
                } catch {
                    respond(id, result: ["content": [["type": "text", "text": message(error)]], "isError": true])
                }
            default:
                if id != nil { respond(id, error: ["code": -32601, "message": "Method not found: \(method)"]) }
            }
        }
        return 0
    }

    static let addressPrompt = """
    I reviewed your changes in pairprogram and left the comments below. For each open comment: \
    call claim_comment first (skip any claimed by another agent), fix the code, then call \
    resolve_comment with a one-line note on what you changed. If a comment needs a decision from \
    me, call reply_to_comment with your question instead of resolving it. When you're done, call \
    list_comments to confirm nothing is left open.
    """

    /// Tell the app an agent is connected: `<git-dir>/pairprogram/agent-<pid>.json`,
    /// removed when the session ends (the app also ignores files from dead processes).
    private static func announce(repoRoot: String, agent: String) -> String? {
        guard let comments = try? commentsPath(repoRoot: repoRoot) else { return nil }
        let dir = (comments as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = (dir as NSString).appendingPathComponent("agent-\(getpid()).json")
        let info: [String: Any] = ["agent": agent, "pid": Int(getpid()), "since": Int(Date().timeIntervalSince1970)]
        guard let data = try? JSONSerialization.data(withJSONObject: info) else { return nil }
        FileManager.default.createFile(atPath: path, contents: data)
        return path
    }

    /// Record the agent's latest tool call in its presence file.
    private static func touch(_ path: String, agent: String, action: String) {
        let now = Int(Date().timeIntervalSince1970)
        var info = (FileManager.default.contents(atPath: path).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
        info["agent"] = agent
        info["pid"] = Int(getpid())
        info["last_activity"] = now
        info["last_action"] = action
        if let data = try? JSONSerialization.data(withJSONObject: info) { try? data.write(to: URL(fileURLWithPath: path), options: .atomic) }
    }

    static let instructions = """
    The user reviews your code changes in pairprogram and leaves comments on specific lines.
    Call list_comments to see open comments with the code they refer to. Before working on one, \
    call claim_comment so other agents leave it alone (skip comments another agent has claimed). \
    Address each by editing the code, then call resolve_comment with a short note on what you \
    changed. If a comment needs a decision from the user, call reply_to_comment with your question \
    instead of resolving it.
    """

    static let tools: [[String: Any]] = [
        tool("list_comments", "List review comments on the current changes, with the code each refers to (Markdown).", [
            "include_resolved": ["type": "boolean", "description": "Also include resolved threads (default false)."],
        ], required: []),
        tool("reply_to_comment", "Add a reply to a comment thread, e.g. to ask a question or explain a decision.", [
            "id": ["type": "string", "description": "Thread id from list_comments."],
            "body": ["type": "string", "description": "Your reply."],
        ], required: ["id", "body"]),
        tool("resolve_comment", "Mark a comment thread resolved after addressing it.", [
            "id": ["type": "string", "description": "Thread id from list_comments."],
            "note": ["type": "string", "description": "Short note on what you changed."],
        ], required: ["id"]),
        tool("reopen_comment", "Reopen a resolved comment thread.", [
            "id": ["type": "string", "description": "Thread id."],
        ], required: ["id"]),
        tool("claim_comment", "Claim a comment thread before working on it, so other agents skip it. Fails if another agent has it.", [
            "id": ["type": "string", "description": "Thread id from list_comments."],
        ], required: ["id"]),
        tool("release_comment", "Give a claimed thread back without resolving it (e.g. you can't do it).", [
            "id": ["type": "string", "description": "Thread id."],
        ], required: ["id"]),
    ]

    private static func tool(_ name: String, _ description: String, _ props: [String: Any], required: [String]) -> [String: Any] {
        ["name": name, "description": description,
         "inputSchema": ["type": "object", "properties": props, "required": required]]
    }

    private static func call(_ name: String, _ args: [String: Any], repoRoot: String, author: String) throws -> String {
        func arg(_ k: String) throws -> String {
            guard let v = args[k] as? String, !v.isEmpty else { throw CoreError.Io(message: "missing argument: \(k)") }
            return v
        }
        switch name {
        case "list_comments":
            return try exportMarkdown(repoRoot: repoRoot, includeResolved: args["include_resolved"] as? Bool ?? false)
        case "reply_to_comment":
            let t = try reply(repoRoot: repoRoot, id: try arg("id"), author: author, body: try arg("body"), pending: false)
            return "Replied to \(t.id)."
        case "resolve_comment":
            let t = try setResolved(repoRoot: repoRoot, id: try arg("id"), resolved: true, author: author, note: args["note"] as? String)
            return "Resolved \(t.id)."
        case "claim_comment":
            let t = try claimThread(repoRoot: repoRoot, id: try arg("id"), agent: author)
            return "Claimed \(t.id): it's yours. Resolve it (or release_comment) when done."
        case "release_comment":
            let t = try releaseThread(repoRoot: repoRoot, id: try arg("id"), agent: author)
            return "Released \(t.id)."
        case "reopen_comment":
            let t = try setResolved(repoRoot: repoRoot, id: try arg("id"), resolved: false, author: author, note: nil)
            return "Reopened \(t.id)."
        default:
            throw CoreError.Io(message: "unknown tool: \(name)")
        }
    }

    private static func message(_ error: Error) -> String {
        if let e = error as? CoreError { switch e { case let .Git(m), let .Io(m): return m } }
        return "\(error)"
    }

    private static func respond(_ id: Any?, result: [String: Any]? = nil, error: [String: Any]? = nil) {
        guard let id else { return }
        var msg: [String: Any] = ["jsonrpc": "2.0", "id": id]
        if let result { msg["result"] = result }
        if let error { msg["error"] = error }
        guard let data = try? JSONSerialization.data(withJSONObject: msg), var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        FileHandle.standardOutput.write(line.data(using: .utf8)!)
    }
}
