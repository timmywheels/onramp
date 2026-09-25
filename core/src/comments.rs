//! Review comments: threads anchored to lines, stored in
//! `<git-dir>/onramp/comments.json` so they never get committed.
//!
//! The app and the `onramp` CLI (what agents use) share this code, so a
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
    /// An agent working on this thread right now (see `claim_thread`).
    #[serde(default)]
    pub claim: Option<Claim>,
    /// Where it came from when not a person: "ci:<key>" for a CI failure.
    #[serde(default)]
    pub source: Option<String>,
}

/// One failing CI annotation (a check run's file + line + message).
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct CiFinding {
    pub check: String,
    pub path: String,
    pub line: u32, // 0-based
    /// The file as CI saw it (to anchor the thread).
    pub text: String,
    pub level: String, // "failure" | "warning"
    pub title: String,
    pub message: String,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct CiSync {
    pub added: u32,
    pub reopened: u32,
    pub resolved: u32,
}

fn ci_key(f: &CiFinding) -> String {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for b in format!("{}|{}|{}|{}", f.check, f.path, f.text.lines().nth(f.line as usize).unwrap_or("").trim(), f.message).bytes() {
        h = (h ^ b as u64).wrapping_mul(0x100_0000_01b3);
    }
    format!("ci:{h:016x}")
}

/// Mirror CI failures as review threads: new failures become threads
/// ("CI · <check>"), ones that come back reopen, and — when `complete` (every
/// check finished) — threads CI no longer reports are resolved.
#[uniffi::export]
pub fn sync_ci_threads(repo_root: String, findings: Vec<CiFinding>, complete: bool) -> Result<CiSync, CoreError> {
    let mut sync = CiSync { added: 0, reopened: 0, resolved: 0 };
    let keys: Vec<String> = findings.iter().map(ci_key).collect();
    for (f, key) in findings.iter().zip(&keys) {
        let existing = load_threads(repo_root.clone())?.into_iter().find(|t| t.source.as_deref() == Some(key.as_str()));
        match existing {
            Some(t) if t.status == ThreadStatus::Open => {}
            Some(t) => {
                set_resolved(repo_root.clone(), t.id.clone(), false, format!("CI · {}", f.check), Some("Failing again.".into()))?;
                sync.reopened += 1;
            }
            None => {
                let heading = if f.title.trim().is_empty() { format!("{} {}", f.check, f.level) } else { f.title.trim().to_string() };
                let body = format!("**{heading}**\n\n```\n{}\n```", f.message.trim());
                let t = add_thread(repo_root.clone(), f.path.clone(), f.text.clone(), f.line, false, format!("CI · {}", f.check), body, false)?;
                let key = key.clone();
                modify(&repo_root, |store| {
                    if let Some(s) = store.threads.iter_mut().find(|s| s.id == t.id) {
                        s.source = Some(key);
                    }
                    Ok(())
                })?;
                sync.added += 1;
            }
        }
    }
    if complete {
        for t in load_threads(repo_root.clone())? {
            let is_ci = t.source.as_deref().is_some_and(|s| s.starts_with("ci:"));
            if is_ci && t.status == ThreadStatus::Open && !keys.contains(t.source.as_ref().unwrap()) {
                set_resolved(repo_root.clone(), t.id.clone(), true, "CI".into(), Some("No longer reported by CI.".into()))?;
                sync.resolved += 1;
            }
        }
    }
    Ok(sync)
}

/// "This agent is on it": other agents skip claimed threads. Gone when the
/// claimer resolves or replies (a reply means it's your turn), when its session
/// ends, or after `CLAIM_TTL` quiet seconds.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, uniffi::Record)]
pub struct Claim {
    pub agent: String,
    pub at: u64, // unix seconds, last activity
}

pub const CLAIM_TTL: u64 = 600;

/// The thread's claim if it's still live.
#[uniffi::export]
pub fn active_claim(thread: Thread) -> Option<Claim> {
    let open = thread.status == ThreadStatus::Open;
    thread.claim.filter(|c| open && now().saturating_sub(c.at) < CLAIM_TTL)
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
    Ok(PathBuf::from(String::from_utf8_lossy(&out.stdout).trim()).join("onramp"))
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
            claim: None,
            source: None,
        };
        store.threads.push(thread.clone());
        Ok(thread)
    })
}

