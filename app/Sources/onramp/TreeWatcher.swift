import CoreServices
import Foundation

/// Watches a repo's working tree (recursively, via FSEvents) and reports
/// batches of changed paths. Git internals are ignored except HEAD/index/refs,
/// which change what the diff is against (e.g. after a commit).
final class TreeWatcher {
    private var stream: FSEventStreamRef?
    private let root: String
    private let onChange: () -> Void

    init(root: String, onChange: @escaping () -> Void) {
        self.root = (root as NSString).standardizingPath
        self.onChange = onChange
    }

    deinit { stop() }

    func start() {
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<TreeWatcher>.fromOpaque(info).takeUnretainedValue()
            let changed = (unsafeBitCast(paths, to: NSArray.self) as? [String]) ?? []
            if changed.contains(where: watcher.matters) { watcher.onChange() }
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        stream = FSEventStreamCreate(nil, callback, &context, [root] as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.05, flags)
        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func matters(_ path: String) -> Bool {
        guard let range = path.range(of: root) else { return true }
        let rel = path[range.upperBound...].drop { $0 == "/" }
        guard rel.hasPrefix(".git") else { return true }
        return rel == ".git/HEAD" || rel == ".git/index" || rel.hasPrefix(".git/refs/")
    }
}
