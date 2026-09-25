//! Review comments: threads anchored to lines, stored in
//! `<git-dir>/pairprogram/comments.json` so they never get committed.
//!
//! The app and the `pairprogram` CLI (what agents use) share this code, so a
//! comment written in either shows up in both. Writes are load-modify-save
//! under a lock file, so the app and an agent can't clobber each other.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

use crate::CoreError;

/// Where a comment points: the line's text plus neighbors, so it can be found
/// again after the file changes. `line` is only a hint.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, uniffi::Record)]
pub struct Anchor {
    pub line: u32, // 0-based, in the file as it was when commented
    /// On a deleted (red) line: `line`/`text` refer to the HEAD version.
    #[serde(default)]
    pub old_side: bool,
    pub text: String,
    pub before: Vec<String>,
    pub after: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, uniffi::Record)]
pub struct Entry {
    pub author: String,
    pub body: String,
    pub created_at: u64, // unix seconds
    /// Part of a review that hasn't been submitted yet: only its author sees it.
    #[serde(default)]
    pub pending: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "snake_case")]
pub enum Verdict {
    Comment,
    Approve,
    RequestChanges,
}

/// A submitted review: a summary + verdict, publishing a batch of comments at once.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, uniffi::Record)]
pub struct Review {
    pub id: String,
    pub author: String,
    pub body: String,
    pub verdict: Verdict,
    pub thread_ids: Vec<String>,
    pub submitted_at: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "lowercase")]
pub enum ThreadStatus {
    Open,
    Resolved,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, uniffi::Record)]
pub struct Thread {
    pub id: String,
    pub path: String,
    pub anchor: Anchor,
    pub status: ThreadStatus,
    pub entries: Vec<Entry>,
    pub resolved_by: Option<String>,
}

/// A thread plus where its line is now (None = the line is gone: "outdated").
#[derive(Debug, Clone, PartialEq, Serialize, uniffi::Record)]
pub struct LocatedThread {
    pub thread: Thread,
    pub line: Option<u32>,
}

#[derive(Default, Serialize, Deserialize)]
struct Store {
    version: u32,
    threads: Vec<Thread>,
    #[serde(default)]
    reviews: Vec<Review>,
}

fn io(e: std::io::Error) -> CoreError {
    CoreError::Io { message: e.to_string() }
}

fn now() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

pub(crate) fn store_dir(repo_root: &str) -> Result<PathBuf, CoreError> {
    let out = Command::new("git")
        .args(["-C", repo_root, "rev-parse", "--absolute-git-dir"])
        .output()
        .map_err(io)?;
    if !out.status.success() {
        return Err(CoreError::Git { message: String::from_utf8_lossy(&out.stderr).trim().to_string() });
    }
    Ok(PathBuf::from(String::from_utf8_lossy(&out.stdout).trim()).join("pairprogram"))
}

/// Path of the comments file (the app watches it for changes made by agents).
#[uniffi::export]
pub fn comments_path(repo_root: String) -> Result<String, CoreError> {
    Ok(store_dir(&repo_root)?.join("comments.json").to_string_lossy().into_owned())
}

fn load(dir: &Path) -> Result<Store, CoreError> {
    match fs::read(dir.join("comments.json")) {
        Ok(bytes) => serde_json::from_slice(&bytes).map_err(|e| CoreError::Io { message: format!("comments.json: {e}") }),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Store { version: 1, threads: vec![], reviews: vec![] }),
        Err(e) => Err(io(e)),
    }
}

/// Load, change, save — holding a lock so concurrent writers serialize.
fn modify<T>(repo_root: &str, change: impl FnOnce(&mut Store) -> Result<T, CoreError>) -> Result<T, CoreError> {
    let dir = store_dir(repo_root)?;
    fs::create_dir_all(&dir).map_err(io)?;
    let lock = dir.join("comments.lock");
    let start = Instant::now();
    loop {
        match fs::OpenOptions::new().write(true).create_new(true).open(&lock) {
            Ok(_) => break,
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {
                if start.elapsed() > Duration::from_secs(2) {
                    let _ = fs::remove_file(&lock); // stale lock from a crashed writer
                }
                std::thread::sleep(Duration::from_millis(5));
            }
            Err(e) => return Err(io(e)),
        }
    }
    let result = (|| {
        let mut store = load(&dir)?;
        store.version = 1;
        let value = change(&mut store)?;
        let tmp = dir.join("comments.json.tmp");
        fs::write(&tmp, serde_json::to_vec_pretty(&store).expect("serializable")).map_err(io)?;
        fs::rename(&tmp, dir.join("comments.json")).map_err(io)?;
        Ok(value)
    })();
    let _ = fs::remove_file(&lock);
    result
}

