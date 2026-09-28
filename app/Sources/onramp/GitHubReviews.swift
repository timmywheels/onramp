import Foundation

/// A pull request's review comments on GitHub: yours go up (one at a time, or
/// as a review), everyone's come down as threads. Call these off the main thread.
extension GitHub {
    /// Where a comment goes on GitHub: 1-based line, and which side of the diff.
    struct Place {
        let path: String
        let line: Int
        let oldSide: Bool
        var json: [String: Any] { ["path": path, "line": line, "side": oldSide ? "LEFT" : "RIGHT"] }
    }

    enum Event: String {
        case comment = "COMMENT", approve = "APPROVE", requestChanges = "REQUEST_CHANGES"
    }

    /// `gh api` with a JSON body (through a temp file: `gh` takes nested arrays best that way).
    private static func api(_ method: String, _ path: String, json: [String: Any]? = nil, repo: String) throws -> Data {
        var args = ["api", "--method", method, path]
        var file: URL?
        if let json {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("onramp-gh-\(UUID().uuidString).json")
            try JSONSerialization.data(withJSONObject: json).write(to: url)
            args += ["--input", url.path]
            file = url
        }
        defer { file.map { try? FileManager.default.removeItem(at: $0) } }
        return try gh(args, repo: repo)
    }

    private struct Created: Decodable { let id: UInt64 }

