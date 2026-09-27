import Foundation

/// Replies you've seen. A thread where an agent spoke last "needs you" until you
/// open it, swipe it read, or Mark All as Read; a newer reply makes it need you again.
enum ReadMarks {
    private static let key = "onramp.readThreads"
    static let changed = Notification.Name("onramp.readMarksChanged")

    /// Thread id → time of the newest entry when you read it.
    private static var marks: [String: UInt64] {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: NSNumber])?.mapValues(\.uint64Value) ?? [:]
    }

    static func isRead(_ t: Thread) -> Bool {
        guard let last = t.entries.last(where: { !$0.pending }) else { return true }
        return (marks[t.id] ?? 0) >= last.createdAt
    }

    static func markRead(_ threads: [Thread]) {
        var m = marks
        var changed = false
        for t in threads {
            guard let last = t.entries.last(where: { !$0.pending })?.createdAt, (m[t.id] ?? 0) < last else { continue }
            m[t.id] = last
            changed = true
        }
        guard changed else { return }
        if m.count > 2000 { // old threads: keep the newest marks
            m = Dictionary(uniqueKeysWithValues: m.sorted { $0.value > $1.value }.prefix(1500).map { ($0.key, $0.value) })
        }
        UserDefaults.standard.set(m.mapValues { NSNumber(value: $0) }, forKey: key)
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.changed, object: nil) }
    }
}

extension Thread {
    /// Open, nobody working on it, and someone else (an agent) spoke last since you looked.
    func waitsOn(_ me: String) -> Bool {
        guard status == .open, source == nil, triage == nil, activeClaim(thread: self) == nil,
              let last = entries.last(where: { !$0.pending }), last.author != me else { return false }
        return !ReadMarks.isRead(self)
    }
}