#[uniffi::export]
pub fn reply(repo_root: String, id: String, author: String, body: String, pending: bool) -> Result<Thread, CoreError> {
    modify(&repo_root, |store| {
        let t = store.threads.iter_mut().find(|t| t.id == id).ok_or_else(|| not_found(&id))?;
        if t.claim.as_ref().is_some_and(|c| c.agent == author) {
            t.claim = None; // it answered: the thread is back with you, not "working"
        }
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
        t.claim = None;
        Ok(t.clone())
    })
}

/// Take a thread before working on it, so other agents leave it alone.
/// Fails if another agent holds a live claim, or the thread is resolved.
#[uniffi::export]
pub fn claim_thread(repo_root: String, id: String, agent: String) -> Result<Thread, CoreError> {
    modify(&repo_root, |store| {
        let t = store.threads.iter_mut().find(|t| t.id == id).ok_or_else(|| not_found(&id))?;
        if t.status == ThreadStatus::Resolved {
            return Err(CoreError::Io { message: format!("{id} is already resolved") });
        }
        if let Some(c) = active_claim(t.clone()).filter(|c| c.agent != agent) {
            return Err(CoreError::Io { message: format!("{id} is claimed by {} (skip it)", c.agent) });
        }
        t.claim = Some(Claim { agent, at: now() });
        Ok(t.clone())
    })
}