fn new_id(existing: &[Thread]) -> String {
    let mut seed = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0) as u64 ^ (std::process::id() as u64) << 32;
    loop {
        seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        let id = format!("{:06x}", (seed >> 40) & 0xffffff);
        if !existing.iter().any(|t| t.id == id) {
            return id;
        }
    }
}

fn not_found(id: &str) -> CoreError {
    CoreError::Io { message: format!("no comment with id {id}") }
}

// MARK: API

#[uniffi::export]
pub fn load_threads(repo_root: String) -> Result<Vec<Thread>, CoreError> {
    Ok(load(&store_dir(&repo_root)?)?.threads)
}

/// Start a thread on `line` (0-based) of `text`, the file's current content.
#[uniffi::export]
/// For a deleted line, pass the HEAD version as `text` and `old_side: true`.
/// `pending`: part of a review in progress (published by `submit_review`).
pub fn add_thread(repo_root: String, path: String, text: String, line: u32, old_side: bool, author: String, body: String, pending: bool) -> Result<Thread, CoreError> {
    let lines: Vec<&str> = split_lines(&text);
    let i = line as usize;
    let get = |r: std::ops::Range<usize>| r.filter_map(|k| lines.get(k).map(|s| s.to_string())).collect::<Vec<_>>();
    let anchor = Anchor {
        line,
        old_side,
        text: lines.get(i).unwrap_or(&"").to_string(),
        before: get(i.saturating_sub(2)..i),
        after: get(i + 1..i + 3),
    };
    modify(&repo_root, |store| {
        let thread = Thread {
            id: new_id(&store.threads),
            path,
            anchor,
            status: ThreadStatus::Open,
            entries: vec![Entry { author, body, created_at: now(), pending }],
            resolved_by: None,
        };
        store.threads.push(thread.clone());
        Ok(thread)
    })
}

#[uniffi::export]
pub fn reply(repo_root: String, id: String, author: String, body: String, pending: bool) -> Result<Thread, CoreError> {
    modify(&repo_root, |store| {
        let t = store.threads.iter_mut().find(|t| t.id == id).ok_or_else(|| not_found(&id))?;
        t.entries.push(Entry { author, body, created_at: now(), pending });
        Ok(t.clone())
    })
}

/// Resolve (or reopen) a thread, optionally adding a note first.
#[uniffi::export]
pub fn set_resolved(repo_root: String, id: String, resolved: bool, author: String, note: Option<String>) -> Result<Thread, CoreError> {
    modify(&repo_root, |store| {
        let t = store.threads.iter_mut().find(|t| t.id == id).ok_or_else(|| not_found(&id))?;
        if let Some(body) = note.filter(|n| !n.trim().is_empty()) {
            t.entries.push(Entry { author: author.clone(), body, created_at: now(), pending: false });
        }
        t.status = if resolved { ThreadStatus::Resolved } else { ThreadStatus::Open };
        t.resolved_by = resolved.then_some(author);
        Ok(t.clone())
    })
}

#[uniffi::export]
pub fn delete_thread(repo_root: String, id: String) -> Result<(), CoreError> {
    modify(&repo_root, |store| {
        let before = store.threads.len();
        store.threads.retain(|t| t.id != id);
        if store.threads.len() == before { Err(not_found(&id)) } else { Ok(()) }
    })
}

/// Edit entry `index` of a thread (e.g. fix a typo in your own comment).
#[uniffi::export]
pub fn edit_entry(repo_root: String, id: String, index: u32, body: String) -> Result<Thread, CoreError> {
    modify(&repo_root, |store| {
        let t = store.threads.iter_mut().find(|t| t.id == id).ok_or_else(|| not_found(&id))?;
        let e = t.entries.get_mut(index as usize).ok_or_else(|| not_found(&id))?;
        e.body = body;
        Ok(t.clone())
    })
}

// MARK: Reviews

