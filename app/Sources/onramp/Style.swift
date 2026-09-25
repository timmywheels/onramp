import AppKit

/// User settings, stored as JSON at ~/.config/onramp/settings.json
/// (edit it directly, or via the View menu; changes apply live).
struct Settings: Codable, Equatable {
    var appearance = "system"              // system | light | dark
    var themeLight = Theme.light.name
    var themeDark = Theme.dark.name
    var fontFamily = ""                    // "" = default (Lilex), "System Mono" = SF Mono, or any installed family
    var fontSize: Double = 12.5
    var fontLigatures = true               // coding ligatures like -> => != (fonts that have them)
    var ghPath = ""                        // GitHub CLI; "" = find it (Homebrew, ~/.local/bin, your shell's PATH)
    var ciComments = true                  // CI failures (check annotations) show up as review threads
    var menuBar = true                     // the yield sign in the menu bar: what your agents are doing

    static let defaultFontSize = 12.5

    init() {}

    init(from decoder: Decoder) throws {
        // Every key optional, so a hand-edited file with only some keys works.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        appearance = try c.decodeIfPresent(String.self, forKey: .appearance) ?? d.appearance
        themeLight = try c.decodeIfPresent(String.self, forKey: .themeLight) ?? d.themeLight
        themeDark = try c.decodeIfPresent(String.self, forKey: .themeDark) ?? d.themeDark
        fontFamily = try c.decodeIfPresent(String.self, forKey: .fontFamily) ?? d.fontFamily
        fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? d.fontSize
        fontLigatures = try c.decodeIfPresent(Bool.self, forKey: .fontLigatures) ?? d.fontLigatures
        ghPath = try c.decodeIfPresent(String.self, forKey: .ghPath) ?? d.ghPath
        ciComments = try c.decodeIfPresent(Bool.self, forKey: .ciComments) ?? d.ciComments
        menuBar = try c.decodeIfPresent(Bool.self, forKey: .menuBar) ?? d.menuBar
    }
}

/// ~/.config/onramp, or $ONRAMP_CONFIG_DIR (tests use a scratch folder).
/// Outside `Style` so the CLI and MCP server (no main actor) can use it too.
let onrampConfigDir = ProcessInfo.processInfo.environment["ONRAMP_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/onramp")

extension Notification.Name {
    static let styleChanged = Notification.Name("onramp.styleChanged")
}

/// Owns settings + themes, picks the theme for the current light/dark mode,
/// and pushes it into DiffStyle. Posts `.styleChanged` whenever the look changes.
@MainActor
final class Style {
    static let shared = Style()

    /// ~/.config/onramp, or $ONRAMP_CONFIG_DIR (tests use a scratch folder).
    static let configDir = onrampConfigDir
    static let settingsURL = configDir.appendingPathComponent("settings.json")
    static let themesDir = configDir.appendingPathComponent("themes")
    static let defaultFontFamily = "Lilex" // from the built-in lilex extension
    static let systemFontFamily = "System Mono"

    private(set) var settings = Settings()
    private(set) var themes: [Theme] = Theme.builtIn
    private(set) var theme = Theme.dark
    private var watchers: [DispatchSourceFileSystemObject] = []
    private var appearanceObservation: NSKeyValueObservation?

    func start() {
        loadMonospaceFamilies()
        load()
        apply()
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { _, _ in
            Task { @MainActor in Style.shared.apply() }
        }
        watch()
    }

    // MARK: Loading