/// Give a thread back without resolving it.
#[uniffi::export]
pub fn release_thread(repo_root: String, id: String, agent: String) -> Result<Thread, CoreError> {
    modify(&repo_root, |store| {
        let t = store.threads.iter_mut().find(|t| t.id == id).ok_or_else(|| not_found(&id))?;
        if t.claim.as_ref().is_some_and(|c| c.agent == agent) {
            t.claim = None;
        }
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
        if thread_ids.is_empty() {
            // Comments posted straight away (not in the review) still need addressing:
            // a review with nothing pending hands those open threads to the agent.
            thread_ids = store.threads.iter().filter(|t| t.status == ThreadStatus::Open && t.entries.iter().all(|e| !e.pending)).map(|t| t.id.clone()).collect();
        }
        if thread_ids.is_empty() && body.trim().is_empty() && verdict == Verdict::Comment {
            return Err(CoreError::Io { message: "Nothing to send yet: leave a comment or a summary first.".into() });
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

/// The file as the review shows it now: from the commit being reviewed (a PR
/// or commit view), else the working tree.
fn current_version(repo_root: &str, path: &str) -> String {
    match crate::repo::review_base(repo_root.to_string()).ok().and_then(|b| b.target) {
        Some(target) => crate::repo::texts_at(repo_root, &target, &[path.to_string()]).ok().and_then(|mut v| v.pop().flatten()).unwrap_or_default(),
        None => fs::read_to_string(Path::new(repo_root).join(path)).unwrap_or_default(),
    }
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
        let text = current_version(repo_root, &p);
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
    md.push_str("Claim a comment before working on it (`onramp claim <id>`) and skip ones another agent has claimed.\n");
    md.push_str("Address each open comment by editing the code. Then resolve it with a short note:\n");
    md.push_str("`onramp resolve <id> --note \"what you changed\"`\n");
    md.push_str("If you disagree or need input, reply instead: `onramp reply <id> \"...\"`\n\n");
    for l in &located {
        let t = &l.thread;
        let status = match active_claim(t.clone()) {
            _ if t.status == ThreadStatus::Resolved => " (resolved)".to_string(),
            Some(c) => format!(" (claimed by {}: skip it unless that's you)", c.agent),
            None => String::new(),
        };
        let side = if t.anchor.old_side { " (on a deleted line; numbers are from the original file)" } else { "" };
        match l.line {
            Some(n) => md.push_str(&format!("## `{}` · {}:{}{}{}\n\n", t.id, t.path, n + 1, side, status)),
            None => md.push_str(&format!("## `{}` · {} (line changed since comment; was line {}){}\n\n", t.id, t.path, t.anchor.line + 1, status)),
        }
        // Code in context: the working tree, or the original for deleted lines.
        let text = if t.anchor.old_side { base_version(&repo_root, &t.path) } else { current_version(&repo_root, &t.path) };
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
    fn ci_failures_sync_as_threads() {
        let dir = std::env::temp_dir().join(format!("pp-ci-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        Command::new("git").args(["init", "-q"]).current_dir(&dir).status().unwrap();
        let root = dir.to_string_lossy().to_string();
        let f = |msg: &str| CiFinding { check: "lint".into(), path: "a.ts".into(), line: 1, text: "let a = 1\nlet b = a\n".into(),
                                        level: "failure".into(), title: "no-unused-vars".into(), message: msg.into() };

        let s = sync_ci_threads(root.clone(), vec![f("'b' is unused")], false).unwrap();
        assert_eq!((s.added, s.resolved), (1, 0));
        let t = load_threads(root.clone()).unwrap();
        assert_eq!((t[0].entries[0].author.as_str(), t[0].source.as_deref().map(|s| s.starts_with("ci:"))), ("CI · lint", Some(true)));
        assert!(t[0].entries[0].body.contains("no-unused-vars"));
        // Same finding again: nothing new. Checks still running: nothing resolved.
        assert_eq!(sync_ci_threads(root.clone(), vec![f("'b' is unused")], false).unwrap(), CiSync { added: 0, reopened: 0, resolved: 0 });
        assert_eq!(sync_ci_threads(root.clone(), vec![], false).unwrap().resolved, 0);
        // All checks done and it's gone: resolved. It comes back: reopened.
        assert_eq!(sync_ci_threads(root.clone(), vec![], true).unwrap().resolved, 1);
        assert_eq!(sync_ci_threads(root.clone(), vec![f("'b' is unused")], true).unwrap().reopened, 1);
        assert_eq!(load_threads(root.clone()).unwrap().len(), 1);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn claims_keep_agents_apart() {
        let dir = std::env::temp_dir().join(format!("pp-claims-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        Command::new("git").args(["init", "-q"]).current_dir(&dir).status().unwrap();
        let root = dir.to_string_lossy().to_string();

        let t = add_thread(root.clone(), "a.txt".into(), "x\n".into(), 0, false, "you".into(), "fix".into(), false).unwrap();
        claim_thread(root.clone(), t.id.clone(), "claude-code".into()).unwrap();
        let err = claim_thread(root.clone(), t.id.clone(), "codex".into()).unwrap_err().to_string();
        assert!(err.contains("claimed by claude-code"), "{err}");
        claim_thread(root.clone(), t.id.clone(), "claude-code".into()).unwrap(); // re-claiming your own is fine
        assert!(export_markdown(root.clone(), false).unwrap().contains("claimed by claude-code"));

        // Its reply (a question for you) hands the thread back: no longer "working".
        let asked = reply(root.clone(), t.id.clone(), "claude-code".into(), "which one?".into(), false).unwrap();
        assert_eq!(asked.claim, None);
        claim_thread(root.clone(), t.id.clone(), "claude-code".into()).unwrap();
        // Someone else's reply leaves the claim alone.
        assert!(reply(root.clone(), t.id.clone(), "you".into(), "the first".into(), false).unwrap().claim.is_some());

        // A review with nothing pending still hands the open comment to the agent.
        let r = submit_review(root.clone(), "you".into(), String::new(), Verdict::RequestChanges).unwrap();
        assert_eq!(r.thread_ids, vec![t.id.clone()]);
        let r = submit_review(root.clone(), "you".into(), String::new(), Verdict::Comment).unwrap();
        assert_eq!(r.thread_ids, vec![t.id.clone()]);

        let done = set_resolved(root.clone(), t.id.clone(), true, "claude-code".into(), Some("fixed".into())).unwrap();
        assert_eq!(done.claim, None);
        assert!(claim_thread(root.clone(), t.id.clone(), "codex".into()).is_err()); // resolved
        assert!(submit_review(root.clone(), "you".into(), String::new(), Verdict::Comment).is_err()); // truly nothing
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
