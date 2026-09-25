import AppKit

/// onramp:// links, e.g. from Stoplight:
///   onramp://pr?repo=owner/name&number=123   view that PR (as a tab)
///   onramp://open?path=/path/to/repo          open a project
@MainActor
enum DeepLinks {
    static func handle(_ url: URL, app: AppDelegate) {
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { q.first { $0.name == name }?.value }
        switch url.host {
        case "pr":
            guard let slug = value("repo"), let n = value("number").flatMap(Int.init) else { return }
            guard let repo = Clones.find(slug) ?? Clones.ask(slug) else { return log("no clone for \(slug)") }
            log("clone for \(slug): \(repo)")
            app.viewPullRequest(n, repo: repo) { error in
                guard let error else { return }
                alert("Couldn't open \(slug)#\(n)", error)
            }
        case "open":
            if let path = value("path"), let root = RecentProjects.repoRoot(of: path) { app.openProject(root) }
        default:
            break
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Up front, never behind another app's windows (links arrive while you're elsewhere).
    static func alert(_ title: String, _ detail: String) {
        guard ProcessInfo.processInfo.environment["ONRAMP_SELFTEST"] == nil else { return log("alert: \(title) — \(detail)") }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.runModal()
    }

    /// Self-tests read these (stderr); normal runs stay quiet.
    static func log(_ s: String) {
        guard ProcessInfo.processInfo.environment["ONRAMP_SELFTEST"] != nil else { return }
        FileHandle.standardError.write("[link] \(s)\n".data(using: .utf8)!)
    }
}

/// Which local clone is "owner/name": remembered, among the projects you've
/// opened (and their worktrees), or in the usual code folders (~/dev, ~/code…),
/// matched by git remote. Only if none of that finds it do we ask.
@MainActor
enum Clones {
    private static func key(_ slug: String) -> String { "onramp.clone." + slug.lowercased() }

    /// Where people keep their clones, searched two levels deep (~/dev/org/repo).
    /// (Never Documents, Desktop or Downloads: macOS would ask you to allow that.)
    private static let codeFolders = ["dev", "code", "src", "Developer", "Projects", "projects", "repos", "git", "github", "work", "workspace", "Code", ""]
    private static let privateFolders: Set<String> = ["Desktop", "Documents", "Downloads", "Library", "Movies", "Music", "Pictures", "Public", "Applications"]

    /// Your home folder (self-tests search a scratch one).
    private static var home: URL {
        let env = ProcessInfo.processInfo.environment
        if env["ONRAMP_SELFTEST"] != nil, let h = env["ONRAMP_SEARCH_HOME"] { return URL(fileURLWithPath: h) }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    static func find(_ slug: String) -> String? {
        if let saved = UserDefaults.standard.string(forKey: key(slug)), matches(saved, slug) { return saved }
        var candidates = RecentProjects.list
        for p in RecentProjects.list { candidates += ((try? listWorktrees(repoRoot: p)) ?? []).map(\.path) }
        if let found = Set(candidates).sorted().first(where: { matches($0, slug) }) ?? search(slug) {
            UserDefaults.standard.set(found, forKey: key(slug))
            RecentProjects.add(found)
            return found
        }
        return nil
    }

    /// Look through the usual code folders for a repo whose .git/config names the slug
    /// (a cheap text check first, then git confirms).
    private static func search(_ slug: String) -> String? {
        let fm = FileManager.default
        let needle = slug.lowercased()
        func configNames(_ repo: URL) -> Bool {
            guard let text = try? String(contentsOf: repo.appendingPathComponent(".git/config"), encoding: .utf8) else { return false }
            return text.lowercased().contains(needle)
        }
        func children(_ dir: URL) -> [URL] {
            ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? [])
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        }
        let name = (slug as NSString).lastPathComponent.lowercased()
        var seen = Set<String>()
        for folder in codeFolders {
            let root = folder.isEmpty ? home : home.appendingPathComponent(folder)
            guard seen.insert(root.path).inserted, fm.fileExists(atPath: root.path) else { continue }
            let level1 = children(root).filter { !(folder.isEmpty && privateFolders.contains($0.lastPathComponent)) }
            // Same-named folders first: ~/dev/PushPress-Services before everything else.
            let ordered = level1.sorted { ($0.lastPathComponent.lowercased() == name ? 0 : 1) < ($1.lastPathComponent.lowercased() == name ? 0 : 1) }
            for dir in ordered {
                if configNames(dir), matches(dir.path, slug) { return dir.path }
            }
            guard !folder.isEmpty else { continue } // don't walk all of ~ two deep
            for dir in level1 where !fm.fileExists(atPath: dir.appendingPathComponent(".git").path) {
                for sub in children(dir) where configNames(sub) && matches(sub.path, slug) { return sub.path }
            }
        }
        return nil
    }

    /// Ask where the clone is (once; remembered).
    static func ask(_ slug: String) -> String? {
        // Self-test: answer the panel with this folder (as if you'd picked it).
        if ProcessInfo.processInfo.environment["ONRAMP_SELFTEST"] != nil {
            guard let path = ProcessInfo.processInfo.environment["ONRAMP_CLONE_PATH"] else { DeepLinks.log("would ask for \(slug)"); return nil }
            return accept(URL(fileURLWithPath: path), slug)
        }
        NSApp.activate(ignoringOtherApps: true) // in front, so nothing that follows opens behind other apps
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Use This Clone"
        panel.message = "Where's your local clone of \(slug)? (Onramp remembers it.)"
        if let dev = codeFolders.dropLast().map({ home.appendingPathComponent($0) })
            .first(where: { FileManager.default.fileExists(atPath: $0.path) }) { panel.directoryURL = dev }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return accept(url, slug)
    }

    private static func accept(_ url: URL, _ slug: String) -> String? {
        DeepLinks.log("picked \(url.path)")
        guard let root = RecentProjects.repoRoot(of: url.path) else {
            DeepLinks.alert("That folder isn't a git repository", "Choose the folder you cloned \(slug) into (the one with the .git folder).")
            return nil
        }
        guard matches(root, slug) else {
            let found = remotes(root)
            DeepLinks.alert("That folder isn't a clone of \(slug)",
                            found.isEmpty ? "It has no git remotes." : "Its remotes point at:\n" + found.joined(separator: "\n"))
            return nil
        }
        UserDefaults.standard.set(root, forKey: key(slug))
        RecentProjects.add(root)
        return root
    }

    /// The repo's remote URLs (`git remote -v`, deduplicated).
    static func remotes(_ path: String) -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git", "-C", path, "remote", "-v"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        var urls: [String] = []
        for line in (String(data: data, encoding: .utf8) ?? "").split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == "\t" || $0 == " " })
            if parts.count >= 2, !urls.contains(String(parts[1])) { urls.append(String(parts[1])) }
        }
        return urls
    }

    /// Does any remote of the repo at `path` end in "owner/name"? Any host counts:
    /// github.com, an SSH alias like git@github-work:owner/name, or GitHub Enterprise.
    static func matches(_ path: String, _ slug: String) -> Bool {
        let s = slug.lowercased()
        return remotes(path).contains { url in
            var u = url.lowercased()
            while u.hasSuffix("/") { u.removeLast() }
            if u.hasSuffix(".git") { u.removeLast(4) }
            return u.hasSuffix("/" + s) || u.hasSuffix(":" + s)
        }
    }
}
