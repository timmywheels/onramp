//! Extensions: folders with an `extension.toml` manifest.
//!
//! Today extensions are declarative (fonts, themes). The manifest already
//! carries what code extensions will need: `api_version`, `runtime`
//! ("process" now, "wasm" later) and `permissions`, so the format doesn't
//! change when they arrive.
//!
//! ```toml
//! id = "lilex"
//! name = "Lilex"
//! version = "2.700.0"
//! api_version = 1
//! description = "Default code font"
//! fonts = ["fonts/Lilex-Regular.ttf"]
//! themes = ["themes/one.json"]
//! ```
//!
//! Scanned from several roots in order (built-in first, then the user's
//! folder); a later extension with the same id replaces an earlier one.

use std::fs;
use std::path::{Component, Path, PathBuf};

use serde::Deserialize;

/// Newest manifest `api_version` this build understands.
pub const API_VERSION: u32 = 1;

/// Permissions a code extension can ask for. Declarative extensions need none.
pub const PERMISSIONS: [&str; 5] = ["read-repo", "post-comments", "edit-files", "run-commands", "network"];

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct Extension {
    pub id: String,
    pub name: String,
    pub version: String,
    pub api_version: u32,
    pub description: String,
    pub authors: Vec<String>,
    pub dir: String,
    /// Absolute paths, checked to be inside `dir`.
    pub fonts: Vec<String>,
    pub themes: Vec<String>,
    /// "process" | "wasm" for code extensions; None for declarative ones.
    pub runtime: Option<String>,
    pub permissions: Vec<String>,
    /// Found in the first root (shipped with the app).
    pub builtin: bool,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ExtensionProblem {
    pub dir: String,
    pub message: String,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ExtensionScan {
    pub extensions: Vec<Extension>,
    pub problems: Vec<ExtensionProblem>,
}

#[derive(Deserialize)]
struct Manifest {
    id: String,
    name: String,
    version: String,
    api_version: u32,
    #[serde(default)]
    description: String,
    #[serde(default)]
    authors: Vec<String>,
    #[serde(default)]
    fonts: Vec<String>,
    #[serde(default)]
    themes: Vec<String>,
    runtime: Option<String>,
    #[serde(default)]
    permissions: Vec<String>,
}

#[uniffi::export]
pub fn extension_api_version() -> u32 {
    API_VERSION
}

/// Every extension under `roots` (each root holds one folder per extension).
/// `roots[0]` is treated as the built-in root.
#[uniffi::export]
pub fn scan_extensions(roots: Vec<String>) -> ExtensionScan {
    let mut extensions: Vec<Extension> = Vec::new();
    let mut problems = Vec::new();
    for (i, root) in roots.iter().enumerate() {
        let Ok(entries) = fs::read_dir(root) else { continue };
        let mut dirs: Vec<PathBuf> = entries.flatten().map(|e| e.path()).filter(|p| p.join("extension.toml").is_file()).collect();
        dirs.sort();
        for dir in dirs {
            match load(&dir, i == 0) {
                Ok(ext) => {
                    extensions.retain(|e| e.id != ext.id);
                    extensions.push(ext);
                }
                Err(message) => problems.push(ExtensionProblem { dir: dir.display().to_string(), message }),
            }
        }
    }
    ExtensionScan { extensions, problems }
}

fn load(dir: &Path, builtin: bool) -> Result<Extension, String> {
    let text = fs::read_to_string(dir.join("extension.toml")).map_err(|e| e.to_string())?;
    let m: Manifest = toml::from_str(&text).map_err(|e| format!("extension.toml: {}", e.message()))?;
    if m.id.is_empty() || !m.id.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-') {
        return Err(format!("id {:?} must be lowercase letters, digits and dashes", m.id));
    }
    if m.api_version == 0 || m.api_version > API_VERSION {
        return Err(format!("needs api_version {}, this pairprogram supports up to {API_VERSION}", m.api_version));
    }
    match m.runtime.as_deref() {
        None => {}
        Some("process") | Some("wasm") => return Err(format!("runtime {:?} isn't supported yet", m.runtime.unwrap())),
        Some(other) => return Err(format!("unknown runtime {other:?} (expected \"process\" or \"wasm\")")),
    }
    if let Some(p) = m.permissions.iter().find(|p| !PERMISSIONS.contains(&p.as_str())) {
        return Err(format!("unknown permission {p:?} (known: {})", PERMISSIONS.join(", ")));
    }
    let files = |list: &[String]| list.iter().map(|f| inside(dir, f)).collect::<Result<Vec<_>, _>>();
    Ok(Extension {
        fonts: files(&m.fonts)?,
        themes: files(&m.themes)?,
        id: m.id,
        name: m.name,
        version: m.version,
        api_version: m.api_version,
        description: m.description,
        authors: m.authors,
        dir: dir.display().to_string(),
        runtime: m.runtime,
        permissions: m.permissions,
        builtin,
    })
}

/// `file` resolved against `dir`; must be a relative path that stays inside it.
fn inside(dir: &Path, file: &str) -> Result<String, String> {
    let rel = Path::new(file);
    if !rel.components().all(|c| matches!(c, Component::Normal(_) | Component::CurDir)) {
        return Err(format!("{file:?} must be a path inside the extension folder"));
    }
    let path = dir.join(rel);
    if !path.is_file() {
        return Err(format!("{file:?} not found"));
    }
    Ok(path.display().to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scratch(name: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("pp-ext-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&d);
        fs::create_dir_all(&d).unwrap();
        d
    }

    fn write(dir: &Path, rel: &str, text: &str) {
        let p = dir.join(rel);
        fs::create_dir_all(p.parent().unwrap()).unwrap();
        fs::write(p, text).unwrap();
    }

    #[test]
    fn loads_and_overrides_by_id() {
        let builtin = scratch("builtin");
        let user = scratch("user");
        write(&builtin, "one/extension.toml", "id = \"one\"\nname = \"One\"\nversion = \"1.0.0\"\napi_version = 1\nthemes = [\"themes/one.json\"]\n");
        write(&builtin, "one/themes/one.json", "{}");
        write(&user, "one/extension.toml", "id = \"one\"\nname = \"My One\"\nversion = \"2.0.0\"\napi_version = 1\n");
        let scan = scan_extensions(vec![builtin.display().to_string(), user.display().to_string()]);
        assert_eq!(scan.problems, vec![]);
        assert_eq!(scan.extensions.len(), 1);
        assert_eq!(scan.extensions[0].name, "My One");
        assert!(!scan.extensions[0].builtin);

        let only_builtin = scan_extensions(vec![builtin.display().to_string()]);
        assert!(only_builtin.extensions[0].themes[0].ends_with("one/themes/one.json"));
        assert!(only_builtin.extensions[0].builtin);
    }

    #[test]
    fn rejects_bad_manifests() {
        let root = scratch("bad");
        let head = |id: &str| format!("id = \"{id}\"\nname = \"x\"\nversion = \"1\"\n");
        write(&root, "a/extension.toml", &format!("{}api_version = 99\n", head("a")));
        write(&root, "b/extension.toml", &format!("{}api_version = 1\nfonts = [\"../../etc/passwd\"]\n", head("b")));
        write(&root, "c/extension.toml", &format!("{}api_version = 1\npermissions = [\"root\"]\n", head("c")));
        write(&root, "d/extension.toml", &format!("{}api_version = 1\nruntime = \"wasm\"\n", head("d")));
        write(&root, "e/extension.toml", "name = ");
        write(&root, "f/extension.toml", &format!("{}api_version = 1\nthemes = [\"missing.json\"]\n", head("F")));
        let scan = scan_extensions(vec![root.display().to_string()]);
        assert_eq!(scan.extensions, vec![]);
        let msgs: Vec<_> = scan.problems.iter().map(|p| p.message.as_str()).collect();
        assert_eq!(msgs.len(), 6, "{msgs:?}");
        assert!(msgs[0].contains("api_version 99"));
        assert!(msgs[1].contains("inside the extension folder"));
        assert!(msgs[2].contains("unknown permission"));
        assert!(msgs[3].contains("isn't supported yet"));
        assert!(msgs[4].starts_with("extension.toml:"));
        assert!(msgs[5].contains("lowercase"));
    }
}