/// Comments and replies `author` has pending (not yet submitted).
#[uniffi::export]
pub fn pending_count(repo_root: String, author: String) -> Result<u32, CoreError> {
    let store = load(&store_dir(&repo_root)?)?;
    Ok(store.threads.iter().flat_map(|t| &t.entries).filter(|e| e.pending && e.author == author).count() as u32)
}

/// Publish everything `author` has pending, as one review with a summary and verdict.
#[uniffi::export]
pub fn submit_review(repo_root: String, author: String, body: String, verdict: Verdict) -> Result<Review, CoreError> {
    modify(&repo_root, |store| {
        let mut thread_ids = Vec::new();
        for t in store.threads.iter_mut() {
            let mut touched = false;
            for e in t.entries.iter_mut().filter(|e| e.pending && e.author == author) {
                e.pending = false;
                touched = true;
            }
            if touched { thread_ids.push(t.id.clone()); }
        }
        if thread_ids.is_empty() && body.trim().is_empty() && verdict == Verdict::Comment {
            return Err(CoreError::Io { message: "nothing to submit: add comments or a summary".into() });
        }
        let review = Review { id: new_id(&store.threads), author, body, verdict, thread_ids, submitted_at: now() };
        store.reviews.push(review.clone());
        Ok(review)
    })
}

/// Throw away `author`'s pending comments and replies.
#[uniffi::export]
pub fn discard_pending(repo_root: String, author: String) -> Result<(), CoreError> {
    modify(&repo_root, |store| {
        for t in store.threads.iter_mut() {
            t.entries.retain(|e| !(e.pending && e.author == author));
        }
        store.threads.retain(|t| !t.entries.is_empty());
        Ok(())
    })
}

#[uniffi::export]
pub fn load_reviews(repo_root: String) -> Result<Vec<Review>, CoreError> {
    Ok(load(&store_dir(&repo_root)?)?.reviews)
}

/// What agents see: no pending (unsubmitted) entries, and no threads that are only pending.
fn submitted_only(threads: Vec<Thread>) -> Vec<Thread> {
    threads
        .into_iter()
        .filter_map(|mut t| {
            t.entries.retain(|e| !e.pending);
            (!t.entries.is_empty()).then_some(t)
        })
        .collect()
}

// MARK: Anchoring

fn split_lines(text: &str) -> Vec<&str> {
    let mut v: Vec<&str> = text.split('\n').map(|l| l.strip_suffix('\r').unwrap_or(l)).collect();
    if text.ends_with('\n') {
        v.pop();
    }
    v
}

/// Where `anchor` is in `lines` now: an exact line-text match, preferring the
/// one whose neighbors still match and that's closest to where it was.
fn locate(anchor: &Anchor, lines: &[&str]) -> Option<u32> {
    let i = anchor.line as usize;
    if lines.get(i) == Some(&anchor.text.as_str()) {
        return Some(anchor.line);
    }
    let context = |k: usize| -> i64 {
        let before = anchor.before.iter().rev().enumerate().filter(|(d, s)| k > *d && lines.get(k - d - 1) == Some(&s.as_str())).count();
        let after = anchor.after.iter().enumerate().filter(|(d, s)| lines.get(k + d + 1) == Some(&s.as_str())).count();
        (before + after) as i64
    };
    let blank = anchor.text.trim().is_empty();
    lines
        .iter()
        .enumerate()
        .filter(|(_, l)| **l == anchor.text)
        .map(|(k, _)| (k, context(k)))
        .filter(|(_, c)| !blank || *c > 0) // a blank line needs matching neighbors
        .max_by_key(|(k, c)| (c * 100_000) - (*k as i64 - i as i64).abs())
        .map(|(k, _)| k as u32)
}

/// Threads for `path`, located in its current `text` (or `old_text`, the
/// review-base version, for comments on deleted lines).
#[uniffi::export]
pub fn locate_threads(threads: Vec<Thread>, path: String, text: String, old_text: String) -> Vec<LocatedThread> {
    let lines = split_lines(&text);
    let old_lines = split_lines(&old_text);
    threads
        .into_iter()
        .filter(|t| t.path == path)
        .map(|t| {
            let line = locate(&t.anchor, if t.anchor.old_side { &old_lines } else { &lines });
            LocatedThread { thread: t, line }
        })
        .collect()
}

