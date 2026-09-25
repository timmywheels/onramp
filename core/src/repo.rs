use std::process::Command;

use crate::CoreError;

#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum FileStatus {
    Modified,
    Added,
    Deleted,
    Untracked,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ChangedFile {
    /// Path relative to the repo root.
    pub path: String,
    pub status: FileStatus,
}

fn git(repo_root: &str, args: &[&str]) -> Result<std::process::Output, CoreError> {
    Command::new("git")
        .arg("-C")
        .arg(repo_root)
        .args(args)
        .output()
        .map_err(|e| CoreError::Io { message: e.to_string() })
}

/// What the review shows.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Enum)]
#[serde(rename_all = "snake_case")]
pub enum ReviewMode {
    /// Everything on this branch: working tree vs where it forked from the
    /// base branch (like a PR). Commits don't make changes disappear.
    Branch,
    /// Only what isn't committed yet: working tree vs HEAD.
    Uncommitted,
    /// One commit: its parent vs the commit (read-only; not on disk).
    Commit,
}

/// The saved choice: which mode, against which branch, or which commit.
/// Stored per repo in the git dir, so the app, CLI and MCP agree on what
/// "the review" is.
#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct ReviewChoice {
    pub mode: ReviewMode,
    /// Branch mode: compare against this instead of the default branch.
    #[serde(default)]
    pub base_branch: Option<String>,
    /// Commit mode: the commit to show.
    #[serde(default)]
    pub commit: Option<String>,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ReviewBase {
    pub mode: ReviewMode,
    /// Old side: commit to diff against ("HEAD" in uncommitted mode or when there's no base branch).
    pub rev: String,
    /// New side: a commit, or None for the working tree (editable).
    pub target: Option<String>,
    /// The branch compared against, e.g. "origin/main" (branch mode).
    pub branch: Option<String>,
    /// Commits on this branch since `rev` (branch mode).
    pub commits: u32,
    /// Commit mode: "a1b2c3d Fix the thing".
    pub title: Option<String>,
}

fn stdout(out: std::process::Output) -> Option<String> {
    let s = String::from_utf8_lossy(&out.stdout).trim().to_string();
    (out.status.success() && !s.is_empty()).then_some(s)
}

fn choice_file(repo_root: &str) -> Result<std::path::PathBuf, CoreError> {
    Ok(crate::comments::store_dir(repo_root)?.join("review.json"))
}

#[uniffi::export]
pub fn review_choice(repo_root: String) -> ReviewChoice {
    let dir = crate::comments::store_dir(&repo_root).ok();
    if let Some(c) = dir.as_ref().and_then(|d| std::fs::read(d.join("review.json")).ok()).and_then(|b| serde_json::from_slice(&b).ok()) {
        return c;
    }
    // Before review.json there was a plain "mode" file.
    let legacy = dir.and_then(|d| std::fs::read_to_string(d.join("mode")).ok());
    let mode = if legacy.as_deref().map(str::trim) == Some("uncommitted") { ReviewMode::Uncommitted } else { ReviewMode::Branch };
    ReviewChoice { mode, base_branch: None, commit: None }
}

#[uniffi::export]
pub fn set_review_choice(repo_root: String, choice: ReviewChoice) -> Result<(), CoreError> {
    let path = choice_file(&repo_root)?;
    let io = |e: std::io::Error| CoreError::Io { message: e.to_string() };
    std::fs::create_dir_all(path.parent().expect("has parent")).map_err(io)?;
    std::fs::write(&path, serde_json::to_vec_pretty(&choice).expect("serializable")).map_err(io)
}

/// Switch mode, keeping the rest of the saved choice.
#[uniffi::export]
pub fn set_review_mode(repo_root: String, mode: ReviewMode) -> Result<(), CoreError> {
    let mut c = review_choice(repo_root.clone());
    c.mode = mode;
    set_review_choice(repo_root, c)
}

fn is_commit(repo_root: &str, rev: &str) -> Result<bool, CoreError> {
    Ok(git(repo_root, &["rev-parse", "--verify", "-q", &format!("{rev}^{{commit}}")])?.status.success())
}

