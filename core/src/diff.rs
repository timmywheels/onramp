use imara_diff::{Algorithm, Diff, InternedInput};

/// One change region, described in terms the editor needs: which lines of the
/// *current* text are new, and which old lines to draw (read-only) above them.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct DiffHunk {
    /// 0-based line in the new text where this hunk starts.
    pub new_start: u32,
    /// Number of added lines (0 for a pure deletion).
    pub new_len: u32,
    /// 0-based line in the old text where this hunk starts.
    pub old_start: u32,
    /// Removed lines, without trailing newlines, in order.
    pub deleted: Vec<String>,
}

/// Line diff of `old` → `new`. Called on every edit pause, so it must stay
/// well under a frame for normal source files.
#[uniffi::export]
pub fn diff_lines(old: String, new: String) -> Vec<DiffHunk> {
    let input = InternedInput::new(old.as_str(), new.as_str());
    let mut diff = Diff::compute(Algorithm::Histogram, &input);
    diff.postprocess_lines(&input);

    diff.hunks()
        .map(|h| DiffHunk {
            new_start: h.after.start,
            new_len: h.after.end - h.after.start,
            old_start: h.before.start,
            deleted: h
                .before
                .clone()
                .map(|i| {
                    let line: &str = input.interner[input.before[i as usize]];
                    line.strip_suffix('\n').unwrap_or(line).trim_end_matches('\r').to_string()
                })
                .collect(),
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn modification_insertion_deletion() {
        let old = "a\nb\nc\nd\n".to_string();
        let new = "a\nB\nc\nd\ne\n".to_string();
        let hunks = diff_lines(old, new);
        assert_eq!(
            hunks,
            vec![
                DiffHunk { new_start: 1, new_len: 1, old_start: 1, deleted: vec!["b".into()] },
                DiffHunk { new_start: 4, new_len: 1, old_start: 4, deleted: vec![] },
            ]
        );
    }

    #[test]
    fn pure_deletion() {
        let hunks = diff_lines("a\nb\nc\n".into(), "a\nc\n".into());
        assert_eq!(hunks, vec![DiffHunk { new_start: 1, new_len: 0, old_start: 1, deleted: vec!["b".into()] }]);
    }

    #[test]
    fn fast_on_large_file() {
        let old: String = (0..20_000).map(|i| format!("    let value_{i} = compute({i});\n")).collect();
        let new = old.replace("compute(500)", "compute(501)").replace("compute(15000)", "other(15000)");
        let start = std::time::Instant::now();
        let hunks = diff_lines(old, new);
        let elapsed = start.elapsed();
        assert_eq!(hunks.len(), 2);
        eprintln!("20k-line diff: {elapsed:?}");
    }
}
