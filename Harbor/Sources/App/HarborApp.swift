import AppKit
import Carbon
import SwiftUI
import UserNotifications

/// One borderless panel for the app's whole life; opening it is just `orderFront`.
final class HarborPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    var onCancel: () -> Void = {}
    override func cancelOperation(_ sender: Any?) { onCancel() }
}

@main
@MainActor
final class HarborApp: NSObject, NSApplicationDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = HarborApp()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    private let model = HarborModel()
    private var statusItem: NSStatusItem!
    private var panel: HarborPanel!
    private var host: NSHostingView<HarborView>!
    private var monitor: Any?
    private var menuOpen = false
    private var lastResignClose = Date.distantPast
    private var closing: DispatchWorkItem?
    private let intro = IntroController()
    private lazy var settings = SettingsController(model: model)
    private var openedOnce = false
    private var noticeDebounce = PortNoticeDebounce(lastSent: UserDefaults.standard.dictionary(forKey: "harborPortNoticeTimes") as? [String: TimeInterval] ?? [:])
    private var checkingNotices = false
    private var retryNoticesAfter = Date.distantPast

    func applicationDidFinishLaunching(_ notification: Notification) {
        if QA.runIfAsked() || IntroPreview.runIfAsked() { return }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = StatusImage.make(count: 0)
            button.target = self
            button.action = #selector(toggle)
            button.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        }
        model.onCount = { [weak self] n in self?.statusItem.button?.image = StatusImage.make(count: n) }
        if !Perf.enabled { registerPortNotices() }
        model.onTick = { [weak self] snapshot in
            Perf.tick(snapshot)
            if !Perf.enabled { self?.notifyIfNeeded(snapshot.conflicts) }
        }
        makePanel()
        let register = { (k: KitHotKey?) in
            guard let k else { HotKeys.shared.unregister(1); return }
            HotKeys.shared.register(1, HotKeyPref.carbon(k)) { [weak self] in self?.toggle() }
        }
        register(HotKeyPref.load())
        model.onHotKey = register
        model.onSettings = { [weak self] in self?.hide(); self?.settings.show() }
        model.onShowIntro = { [weak self] in self?.hide(); self?.intro.show() }
        model.start()
        if !IntroController.seen { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in MainActor.assumeIsolated { self?.hide(); self?.intro.show() } } }
        if let button = statusItem.button { Perf.run(button: button) }
    }

    /// Cursor entered the menu bar item: refresh now, so the data is fresh when the click lands.
    @objc func mouseEntered(_ event: NSEvent) { model.prewarm() }

    // MARK: panel

    private func makePanel() {
        panel = HarborPanel(contentRect: NSRect(x: 0, y: 0, width: Layout.width, height: 200),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.onCancel = { [weak self] in
            guard let self, !self.model.escape() else { return }
            self.hide()
        }
        host = NSHostingView(rootView: HarborView(model: model, onHeight: { [weak self] h in self?.resize(to: h) }))
        host.sizingOptions = []
        panel.contentView = host
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.panel.isVisible, self.model.shown, !self.menuOpen else { return }
                self.lastResignClose = Date()
                self.hide()
            }
        }
        NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.menuOpen = true }
        }
        NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.menuOpen = false
                if self.panel.isVisible, self.model.shown, !self.panel.isKeyWindow { self.hide() }
            }
        }
        // Warm up: lay the view tree out once without showing anything.
        host.frame = NSRect(x: 0, y: 0, width: Layout.width, height: 300)
        host.layoutSubtreeIfNeeded()
    }

    /// The panel keeps its top edge and resizes in one 0.28 s ease-out, in step with the content's spring.
    private func resize(to height: CGFloat) {
        guard height > 1, let panel else { return }
        var f = panel.frame
        guard abs(f.height - height) > 0.5 else { return }
        f.origin.y += f.height - height
        f.size.height = height
        if !panel.isVisible || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.setFrame(f, display: false)
        } else {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.28
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                ctx.allowsImplicitAnimation = true
                panel.animator().setFrame(f, display: true)
            }
        }
        panel.invalidateShadow()
    }

    @objc private func toggle() {
        if intro.isShowing { hide(); intro.show(); return }    // never the intro and the panel together
        if panel.isVisible && model.shown { hide(); return }
        if Date().timeIntervalSince(lastResignClose) < 0.25 { return }   // the click that closed it
        show()
    }

    private func show() {
        let t0 = CACurrentMediaTime()
        guard let button = statusItem.button, let bw = button.window else { return }
        model.isOpen = true
        let b = bw.frame
        let screen = bw.screen ?? NSScreen.main
        let vis = screen?.visibleFrame ?? .zero
        let size = panel.frame.size
        let x = min(max(b.midX - size.width / 2, vis.minX + 8), vis.maxX - size.width - 8)
        panel.setFrameOrigin(NSPoint(x: x, y: b.minY - 6 - size.height))
        closing?.cancel()
        model.counted = false
        if !openedOnce { openedOnce = true; model.pulse += 1; model.dusk() }
        panel.orderFrontRegardless()
        panel.makeKey()
        model.shown = true
        panel.displayIfNeeded()
        Perf.openTime((CACurrentMediaTime() - t0) * 1000)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in MainActor.assumeIsolated { if self?.model.shown == true { self?.model.counted = true } } }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
    }

    private func hide() {
        // fade out first (panelOut), then take the window off screen
        model.shown = false
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.panel.orderOut(nil); self?.model.counted = false } }
        closing = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14, execute: work)
        model.isOpen = false
        model.dismissPrompts()
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
    }
}