/// The default branch to compare against: origin's HEAD, else main/master.
fn default_branch(repo_root: &str) -> Result<Option<String>, CoreError> {
    let mut candidates = vec![];
    if let Some(r) = stdout(git(repo_root, &["symbolic-ref", "-q", "--short", "refs/remotes/origin/HEAD"])?) {
        candidates.push(r);
    }
    candidates.extend(["origin/main", "origin/master", "main", "master"].map(String::from));
    for c in candidates {
        if is_commit(repo_root, &c)? {
            return Ok(Some(c));
        }
    }
    Ok(None)
}

/// Git's empty tree: the "parent" of a root commit.
const EMPTY_TREE: &str = "4b825dc642cb6eb9a060e54bf8d69288fbee4904";

#[uniffi::export]
pub fn review_base(repo_root: String) -> Result<ReviewBase, CoreError> {
    let choice = review_choice(repo_root.clone());
    let head = |mode| ReviewBase { mode, rev: "HEAD".into(), target: None, branch: None, commits: 0, title: None };
    match choice.mode {
        ReviewMode::Uncommitted => Ok(head(ReviewMode::Uncommitted)),
        ReviewMode::Commit => {
            let Some(sha) = choice.commit.as_deref().and_then(|c| stdout(git(&repo_root, &["rev-parse", "--verify", "-q", &format!("{c}^{{commit}}")]).ok()?))
            else {
                return Ok(head(ReviewMode::Uncommitted));
            };
            let parent = stdout(git(&repo_root, &["rev-parse", "--verify", "-q", &format!("{sha}^")])?).unwrap_or_else(|| EMPTY_TREE.into());
            let title = stdout(git(&repo_root, &["log", "-1", "--format=%h %s", &sha])?);
            Ok(ReviewBase { mode: ReviewMode::Commit, rev: parent, target: Some(sha), branch: None, commits: 0, title })
        }
        ReviewMode::Branch => {
            let chosen = match choice.base_branch {
                Some(b) if is_commit(&repo_root, &b)? => Some(b),
                _ => default_branch(&repo_root)?,
            };
            let Some(branch) = chosen else { return Ok(head(ReviewMode::Branch)) };
            let Some(rev) = stdout(git(&repo_root, &["merge-base", "HEAD", &branch])?) else { return Ok(head(ReviewMode::Branch)) };
            let commits = stdout(git(&repo_root, &["rev-list", "--count", &format!("{rev}..HEAD")])?)
                .and_then(|n| n.parse().ok())
                .unwrap_or(0);
            Ok(ReviewBase { mode: ReviewMode::Branch, rev, target: None, branch: Some(branch), commits, title: None })
        }
    }
}

// MARK: Pickers

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct Worktree {
    pub path: String,
    /// Checked-out branch ("feat/x"), or None when detached.
    pub branch: Option<String>,
    pub is_current: bool,
}

/// This repo's worktrees (the main checkout first).
#[uniffi::export]
pub fn list_worktrees(repo_root: String) -> Result<Vec<Worktree>, CoreError> {
    let out = git(&repo_root, &["worktree", "list", "--porcelain"])?;
    let here = std::fs::canonicalize(&repo_root).unwrap_or_else(|_| repo_root.clone().into());
    let mut trees = Vec::new();
    for block in String::from_utf8_lossy(&out.stdout).split("\n\n") {
        let mut path = None;
        let mut branch = None;
        for line in block.lines() {
            if let Some(p) = line.strip_prefix("worktree ") { path = Some(p.to_string()) }
            if let Some(b) = line.strip_prefix("branch ") { branch = Some(b.trim_start_matches("refs/heads/").to_string()) }
        }
        if let Some(path) = path {
            let is_current = std::fs::canonicalize(&path).map(|p| p == here).unwrap_or(false);
            trees.push(Worktree { path, branch, is_current });
        }
    }
    Ok(trees)
}

