import Foundation

/// Pull requests through the GitHub CLI (`gh`), using your existing login.
/// Nothing here writes to GitHub.
enum GitHub {
    struct Person: Decodable { let login: String }
    struct Label: Decodable { let name: String }

    struct PRSummary: Decodable {
        let number: Int
        let title: String
        let author: Person
        let headRefName: String
        let baseRefName: String
        let updatedAt: Date
        let isDraft: Bool
        let url: String
    }

    struct PR: Codable {
        let number: Int
        let title: String
        let body: String
        let author: String
        let headRefName: String
        let baseRefName: String
        let url: String
        let state: String
        let isDraft: Bool
        let additions: Int
        let deletions: Int
        let changedFiles: Int
        let labels: [String]
    }

    enum Filter: CaseIterable {
        case reviewRequested, mine, open
        var title: String {
            switch self {
            case .reviewRequested: "Review requested"
            case .mine: "Mine"
            case .open: "All open"
            }
        }
        var args: [String] {
            switch self {
            case .reviewRequested: ["--search", "review-requested:@me"]
            case .mine: ["--author", "@me"]
            case .open: []
            }
        }
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        var notFound = false
    }

    /// `gh_path` from settings.json (set by Style); "" = find it.
    nonisolated(unsafe) static var configuredPath = ""
    nonisolated(unsafe) private static var found: String?

