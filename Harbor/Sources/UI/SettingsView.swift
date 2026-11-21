import AppKit
import Carbon
import SwiftUI

enum SettingsTab: String, CaseIterable { case general = "General", servers = "Servers", about = "About" }

/// The global hot key, kept in UserDefaults as JSON; default is ⌥⌘H.
enum HotKeyPref {
    static let key = "harborHotKey"
    static let fallback = KitHotKey(keyCode: UInt16(kVK_ANSI_H), modifiers: NSEvent.ModifierFlags([.option, .command]).rawValue, display: "⌥⌘H")

    static func load() -> KitHotKey? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return fallback }
        if data == Data("null".utf8) { return nil }
        return (try? JSONDecoder().decode(KitHotKey.self, from: data)) ?? fallback
    }

    static func save(_ k: KitHotKey?) {
        UserDefaults.standard.set(k.flatMap { try? JSONEncoder().encode($0) } ?? Data("null".utf8), forKey: key)
    }

    static func carbon(_ k: KitHotKey) -> HotKeys.Combo {
        let f = NSEvent.ModifierFlags(rawValue: k.modifiers)
        var m = 0
        if f.contains(.command) { m |= cmdKey }
        if f.contains(.option) { m |= optionKey }
        if f.contains(.control) { m |= controlKey }
        if f.contains(.shift) { m |= shiftKey }
        return .init(keyCode: UInt32(k.keyCode), modifiers: UInt32(m))
    }
}

struct SettingsView: View {
    let model: HarborModel
    @AppStorage("harborSettingsTab") private var tab: SettingsTab = .general
    @State private var hotKey: KitHotKey? = HotKeyPref.load()

    var body: some View {
        KitSettings(title: "Harbor settings", tabs: SettingsTab.allCases.map { ($0, $0.rawValue) }, selection: $tab) { t in
            switch t {
            case .general: general
            case .servers: servers
            case .about: KitAboutView(name: "Harbor", tagline: "Dev servers on your Mac, and a click to stop them.",
                                      repoURL: URL(string: "https://github.com/noterikkirillov8/harbor"))
            }
        }
        .kitAccent(Color(hex: 0x5BD08A))
        .onChange(of: hotKey) { _, k in HotKeyPref.save(k); model.onHotKey(k) }
    }

    @ViewBuilder private var general: some View {
        KitSection {
            KitToggleRow(title: "Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
            KitRow(title: "Open Harbor", detail: "Global shortcut for the panel") { KitHotKeyField(hotKey: $hotKey) }
            KitRow(title: "Intro") { Button("Show intro") { model.onShowIntro() }.buttonStyle(.kitSecondary) }
        }
        KitSoundSection()
    }

    @ViewBuilder private var servers: some View {
        KitSection(title: "Containers") {
            KitToggleRow(title: "Show Docker containers", isOn: Binding(get: { model.showDocker }, set: { model.showDocker = $0 }))
        }
        KitSection(title: "Port conflicts") {
            KitToggleRow(title: "Notify when a port is taken", isOn: Binding(get: { model.notifyPortTaken }, set: { model.notifyPortTaken = $0 }))
        }
        KitSection(title: "Idle servers", footer: "A server is idle when its CPU stays under 1% and it accepts no new connections.") {
            KitRow(title: "Mark as idle after") {
                KitSegmented(selection: Binding(get: { model.idleHours }, set: { model.idleHours = $0 }),
                             options: [(1, "1 h"), (2, "2 h"), (4, "4 h"), (0, "Off")]).frame(width: 220)
            }
        }
    }
}

/// One Settings window for the app's life; created on first use, entrance from the centre.
@MainActor
final class SettingsController {
    private var window: NSWindow?
    let model: HarborModel
    init(model: HarborModel) { self.model = model }

    func show() {
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 560), styleMask: [.titled, .closable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isReleasedWhenClosed = false
        w.backgroundColor = NSColor(KitColor.window)
        w.contentView = NSHostingView(rootView: SettingsView(model: model))
        w.center()
        window = w
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
    }
}
