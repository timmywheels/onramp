//! Syntax highlighting with tree-sitter.
//!
//! Grammars are compiled in (by name, see `grammar`); which files use which
//! grammar comes from extensions (`[[languages]]` in extension.toml), so adding
//! a language mapping or overriding a highlight query needs no app change.
//! Loading grammars themselves from extensions (as WASM, like Zed) comes later
//! and slots in behind `grammar`.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, OnceLock, RwLock};

use tree_sitter_highlight::{HighlightConfiguration, HighlightEvent, Highlighter};

/// Capture names themes can color. A capture like `function.method.call`
/// uses the longest listed prefix (`function.method`), then `function`.
pub const HIGHLIGHT_NAMES: [&str; 28] = [
    "attribute", "boolean", "comment", "constant", "constant.builtin", "constructor", "embedded", "escape",
    "function", "function.builtin", "function.method", "keyword", "label", "module", "number", "operator",
    "property", "punctuation", "punctuation.bracket", "punctuation.delimiter", "punctuation.special", "string",
    "string.special", "tag", "type", "type.builtin", "variable.builtin", "variable.parameter",
];

/// Which grammar a file uses, from an extension manifest.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct LanguageConfig {
    pub name: String,
    /// A compiled-in grammar (see `grammar_names`).
    pub grammar: String,
    /// File extensions without the dot ("ts"), or whole file names ("Dockerfile").
    pub suffixes: Vec<String>,
    /// Absolute path of a highlights.scm replacing the grammar's own query.
    pub highlights: Option<String>,
}

fn grammar(name: &str) -> Option<(tree_sitter::Language, String)> {
    use tree_sitter_javascript as js;
    let q = |parts: &[&str]| parts.join("\n");
    Some(match name {
        "bash" => (tree_sitter_bash::LANGUAGE.into(), q(&[tree_sitter_bash::HIGHLIGHT_QUERY])),
        "c" => (tree_sitter_c::LANGUAGE.into(), q(&[tree_sitter_c::HIGHLIGHT_QUERY])),
        "cpp" => (tree_sitter_cpp::LANGUAGE.into(), q(&[tree_sitter_c::HIGHLIGHT_QUERY, tree_sitter_cpp::HIGHLIGHT_QUERY])),
        "css" => (tree_sitter_css::LANGUAGE.into(), q(&[tree_sitter_css::HIGHLIGHTS_QUERY])),
        "go" => (tree_sitter_go::LANGUAGE.into(), q(&[tree_sitter_go::HIGHLIGHTS_QUERY])),
        "html" => (tree_sitter_html::LANGUAGE.into(), q(&[tree_sitter_html::HIGHLIGHTS_QUERY])),
        "java" => (tree_sitter_java::LANGUAGE.into(), q(&[tree_sitter_java::HIGHLIGHTS_QUERY])),
        "javascript" => (js::LANGUAGE.into(), q(&[js::HIGHLIGHT_QUERY, js::JSX_HIGHLIGHT_QUERY])),
        "json" => (tree_sitter_json::LANGUAGE.into(), q(&[tree_sitter_json::HIGHLIGHTS_QUERY])),
        "python" => (tree_sitter_python::LANGUAGE.into(), q(&[tree_sitter_python::HIGHLIGHTS_QUERY])),
        "ruby" => (tree_sitter_ruby::LANGUAGE.into(), q(&[tree_sitter_ruby::HIGHLIGHTS_QUERY])),
        "rust" => (tree_sitter_rust::LANGUAGE.into(), q(&[tree_sitter_rust::HIGHLIGHTS_QUERY])),
        "swift" => (tree_sitter_swift::LANGUAGE.into(), q(&[tree_sitter_swift::HIGHLIGHTS_QUERY])),
        "toml" => (tree_sitter_toml_ng::LANGUAGE.into(), q(&[tree_sitter_toml_ng::HIGHLIGHTS_QUERY])),
        // TypeScript's query only adds to JavaScript's (as in Helix/Zed).
        "typescript" => (tree_sitter_typescript::LANGUAGE_TYPESCRIPT.into(), q(&[tree_sitter_typescript::HIGHLIGHTS_QUERY, js::HIGHLIGHT_QUERY])),
        "tsx" => (tree_sitter_typescript::LANGUAGE_TSX.into(), q(&[tree_sitter_typescript::HIGHLIGHTS_QUERY, js::HIGHLIGHT_QUERY, js::JSX_HIGHLIGHT_QUERY])),
        "yaml" => (tree_sitter_yaml::LANGUAGE.into(), q(&[tree_sitter_yaml::HIGHLIGHTS_QUERY])),
        _ => return None,
    })
}

#[uniffi::export]
pub fn grammar_names() -> Vec<String> {
    ["bash", "c", "cpp", "css", "go", "html", "java", "javascript", "json", "python", "ruby", "rust", "swift", "toml", "typescript", "tsx", "yaml"]
        .map(String::from)
        .to_vec()
}

#[uniffi::export]
pub fn highlight_names() -> Vec<String> {
    HIGHLIGHT_NAMES.map(String::from).to_vec()
}

fn languages() -> &'static RwLock<Vec<LanguageConfig>> {
    static L: OnceLock<RwLock<Vec<LanguageConfig>>> = OnceLock::new();
    L.get_or_init(|| RwLock::new(Vec::new()))
}

