import AppKit

/// A color theme. The two fallbacks live here; the rest come from extensions
/// (`themes = [...]` in extension.toml) or loose JSON files in
/// ~/.config/pairprogram/themes/, all with this shape:
///
///     { "name": "My Theme", "appearance": "dark",
///       "colors": { "background": "#1e1e1e", "added_background": "#2ea04326", ... } }
///
/// Missing colors fall back to the built-in theme of the same appearance.
struct Theme: Codable {
    var name: String
    var appearance: String // "light" | "dark"
    var colors: [String: String]
    /// Syntax colors by tree-sitter capture name ("keyword", "string",
    /// "function.method", ...). A name falls back to its parent ("function"),
    /// then to the built-in theme of the same appearance.
    var syntax: [String: String]? = nil

    var isDark: Bool { appearance == "dark" }

    /// Every color a theme can set, with what it's used for.
    static let keys: [String: String] = [
        "background": "editor background",
        "text": "code",
        "line_number": "line numbers",
        "added_background": "added lines",
        "deleted_background": "deleted lines",
        "deleted_text": "deleted line text",
        "fold_background": "\"unchanged lines\" rows",
        "fold_text": "\"unchanged lines\" label",
        "header_background": "file headers",
        "header_text": "file header text",
        "separator": "divider lines",
        "caret": "text cursor",
        "current_line": "line with the cursor",
        "hover": "line under the pointer",
        "comment_background": "comment boxes",
        "comment_border": "comment box border",
        "accent": "buttons and highlights",
        "added_accent": "added: +counts, badges, icons",
        "deleted_accent": "deleted: −counts, badges, icons",
        "modified_accent": "modified-file badges and icons",
    ]

    func color(_ key: String) -> NSColor {
        if let hex = colors[key], let c = NSColor(hex: hex) { return c }
        let fallback = isDark ? Theme.dark : Theme.light
        return NSColor(hex: fallback.colors[key] ?? "#ff00ff") ?? .magenta
    }

    /// Color for a capture name, or nil to draw it as plain text.
    func syntaxColor(_ name: String) -> NSColor? {
        var n = Substring(name)
        let fallback = isDark ? Theme.dark : Theme.light
        while true {
            if let hex = syntax?[String(n)] ?? fallback.syntax?[String(n)] { return NSColor(hex: hex) }
            guard let dot = n.lastIndex(of: ".") else { return nil }
            n = n[..<dot]
        }
    }

    // MARK: Built-ins

    static let dark = Theme(name: "Onramp Dark", appearance: "dark", colors: [
        "background": "#1e1e1e", "text": "#e6e6e6", "line_number": "#6e6e6e",
        "added_background": "#2ea04329", "deleted_background": "#f8514929", "deleted_text": "#e6e6e6bf",
        "fold_background": "#ffffff0d", "fold_text": "#8b8b8b",
        "header_background": "#262626", "header_text": "#e6e6e6", "separator": "#ffffff1a",
        "caret": "#4c9aff", "current_line": "#ffffff0a", "hover": "#ffffff09",
        "comment_background": "#262a31", "comment_border": "#3d4452", "accent": "#4c9aff",
        "added_accent": "#3fb950", "deleted_accent": "#f85149", "modified_accent": "#d29922",
    ], syntax: [ // One Dark
        "keyword": "#c678dd", "string": "#98c379", "string.special": "#56b6c2", "escape": "#56b6c2",
        "comment": "#7f848e", "number": "#d19a66", "boolean": "#d19a66", "constant": "#d19a66",
        "function": "#61afef", "function.builtin": "#56b6c2", "constructor": "#e5c07b",
        "type": "#e5c07b", "module": "#e5c07b", "property": "#e06c75", "variable.builtin": "#e06c75",
        "tag": "#e06c75", "attribute": "#d19a66", "label": "#e06c75", "operator": "#56b6c2",
        "punctuation.special": "#56b6c2",
    ])

    static let light = Theme(name: "Onramp Light", appearance: "light", colors: [
        "background": "#ffffff", "text": "#1f2328", "line_number": "#8c959f",
        "added_background": "#1a7f3724", "deleted_background": "#cf222e1f", "deleted_text": "#1f2328b3",
        "fold_background": "#f6f8fa", "fold_text": "#57606a",
        "header_background": "#f6f8fa", "header_text": "#1f2328", "separator": "#d0d7de",
        "caret": "#0969da", "current_line": "#0000000a", "hover": "#0000000a",
        "comment_background": "#f6f8fa", "comment_border": "#d0d7de", "accent": "#0969da",
        "added_accent": "#1a7f37", "deleted_accent": "#cf222e", "modified_accent": "#9a6700",
    ], syntax: [ // One Light
        "keyword": "#a626a4", "string": "#50a14f", "string.special": "#0184bc", "escape": "#0184bc",
        "comment": "#a0a1a7", "number": "#986801", "boolean": "#986801", "constant": "#986801",
        "function": "#4078f2", "function.builtin": "#0184bc", "constructor": "#c18401",
        "type": "#c18401", "module": "#c18401", "property": "#e45649", "variable.builtin": "#e45649",
        "tag": "#e45649", "attribute": "#986801", "label": "#e45649", "operator": "#0184bc",
        "punctuation.special": "#0184bc",
    ])

    /// The fallbacks every theme builds on. More themes come from extensions.
    static let builtIn = [dark, light]
}

extension NSColor {
    /// "#rrggbb" or "#rrggbbaa".
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        let (r, g, b, a): (UInt64, UInt64, UInt64, UInt64) = s.count == 6
            ? (v >> 16 & 0xff, v >> 8 & 0xff, v & 0xff, 0xff)
            : (v >> 24 & 0xff, v >> 16 & 0xff, v >> 8 & 0xff, v & 0xff)
        self.init(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: CGFloat(a) / 255)
    }
}
