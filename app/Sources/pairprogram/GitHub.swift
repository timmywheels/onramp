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

    struct Failure: Error, CustomStringConvertible { let description: String }

    /// Run `gh` in `repo` through a login shell (your PATH), returning stdout.
    private static func gh(_ args: [String], repo: String) throws -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "gh " + args.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")]
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
            if errText.contains("command not found") { throw Failure(description: "The GitHub CLI isn't installed: brew install gh, then gh auth login") }
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

    /// Fetch a PR (read-only: a private ref, no checkout) and switch the review to it.
    static func open(repo: String, number: Int) throws -> PR {
        let pr = try view(repo: repo, number: number)
        try fetchPullRequest(repoRoot: repo, remote: "origin", number: UInt32(number), baseBranch: pr.baseRefName)
        cache(pr, repo: repo)
        var c = reviewChoice(repoRoot: repo)
        c.mode = .pullRequest
        c.pr = UInt32(number)
        c.baseBranch = "origin/" + pr.baseRefName
        try setReviewChoice(repoRoot: repo, choice: c)
        RecentPRs.add(number, title: pr.title, repo: repo)
        return pr
    }
}

/// PRs opened recently in a repo, for the Changes menu.
enum RecentPRs {
    private static func key(_ repo: String) -> String { "pairprogram.recentPRs." + repo }

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