/// Branches to compare against, most recently committed first (remote
/// branches included, `origin/HEAD` left out).
#[uniffi::export]
pub fn list_branches(repo_root: String) -> Result<Vec<String>, CoreError> {
    let out = git(&repo_root, &["for-each-ref", "--sort=-committerdate", "--count=300", "--format=%(refname:short)", "refs/heads", "refs/remotes"])?;
    Ok(String::from_utf8_lossy(&out.stdout)
        .lines()
        .filter(|b| !b.is_empty() && !b.ends_with("/HEAD") && *b != "origin")
        .map(String::from)
        .collect())
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct CommitInfo {
    pub sha: String,
    pub short: String,
    pub summary: String,
    pub author: String,
    pub time: u64,
}

/// Commits after `since` up to HEAD, newest first ("HEAD" or empty: the last `limit` commits).
#[uniffi::export]
pub fn list_commits(repo_root: String, since: String, limit: u32) -> Result<Vec<CommitInfo>, CoreError> {
    let range = if since.is_empty() || since == "HEAD" { "HEAD".to_string() } else { format!("{since}..HEAD") };
    let out = git(&repo_root, &["log", &format!("-{limit}"), "--format=%H%x1f%h%x1f%s%x1f%an%x1f%ct", &range])?;
    Ok(String::from_utf8_lossy(&out.stdout)
        .lines()
        .filter_map(|l| {
            let f: Vec<&str> = l.split('\u{1f}').collect();
            (f.len() == 5).then(|| CommitInfo {
                sha: f[0].into(),
                short: f[1].into(),
                summary: f[2].into(),
                author: f[3].into(),
                time: f[4].parse().unwrap_or(0),
            })
        })
        .collect())
}

/// The commits a review picker offers: this branch's commits since it forked
/// from the base branch (whatever mode is showing), or the last `limit`
/// commits when there are none (e.g. on main). Returns (commits, on_branch).
#[uniffi::export]
pub fn review_commits(repo_root: String, limit: u32) -> Result<BranchCommits, CoreError> {
    let choice = review_choice(repo_root.clone());
    let base = match choice.base_branch {
        Some(b) if is_commit(&repo_root, &b)? => Some(b),
        _ => default_branch(&repo_root)?,
    };
    if let Some(fork) = base.and_then(|b| stdout(git(&repo_root, &["merge-base", "HEAD", &b]).ok()?)) {
        let commits = list_commits(repo_root.clone(), fork, limit)?;
        if !commits.is_empty() {
            return Ok(BranchCommits { commits, on_branch: true });
        }
    }
    Ok(BranchCommits { commits: list_commits(repo_root, String::new(), limit)?, on_branch: false })
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct BranchCommits {
    pub commits: Vec<CommitInfo>,
    /// True: commits on this branch. False: just recent history.
    pub on_branch: bool,
}

/// Files changed between two commits, in path order.
pub fn changed_files_between(repo_root: &str, old: &str, new: &str) -> Result<Vec<ChangedFile>, CoreError> {
    let diff = git(repo_root, &["diff", "--name-status", "-z", "--no-renames", old, new])?;
    if !diff.status.success() {
        return Err(CoreError::Git { message: String::from_utf8_lossy(&diff.stderr).trim().to_string() });
    }
    let mut files = parse_name_status(&diff.stdout);
    files.sort_by(|a, b| a.path.cmp(&b.path));
    Ok(files)
}

fn parse_name_status(out: &[u8]) -> Vec<ChangedFile> {
    let mut files = Vec::new();
    let mut fields = out.split(|b| *b == 0).filter(|e| !e.is_empty());
    while let (Some(code), Some(path)) = (fields.next(), fields.next()) {
        let status = match code.first() {
            Some(b'A') => FileStatus::Added,
            Some(b'D') => FileStatus::Deleted,
            _ => FileStatus::Modified,
        };
        files.push(ChangedFile { path: String::from_utf8_lossy(path).to_string(), status });
    }
    files
}

/// Working tree vs `rev`, including untracked files, in path order.
pub fn changed_files_since(repo_root: &str, rev: &str) -> Result<Vec<ChangedFile>, CoreError> {
    if rev == "HEAD" {
        return changed_files(repo_root.to_string());
    }
    let fail = |out: &std::process::Output| CoreError::Git { message: String::from_utf8_lossy(&out.stderr).trim().to_string() };
    let diff = git(repo_root, &["diff", "--name-status", "-z", "--no-renames", rev])?;
    if !diff.status.success() {
        return Err(fail(&diff));
    }
    let untracked = git(repo_root, &["ls-files", "-z", "--others", "--exclude-standard"])?;
    if !untracked.status.success() {
        return Err(fail(&untracked));
    }
    let mut files = parse_name_status(&diff.stdout);
    for path in untracked.stdout.split(|b| *b == 0).filter(|e| !e.is_empty()) {
        files.push(ChangedFile { path: String::from_utf8_lossy(path).to_string(), status: FileStatus::Untracked });
    }
    files.sort_by(|a, b| a.path.cmp(&b.path));
    Ok(files)
}

/// Working tree vs HEAD, including untracked files, in path order.
#[uniffi::export]
pub fn changed_files(repo_root: String) -> Result<Vec<ChangedFile>, CoreError> {
    let out = git(&repo_root, &["status", "--porcelain=v1", "-z", "--untracked-files=all"])?;
    if !out.status.success() {
        return Err(CoreError::Git { message: String::from_utf8_lossy(&out.stderr).trim().to_string() });
    }

    let mut files = Vec::new();
    let mut entries = out.stdout.split(|b| *b == 0).filter(|e| !e.is_empty());
    while let Some(entry) = entries.next() {
        if entry.len() < 4 {
            continue;
        }
        let (x, y) = (entry[0], entry[1]);
        let path = String::from_utf8_lossy(&entry[3..]).to_string();
        // Renames/copies carry the original path as the next entry.
        if x == b'R' || x == b'C' {
            entries.next();
        }
        let status = match (x, y) {
            (b'?', b'?') => FileStatus::Untracked,
            (b'D', _) | (_, b'D') => FileStatus::Deleted,
            (b'A', _) => FileStatus::Added,
            _ => FileStatus::Modified,
        };
        files.push(ChangedFile { path, status });
    }
    files.sort_by(|a, b| a.path.cmp(&b.path));
    Ok(files)
}

/// The file's content at HEAD, or `None` if it doesn't exist there.
#[uniffi::export]
pub fn head_text(repo_root: String, path: String) -> Result<Option<String>, CoreError> {
    let out = git(&repo_root, &["show", &format!("HEAD:{path}")])?;
    if !out.status.success() {
        return Ok(None);
    }
    Ok(Some(String::from_utf8_lossy(&out.stdout).to_string()))
}

/// HEAD content for many paths with a single `git cat-file --batch` process.
/// Spawning git per file costs ~15ms each, which dominated load time.
#[uniffi::export]
pub fn head_texts(repo_root: String, paths: Vec<String>) -> Result<Vec<Option<String>>, CoreError> {
    texts_at(&repo_root, "HEAD", &paths)
}

/// Content of each path at commit `rev` (None where it doesn't exist).
pub fn texts_at(repo_root: &str, rev: &str, paths: &[String]) -> Result<Vec<Option<String>>, CoreError> {
    Ok(blobs_at(repo_root, rev, paths)?.into_iter().map(|b| b.map(|b| String::from_utf8_lossy(&b).into_owned())).collect())
}

/// Raw content of each path at commit `rev` (None where it doesn't exist).
pub fn blobs_at(repo_root: &str, rev: &str, paths: &[String]) -> Result<Vec<Option<Vec<u8>>>, CoreError> {
    use std::io::{BufRead, BufReader, Read, Write};
    use std::process::Stdio;

    let io = |e: std::io::Error| CoreError::Io { message: e.to_string() };
    let mut child = Command::new("git")
        .arg("-C")
        .arg(repo_root)
        .args(["cat-file", "--batch"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .map_err(io)?;

    // Feed requests from another thread so a full stdout pipe can't deadlock us.
    let mut stdin = child.stdin.take().expect("piped stdin");
    let requests: String = paths.iter().map(|p| format!("{rev}:{p}\n")).collect();
    let writer = std::thread::spawn(move || stdin.write_all(requests.as_bytes()));

    let mut out = BufReader::new(child.stdout.take().expect("piped stdout"));
    let mut results = Vec::with_capacity(paths.len());
    let mut header = String::new();
    for _ in paths {
        header.clear();
        out.read_line(&mut header).map_err(io)?;
        // "<sha> blob <size>" or "<object> missing"
        let size = match header.trim_end().rsplit_once(' ') {
            Some((head, size)) if head.ends_with(" blob") => size.parse::<usize>().ok(),
            _ => None,
        };
        match size {
            Some(size) => {
                let mut buf = vec![0; size + 1]; // content + trailing newline
                out.read_exact(&mut buf).map_err(io)?;
                buf.truncate(size);
                results.push(Some(buf));
            }
            None => results.push(None),
        }
    }

    writer.join().ok();
    child.wait().map_err(io)?;
    Ok(results)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn batch_matches_single() {
        let dir = std::env::temp_dir().join(format!("pp-batch-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let git = |args: &[&str]| Command::new("git").args(args).current_dir(&dir).output().unwrap();
        git(&["init", "-q"]);
        std::fs::write(dir.join("a.txt"), "hello\n").unwrap();
        git(&["add", "-A"]);
        git(&["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "init"]);
        let root = dir.to_string_lossy().to_string();

        let paths = vec!["a.txt".to_string(), "does/not/exist".to_string()];
        let batch = head_texts(root.clone(), paths.clone()).unwrap();
        assert_eq!(batch[0].as_deref(), Some("hello\n"));
        assert_eq!(batch[0], head_text(root.clone(), paths[0].clone()).unwrap());
        assert_eq!(batch[1], None);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn branch_mode_keeps_committed_changes() {
        let dir = std::env::temp_dir().join(format!("pp-branch-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let git = |args: &[&str]| Command::new("git").args(args).current_dir(&dir).output().unwrap();
        let commit = |msg: &str| git(&["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qam", msg]);
        git(&["init", "-q", "-b", "main"]);
        std::fs::write(dir.join("a.txt"), "one\n").unwrap();
        std::fs::write(dir.join("gone.txt"), "bye\n").unwrap();
        git(&["add", "-A"]);
        commit("base");
        git(&["checkout", "-qb", "feature"]);
        std::fs::write(dir.join("a.txt"), "two\n").unwrap();
        std::fs::remove_file(dir.join("gone.txt")).unwrap();
        std::fs::write(dir.join("new.txt"), "new\n").unwrap();
        git(&["add", "-A"]);
        commit("work"); // everything committed: uncommitted mode shows nothing
        std::fs::write(dir.join("loose.txt"), "wip\n").unwrap();
        let root = dir.to_string_lossy().to_string();

        let base = review_base(root.clone()).unwrap();
        assert_eq!((base.mode, base.branch.as_deref(), base.commits), (ReviewMode::Branch, Some("main"), 1));
        let files = changed_files_since(&root, &base.rev).unwrap();
        let got: Vec<_> = files.iter().map(|f| (f.path.as_str(), f.status.clone())).collect();
        assert_eq!(got, vec![
            ("a.txt", FileStatus::Modified),
            ("gone.txt", FileStatus::Deleted),
            ("loose.txt", FileStatus::Untracked),
            ("new.txt", FileStatus::Added),
        ]);
        assert_eq!(texts_at(&root, &base.rev, &["a.txt".into()]).unwrap()[0].as_deref(), Some("one\n"));

        let commits = list_commits(root.clone(), base.rev.clone(), 50).unwrap();
        assert_eq!(commits.iter().map(|c| c.summary.as_str()).collect::<Vec<_>>(), vec!["work"]);
        assert_eq!(list_branches(root.clone()).unwrap(), vec!["feature", "main"]);
        let trees = list_worktrees(root.clone()).unwrap();
        assert_eq!((trees.len(), trees[0].branch.as_deref(), trees[0].is_current), (1, Some("feature"), true));

        // One commit: parent → commit, from git, not the working tree.
        set_review_choice(root.clone(), ReviewChoice { mode: ReviewMode::Commit, base_branch: None, commit: Some(commits[0].short.clone()) }).unwrap();
        let one = review_base(root.clone()).unwrap();
        assert_eq!((one.mode, one.target.as_deref(), one.title.as_deref().map(|t| t.ends_with(" work"))), (ReviewMode::Commit, Some(commits[0].sha.as_str()), Some(true)));
        let diffs = crate::review::load_review(root.clone(), one.rev.clone(), one.target.clone()).unwrap();
        assert_eq!(diffs.iter().map(|d| d.path.as_str()).collect::<Vec<_>>(), vec!["a.txt", "gone.txt", "new.txt"]); // no loose.txt

        // A chosen base branch that doesn't exist falls back to the default.
        set_review_choice(root.clone(), ReviewChoice { mode: ReviewMode::Branch, base_branch: Some("nope".into()), commit: None }).unwrap();
        assert_eq!(review_base(root.clone()).unwrap().branch.as_deref(), Some("main"));

        set_review_mode(root.clone(), ReviewMode::Uncommitted).unwrap();
        let head = review_base(root.clone()).unwrap();
        assert_eq!(head.rev, "HEAD");
        let only_loose: Vec<_> = changed_files_since(&root, &head.rev).unwrap().into_iter().map(|f| f.path).collect();
        assert_eq!(only_loose, vec!["loose.txt"]);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
