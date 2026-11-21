import AppKit

/// `Harbor -perf`: drives the real status item and prints the numbers the speed contract asks for.
@MainActor
enum Perf {
    static let enabled = CommandLine.arguments.contains("-perf")
    static var opens: [Double] = []
    static var scans: [Double] = []
    static var scanOnMain = false
    private static var worstGap = 0.0

    static func openTime(_ ms: Double) {
        guard enabled else { return }
        opens.append(ms)
        print(String(format: "open: %.1f ms (click action to panel drawn)", ms))
    }

    static func tick(_ s: Engine.Snapshot) {
        guard enabled else { return }
        scans.append(s.ms)
        scanOnMain = scanOnMain || s.onMain
        print(String(format: "refresh: %.1f ms, %d rows, on main: %@", s.ms, s.rows.count, s.onMain ? "YES" : "no"))
    }

    /// Opens and closes the panel 12 times through the status button, then prints a summary.
    static func run(button: NSStatusBarButton) {
        guard enabled else { return }
        var last = CACurrentMediaTime()
        let watchdog = Timer.scheduledTimer(withTimeInterval: 0.008, repeats: true) { _ in
            MainActor.assumeIsolated {
                let now = CACurrentMediaTime()
                worstGap = max(worstGap, now - last)
                last = now
            }
        }
        Task {
            try? await Task.sleep(for: .seconds(2))
            for _ in 0..<12 {
                button.performClick(nil); try? await Task.sleep(for: .milliseconds(2300))
                button.performClick(nil); try? await Task.sleep(for: .milliseconds(400))
            }
            watchdog.invalidate()
            let o = opens.sorted(), sc = scans.sorted()
            func med(_ a: [Double]) -> Double { a.isEmpty ? 0 : a[a.count / 2] }
            print(String(format: "SUMMARY open median %.1f ms, max %.1f ms; refresh median %.1f ms, max %.1f ms; scan on main: %@; longest main-thread stall %.0f ms",
                         med(o), o.last ?? 0, med(sc), sc.last ?? 0, scanOnMain ? "YES" : "never", worstGap * 1000))
            NSApp.terminate(nil)
        }
    }
}