/// Compiled queries by (grammar, override path). Compiling a query takes
/// 10–50 ms, so each is built once and shared across threads.
fn configs() -> &'static Mutex<HashMap<(String, Option<String>), Option<Arc<HighlightConfiguration>>>> {
    static C: OnceLock<Mutex<HashMap<(String, Option<String>), Option<Arc<HighlightConfiguration>>>>> = OnceLock::new();
    C.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Replace the language table (the app calls this after loading extensions).
#[uniffi::export]
pub fn set_languages(configs: Vec<LanguageConfig>) {
    *languages().write().expect("languages lock") = configs;
}

fn language_for(path: &str) -> Option<LanguageConfig> {
    let name = path.rsplit('/').next().unwrap_or(path);
    let ext = name.rsplit_once('.').map(|(_, e)| e);
    let langs = languages().read().expect("languages lock");
    // Later entries win (user extensions load after built-ins).
    langs.iter().rev().find(|l| l.suffixes.iter().any(|s| s == name || Some(s.as_str()) == ext)).cloned()
}

/// The language name used for `path`, if any.
#[uniffi::export]
pub fn language_name(path: String) -> Option<String> {
    language_for(&path).map(|l| l.name)
}

fn config(lang: &LanguageConfig) -> Option<Arc<HighlightConfiguration>> {
    let key = (lang.grammar.clone(), lang.highlights.clone());
    if let Some(c) = configs().lock().expect("configs lock").get(&key) {
        return c.clone();
    }
    let built = grammar(&lang.grammar).and_then(|(language, builtin_query)| {
        let query = match &lang.highlights {
            Some(path) => std::fs::read_to_string(path).ok()?,
            None => builtin_query,
        };
        let mut c = HighlightConfiguration::new(language, &lang.name, &query, "", "").ok()?;
        c.configure(&HIGHLIGHT_NAMES);
        Some(Arc::new(c))
    });
    configs().lock().expect("configs lock").insert(key, built.clone());
    built
}

/// Highlights for `text` as flat triples `[start, end, name index, ...]`,
/// offsets in UTF-16 code units (what NSString uses), sorted, non-overlapping
/// (the innermost capture wins). None when no language matches `path`.
#[uniffi::export]
pub fn highlight(path: String, text: String) -> Option<Vec<u32>> {
    let config = config(&language_for(&path)?)?;
    let mut highlighter = Highlighter::new();
    let events = highlighter.highlight(&config, text.as_bytes(), None, None, |_| None).ok()?;

    let mut out = Vec::new();
    let mut stack: Vec<u32> = Vec::new();
    // Byte → UTF-16 offset, walked forward since events arrive in order.
    let (mut byte, mut utf16) = (0usize, 0u32);
    let mut to_utf16 = |target: usize| {
        for ch in text[byte..target].chars() {
            utf16 += ch.len_utf16() as u32;
        }
        byte = target;
        utf16
    };
    for event in events {
        match event.ok()? {
            HighlightEvent::HighlightStart(h) => stack.push(h.0 as u32),
            HighlightEvent::HighlightEnd => {
                stack.pop();
            }
            HighlightEvent::Source { start, end } => {
                let Some(&kind) = stack.last() else {
                    to_utf16(end);
                    continue;
                };
                let s = to_utf16(start);
                let e = to_utf16(end);
                if e > s {
                    // Merge with the previous span when it continues it.
                    let n = out.len();
                    if n >= 3 && out[n - 1] == kind && out[n - 2] == s {
                        out[n - 2] = e;
                    } else {
                        out.extend([s, e, kind]);
                    }
                }
            }
        }
    }
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn name_at(spans: &[u32], text: &str, needle: &str) -> Option<&'static str> {
        let at = text.encode_utf16().collect::<Vec<_>>();
        let pos = String::from_utf16(&at).unwrap().find(needle)? as u32; // ASCII test text
        spans.chunks(3).find(|c| c[0] <= pos && pos < c[1]).map(|c| HIGHLIGHT_NAMES[c[2] as usize])
    }

    #[test]
    fn highlights_every_grammar() {
        set_languages(
            grammar_names()
                .into_iter()
                .map(|g| LanguageConfig { name: g.clone(), grammar: g.clone(), suffixes: vec![g], highlights: None })
                .collect(),
        );
        for g in grammar_names() {
            assert!(config(&language_for(&format!("x.{g}")).unwrap()).is_some(), "{g} query doesn't compile");
        }

        let ts = "// hi\nconst greet = (name: string): string => `hello ${name}`;\n";
        let spans = highlight("a/b.typescript".into(), ts.into()).unwrap();
        assert_eq!(name_at(&spans, ts, "// hi"), Some("comment"));
        assert_eq!(name_at(&spans, ts, "const"), Some("keyword"));
        assert_eq!(name_at(&spans, ts, "string)"), Some("type.builtin"));

        let rs = "fn main() { let x = \"é\"; }\n";
        let spans = highlight("main.rust".into(), rs.into()).unwrap();
        assert_eq!(name_at(&spans, rs, "fn"), Some("keyword"));
        // UTF-16 offsets: the string "é" spans 3 units ("é" is one UTF-16 unit, two bytes).
        let s = spans.chunks(3).find(|c| HIGHLIGHT_NAMES[c[2] as usize] == "string").unwrap();
        assert_eq!(s[1] - s[0], 3);

        assert_eq!(highlight("notes.unknown".into(), "x".into()), None);
    }
}
