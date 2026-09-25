import AppKit

/// onramp:// (and the older pairprogram://) links, e.g. from Stoplight:
///   pairprogram://pr?repo=owner/name&number=123   view that PR (as a tab)
///   pairprogram://open?path=/path/to/repo          open a project
@MainActor
enum DeepLinks {
    static func handle(_ url: URL, app: AppDelegate) {
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { q.first { $0.name == name }?.value }
        switch url.host {
        case "pr":
            guard let slug = value("repo"), let n = value("number").flatMap(Int.init) else { return }
            guard let repo = Clones.find(slug) ?? Clones.ask(slug) else { return }
            app.viewPullRequest(n, repo: repo) { error in
                guard let error else { return }
                let alert = NSAlert()
                alert.messageText = "Couldn't open \(slug)#\(n)"
                alert.informativeText = error
                alert.runModal()
            }
        case "open":
            if let path = value("path"), let root = RecentProjects.repoRoot(of: path) { app.openProject(root) }
        default:
            break
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Which local clone is "owner/name": remembered, or found among the projects
/// you've opened (and their worktrees) by their git remotes.
enum Clones {
    private static func key(_ slug: String) -> String { "pairprogram.clone." + slug.lowercased() }

    static func find(_ slug: String) -> String? {
        if let saved = UserDefaults.standard.string(forKey: key(slug)), matches(saved, slug) { return saved }
        var candidates = RecentProjects.list
        for p in RecentProjects.list { candidates += ((try? listWorktrees(repoRoot: p)) ?? []).map(\.path) }
        for path in Set(candidates) where matches(path, slug) {
            UserDefaults.standard.set(path, forKey: key(slug))
            return path
        }
        return nil
    }

    /// Ask where the clone is (once; remembered).
    static func ask(_ slug: String) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Use This Clone"
        panel.message = "Where's your local clone of \(slug)?"
        guard panel.runModal() == .OK, let url = panel.url, let root = RecentProjects.repoRoot(of: url.path) else { return nil }
        guard matches(root, slug) else {
            let alert = NSAlert()
            alert.messageText = "That folder isn't a clone of \(slug)"
            alert.informativeText = "None of its git remotes point at github.com/\(slug)."
            alert.runModal()
            return nil
        }
        UserDefaults.standard.set(root, forKey: key(slug))
        RecentProjects.add(root)
        return root
    }

    /// Does any remote of the repo at `path` point at github.com/<slug>?
    static func matches(_ path: String, _ slug: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git", "-C", path, "remote", "-v"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        let remotes = (String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "").lowercased()
        let s = slug.lowercased()
        return remotes.contains("github.com/\(s).git") || remotes.contains("github.com/\(s) ") || remotes.contains("github.com/\(s)\t")
            || remotes.contains("github.com:\(s).git") || remotes.contains("github.com:\(s) ") || remotes.contains("github.com:\(s)\t")
    }
}
