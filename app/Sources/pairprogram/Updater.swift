import AppKit
import OSLog

private let log = Logger(subsystem: "com.timwheeler.pairprogram", category: "Updater")

/// Updates from GitHub Releases, the same way Stoplight does: find the
/// latest release's notarized zip, download it, check it with Gatekeeper and
/// that it's really Onramp, swap the bundle in place, relaunch.
@MainActor
final class Updater {
    static let shared = Updater()

    struct Release: Equatable {
        let version: String
        let zipURL: URL
        let pageURL: URL
    }

    enum State: Equatable { case idle, checking, upToDate, available, downloading, installing, failed(String) }

    static let repo = "timmywheels/pairprogram"
    static let checkInterval: TimeInterval = 6 * 60 * 60

    private(set) var latest: Release?
    private(set) var state: State = .idle { didSet { NotificationCenter.default.post(name: .updaterChanged, object: nil) } }
    private var lastCheck: Date?
    private var timer: Timer?

    var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }
    var updateAvailable: Bool { latest.map { Self.isNewer($0.version, than: currentVersion) } ?? false }
    /// Only the installed app updates itself (a development build has no bundle to replace).
    var canUpdate: Bool { Bundle.main.bundleIdentifier == CLI.bundleID }

    /// Check now, then every 6 hours.
    func start() {
        let env = ProcessInfo.processInfo.environment
        if env["PP_UPDATE_TEST"] != nil { // tests: check and install, then quit
            Task {
                await check()
                FileHandle.standardError.write("[update] current \(currentVersion), latest \(latest?.version ?? "?"), state \(state)\n".data(using: .utf8)!)
                await install()
                FileHandle.standardError.write("[update] after install: \(state)\n".data(using: .utf8)!)
                NSApp.terminate(nil)
            }
            return
        }
        guard canUpdate, env["PP_SELFTEST"] == nil else { return }
        Task { await check() }
        timer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { _ in
            Task { @MainActor in await Updater.shared.checkIfDue() }
        }
    }

    func checkIfDue() async {
        if let last = lastCheck, Date.now.timeIntervalSince(last) < Self.checkInterval { return }
        await check()
    }

    func check() async {
        state = .checking
        defer { lastCheck = .now }
        do {
            var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            req.setValue("Onramp/\(currentVersion)", forHTTPHeaderField: "User-Agent")
            let (data, _) = try await URLSession.shared.data(for: req)
            struct R: Decodable {
                struct Asset: Decodable { let name: String; let browser_download_url: URL }
                let tag_name: String
                let html_url: URL
                let assets: [Asset]
            }
            let r = try JSONDecoder().decode(R.self, from: data)
            guard let zip = r.assets.first(where: { $0.name.hasSuffix(".zip") }) else { throw Err.noAsset }
            let version = r.tag_name.hasPrefix("v") ? String(r.tag_name.dropFirst()) : r.tag_name
            latest = Release(version: version, zipURL: zip.browser_download_url, pageURL: r.html_url)
            state = updateAvailable ? .available : .upToDate
        } catch {
            log.error("check failed: \(String(describing: error), privacy: .public)")
            state = .failed("Couldn't check for updates")
        }
    }

    /// Download → verify → replace → relaunch.
    func install() async {
        guard let release = latest, updateAvailable, canUpdate else { return }
        state = .downloading
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("onramp-update-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            let (file, _) = try await URLSession.shared.download(from: release.zipURL)
            let zip = tmp.appendingPathComponent("Onramp.zip")
            try FileManager.default.moveItem(at: file, to: zip)

            state = .installing
            try run("/usr/bin/ditto", "-x", "-k", zip.path, tmp.path)
            // Onramp.app (or Onramp.app, from before the rename).
            guard let newApp = ["Onramp.app", "Onramp.app"].map({ tmp.appendingPathComponent($0) })
                .first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { throw Err.badArchive }

            // Refuse anything Gatekeeper wouldn't launch, and anything that isn't us.
            try run("/usr/sbin/spctl", "--assess", "--type", "execute", newApp.path)
            guard Bundle(url: newApp)?.bundleIdentifier == Bundle.main.bundleIdentifier else { throw Err.wrongBundle }

            let current = Bundle.main.bundleURL
            // Trash the running bundle (allowed: the binary stays mapped), then move the new one in.
            try FileManager.default.trashItem(at: current, resultingItemURL: nil)
            try FileManager.default.moveItem(at: newApp, to: current)
            try? FileManager.default.removeItem(at: tmp)
            log.notice("installed \(release.version, privacy: .public); relaunching")
            if ProcessInfo.processInfo.environment["PP_UPDATE_NO_RELAUNCH"] != nil { state = .upToDate; return } // tests
            relaunch(current)
        } catch {
            log.error("install failed: \(String(describing: error), privacy: .public)")
            try? FileManager.default.removeItem(at: tmp)
            state = .failed(error.localizedDescription)
        }
    }

    /// The menu item: check, then offer to install (or say you're current).
    func checkInteractively() {
        Task {
            await check()
            let alert = NSAlert()
            switch state {
            case .available:
                guard let latest else { return }
                alert.messageText = "Onramp \(latest.version) is available"
                alert.informativeText = "You have \(currentVersion). It installs in a few seconds and relaunches."
                alert.addButton(withTitle: "Install and Relaunch")
                alert.addButton(withTitle: "Release Notes")
                alert.addButton(withTitle: "Later")
                switch alert.runModal() {
                case .alertFirstButtonReturn: await confirmedInstall()
                case .alertSecondButtonReturn: NSWorkspace.shared.open(latest.pageURL)
                default: break
                }
            case .upToDate:
                alert.messageText = "Onramp is up to date"
                alert.informativeText = "You have the latest version, \(currentVersion)."
                alert.runModal()
            case let .failed(message):
                alert.alertStyle = .warning
                alert.messageText = message
                alert.informativeText = "Check your connection, or download the latest release from GitHub."
                alert.runModal()
            default: break
            }
        }
    }

    /// Install, unless a window has unsaved edits.
    func confirmedInstall() async {
        if (NSApp.delegate as? AppDelegate)?.hasUnsavedEdits == true {
            let alert = NSAlert()
            alert.messageText = "Save your edits first"
            alert.informativeText = "A file has unsaved changes (⌘S), so the update would lose them."
            alert.runModal()
            return
        }
        await install()
        if case let .failed(message) = state {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "The update wasn't installed"
            alert.informativeText = message
            alert.runModal()
        }
    }

    private func relaunch(_ app: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"\(app.path)\""]
        try? p.run()
        NSApp.terminate(nil)
    }

    private func run(_ exe: String, _ args: String...) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw Err.command(exe, p.terminationStatus) }
    }

    enum Err: LocalizedError {
        case noAsset, badArchive, wrongBundle, command(String, Int32)
        var errorDescription: String? {
            switch self {
            case .noAsset: "The release has no zip to install"
            case .badArchive: "The download didn't contain the app"
            case .wrongBundle: "The download isn't Onramp (different bundle identifier)"
            case let .command(c, code): "\(URL(fileURLWithPath: c).lastPathComponent) failed (\(code)). The update was not installed."
            }
        }
    }

    /// Numeric dotted compare. "0.10.0" > "0.9.1".
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let (x, y) = (i < pa.count ? pa[i] : 0, i < pb.count ? pb[i] : 0)
            if x != y { return x > y }
        }
        return false
    }
}

extension Notification.Name {
    /// The updater's state changed (the status bar shows "Update to …").
    static let updaterChanged = Notification.Name("pairprogram.updaterChanged")
}
