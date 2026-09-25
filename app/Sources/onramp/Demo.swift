import AppKit

/// ONRAMP_DEMO=1: a hands-off tour for screen recordings (scripts/demo-big.sh).
/// Waits for you to start recording, glides from the first file to the last,
/// then jumps around through the file tree.
@MainActor
enum Demo {
    nonisolated static var isOn: Bool { ProcessInfo.processInfo.environment["ONRAMP_DEMO"] != nil }
    private static var started = false

    static func run(review: ReviewView) {
        guard isOn, !started, let window = review.window else { return }
        started = true
        // A recording-friendly size, centred.
        window.setContentSize(NSSize(width: 1440, height: 900))
        window.center()
        let scroll = review.scrollView
        Task { @MainActor in
            let say = { (s: String) in FileHandle.standardError.write("[demo] \(s)\n".data(using: .utf8)!) }
            say("start recording now (⌘⇧5 → Record Selected Window); the tour begins in 4 s")
            try? await Task.sleep(nanoseconds: 4_000_000_000)

            // 1. Top to bottom in 12 s, easing in and out: readable at both ends, flat out in the middle.
            let bottom = max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentSize.height)
            let (frames, worst) = await glide(scroll, from: 0, to: bottom, seconds: 12)
            say(String(format: "glided %.0fpt in %d frames; slowest frame %.1f ms", bottom, frames, worst))
            try? await Task.sleep(nanoseconds: 1_000_000_000)

            // 2. Jump around like clicking files in the tree.
            let files = review.document.files.count
            for fraction in [0.35, 0.8, 0.12, 0.6, 0.02] {
                review.document.scrollToFile(Int(Double(files - 1) * fraction))
                try? await Task.sleep(nanoseconds: 1_100_000_000)
            }
            say("done: stop recording")
            if ProcessInfo.processInfo.environment["ONRAMP_SELFTEST"] != nil { NSApp.terminate(nil) } // dry run
        }
    }

    /// Scroll at display rate (120 Hz) with an ease-in-out curve.
    private static func glide(_ scroll: NSScrollView, from: CGFloat, to: CGFloat, seconds: Double) async -> (frames: Int, worstMs: Double) {
        let start = CACurrentMediaTime()
        var frames = 0, worst = 0.0
        while true {
            let f0 = CACurrentMediaTime()
            let t = min(1, (CACurrentMediaTime() - start) / seconds)
            let eased = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
            scroll.contentView.scroll(to: NSPoint(x: 0, y: from + (to - from) * eased))
            scroll.reflectScrolledClipView(scroll.contentView)
            scroll.window?.displayIfNeeded()
            frames += 1
            worst = max(worst, (CACurrentMediaTime() - f0) * 1000)
            if t >= 1 { return (frames, worst) }
            try? await Task.sleep(nanoseconds: 8_333_000)
        }
    }
}
