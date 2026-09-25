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

/// What the review compares the working tree against.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ReviewMode {
    /// Everything on this branch: working tree vs where it forked from the
    /// default branch (like a PR). Commits don't make changes disappear.
    Branch,
    /// Only what isn't committed yet: working tree vs HEAD.
    Uncommitted,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ReviewBase {
    pub mode: ReviewMode,
    /// Commit to diff against ("HEAD" in uncommitted mode or when there's no base branch).
    pub rev: String,
    /// The branch compared against, e.g. "origin/main" (None in uncommitted mode).
    pub branch: Option<String>,
    /// Commits on this branch since `rev`.
    pub commits: u32,
}

fn stdout(out: std::process::Output) -> Option<String> {
    let s = String::from_utf8_lossy(&out.stdout).trim().to_string();
    (out.status.success() && !s.is_empty()).then_some(s)
}

fn mode_file(repo_root: &str) -> Result<std::path::PathBuf, CoreError> {
    Ok(crate::comments::store_dir(repo_root)?.join("mode"))
}

/// Saved per repo (in the git dir) so the app, CLI and MCP agree on what
/// "the review" is.
#[uniffi::export]
pub fn set_review_mode(repo_root: String, mode: ReviewMode) -> Result<(), CoreError> {
    let path = mode_file(&repo_root)?;
    let io = |e: std::io::Error| CoreError::Io { message: e.to_string() };
    std::fs::create_dir_all(path.parent().expect("has parent")).map_err(io)?;
    std::fs::write(&path, if mode == ReviewMode::Branch { "branch\n" } else { "uncommitted\n" }).map_err(io)
}

/// The default branch to compare against: origin's HEAD, else main/master.
fn default_branch(repo_root: &str) -> Result<Option<String>, CoreError> {
    let mut candidates = vec![];
    if let Some(r) = stdout(git(repo_root, &["symbolic-ref", "-q", "--short", "refs/remotes/origin/HEAD"])?) {
        candidates.push(r);
    }
    candidates.extend(["origin/main", "origin/master", "main", "master"].map(String::from));
    for c in candidates {
        if git(repo_root, &["rev-parse", "--verify", "-q", &format!("{c}^{{commit}}")])?.status.success() {
            return Ok(Some(c));
        }
    }
    Ok(None)
}

#[uniffi::export]
pub fn review_base(repo_root: String) -> Result<ReviewBase, CoreError> {
    let saved = mode_file(&repo_root).ok().and_then(|p| std::fs::read_to_string(p).ok());
    let mode = if saved.as_deref().map(str::trim) == Some("uncommitted") { ReviewMode::Uncommitted } else { ReviewMode::Branch };
    let head = ReviewBase { mode, rev: "HEAD".into(), branch: None, commits: 0 };
    if mode == ReviewMode::Uncommitted {
        return Ok(head);
    }
    let Some(branch) = default_branch(&repo_root)? else { return Ok(head) };
    let Some(rev) = stdout(git(&repo_root, &["merge-base", "HEAD", &branch])?) else { return Ok(head) };
    let commits = stdout(git(&repo_root, &["rev-list", "--count", &format!("{rev}..HEAD")])?)
        .and_then(|n| n.parse().ok())
        .unwrap_or(0);
    Ok(ReviewBase { mode, rev, branch: Some(branch), commits })
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
    let mut files = Vec::new();
    let mut fields = diff.stdout.split(|b| *b == 0).filter(|e| !e.is_empty());
    while let (Some(code), Some(path)) = (fields.next(), fields.next()) {
        let status = match code.first() {
            Some(b'A') => FileStatus::Added,
            Some(b'D') => FileStatus::Deleted,
            _ => FileStatus::Modified,
        };
        files.push(ChangedFile { path: String::from_utf8_lossy(path).to_string(), status });
    }
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
                results.push(Some(String::from_utf8_lossy(&buf).into_owned()));
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

        set_review_mode(root.clone(), ReviewMode::Uncommitted).unwrap();
        let head = review_base(root.clone()).unwrap();
        assert_eq!(head.rev, "HEAD");
        let only_loose: Vec<_> = changed_files_since(&root, &head.rev).unwrap().into_iter().map(|f| f.path).collect();
        assert_eq!(only_loose, vec!["loose.txt"]);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
