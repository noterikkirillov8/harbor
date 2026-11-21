import AppKit
import SwiftUI

/// `Harbor -qa <dir>`: renders the real views with fake data to PNGs, then quits.
@MainActor
enum QA {
    static var mismatches = 0

    static func runIfAsked() -> Bool {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "-qa"), i + 1 < args.count else { return false }
        let dir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Layout.frozen = true
        NSApp.setActivationPolicy(.prohibited)   // nothing may appear on screen
        let home = NSHomeDirectory()
        func row(_ pid: Int32, _ port: Int, _ name: String, _ cwd: String, _ args: String, _ mins: Double, _ exe: String? = nil) -> PortRow {
            PortRow(pid: pid, port: port, name: name, exePath: exe ?? "/usr/local/bin/\(name)", cwd: cwd.isEmpty ? "/" : home + "/" + cwd,
                    args: args, started: Date().addingTimeInterval(-mins * 60))
        }
        let mb: UInt64 = 1_048_576
        let rows = [
            row(1, 3000, "node", "Projects/copper-shop", "/opt/homebrew/bin/node /Users/e/Projects/copper-shop/node_modules/.bin/next dev -p 3000", 190),
            row(2, 4173, "node", "Projects/atlas-web", "/opt/homebrew/bin/node /Users/e/Projects/atlas-web/node_modules/.bin/vite preview", 42),
            row(3, 5293, "node", "Projects/orbit", "node /Users/e/Projects/orbit/node_modules/.bin/vite --port 5293 --host", 7),
            row(4, 8000, "Python", "Projects/paper-planes", "/Library/Frameworks/Python.framework/Versions/3.13/Resources/Python.app/Contents/MacOS/Python -m http.server 8000", 2400),
            row(6, 7265, "Spotify", "", "/Applications/Spotify.app/Contents/MacOS/Spotify", 900, "/Applications/Spotify.app/Contents/MacOS/Spotify"),
            row(7, 49152, "Claude", "", "/Applications/Claude.app/Contents/MacOS/Claude", 300, "/Applications/Claude.app/Contents/MacOS/Claude"),
            row(8, 5000, "Raycast", "", "/Applications/Raycast.app/Contents/MacOS/Raycast", 6000, "/Applications/Raycast.app/Contents/MacOS/Raycast"),
        ]
        let stats: [Int32: Stat] = [
            1: Stat(cpu: 34, bytes: 312 * mb), 2: Stat(cpu: 4, bytes: 148 * mb), 3: Stat(cpu: 62, bytes: 486 * mb),
            4: Stat(cpu: 0.2, bytes: 24 * mb), 6: Stat(cpu: 7, bytes: 410 * mb), 7: Stat(cpu: 1, bytes: 905 * mb), 8: Stat(cpu: 0, bytes: 188 * mb),
        ]
        func scene(_ name: String, dark: Bool = true, rows: [PortRow] = rows, stats: [Int32: Stat] = stats, forceHover: Int32? = nil, data: Bool = true,
                   tweak: (HarborModel) -> Void = { _ in }) {
            let model = HarborModel(live: false)
            if data { model.load(rows, stats: stats) }
            tweak(model)
            let backdrop = dark ? Color(hex: 0x3A3B3E) : Color(hex: 0xC9C8C3)
            let view = HarborView(model: model, forceHover: forceHover)
            let host = NSHostingView(rootView: view.padding(24).background(backdrop)
                .environment(\.colorScheme, dark ? .dark : .light))
            capture(host, dark: dark, name: name)
            let measured = host.fittingSize.height - 48
            if abs(measured - view.targetHeight) > 0.5 { mismatches += 1; print("height mismatch in \(name): layout \(measured), computed \(view.targetHeight)") }
        }
        /// Off-screen: the hosting view is laid out and drawn without any window.
        func capture(_ host: NSView, dark: Bool, name: String) {
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
        }
        let devOnly = Array(rows.prefix(4))
        var tide = row(1, 4173, "node", "Checkouts/tide/paper-kite", "node vite", 42)
        var coast = row(2, 5173, "node", "Checkouts/coast/paper-kite", "node vite", 7)
        tide.checkout = Checkout(branch: "feature/tide", linked: true)
        coast.checkout = Checkout(branch: "fix/coast", linked: true)
        scene("27-worktree-ports", rows: [tide, coast])
        if args.contains("-worktrees-only") { NSApp.terminate(nil); return true }
        scene("01-list")
        let containers = Docker.parse("""
            {"ID":"abcdef012345","Names":"paper-api","Image":"paper-api:1.4","Ports":"0.0.0.0:8080->80/tcp"}
            {"ID":"012345abcdef","Names":"paper-db","Image":"postgres:16","Ports":"127.0.0.1:5432->5432/tcp"}
            """, socket: "/demo/docker.sock")
        scene("26-docker-containers", rows: containers, stats: [:])
        scene("02-hover-keys", forceHover: 3)
        let database = row(5, 5432, "postgres", "Projects/paper-store", "postgres", 18)
        let pair = [rows[1], database]
        scene("24-database-copy", rows: pair, forceHover: database.pid)
        scene("24-web-open", rows: pair, forceHover: rows[1].pid)
        scene("03-other-apps") { $0.showOther = true }
        scene("04-confirm-other") { $0.showOther = true; $0.requestStop(rows[4], isOther: true) }
        let vite = [3000, 3001].map { row(9, $0, "node", "Projects/paper-kite", "node /x/.bin/vite", 12) }
        scene("25-shared-stop-confirm", rows: vite) { $0.requestStop(vite[0], isOther: false) }
        scene("05-stop-all-confirm") { $0.confirmAll = true }
        scene("06-stopping-and-force") {
            $0.states = [rows[0].ownerKey: .stopping(since: Date().addingTimeInterval(-1.4)), rows[1].ownerKey: .stuck]
        }
        for (name, t) in [("06a-stop-start", -0.05), ("06b-stop-middle", -1.5), ("06c-stop-end", -2.95)] {
            scene(name) { $0.states = [rows[0].ownerKey: .stopping(since: Date().addingTimeInterval(t))] }
        }
        scene("06d-stop-gone") { $0.states = [rows[0].ownerKey: .gone] }
        scene("07-empty", rows: Array(rows.suffix(3)))
        scene("08-light", dark: false, forceHover: 3) { $0.showOther = true }
        scene("09-skeleton", data: false)
        scene("10-one-server", rows: [rows[2]], stats: [3: stats[3]!])
        let many = (0..<12).map { i in
            row(Int32(100 + i), 3000 + i * 11, "node", "Projects/app-\(i + 1)", "node /x/node_modules/.bin/vite --port \(3000 + i * 11)", Double(5 + i * 17))
        }
        var manyStats: [Int32: Stat] = [:]
        for (i, r) in many.enumerated() { manyStats[r.pid] = Stat(cpu: Double((i * 29) % 100), bytes: UInt64(60 + i * 53) * mb) }
        scene("11-many-scrolls", rows: many, stats: manyStats)
        scene("16-power-line-middle") { $0.pulsePreview = 0.5 }
        scene("17-dusk-middle") { $0.ledsLit = 2 }
        scene("12-light-list", dark: false)
        scene("13-load-warning", rows: devOnly, stats: [1: Stat(cpu: 96, bytes: 1_400 * mb), 2: Stat(cpu: 82, bytes: 148 * mb), 3: Stat(cpu: 12, bytes: 486 * mb), 4: Stat(cpu: nil, bytes: 24 * mb)])
        let ago = { (h: Double) in ProcessInfo.processInfo.systemUptime - h * 3600 }
        let idle: (HarborModel) -> Void = { $0.loadWatch(lastActive: [1: ago(0), 2: ago(2.5), 3: ago(0), 4: ago(26)], conflicts: []) }
        scene("18-idle-rows", tweak: idle)
        scene("19-idle-confirm") { idle($0); $0.confirmIdle = true }
        let conflict = Conflict(port: 3000, holder: rows[0], wanter: 99)
        scene("21-port-taken") { $0.loadWatch(lastActive: [:], conflicts: [conflict]) }
        scene("22-port-taken-idle-light", dark: false) { idle($0); $0.loadWatch(lastActive: [2: ago(2.5), 4: ago(3)], conflicts: [conflict]) }
        for (n, t) in SettingsTab.allCases.enumerated() {
            UserDefaults.standard.set(t.rawValue, forKey: "harborSettingsTab")
            let host = NSHostingView(rootView: SettingsView(model: HarborModel(live: false)).environment(\.colorScheme, .dark))
            capture(host, dark: true, name: "23-settings-\(n + 1)-\(t.rawValue.lowercased())")
        }
        UserDefaults.standard.set("General", forKey: "harborSettingsTab")
        statusItems(dir)
        print(mismatches == 0 ? "panel heights match layout" : "\(mismatches) height mismatches")
        NSApp.terminate(nil)
        return true
    }

    /// The menu bar image for 0, 3 and 12 servers on a dark and a light bar, at 4x for a close look.
    private static func statusItems(_ dir: URL) {
        let counts = [0, 3, 12]
        let scale: CGFloat = 4
        let tile = NSSize(width: 360 * scale, height: 56 * scale)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(tile.width), pixelsHigh: Int(tile.height), bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        for (half, dark) in [(0, true), (1, false)] {
            let bar = NSRect(x: CGFloat(half) * tile.width / 2, y: 0, width: tile.width / 2, height: tile.height)
            (dark ? NSColor(srgbRed: 0.1, green: 0.1, blue: 0.11, alpha: 1) : NSColor(srgbRed: 0.85, green: 0.85, blue: 0.83, alpha: 1)).setFill()
            bar.fill()
            var x = bar.minX + 28 * scale
            for n in counts {
                let img = StatusImage.make(count: n)
                let tinted = NSImage(size: img.size, flipped: false) { r in
                    img.draw(in: r)
                    (dark ? NSColor.white : NSColor.black).setFill()
                    r.fill(using: .sourceIn)
                    return true
                }
                let r = NSRect(x: x, y: (tile.height - img.size.height * scale) / 2, width: img.size.width * scale, height: img.size.height * scale)
                tinted.draw(in: r)
                x += r.width + 28 * scale
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("14-menu-bar-image.png"))
    }
}