    /// Where gh is: your setting, the usual install spots, then your shell
    /// (interactive, so ~/.zshrc PATH changes count).
    static func ghPath() -> String? {
        let fm = FileManager.default
        let setting = (configuredPath as NSString).expandingTildeInPath
        if !setting.isEmpty { return fm.isExecutableFile(atPath: setting) ? setting : nil }
        if let found, fm.isExecutableFile(atPath: found) { return found }
        let home = fm.homeDirectoryForCurrentUser.path
        let spots = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "\(home)/.local/bin/gh", "\(home)/bin/gh", "/usr/bin/gh",
                     "/opt/local/bin/gh", "\(home)/.nix-profile/bin/gh", "/run/current-system/sw/bin/gh"]
        if let hit = spots.first(where: fm.isExecutableFile(atPath:)) { found = hit; return hit }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-ilc", "command -v gh"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        let path = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .split(separator: "\n").last.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        guard p.terminationStatus == 0, path.hasPrefix("/"), fm.isExecutableFile(atPath: path) else { return nil }
        found = path
        return path
    }

    /// Run gh in `repo`, returning stdout.
    private static func gh(_ args: [String], repo: String) throws -> Data {
        guard let path = ghPath() else {
            throw Failure(description: configuredPath.isEmpty
                ? "Couldn't find the GitHub CLI (gh). Install it (brew install gh), or choose where it is."
                : "gh_path in settings.json (\(configuredPath)) isn't an executable.", notFound: true)
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment // apps launched from the Dock get a bare PATH; gh runs git
        env["PATH"] = ([(path as NSString).deletingLastPathComponent, "/opt/homebrew/bin", "/usr/local/bin"] + (env["PATH"] ?? "/usr/bin:/bin").split(separator: ":").map(String.init)).joined(separator: ":")
        p.environment = env
        p.currentDirectoryURL = URL(fileURLWithPath: repo)
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { throw Failure(description: "couldn't run gh: \(error.localizedDescription)") }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errText = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            if errText.contains("gh auth login") { throw Failure(description: "Not logged in to GitHub: run gh auth login") }
            throw Failure(description: errText.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").first ?? "gh failed")
        }
        return data
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    static func list(repo: String, filter: Filter) throws -> [PRSummary] {
        let data = try gh(["pr", "list", "--limit", "50", "--json", "number,title,author,headRefName,baseRefName,updatedAt,isDraft,url"] + filter.args, repo: repo)
        return try decoder.decode([PRSummary].self, from: data)
    }

    static func view(repo: String, number: Int) throws -> PR {
        struct Raw: Decodable {
            let number: Int, title: String, body: String, author: Person, headRefName: String, baseRefName: String
            let url: String, state: String, isDraft: Bool, additions: Int, deletions: Int, changedFiles: Int, labels: [Label]
        }
        let data = try gh(["pr", "view", String(number), "--json",
                           "number,title,body,author,headRefName,baseRefName,url,state,isDraft,additions,deletions,changedFiles,labels"], repo: repo)
        let r = try decoder.decode(Raw.self, from: data)
        return PR(number: r.number, title: r.title, body: r.body, author: r.author.login, headRefName: r.headRefName, baseRefName: r.baseRefName,
                  url: r.url, state: r.state, isDraft: r.isDraft, additions: r.additions, deletions: r.deletions, changedFiles: r.changedFiles,
                  labels: r.labels.map(\.name))
    }

    // MARK: The PR sidebar

    enum Checks { case none, passing, failing, pending }
    enum Review { case none, required, approved, changesRequested }

    /// One open PR with what the sidebar filters on.
    struct PRItem {
        let number: Int
        let title: String
        let author: String
        let headRefName: String
        let baseRefName: String
        let updatedAt: Date
        let isDraft: Bool
        let additions: Int
        let deletions: Int
        let review: Review
        let requested: [String] // logins (and team names) asked to review
        let checks: Checks
        let labels: [String]
    }

    static func listAll(repo: String) throws -> [PRItem] {
        struct Check: Decodable { let status: String?; let conclusion: String?; let state: String? }
        struct Request: Decodable { let login: String?; let name: String? }
        struct Raw: Decodable {
            let number: Int, title: String, author: Person, headRefName: String, baseRefName: String, updatedAt: Date, isDraft: Bool
            let additions: Int, deletions: Int, reviewDecision: String?, reviewRequests: [Request], statusCheckRollup: [Check]?, labels: [Label]
        }
        let data = try gh(["pr", "list", "--state", "open", "--limit", "100", "--json",
                           "number,title,author,headRefName,baseRefName,updatedAt,isDraft,additions,deletions,reviewDecision,reviewRequests,statusCheckRollup,labels"], repo: repo)
        return try decoder.decode([Raw].self, from: data).map { r in
            let checks: Checks = {
                let all = r.statusCheckRollup ?? []
                guard !all.isEmpty else { return .none }
                let bad = ["FAILURE", "ERROR", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE"]
                if all.contains(where: { bad.contains($0.conclusion ?? "") || bad.contains($0.state ?? "") }) { return .failing }
                if all.contains(where: { ($0.status.map { $0 != "COMPLETED" } ?? false) || $0.state == "PENDING" || $0.state == "EXPECTED" }) { return .pending }
                return .passing
            }()
            let review: Review = switch r.reviewDecision ?? "" {
            case "APPROVED": .approved
            case "CHANGES_REQUESTED": .changesRequested
            case "REVIEW_REQUIRED": .required
            default: .none
            }
            return PRItem(number: r.number, title: r.title, author: r.author.login, headRefName: r.headRefName, baseRefName: r.baseRefName,
                          updatedAt: r.updatedAt, isDraft: r.isDraft, additions: r.additions, deletions: r.deletions, review: review,
                          requested: r.reviewRequests.compactMap { $0.login ?? $0.name }, checks: checks, labels: r.labels.map(\.name))
        }
    }

    /// Your GitHub login (for "me" filters), asked once.
    nonisolated(unsafe) private static var login: String?
    static func myLogin(repo: String) -> String? {
        if let login { return login }
        let data = try? gh(["api", "user", "-q", ".login"], repo: repo)
        login = data.flatMap { String(data: $0, encoding: .utf8) }?.trimmingCharacters(in: .whitespacesAndNewlines)
        return login
    }

    // MARK: Merging your own PRs

    enum MergeMethod: String, CaseIterable { case squash, merge, rebase
        var title: String { switch self { case .squash: "Squash and merge"; case .merge: "Merge commit"; case .rebase: "Rebase and merge" } }
    }

    /// What the merge panel needs: can it merge, and how.
    struct MergeInfo {
        let author: String
        let isMine: Bool
        let state: String            // OPEN / MERGED / CLOSED
        let isDraft: Bool
        let mergeable: String        // MERGEABLE / CONFLICTING / UNKNOWN
        let mergeState: String       // CLEAN / BLOCKED / BEHIND / UNSTABLE / DIRTY / …
        let review: Review
        let checks: Checks
        let methods: [MergeMethod]   // allowed by the repo
        let deleteBranchDefault: Bool
    }

    static func mergeInfo(repo: String, number: Int) throws -> MergeInfo {
        struct Check: Decodable { let status: String?; let conclusion: String?; let state: String? }
        struct PRRaw: Decodable {
            let author: Person, state: String, isDraft: Bool, mergeable: String, mergeStateStatus: String
            let reviewDecision: String?, statusCheckRollup: [Check]?
        }
        struct RepoRaw: Decodable { let squashMergeAllowed: Bool, mergeCommitAllowed: Bool, rebaseMergeAllowed: Bool, deleteBranchOnMerge: Bool }
        let pr = try decoder.decode(PRRaw.self, from: gh(["pr", "view", String(number), "--json",
                                                         "author,state,isDraft,mergeable,mergeStateStatus,reviewDecision,statusCheckRollup"], repo: repo))
        let r = try decoder.decode(RepoRaw.self, from: gh(["repo", "view", "--json", "squashMergeAllowed,mergeCommitAllowed,rebaseMergeAllowed,deleteBranchOnMerge"], repo: repo))
        let all = pr.statusCheckRollup ?? []
        let bad = ["FAILURE", "ERROR", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE"]
        let checks: Checks = all.isEmpty ? .none
            : all.contains(where: { bad.contains($0.conclusion ?? "") || bad.contains($0.state ?? "") }) ? .failing
            : all.contains(where: { ($0.status.map { $0 != "COMPLETED" } ?? false) || $0.state == "PENDING" }) ? .pending : .passing
        let review: Review = switch pr.reviewDecision ?? "" {
        case "APPROVED": .approved
        case "CHANGES_REQUESTED": .changesRequested
        case "REVIEW_REQUIRED": .required
        default: .none
        }
        var methods: [MergeMethod] = []
        if r.squashMergeAllowed { methods.append(.squash) }
        if r.mergeCommitAllowed { methods.append(.merge) }
        if r.rebaseMergeAllowed { methods.append(.rebase) }
        return MergeInfo(author: pr.author.login, isMine: pr.author.login == myLogin(repo: repo), state: pr.state, isDraft: pr.isDraft,
                         mergeable: pr.mergeable, mergeState: pr.mergeStateStatus, review: review, checks: checks,
                         methods: methods, deleteBranchDefault: r.deleteBranchOnMerge)
    }

    /// Merge on GitHub. With `deleteBranch`, gh also deletes the branch
    /// (and, if you're on it locally, switches you to the base branch).
    static func merge(repo: String, number: Int, method: MergeMethod, deleteBranch: Bool) throws {
        _ = try gh(["pr", "merge", String(number), "--\(method.rawValue)"] + (deleteBranch ? ["--delete-branch"] : []), repo: repo)
    }

    // MARK: CI failures → review threads

    nonisolated(unsafe) private static var slugs: [String: String] = [:]

    /// "owner/name" of the repo's GitHub remote.
    static func slug(repo: String) throws -> String {
        if let s = slugs[repo] { return s }
        let s = String(decoding: try gh(["repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"], repo: repo), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        slugs[repo] = s
        return s
    }

    /// Failing check runs' annotations on commit `sha`, and whether every check has finished.
    static func ciFindings(repo: String, sha: String) throws -> (findings: [CiFinding], complete: Bool) {
        struct Runs: Decodable { let check_runs: [Run] }
        struct Run: Decodable { let id: Int; let name: String; let status: String; let conclusion: String?; let output: Output }
        struct Output: Decodable { let annotations_count: Int }
        struct Annotation: Decodable { let path: String; let start_line: Int; let annotation_level: String; let title: String?; let message: String }
        let s = try slug(repo: repo)
        let runs = try JSONDecoder().decode(Runs.self, from: gh(["api", "repos/\(s)/commits/\(sha)/check-runs?per_page=100"], repo: repo)).check_runs
        let complete = runs.allSatisfy { $0.status == "completed" }
        let failing = runs.filter { ["failure", "timed_out", "action_required"].contains($0.conclusion ?? "") && $0.output.annotations_count > 0 }
        var findings: [CiFinding] = []
        var texts: [String: String?] = [:]
        for run in failing.prefix(10) {
            let notes = try JSONDecoder().decode([Annotation].self, from: gh(["api", "repos/\(s)/check-runs/\(run.id)/annotations?per_page=100"], repo: repo))
            for a in notes where a.annotation_level != "notice" {
                if texts[a.path] == nil { texts[a.path] = fileAt(repoRoot: repo, rev: sha, path: a.path) }
                guard let text = texts[a.path] ?? nil, a.start_line >= 1 else { continue } // not a file in the repo (e.g. ".github")
                findings.append(CiFinding(check: run.name, path: a.path, line: UInt32(a.start_line - 1), text: text,
                                          level: a.annotation_level, title: a.title ?? "", message: a.message))
            }
        }
        return (findings, complete)
    }

    /// "123", "#123" or a PR URL → 123.
    static func number(from text: String) -> Int? {
        let t = text.trimmingCharacters(in: .whitespaces)
        if let n = Int(t.trimmingCharacters(in: CharacterSet(charactersIn: "#"))) { return n }
        if let r = t.range(of: #"/pull/(\d+)"#, options: .regularExpression) {
            return Int(t[r].dropFirst("/pull/".count))
        }
        return nil
    }

    // MARK: Cache (the description bar reads it without calling gh)

    private static func cacheURL(repo: String, number: Int) -> URL? {
        (try? commentsPath(repoRoot: repo)).map { URL(fileURLWithPath: $0).deletingLastPathComponent().appendingPathComponent("pr-\(number).json") }
    }

    static func cache(_ pr: PR, repo: String) {
        guard let url = cacheURL(repo: repo, number: pr.number), let data = try? JSONEncoder().encode(pr) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func cached(repo: String, number: Int) -> PR? {
        cacheURL(repo: repo, number: number).flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(PR.self, from: $0) }
    }

    /// Fetch a PR (read-only: a private ref, no checkout). The tab then points its review at it.
    static func fetch(repo: String, number: Int) throws -> PR {
        let pr = try view(repo: repo, number: number)
        try fetchPullRequest(repoRoot: repo, remote: "origin", number: UInt32(number), baseBranch: pr.baseRefName)
        cache(pr, repo: repo)
        RecentPRs.add(number, title: pr.title, repo: repo)
        return pr
    }
}

/// PRs opened recently in a repo, for the Changes menu.
enum RecentPRs {
    private static func key(_ repo: String) -> String { "onramp.recentPRs." + repo }

    static func list(repo: String) -> [(number: Int, title: String)] {
        (UserDefaults.standard.array(forKey: key(repo)) as? [[String: Any]] ?? []).compactMap { d in
            guard let n = d["n"] as? Int, let t = d["t"] as? String else { return nil }
            return (n, t)
        }
    }

    static func add(_ number: Int, title: String, repo: String) {
        let rest = list(repo: repo).filter { $0.number != number }.prefix(7).map { ["n": $0.number, "t": $0.title] as [String: Any] }
        UserDefaults.standard.set([["n": number, "t": title]] + rest, forKey: key(repo))
    }
}
