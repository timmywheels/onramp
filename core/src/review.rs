//! Loads a whole review in one call: status + HEAD contents + working files +
//! diffs, computed in parallel. Swift gets everything it needs to size every
//! file in the scroll without building editors for them.

use std::path::Path;

use crate::diff::{diff_lines, DiffHunk};
use crate::repo::{changed_files_since, texts_at, ChangedFile, FileStatus};
use crate::CoreError;

const MAX_FILE_BYTES: usize = 2_000_000;

#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum FileBody {
    /// Text on both sides (old is empty for new files).
    Text { old_text: String, new_text: String, hunks: Vec<DiffHunk>, new_line_count: u32 },
    /// Removed from the working tree. `old_text` is empty when the old
    /// version is binary or too large to show.
    Deleted { old_text: String, old_line_count: u32 },
    Binary,
    TooLarge { bytes: u64 },
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct FileDiff {
    pub path: String,
    pub status: FileStatus,
    pub body: FileBody,
}

fn line_count(s: &str) -> u32 {
    if s.is_empty() {
        0
    } else {
        s.bytes().filter(|b| *b == b'\n').count() as u32 + u32::from(!s.ends_with('\n'))
    }
}

fn load_one(root: &Path, file: &ChangedFile, old: Option<String>) -> FileDiff {
    let body = if file.status == FileStatus::Deleted {
        let old_line_count = old.as_deref().map(line_count).unwrap_or(0);
        let old_text = old.filter(|t| t.len() <= MAX_FILE_BYTES && !t.contains('\0')).unwrap_or_default();
        FileBody::Deleted { old_text, old_line_count }
    } else {
        match std::fs::read(root.join(&file.path)) {
            Ok(bytes) if bytes.len() > MAX_FILE_BYTES => FileBody::TooLarge { bytes: bytes.len() as u64 },
            Ok(bytes) => match String::from_utf8(bytes) {
                Ok(new_text) if !new_text.contains('\0') => {
                    let old_text = old.unwrap_or_default();
                    let hunks = diff_lines(old_text.clone(), new_text.clone());
                    let new_line_count = line_count(&new_text);
                    FileBody::Text { old_text, new_text, hunks, new_line_count }
                }
                _ => FileBody::Binary,
            },
            Err(_) => FileBody::Binary,
        }
    };
    FileDiff { path: file.path.clone(), status: file.status.clone(), body }
}

/// Everything changed in the working tree vs `base_rev` (see `review_base`),
/// diffed, in path order.
#[uniffi::export]
pub fn load_review(repo_root: String, base_rev: String) -> Result<Vec<FileDiff>, CoreError> {
    let files = changed_files_since(&repo_root, &base_rev)?;
    let olds = texts_at(&repo_root, &base_rev, &files.iter().map(|f| f.path.clone()).collect::<Vec<_>>())?;
    let root = Path::new(&repo_root);

    let work: Vec<(&ChangedFile, Option<String>)> = files.iter().zip(olds).collect();
    let threads = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(4);
    let chunk = work.len().div_ceil(threads).max(1);

    let mut out: Vec<FileDiff> = Vec::with_capacity(work.len());
    std::thread::scope(|scope| {
        let handles: Vec<_> = work
            .chunks(chunk)
            .map(|batch| scope.spawn(move || batch.iter().map(|(f, old)| load_one(root, f, old.clone())).collect::<Vec<_>>()))
            .collect();
        for h in handles {
            out.extend(h.join().expect("diff worker panicked"));
        }
    });
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn counts_lines() {
        assert_eq!(line_count(""), 0);
        assert_eq!(line_count("a"), 1);
        assert_eq!(line_count("a\n"), 1);
        assert_eq!(line_count("a\nb"), 2);
    }

    #[test]
    fn loads_big_review_fast() {
        let Ok(root) = std::env::var("PP_BENCH_REPO") else { return };
        let t = std::time::Instant::now();
        let files = load_review(root, "HEAD".into()).unwrap();
        eprintln!("load_review: {} files in {:?}", files.len(), t.elapsed());
    }
}