    /// The commit GitHub has as the PR's head (comments are made against it).
    static func headSha(repo: String, number: Int) throws -> String {
        String(decoding: try gh(["pr", "view", String(number), "--json", "headRefOid", "-q", ".headRefOid"], repo: repo), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A single comment, published now. Returns its id.
    static func postComment(repo: String, number: Int, sha: String, place: Place, body: String) throws -> UInt64 {
        var json = place.json
        json["body"] = body
        json["commit_id"] = sha
        return try JSONDecoder().decode(Created.self, from: api("POST", "repos/\(slug(repo: repo))/pulls/\(number)/comments", json: json, repo: repo)).id
    }

    /// A reply in the thread that starts with comment `to`.
    static func postReply(repo: String, number: Int, to: UInt64, body: String) throws -> UInt64 {
        try JSONDecoder().decode(Created.self, from: api("POST", "repos/\(slug(repo: repo))/pulls/\(number)/comments/\(to)/replies",
                                                         json: ["body": body], repo: repo)).id
    }

    static func editComment(repo: String, id: UInt64, body: String) throws {
        _ = try api("PATCH", "repos/\(slug(repo: repo))/pulls/comments/\(id)", json: ["body": body], repo: repo)
    }

    static func deleteComment(repo: String, id: UInt64) throws {
        _ = try api("DELETE", "repos/\(slug(repo: repo))/pulls/comments/\(id)", repo: repo)
    }

    /// Submit a review with its comments in one go. Returns each comment's id, in order.
    static func postReview(repo: String, number: Int, sha: String, body: String, event: Event, comments: [(Place, String)]) throws -> [UInt64] {
        let s = try slug(repo: repo)
        var json: [String: Any] = ["commit_id": sha, "event": event.rawValue,
                                   "comments": comments.map { place, text in place.json.merging(["body": text]) { a, _ in a } }]
        if !body.isEmpty { json["body"] = body }
        let review = try JSONDecoder().decode(Created.self, from: api("POST", "repos/\(s)/pulls/\(number)/reviews", json: json, repo: repo))
        guard !comments.isEmpty else { return [] }
        struct Posted: Decodable { let id: UInt64; let path: String; let body: String; let line: Int?; let original_line: Int? }
        var posted = try JSONDecoder().decode([Posted].self, from: gh(["api", "repos/\(s)/pulls/\(number)/reviews/\(review.id)/comments?per_page=100"], repo: repo))
        // Match each by what it says and where (GitHub's order isn't promised).
        return comments.map { place, text in
            let k = posted.firstIndex { $0.path == place.path && $0.body == text && ($0.line ?? $0.original_line) == place.line }
                ?? posted.firstIndex { $0.path == place.path && $0.body == text }
            return k.map { posted.remove(at: $0).id } ?? 0
        }
    }

    static func setThreadResolved(repo: String, threadId: String, resolved: Bool) throws {
        let name = resolved ? "resolveReviewThread" : "unresolveReviewThread"
        _ = try gh(["api", "graphql", "-f", "query=mutation($id: ID!) { \(name)(input: {threadId: $id}) { thread { id } } }", "-f", "id=\(threadId)"], repo: repo)
    }

    /// Every review thread on the PR, placed in the files they point into.
    /// `base`: the diff's base commit (what deleted-line comments point into).
    /// `complete`: false if a thread had more comments than one page.
    static func reviewThreads(repo: String, number: Int, base: String) throws -> (threads: [GhThread], complete: Bool) {
        struct Page: Decodable {
            struct D: Decodable { let repository: R }
            struct R: Decodable { let pullRequest: P }
            struct P: Decodable { let headRefOid: String; let reviewThreads: Threads }
            struct Threads: Decodable { let pageInfo: Info; let nodes: [T] }
            struct Info: Decodable { let hasNextPage: Bool; let endCursor: String? }
            struct T: Decodable {
                let id: String, isResolved: Bool, path: String, line: Int?, originalLine: Int?, diffSide: String
                let comments: Comments
            }
            struct Oid: Decodable { let oid: String }
            struct Comments: Decodable { let totalCount: Int; let nodes: [C] }
            struct C: Decodable { let databaseId: UInt64?; let author: Person?; let body: String; let createdAt: Date; let originalCommit: Oid? }
            let data: D
        }
        let query = """
        query($owner: String!, $name: String!, $number: Int!, $after: String) {
          repository(owner: $owner, name: $name) { pullRequest(number: $number) {
            headRefOid
            reviewThreads(first: 50, after: $after) {
              pageInfo { hasNextPage endCursor }
              nodes { id isResolved path line originalLine diffSide
                comments(first: 100) { totalCount nodes { databaseId author { login } body createdAt originalCommit { oid } } } }
            }
          } }
        }
        """
        let parts = try slug(repo: repo).split(separator: "/").map(String.init)
        guard parts.count == 2 else { throw Failure(description: "couldn't tell this repo's GitHub owner and name") }
        var out: [GhThread] = [], after: String?, complete = true
        var texts: [String: String] = [:]
        func text(_ rev: String, _ path: String) -> String {
            let key = rev + ":" + path
            if let t = texts[key] { return t }
            let t = fileAt(repoRoot: repo, rev: rev, path: path) ?? ""
            texts[key] = t
            return t
        }
        repeat {
            var args = ["api", "graphql", "-f", "query=\(query)", "-f", "owner=\(parts[0])", "-f", "name=\(parts[1])", "-F", "number=\(number)"]
            if let after { args += ["-f", "after=\(after)"] }
            let pr = try decoder.decode(Page.self, from: gh(args, repo: repo)).data.repository.pullRequest
            for t in pr.reviewThreads.nodes {
                if t.comments.totalCount > t.comments.nodes.count { complete = false }
                let old = t.diffSide == "LEFT"
                // Outdated (its line changed since): place it where it was, in the commit it was made on.
                let (line, rev) = t.line.map { ($0, old ? base : pr.headRefOid) } ?? (t.originalLine ?? 1, t.comments.nodes.first?.originalCommit?.oid ?? pr.headRefOid)
                let comments = t.comments.nodes.compactMap { c in
                    c.databaseId.map { GhComment(id: $0, login: c.author?.login ?? "ghost", body: c.body, createdAt: UInt64(c.createdAt.timeIntervalSince1970)) }
                }
                out.append(GhThread(threadId: t.id, path: t.path, line: UInt32(max(line - 1, 0)), oldSide: old, text: text(rev, t.path),
                                    resolved: t.isResolved, comments: comments))
            }
            after = pr.reviewThreads.pageInfo.hasNextPage ? pr.reviewThreads.pageInfo.endCursor : nil
        } while after != nil
        return (out, complete)
    }
}

/// Keeps a PR's threads here and on GitHub in step: what you write goes up,
/// what others write comes down. Agents' replies stay here.
enum GitHubReviewSync {
    /// Bring the PR's GitHub threads in: what changed here.
    @discardableResult
    static func pull(repo: String, pr: Int, me: String, base: String) throws -> GhSync {
        let (threads, complete) = try GitHub.reviewThreads(repo: repo, number: pr, base: base)
        return try syncGithubThreads(repoRoot: repo, pr: UInt32(pr), me: me, myLogin: GitHub.myLogin(repo: repo) ?? "", threads: threads, complete: complete)
    }
}

extension GhSync {
    var any: Bool { added + replies + changed + removed > 0 }

    /// "2 new threads, 1 reply" (nil: nothing new).
    var summary: String? {
        let n = { (k: UInt32, one: String, many: String) in k == 0 ? nil : "\(k) \(k == 1 ? one : many)" }
        let parts = [n(added, "new thread", "new threads"), n(replies, "new reply", "new replies"),
                     n(changed, "update", "updates"), n(removed, "deleted thread", "deleted threads")].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

extension GitHubReviewSync {

    /// Where `thread` is in the PR as GitHub has it (its pushed head, or the base for deleted lines).
    static func place(_ thread: Thread, repo: String, sha: String, base: String) throws -> GitHub.Place {
        let rev = thread.anchor.oldSide ? base : sha
        let text = fileAt(repoRoot: repo, rev: rev, path: thread.path) ?? ""
        let located = locateThreads(threads: [thread], path: thread.path, text: thread.anchor.oldSide ? "" : text, oldText: thread.anchor.oldSide ? text : "")
        guard let line = located.first?.line else {
            throw GitHub.Failure(description: "That line isn't in the PR on GitHub (push your changes first), so the comment stays in Onramp.")
        }
        return GitHub.Place(path: thread.path, line: Int(line) + 1, oldSide: thread.anchor.oldSide)
    }

    /// A comment you just made (not in a review): publish it now.
    static func publish(_ thread: Thread, repo: String, pr: Int, base: String) throws {
        let sha = try GitHub.headSha(repo: repo, number: pr)
        let id = try GitHub.postComment(repo: repo, number: pr, sha: sha, place: place(thread, repo: repo, sha: sha, base: base), body: thread.entries[0].body)
        _ = try linkGithub(repoRoot: repo, id: thread.id, pr: UInt32(pr), index: 0, commentId: id)
    }

    /// Your reply `index` in a thread that's on GitHub: publish it now. False: the thread isn't on GitHub.
    @discardableResult
    static func publishReply(_ thread: Thread, index: Int, repo: String, pr: Int) throws -> Bool {
        guard thread.github?.pr == UInt32(pr), let root = thread.entries.first?.githubId, index < thread.entries.count else { return false }
        let id = try GitHub.postReply(repo: repo, number: pr, to: root, body: thread.entries[index].body)
        _ = try linkGithub(repoRoot: repo, id: thread.id, pr: UInt32(pr), index: UInt32(index), commentId: id)
        return true
    }

    /// Resolve or reopen it on GitHub too (finding its thread id first, if a sync hasn't yet).
    static func setResolved(_ thread: Thread, resolved: Bool, repo: String, pr: Int, me: String, base: String) throws {
        guard thread.github?.pr == UInt32(pr) else { return }
        var threadId = thread.github?.threadId
        if threadId == nil {
            _ = try pull(repo: repo, pr: pr, me: me, base: base)
            threadId = try loadThreads(repoRoot: repo).first { $0.id == thread.id }?.github?.threadId
        }
        guard let threadId else { return }
        try GitHub.setThreadResolved(repo: repo, threadId: threadId, resolved: resolved)
    }

    /// Your pending comments in this PR's review: new threads go up as review
    /// comments with the summary and verdict, pending replies after it. Local-only
    /// threads (an agent's, CI's) stay here. Returns problems worth mentioning.
    static func submit(repo: String, pr: Int, me: String, base: String, body: String, verdict: Verdict) throws -> [String] {
        let threads = try loadThreads(repoRoot: repo).filter { threadInView(thread: $0, pr: UInt32(pr)) }
        let sha = try GitHub.headSha(repo: repo, number: pr)
        var notes: [String] = []
        // New threads of yours, still pending.
        var fresh: [(Thread, GitHub.Place)] = []
        for t in threads where t.github == nil && t.source == nil {
            guard let first = t.entries.first, first.pending, first.author == me, !first.local else { continue }
            do { fresh.append((t, try place(t, repo: repo, sha: sha, base: base))) } catch { notes.append(message(for: error)) }
        }
        // Your PR: GitHub won't take an approval or a change request from you.
        var event: GitHub.Event = switch verdict { case .comment: .comment; case .approve: .approve; case .requestChanges: .requestChanges }
        if event != .comment, let login = GitHub.myLogin(repo: repo), (try? GitHub.view(repo: repo, number: pr))?.author == login {
            event = .comment
            notes.append("It's your PR, so GitHub has it as a comment, not \(verdict == .approve ? "an approval" : "a change request").")
        }
        if !fresh.isEmpty || !body.isEmpty || event != .comment {
            let ids = try GitHub.postReview(repo: repo, number: pr, sha: sha, body: body, event: event, comments: fresh.map { ($0.1, $0.0.entries[0].body) })
            for ((t, _), id) in zip(fresh, ids) where id != 0 {
                _ = try linkGithub(repoRoot: repo, id: t.id, pr: UInt32(pr), index: 0, commentId: id)
            }
        }
        // Pending replies on threads that are on GitHub.
        for t in try loadThreads(repoRoot: repo) where t.github?.pr == UInt32(pr) {
            for (k, e) in t.entries.enumerated() where e.pending && e.author == me && e.githubId == nil && !e.local && k > 0 {
                do { try publishReply(t, index: k, repo: repo, pr: pr) } catch { notes.append(message(for: error)) }
            }
        }
        return notes
    }
}