extension HarborApp: UNUserNotificationCenterDelegate {
    private func registerPortNotices() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let stop = UNNotificationAction(identifier: "stopHolder", title: "Stop it", options: [.destructive])
        let show = UNNotificationAction(identifier: "showPanel", title: "Show", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "portTaken", actions: [stop, show], intentIdentifiers: []),
            UNNotificationCategory(identifier: "portTakenShowOnly", actions: [show], intentIdentifiers: [])
        ])
    }

    private func notifyIfNeeded(_ conflicts: [Conflict]) {
        let now = Date()
        noticeDebounce.prune(now: now.timeIntervalSince1970)
        guard model.notifyPortTaken, !checkingNotices, now >= retryNoticesAfter,
              conflicts.contains(where: { noticeDebounce.allows($0.port, now: now.timeIntervalSince1970) }) else { return }
        checkingNotices = true
        Task {
            defer { checkingNotices = false }
            let center = UNUserNotificationCenter.current()
            do {
                let settings = await center.notificationSettings()
                guard model.notifyPortTaken, !model.conflicts.isEmpty else { return }
                switch settings.authorizationStatus {
                case .notDetermined:
                    guard try await center.requestAuthorization(options: [.alert]) else { retryNoticesAfter = Date().addingTimeInterval(60); return }
                case .authorized, .provisional: break
                default: retryNoticesAfter = Date().addingTimeInterval(60); return
                }
                for conflict in model.conflicts {
                    guard model.notifyPortTaken else { return }
                    let stamp = Date().timeIntervalSince1970
                    guard model.conflicts.contains(conflict), noticeDebounce.allows(conflict.port, now: stamp) else { continue }
                    let notice = PortNotice(conflict), content = UNMutableNotificationContent()
                    content.title = notice.title
                    content.categoryIdentifier = notice.holderKey == nil ? "portTakenShowOnly" : "portTaken"
                    if let key = notice.holderKey { content.userInfo = ["holder": key] }
                    try await center.add(UNNotificationRequest(identifier: "portTaken.\(conflict.port)", content: content, trigger: nil))
                    noticeDebounce.record(conflict.port, now: Date().timeIntervalSince1970)
                    UserDefaults.standard.set(noticeDebounce.lastSent, forKey: "harborPortNoticeTimes")
                }
            } catch { retryNoticesAfter = Date().addingTimeInterval(60) }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        await model.notifyPortTaken ? [.banner] : []
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        switch response.actionIdentifier {
        case "stopHolder":
            guard let key = response.notification.request.content.userInfo["holder"] as? String else { return }
            await model.requestNoticeStop(holderKey: key)
            if await model.confirming != nil { await showNoticePanel() }
        case "showPanel", UNNotificationDefaultActionIdentifier: await showNoticePanel()
        default: break
        }
    }

    private func showNoticePanel() {
        if !panel.isVisible || !model.shown { show() }
    }
}
