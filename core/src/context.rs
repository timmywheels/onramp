//! Review context: files and folders the user wants agents to read before
//! working on their comments (review standards, architecture notes, …).
//!
//! Sources live in two lists: this repo's (`<git-dir>/pairprogram/context.json`,
//! never committed) and the user's for all repos (`<config>/context.json`).
//! Agents get the bundled text through MCP (`get_review_context`) or the CLI.

use std::fs;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::CoreError;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, uniffi::Record)]
pub struct ContextSource {
    /// Absolute, or relative to the repo root (repo scope only).
    pub path: String,
    #[serde(default = "yes")]
    pub enabled: bool,
}

fn yes() -> bool {
    true
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ContextScope {
    Repo,
    Global,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ContextFile {
    pub path: String, // as shown to agents
    pub bytes: u64,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ContextBundle {
    /// Every enabled source's text, each file under a `## path` header.
    pub text: String,
    pub files: Vec<ContextFile>,
    /// Paths skipped: missing, binary, or over the size limits.
    pub skipped: Vec<String>,
}

/// Per file and in total: agents get useful guidance, not a repo dump.
const MAX_FILE: u64 = 200_000;
const MAX_TOTAL: u64 = 600_000;
const MAX_FILES_PER_FOLDER: usize = 200;

fn io(e: std::io::Error) -> CoreError {
    CoreError::Io { message: e.to_string() }
}

fn list_path(repo_root: &str, config_dir: &str, scope: ContextScope) -> Result<PathBuf, CoreError> {
    Ok(match scope {
        ContextScope::Repo => crate::comments::store_dir(repo_root)?.join("context.json"),
        ContextScope::Global => Path::new(config_dir).join("context.json"),
    })
}

#[uniffi::export]
pub fn context_sources(repo_root: String, config_dir: String, scope: ContextScope) -> Vec<ContextSource> {
    list_path(&repo_root, &config_dir, scope)
        .ok()
        .and_then(|p| fs::read(p).ok())
        .and_then(|b| serde_json::from_slice(&b).ok())
        .unwrap_or_default()
}

#[uniffi::export]
pub fn set_context_sources(repo_root: String, config_dir: String, scope: ContextScope, sources: Vec<ContextSource>) -> Result<(), CoreError> {
    let path = list_path(&repo_root, &config_dir, scope)?;
    fs::create_dir_all(path.parent().expect("has parent")).map_err(io)?;
    fs::write(&path, serde_json::to_vec_pretty(&sources).expect("serializable")).map_err(io)
}

fn is_text(bytes: &[u8]) -> bool {
    !bytes.iter().take(8000).any(|b| *b == 0) && std::str::from_utf8(bytes).is_ok()
}

/// Text files under `dir` (sorted, hidden and build folders skipped).
fn walk(dir: &Path, out: &mut Vec<PathBuf>) {
    let Ok(entries) = fs::read_dir(dir) else { return };
    let mut entries: Vec<PathBuf> = entries.flatten().map(|e| e.path()).collect();
    entries.sort();
    for p in entries {
        if out.len() >= MAX_FILES_PER_FOLDER {
            return;
        }
        let name = p.file_name().and_then(|n| n.to_str()).unwrap_or("");
        if name.starts_with('.') || matches!(name, "node_modules" | "target" | "dist" | "build") {
            continue;
        }
        if p.is_dir() {
            walk(&p, out);
        } else {
            out.push(p);
        }
    }
}

/// Everything enabled in both lists, bundled for an agent.
#[uniffi::export]
pub fn review_context(repo_root: String, config_dir: String) -> ContextBundle {
    let root = Path::new(&repo_root);
    let mut sources: Vec<ContextSource> = context_sources(repo_root.clone(), config_dir.clone(), ContextScope::Global);
    sources.extend(context_sources(repo_root.clone(), config_dir, ContextScope::Repo));

    let mut text = String::new();
    let mut files = Vec::new();
    let mut skipped = Vec::new();
    let mut total = 0u64;
    let mut seen = std::collections::HashSet::new();
    for s in sources.into_iter().filter(|s| s.enabled) {
        let full = if Path::new(&s.path).is_absolute() { PathBuf::from(&s.path) } else { root.join(&s.path) };
        let mut paths = Vec::new();
        if full.is_dir() {
            walk(&full, &mut paths);
        } else if full.is_file() {
            paths.push(full.clone());
        } else {
            skipped.push(format!("{} (not found)", s.path));
            continue;
        }
        for p in paths {
            if !seen.insert(p.clone()) {
                continue;
            }
            // Show repo files relative to the repo; others with ~ for home.
            let shown = p.strip_prefix(root).map(|r| r.display().to_string()).unwrap_or_else(|_| {
                let home = std::env::var("HOME").unwrap_or_default();
                let d = p.display().to_string();
                if !home.is_empty() && d.starts_with(&home) { format!("~{}", &d[home.len()..]) } else { d }
            });
            let Ok(bytes) = fs::read(&p) else { continue };
            let n = bytes.len() as u64;
            if n > MAX_FILE || total + n > MAX_TOTAL || !is_text(&bytes) {
                skipped.push(format!("{shown} ({})", if !is_text(&bytes) { "not text" } else { "too large" }));
                continue;
            }
            total += n;
            text.push_str(&format!("## {shown}\n\n{}\n\n", String::from_utf8_lossy(&bytes).trim_end()));
            files.push(ContextFile { path: shown, bytes: n });
        }
    }
    ContextBundle { text, files, skipped }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::process::Command;

    #[test]
    fn bundles_files_and_folders_from_both_scopes() {
        let base = std::env::temp_dir().join(format!("pp-context-{}", std::process::id()));
        let _ = fs::remove_dir_all(&base);
        let repo = base.join("repo");
        let config = base.join("config");
        fs::create_dir_all(repo.join("docs/review/.hidden")).unwrap();
        fs::create_dir_all(&config).unwrap();
        Command::new("git").args(["init", "-q"]).current_dir(&repo).status().unwrap();
        fs::write(repo.join("docs/review/api.md"), "Every endpoint validates input.\n").unwrap();
        fs::write(repo.join("docs/review/logo.png"), [0u8, 1, 2, 3]).unwrap();
        fs::write(repo.join("docs/review/.hidden/x.md"), "skip me").unwrap();
        fs::write(base.join("mine.md"), "Prefer small functions.\n").unwrap();
        let (r, c) = (repo.display().to_string(), config.display().to_string());

        set_context_sources(r.clone(), c.clone(), ContextScope::Repo, vec![
            ContextSource { path: "docs/review".into(), enabled: true },
            ContextSource { path: "docs/missing.md".into(), enabled: true },
            ContextSource { path: "docs/review/api.md".into(), enabled: false },
        ]).unwrap();
        set_context_sources(r.clone(), c.clone(), ContextScope::Global, vec![
            ContextSource { path: base.join("mine.md").display().to_string(), enabled: true },
        ]).unwrap();

        let b = review_context(r.clone(), c.clone());
        let paths: Vec<_> = b.files.iter().map(|f| f.path.clone()).collect();
        assert_eq!(paths.len(), 2, "{paths:?}");
        assert!(paths[0].ends_with("mine.md")); // global first
        assert_eq!(paths[1], "docs/review/api.md");
        assert!(b.text.contains("## docs/review/api.md\n\nEvery endpoint validates input."));
        assert!(b.skipped.iter().any(|s| s.contains("logo.png (not text)")), "{:?}", b.skipped);
        assert!(b.skipped.iter().any(|s| s.contains("missing.md (not found)")));
        assert!(!b.text.contains("skip me"));
        let _ = fs::remove_dir_all(&base);
    }
}
