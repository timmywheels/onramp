//! Reviewers: agent personas that review the whole change on their own (the red
//! team, a security pass…), declared in TOML files. No code needed.
//!
//! ```toml
//! id = "red-team"
//! name = "Red team"
//! agent = "claude"          # which agent runs it
//! model = "opus"            # optional, passed to the agent
//! when = "manual"           # manual | pr_open
//! read_only = true          # it reports; it never edits
//! focus = ["correctness", "security", "missing tests"]
//! min_severity = "medium"   # low | medium | high | critical
//! max_findings = 12
//! prompt = """
//! Assume this change is wrong until the code proves otherwise.
//! """
//! ```
//!
//! Loaded from, in order (a later file with the same id replaces an earlier one):
//! the reviewers that ship with Onramp, yours (`<config>/reviewers/*.toml`), then
//! the repo's (`.onramp/reviewers/*.toml`, shared with your team).
use std::fs;
use std::path::Path;

use serde::Deserialize;

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct Reviewer {
    pub id: String,
    pub name: String,
    pub agent: String,
    pub model: Option<String>,
    pub when: String,
    pub read_only: bool,
    pub focus: Vec<String>,
    pub min_severity: String,
    pub max_findings: u32,
    pub prompt: String,
    /// The file it came from.
    pub file: String,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ReviewerScan {
    pub reviewers: Vec<Reviewer>,
    /// Files that didn't parse: path and why.
    pub problems: Vec<String>,
}

#[derive(Deserialize)]
struct Manifest {
    id: String,
    name: Option<String>,
    agent: Option<String>,
    model: Option<String>,
    when: Option<String>,
    read_only: Option<bool>,
    #[serde(default)]
    focus: Vec<String>,
    min_severity: Option<String>,
    max_findings: Option<u32>,
    #[serde(default)]
    prompt: String,
}

pub const SEVERITIES: [&str; 4] = ["low", "medium", "high", "critical"];

/// How bad, as a number (low 0 … critical 3); unknown counts as medium.
#[uniffi::export]
pub fn severity_rank(severity: String) -> u32 {
    SEVERITIES.iter().position(|s| *s == severity.to_lowercase()).unwrap_or(1) as u32
}

/// Every reviewer, from `builtin_dir`, `<config_dir>/reviewers` and `<repo>/.onramp/reviewers`.
#[uniffi::export]
pub fn list_reviewers(repo_root: String, config_dir: String, builtin_dir: String) -> ReviewerScan {
    let mut reviewers: Vec<Reviewer> = Vec::new();
    let mut problems = Vec::new();
    let dirs = [
        Path::new(&builtin_dir).to_path_buf(),
        Path::new(&config_dir).join("reviewers"),
        Path::new(&repo_root).join(".onramp").join("reviewers"),
    ];
    for dir in dirs {
        let Ok(entries) = fs::read_dir(&dir) else { continue };
        let mut files: Vec<_> = entries.filter_map(|e| e.ok().map(|e| e.path())).filter(|p| p.extension().is_some_and(|x| x == "toml")).collect();
        files.sort();
        for file in files {
            match fs::read_to_string(&file).map_err(|e| e.to_string()).and_then(|s| toml::from_str::<Manifest>(&s).map_err(|e| e.to_string())) {
                Ok(m) => {
                    let r = Reviewer {
                        name: m.name.unwrap_or_else(|| m.id.clone()),
                        agent: m.agent.unwrap_or_else(|| "claude".into()),
                        model: m.model.filter(|s| !s.trim().is_empty()),
                        when: m.when.unwrap_or_else(|| "manual".into()),
                        read_only: m.read_only.unwrap_or(true),
                        focus: m.focus,
                        min_severity: m.min_severity.unwrap_or_else(|| "low".into()).to_lowercase(),
                        max_findings: m.max_findings.unwrap_or(15),
                        prompt: m.prompt,
                        file: file.display().to_string(),
                        id: m.id,
                    };
                    reviewers.retain(|x| x.id != r.id); // a later one with the same id wins
                    reviewers.push(r);
                }
                Err(e) => problems.push(format!("{}: {e}", file.display())),
            }
        }
    }
    ReviewerScan { reviewers, problems }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn later_files_override_and_defaults_fill_in() {
        let dir = std::env::temp_dir().join(format!("onramp-reviewers-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        let (builtin, config, repo) = (dir.join("builtin"), dir.join("config"), dir.join("repo"));
        fs::create_dir_all(&builtin).unwrap();
        fs::create_dir_all(config.join("reviewers")).unwrap();
        fs::create_dir_all(repo.join(".onramp/reviewers")).unwrap();
        fs::write(builtin.join("red-team.toml"), "id = \"red-team\"\nname = \"Red team\"\nprompt = \"break it\"\n").unwrap();
        fs::write(builtin.join("security.toml"), "id = \"security\"\nmin_severity = \"HIGH\"\n").unwrap();
        fs::write(repo.join(".onramp/reviewers/red-team.toml"), "id = \"red-team\"\nname = \"Our red team\"\nmax_findings = 5\n").unwrap();
        fs::write(config.join("reviewers/broken.toml"), "id = ").unwrap();

        let scan = list_reviewers(repo.display().to_string(), config.display().to_string(), builtin.display().to_string());
        let names: Vec<_> = scan.reviewers.iter().map(|r| (r.id.as_str(), r.name.as_str())).collect();
        assert_eq!(names, vec![("security", "security"), ("red-team", "Our red team")]);
        let red = &scan.reviewers[1];
        assert_eq!((red.max_findings, red.read_only, red.when.as_str(), red.agent.as_str()), (5, true, "manual", "claude"));
        assert_eq!(scan.reviewers[0].min_severity, "high");
        assert_eq!(scan.problems.len(), 1);
        assert_eq!((severity_rank("critical".into()), severity_rank("Low".into()), severity_rank("?".into())), (3, 0, 1));
        let _ = fs::remove_dir_all(&dir);
    }
}
