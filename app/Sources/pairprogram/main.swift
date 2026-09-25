import AppKit

// pairprogram [repo-path] opens the app; `pairprogram comments|reply|resolve|…` is the agent CLI.
if let status = CLI.run(Array(CommandLine.arguments.dropFirst())) { exit(status) }

let repoPath: String
switch CLI.prepareOpen(Array(CommandLine.arguments.dropFirst())) {
case let .exit(status): exit(status)
case let .run(repo): repoPath = repo
}

MainActor.assumeIsolated { // top-level code runs on the main thread
    let app = NSApplication.shared
    let delegate = AppDelegate(repoPath: repoPath)
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
