//! Writing to git for your own work: commit and push. (Everything else in
//! the core only reads.) The app asks before calling any of these.

use std::process::Command;

use crate::CoreError;

fn git(repo_root: &str, args: &[&str]) -> Result<std::process::Output, CoreError> {
    Command::new("git").arg("-C").arg(repo_root).args(args).output().map_err(|e| CoreError::Io { message: e.to_string() })
}

fn text(out: &std::process::Output) -> String {
    String::from_utf8_lossy(&out.stdout).trim().to_string()
}

fn failure(out: &std::process::Output) -> CoreError {
    let err = String::from_utf8_lossy(&out.stderr).trim().to_string();
    let msg = if err.is_empty() { text(out) } else { err };
    CoreError::Git { message: msg }
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct BranchStatus {
    /// None when HEAD is detached.
    pub branch: Option<String>,
    /// e.g. "origin/feat/x"; None when the branch was never pushed.
    pub upstream: Option<String>,
    pub ahead: u32,
    pub behind: u32,
    /// Files with uncommitted changes (tracked or not).
    pub changed: u32,
}

#[uniffi::export]
pub fn branch_status(repo_root: String) -> Result<BranchStatus, CoreError> {
    let branch = Some(text(&git(&repo_root, &["branch", "--show-current"])?)).filter(|b| !b.is_empty());
    let up = git(&repo_root, &["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"])?;
    let upstream = up.status.success().then(|| text(&up)).filter(|u| !u.is_empty());
    let (mut ahead, mut behind) = (0, 0);
    if upstream.is_some() {
        let counts = text(&git(&repo_root, &["rev-list", "--left-right", "--count", "@{u}...HEAD"])?);
        let mut it = counts.split_whitespace().map(|n| n.parse::<u32>().unwrap_or(0));
        behind = it.next().unwrap_or(0);
        ahead = it.next().unwrap_or(0);
    }
    let status = git(&repo_root, &["status", "--porcelain=v1", "-z", "--untracked-files=all"])?;
    let changed = status.stdout.split(|b| *b == 0).filter(|e| e.len() > 3).count() as u32;
    Ok(BranchStatus { branch, upstream, ahead, behind, changed })
}

/// Stage everything and commit it (your hooks run). Returns the new commit's short sha.
#[uniffi::export]
pub fn commit_all(repo_root: String, message: String) -> Result<String, CoreError> {
    if message.trim().is_empty() {
        return Err(CoreError::Git { message: "a commit needs a message".into() });
    }
    let add = git(&repo_root, &["add", "-A"])?;
    if !add.status.success() {
        return Err(failure(&add));
    }
    let out = git(&repo_root, &["commit", "-q", "-m", &message])?;
    if !out.status.success() {
        return Err(failure(&out));
    }
    Ok(text(&git(&repo_root, &["rev-parse", "--short", "HEAD"])?))
}

/// Push the current branch to its upstream; with none yet, publish it to
/// `origin` and track it. Never forces.
#[uniffi::export]
pub fn push_branch(repo_root: String) -> Result<String, CoreError> {
    let s = branch_status(repo_root.clone())?;
    let Some(branch) = s.branch else { return Err(CoreError::Git { message: "not on a branch (detached HEAD)".into() }) };
    let out = if s.upstream.is_some() { git(&repo_root, &["push", "--quiet"])? } else { git(&repo_root, &["push", "--quiet", "-u", "origin", &branch])? };
    if !out.status.success() {
        return Err(failure(&out));
    }
    Ok(branch)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn commit_and_push_to_a_remote() {
        let base = std::env::temp_dir().join(format!("pp-gitact-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&base);
        let (origin, me) = (base.join("origin.git"), base.join("me"));
        std::fs::create_dir_all(&base).unwrap();
        let run = |dir: &std::path::Path, args: &[&str]| {
            let o = Command::new("git").args(["-c", "user.name=t", "-c", "user.email=t@t"]).args(args).current_dir(dir).output().unwrap();
            assert!(o.status.success(), "{args:?}: {}", String::from_utf8_lossy(&o.stderr));
        };
        run(&base, &["init", "-q", "--bare", "-b", "main", origin.to_str().unwrap()]);
        run(&base, &["clone", "-q", origin.to_str().unwrap(), me.to_str().unwrap()]);
        run(&me, &["config", "user.name", "t"]);
        run(&me, &["config", "user.email", "t@t"]);
        std::fs::write(me.join("a.txt"), "one\n").unwrap();
        run(&me, &["add", "-A"]);
        run(&me, &["commit", "-qm", "base"]);
        run(&me, &["push", "-q", "-u", "origin", "main"]);
        run(&me, &["checkout", "-qb", "feat"]);
        let root = me.display().to_string();

        std::fs::write(me.join("a.txt"), "two\n").unwrap();
        std::fs::write(me.join("b.txt"), "new\n").unwrap();
        let s = branch_status(root.clone()).unwrap();
        assert_eq!((s.branch.as_deref(), s.upstream.as_deref(), s.changed), (Some("feat"), None, 2));
        assert!(commit_all(root.clone(), "  ".into()).is_err());
        commit_all(root.clone(), "my change".into()).unwrap();
        assert_eq!(branch_status(root.clone()).unwrap().changed, 0);

        assert_eq!(push_branch(root.clone()).unwrap(), "feat"); // publishes: no upstream yet
        let s = branch_status(root.clone()).unwrap();
        assert_eq!((s.upstream.as_deref(), s.ahead), (Some("origin/feat"), 0));
        std::fs::write(me.join("c.txt"), "more\n").unwrap();
        commit_all(root.clone(), "more".into()).unwrap();
        assert_eq!(branch_status(root.clone()).unwrap().ahead, 1);
        push_branch(root.clone()).unwrap();
        assert_eq!(branch_status(root.clone()).unwrap().ahead, 0);
        let _ = std::fs::remove_dir_all(&base);
    }
}