/// The file as it was at the review's base (what deleted-line comments point into).
fn base_version(repo_root: &str, path: &str) -> String {
    let rev = crate::repo::review_base(repo_root.to_string()).map(|b| b.rev).unwrap_or_else(|_| "HEAD".into());
    crate::repo::texts_at(repo_root, &rev, &[path.to_string()]).ok().and_then(|mut v| v.pop().flatten()).unwrap_or_default()
}

// MARK: Export for agents

fn located_all(repo_root: &str, threads: Vec<Thread>) -> Vec<LocatedThread> {
    let mut out = Vec::new();
    let mut paths: Vec<String> = threads.iter().map(|t| t.path.clone()).collect();
    paths.sort();
    paths.dedup();
    for p in paths {
        let text = fs::read_to_string(Path::new(repo_root).join(&p)).unwrap_or_default();
        let old = if threads.iter().any(|t| t.path == p && t.anchor.old_side) { base_version(repo_root, &p) } else { String::new() };
        out.extend(locate_threads(threads.clone(), p, text, old));
    }
    out
}

/// Threads as JSON (with current line numbers) for agents and scripts.
#[uniffi::export]
pub fn export_json(repo_root: String, include_resolved: bool) -> Result<String, CoreError> {
    let threads: Vec<Thread> = submitted_only(load_threads(repo_root.clone())?)
        .into_iter()
        .filter(|t| include_resolved || t.status == ThreadStatus::Open)
        .collect();
    Ok(serde_json::to_string_pretty(&located_all(&repo_root, threads)).expect("serializable"))
}

