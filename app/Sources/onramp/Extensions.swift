import AppKit
import CoreText

/// Loads extensions (folders with an `extension.toml`, parsed by the Rust core)
/// from the app's built-in folder and ~/.config/onramp/extensions, and
/// applies what they contribute: fonts are registered for this process,
/// themes are handed to `Style`.
@MainActor
enum Extensions {
    static let userDir = Style.configDir.appendingPathComponent("extensions")

    /// Shipped inside the app's resource bundle (SwiftPM `resources: [.copy("Extensions")]`).
    /// Found next to the real executable, so the ~/.local/bin symlink works too.
    static var builtinDir: URL? { resource("Extensions") }

    /// A file shipped in the app's resource bundle, if present.
    static func resource(_ name: String) -> URL? {
        // In Onramp.app the resources sit in Contents/Resources (see scripts/package.sh).
        if Bundle.main.bundleIdentifier != nil, let url = Bundle.main.resourceURL?.appendingPathComponent(name),
           FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        guard let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
        let bundle = exe.deletingLastPathComponent().appendingPathComponent("onramp_onramp.bundle")
        let root = Bundle(url: bundle)?.resourceURL ?? bundle
        let url = root.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private(set) static var loaded: [Extension] = []
    private(set) static var problems: [ExtensionProblem] = []
    private static var registeredFonts: Set<String> = []

    static func scan() -> ExtensionScan {
        scanExtensions(roots: [builtinDir?.path ?? "", userDir.path])
    }

    /// Re-scan; registers any new fonts and returns every theme extensions provide.
    static func load() -> [Theme] {
        let result = scan()
        loaded = result.extensions
        problems = result.problems
        for p in problems { NSLog("Onramp: extension %@: %@", p.dir, p.message) }

        let fonts = loaded.flatMap(\.fonts).filter { !registeredFonts.contains($0) }
        if !fonts.isEmpty {
            // Process scope: the fonts exist for onramp only, nothing is installed system-wide.
            CTFontManagerRegisterFontURLs(fonts.map { URL(fileURLWithPath: $0) } as CFArray, .process, false, nil)
            registeredFonts.formUnion(fonts)
        }

        return loaded.flatMap(\.themes).compactMap { path in
            guard let data = FileManager.default.contents(atPath: path) else { return nil }
            do {
                return try JSONDecoder().decode(Theme.self, from: data)
            } catch {
                NSLog("Onramp: theme %@: %@", path, "\(error)")
                return nil
            }
        }
    }
}