    private func load() {
        if let data = try? Data(contentsOf: Self.settingsURL) {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            if let s = try? decoder.decode(Settings.self, from: data) { settings = s }
        }
        var all = Theme.builtIn
        let extensionThemes = Extensions.load()
        setLanguages(configs: Extensions.loaded.flatMap(\.languages))
        for t in extensionThemes {
            all.removeAll { $0.name == t.name }
            all.append(t)
        }
        // Loose theme files still work (and win over extensions with the same name).
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.themesDir, includingPropertiesForKeys: nil)) ?? []
        for url in files where url.pathExtension == "json" {
            if let data = try? Data(contentsOf: url), let t = try? JSONDecoder().decode(Theme.self, from: data) {
                all.removeAll { $0.name == t.name }
                all.append(t)
            }
        }
        themes = all
    }

    func save() {
        try? FileManager.default.createDirectory(at: Self.configDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(settings) { try? data.write(to: Self.settingsURL, options: .atomic) }
    }

    /// Re-read settings.json and themes/ when they change on disk.
    private func watch() {
        watchers.forEach { $0.cancel() }
        watchers = []
        try? FileManager.default.createDirectory(at: Self.themesDir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: Self.settingsURL.path) { save() }
        try? FileManager.default.createDirectory(at: Extensions.userDir, withIntermediateDirectories: true)
        for url in [Self.configDir, Self.themesDir, Extensions.userDir] {
            let fd = open(url.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
            source.setEventHandler { Task { @MainActor in Style.shared.reload() } }
            source.setCancelHandler { close(fd) }
            source.resume()
            watchers.append(source)
        }
        // The settings file itself (editors save by rename, so directory events cover most cases).
        let fd = open(Self.settingsURL.path, O_EVTONLY)
        if fd >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
            source.setEventHandler { Task { @MainActor in Style.shared.reload(); Style.shared.watch() } }
            source.setCancelHandler { close(fd) }
            source.resume()
            watchers.append(source)
        }
    }

    private func reload() {
        let before = (settings, themes.map(\.name), theme.colors)
        load()
        if before.0 != settings || before.1 != themes.map(\.name) || before.2 != theme.colors { apply() }
    }

    // MARK: Applying

    func update(_ change: (inout Settings) -> Void) {
        change(&settings)
        save()
        apply()
    }

    var fontFamily: String { settings.fontFamily.isEmpty ? Self.defaultFontFamily : settings.fontFamily }

    var font: NSFont { font(weight: 5) }

    /// `weight` on NSFontManager's 0–15 scale: 5 regular, 8 semibold, 9 bold.
    func font(weight: Int, sizeDelta: CGFloat = 0) -> NSFont {
        let size = CGFloat(max(8, min(32, settings.fontSize))) + sizeDelta
        let base = fontFamily == Self.systemFontFamily ? nil
            : NSFontManager.shared.font(withFamily: fontFamily, traits: [], weight: weight, size: size)
        let f = base ?? .monospacedSystemFont(ofSize: size, weight: weight >= 8 ? .semibold : .regular)
        guard !settings.fontLigatures else { return f }
        let off: [[NSFontDescriptor.FeatureKey: Int]] = [
            [.typeIdentifier: kLigaturesType, .selectorIdentifier: kCommonLigaturesOffSelector],
            [.typeIdentifier: kContextualAlternatesType, .selectorIdentifier: kContextualAlternatesOffSelector],
        ]
        return NSFont(descriptor: f.fontDescriptor.addingAttributes([.featureSettings: off]), size: size) ?? f
    }

    /// Monospace families for the Font menu: the default first, then the rest A–Z.
    /// Built in the background at launch: loading every font to ask "fixed
    /// pitch?" took ~3 s and stalled the first menu open (and first ⌘-shortcut).
    private(set) var monospaceFamilies: [String] = [Style.defaultFontFamily, Style.systemFontFamily]

    private func loadMonospaceFamilies() {
        DispatchQueue.global(qos: .utility).async {
            let fm = NSFontManager.shared
            // Each family's members carry their traits; no font needs to be loaded.
            let mono = fm.availableFontFamilies.filter { family in
                !family.hasPrefix(".") && (fm.availableMembers(ofFontFamily: family) ?? []).contains { member in
                    ((member.count > 3 ? member[3] as? UInt : nil) ?? 0) & UInt(NSFontTraitMask.fixedPitchFontMask.rawValue) != 0
                }
            }
            let list = [Style.defaultFontFamily, Style.systemFontFamily] + Set(mono).subtracting([Style.defaultFontFamily]).sorted()
            DispatchQueue.main.async { Style.shared.monospaceFamilies = list }
        }
    }

    private func apply() {
        GitHub.configuredPath = settings.ghPath
        switch settings.appearance {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let wanted = dark ? settings.themeDark : settings.themeLight
        theme = themes.first { $0.name == wanted && $0.isDark == dark } ?? (dark ? Theme.dark : Theme.light)
        DiffStyle.apply(theme: theme, font: font, headerFont: font(weight: 8, sizeDelta: -0.5))
        NotificationCenter.default.post(name: .styleChanged, object: nil)
    }

    /// Themes matching the current light/dark mode.
    var themesForCurrentMode: [Theme] { themes.filter { $0.isDark == theme.isDark } }

    func selectTheme(_ name: String) {
        guard let t = themes.first(where: { $0.name == name }) else { return }
        update { if t.isDark { $0.themeDark = name } else { $0.themeLight = name } }
    }
}
