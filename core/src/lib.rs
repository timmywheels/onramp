//! pairprogram-core: everything pairprogram computes. The Swift app only draws.
//!
//! Modules grow here by feature (diff, repo, later comments/agent); this file
//! re-exports what Swift sees through UniFFI.

mod comments;
mod diff;
mod extensions;
mod repo;
mod review;
mod syntax;

pub use diff::{diff_lines, DiffHunk};
pub use repo::{changed_files, head_text, head_texts, review_base, set_review_mode, ChangedFile, FileStatus, ReviewBase, ReviewMode};
pub use syntax::{grammar_names, highlight, highlight_names, language_name, set_languages, LanguageConfig};
pub use review::{load_review, FileBody, FileDiff};
pub use comments::*;
pub use extensions::{extension_api_version, scan_extensions, Extension, ExtensionProblem, ExtensionScan};

uniffi::setup_scaffolding!();

#[derive(Debug, uniffi::Error)]
pub enum CoreError {
    Git { message: String },
    Io { message: String },
}

impl std::fmt::Display for CoreError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            CoreError::Git { message } => write!(f, "git: {message}"),
            CoreError::Io { message } => write!(f, "io: {message}"),
        }
    }
}

impl std::error::Error for CoreError {}