/// Threads as Markdown an agent can act on: code in context, the thread, and
/// the exact command to resolve it.
#[uniffi::export]
pub fn export_markdown(repo_root: String, include_resolved: bool) -> Result<String, CoreError> {
    let threads: Vec<Thread> = submitted_only(load_threads(repo_root.clone())?)
        .into_iter()
        .filter(|t| include_resolved || t.status == ThreadStatus::Open)
        .collect();
    let located = located_all(&repo_root, threads);
    let open = located.iter().filter(|l| l.thread.status == ThreadStatus::Open).count();
    let mut md = format!("# Review comments ({open} open)\n\n");
    if let Some(r) = load_reviews(repo_root.clone())?.last() {
        let verdict = match r.verdict {
            Verdict::Approve => "approved",
            Verdict::RequestChanges => "requested changes",
            Verdict::Comment => "commented",
        };
        md.push_str(&format!("## Latest review: {} {verdict}\n\n", r.author));
        if !r.body.trim().is_empty() {
            md.push_str(&format!("{}\n\n", r.body.trim()));
        }
    }
    if located.is_empty() {
        md.push_str("No open comments.\n");
        return Ok(md);
    }
    md.push_str("Address each open comment by editing the code. Then resolve it with a short note:\n");
    md.push_str("`pairprogram resolve <id> --note \"what you changed\"`\n");
    md.push_str("If you disagree or need input, reply instead: `pairprogram reply <id> \"...\"`\n\n");
    for l in &located {
        let t = &l.thread;
        let status = if t.status == ThreadStatus::Resolved { " (resolved)" } else { "" };
        let side = if t.anchor.old_side { " (on a deleted line; numbers are from the original file)" } else { "" };
        match l.line {
            Some(n) => md.push_str(&format!("## `{}` · {}:{}{}{}\n\n", t.id, t.path, n + 1, side, status)),
            None => md.push_str(&format!("## `{}` · {} (line changed since comment; was line {}){}\n\n", t.id, t.path, t.anchor.line + 1, status)),
        }
        // Code in context: the working tree, or the original for deleted lines.
        let text = if t.anchor.old_side { base_version(&repo_root, &t.path) } else { fs::read_to_string(Path::new(&repo_root).join(&t.path)).unwrap_or_default() };
        let lines = split_lines(&text);
        md.push_str("```\n");
        match l.line {
            Some(n) => {
                let n = n as usize;
                for k in n.saturating_sub(2)..(n + 3).min(lines.len()) {
                    md.push_str(&format!("{}{:>5} | {}\n", if k == n { ">" } else { " " }, k + 1, lines[k]));
                }
            }
            None => md.push_str(&format!(">{:>5} | {}\n", t.anchor.line + 1, t.anchor.text)),
        }
        md.push_str("```\n\n");
        for e in &t.entries {
            md.push_str(&format!("**{}:** {}\n\n", e.author, e.body.trim()));
        }
    }
    Ok(md)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn anchor(line: u32, text: &str, before: &[&str], after: &[&str]) -> Anchor {
        Anchor { line, old_side: false, text: text.into(), before: before.iter().map(|s| s.to_string()).collect(), after: after.iter().map(|s| s.to_string()).collect() }
    }

    #[test]
    fn finds_line_after_insertions_above() {
        let a = anchor(1, "b", &["a"], &["c"]);
        assert_eq!(locate(&a, &["x", "y", "a", "b", "c"]), Some(3));
    }

    #[test]
    fn prefers_matching_context_over_distance() {
        let a = anchor(5, "}", &["return x"], &[]);
        assert_eq!(locate(&a, &["}", "", "return x", "}", "", "", "}"]), Some(3));
    }

    #[test]
    fn outdated_when_line_is_gone() {
        let a = anchor(1, "let old = 1", &[], &[]);
        assert_eq!(locate(&a, &["let new = 1"]), None);
    }

    #[test]
    fn round_trip_in_a_real_repo() {
        let dir = std::env::temp_dir().join(format!("pp-comments-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        Command::new("git").args(["init", "-q"]).current_dir(&dir).status().unwrap();
        fs::write(dir.join("a.txt"), "one\ntwo\nthree\n").unwrap();
        let root = dir.to_string_lossy().to_string();

        let t = add_thread(root.clone(), "a.txt".into(), "one\ntwo\nthree\n".into(), 1, false, "you".into(), "rename".into(), false).unwrap();
        reply(root.clone(), t.id.clone(), "agent".into(), "on it".into(), false).unwrap();
        fs::write(dir.join("a.txt"), "zero\none\ntwo\nthree\n").unwrap();
        let md = export_markdown(root.clone(), false).unwrap();
        assert!(md.contains(&format!("`{}` · a.txt:3", t.id)), "{md}");
        assert!(md.contains("**agent:** on it"));

        set_resolved(root.clone(), t.id.clone(), true, "agent".into(), Some("renamed".into())).unwrap();
        assert!(export_markdown(root.clone(), false).unwrap().contains("No open comments"));
        let all = load_threads(root.clone()).unwrap();
        assert_eq!(all[0].status, ThreadStatus::Resolved);
        assert_eq!(all[0].entries.len(), 3);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn pending_review_is_invisible_until_submitted() {
        let dir = std::env::temp_dir().join(format!("pp-review-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        Command::new("git").args(["init", "-q"]).current_dir(&dir).status().unwrap();
        fs::write(dir.join("a.txt"), "one\ntwo\n").unwrap();
        let root = dir.to_string_lossy().to_string();

        let now = add_thread(root.clone(), "a.txt".into(), "one\ntwo\n".into(), 0, false, "you".into(), "single".into(), false).unwrap();
        add_thread(root.clone(), "a.txt".into(), "one\ntwo\n".into(), 1, false, "you".into(), "in review".into(), true).unwrap();
        reply(root.clone(), now.id.clone(), "you".into(), "pending reply".into(), true).unwrap();
        assert_eq!(pending_count(root.clone(), "you".into()).unwrap(), 2);

        let md = export_markdown(root.clone(), false).unwrap();
        assert!(md.contains("(1 open)") && md.contains("single") && !md.contains("in review") && !md.contains("pending reply"), "{md}");

        let r = submit_review(root.clone(), "you".into(), "Two things to fix.".into(), Verdict::RequestChanges).unwrap();
        assert_eq!(r.thread_ids.len(), 2);
        assert_eq!(pending_count(root.clone(), "you".into()).unwrap(), 0);
        let md = export_markdown(root.clone(), false).unwrap();
        assert!(md.contains("(2 open)") && md.contains("in review") && md.contains("pending reply"), "{md}");
        assert!(md.contains("Latest review: you requested changes") && md.contains("Two things to fix."), "{md}");

        add_thread(root.clone(), "a.txt".into(), "one\ntwo\n".into(), 0, false, "you".into(), "oops".into(), true).unwrap();
        discard_pending(root.clone(), "you".into()).unwrap();
        assert_eq!(load_threads(root.clone()).unwrap().len(), 2);
        let _ = fs::remove_dir_all(&dir);
    }
}
