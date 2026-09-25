import AppKit

/// Things the installed app (PairProgram.app) sets up for you.
@MainActor
enum Installation {
    /// The Claude Code plugin ships inside the app; keep the copy agents install from current.
    static func syncIntegrations() {
        guard let bundled = Bundle.main.resourceURL?.appendingPathComponent("integrations"),
              FileManager.default.fileExists(atPath: bundled.path) else { return } // a development build: install.sh does this
        let dest = pairprogramConfigDir.appendingPathComponent("integrations")
        try? FileManager.default.createDirectory(at: pairprogramConfigDir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.copyItem(at: bundled, to: dest)
    }

    /// `pair` (and the older `pairprogram`) in ~/.local/bin, pointing into the app.
    static func installCommandLineTool() {
        let alert = NSAlert()
        guard let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return }
        let bin = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin")
        do {
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            for name in ["pair", "pairprogram"] {
                let link = bin.appendingPathComponent(name)
                try? FileManager.default.removeItem(at: link)
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: exe)
            }
            let onPath = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").contains { $0 == bin.path } || shellPathHas(bin.path)
            alert.messageText = "Installed the pair command"
            alert.informativeText = onPath
                ? "Run `pair` in any git repo to review it, or `pair --help` for the agent commands."
                : "It's in ~/.local/bin, which isn't on your PATH yet. Add this line to ~/.zshrc, then open a new terminal:\n\nexport PATH=\"$HOME/.local/bin:$PATH\""
        } catch {
            alert.alertStyle = .warning
            alert.messageText = "Couldn't install the pair command"
            alert.informativeText = error.localizedDescription
        }
        alert.runModal()
    }

    private static func shellPathHas(_ dir: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-ilc", "echo $PATH"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        let path = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return path.split(separator: ":").contains { $0.trimmingCharacters(in: .whitespacesAndNewlines) == dir }
    }
}
