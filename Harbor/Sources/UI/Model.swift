import AppKit
import Observation
import ServiceManagement
import SwiftUI

enum StopState: Equatable {
    case stopping(since: Date)   // SIGTERM sent, waiting up to 3 s
    case gone                    // the process exited, the row is about to collapse
    case stuck                   // survived SIGTERM: offer Force quit
}

struct Stat: Equatable, Sendable {
    var cpu: Double?             // nil until the second reading
    var bytes: UInt64
}

/// Scans and samples off the main actor. Actor isolation keeps the CPU tracker single-threaded.
actor Engine {
    struct Snapshot: Sendable {
        let rows: [PortRow]
        let stats: [Int32: Stat]
        let ms: Double
        let onMain: Bool
        var lastActive: [Int32: TimeInterval] = [:]
        var conflicts: [Conflict] = []
    }
    private var tracker = CpuTracker()
    private var idle = IdleTracker()
    private var silentSince: [Int32: Date] = [:]
    private var checkouts: [String: (cwd: String, until: ContinuousClock.Instant, value: Checkout?)] = [:]

    func currentListeners(showDocker: Bool) async -> [PortRow] {
        let rows = Scanner.scan()
        var native = rows.filter { !Docker.isProxy($0) }
        let now = ContinuousClock.now
        let servers = native.filter { Classifier.classify($0) == .dev && $0.started != nil }
        let owners = Set(servers.map(\.ownerKey))
        checkouts = checkouts.filter { owners.contains($0.key) && $0.value.until > now }
        await withTaskGroup(of: (PortRow, Checkout?).self) { group in
            var pending = Set<String>()
            for row in servers where checkouts[row.ownerKey]?.cwd != row.cwd && pending.insert(row.ownerKey).inserted {
                group.addTask { (row, Checkout.lookup(pid: row.pid)) }
            }
            for await (row, value) in group { checkouts[row.ownerKey] = (row.cwd, now + .seconds(30), value) }
        }
        for index in native.indices { native[index].checkout = checkouts[native[index].ownerKey]?.value }
        guard showDocker else { return native }
        return native + (await Docker.published(hasProxy: native.count != rows.count))
    }

    func tick(showDocker: Bool) async -> Snapshot {
        let t0 = Sampler.nowNs()
        let rows = await currentListeners(showDocker: showDocker)
        var usage: [Int32: ProcUsage] = [:]
        for pid in Set(rows.map(\.pid)) where pid > 0 { if let u = Sampler.read(pid) { usage[pid] = u } }
        let cpu = tracker.update(usage, at: Sampler.nowNs())
        let stats = usage.reduce(into: [Int32: Stat]()) { $0[$1.key] = Stat(cpu: cpu[$1.key], bytes: $1.value.footprint) }
        let now = Date()
        var samples: [Int32: (cpu: Double?, conns: Int)] = [:]
        for (pid, st) in stats {
            samples[pid] = (st.cpu, Scanner.establishedCount(pid, ports: Set(rows.filter { $0.pid == pid }.map(\.port))))
        }
        let lastActive = idle.update(samples)
        // a dev process without a listening port for more than 5 s that asks for a port someone else holds
        let silent = Scanner.silentDev(excluding: Set(rows.map(\.pid)))
        silentSince = silentSince.filter { k, _ in silent.contains { $0.pid == k } }
        for s in silent where silentSince[s.pid] == nil { silentSince[s.pid] = now }
        let waited = silent.filter { now.timeIntervalSince(silentSince[$0.pid] ?? now) > 5 }
        let conflicts = Watch.conflicts(silent: waited, rows: rows, parent: Scanner.parent)
        return Snapshot(rows: rows, stats: stats, ms: Double(Sampler.nowNs() - t0) / 1e6, onMain: pthread_main_np() != 0,
                        lastActive: lastActive, conflicts: conflicts)
    }
}

@MainActor
@Observable
final class HarborModel {
    private(set) var dev: [PortRow] = []
    private(set) var other: [PortRow] = []
    private(set) var stats: [Int32: Stat] = [:]
    private(set) var hasData = false
    /// True while the panel is shown; drives the entrance and the row stagger.
    var shown = false
    /// False until just after the panel opens, so figures count up from 0 and strips grow.
    var counted = false
    /// Berth LEDs with a row index below this are lit (dusk and flicker moments); Int.max = all.
    var ledsLit = Int.max
    /// Bumped on the first panel open of a session: the top hairline lights from the centre.
    var pulse = 0
    var pulsePreview: Double?       // QA: freeze the hairline at this width
    var states: [String: StopState] = [:]
    var confirming: PortRow.ID?
    var confirmAll = false
    var confirmIdle = false
    var showDocker = true {
        didSet {
            if live { UserDefaults.standard.set(showDocker, forKey: "harborShowDocker") }
            if !showDocker {
                conflicts.removeAll { $0.holder.container != nil }
                apply(dev + other)
            }
            refresh()
        }
    }
    var notifyPortTaken = UserDefaults.standard.object(forKey: "harborNotifyPortTaken") as? Bool ?? true {
        didSet { UserDefaults.standard.set(notifyPortTaken, forKey: "harborNotifyPortTaken") }
    }
    /// Hours of idleness before a server counts as idle; 0 = off.
    var idleHours = UserDefaults.standard.object(forKey: "harborIdleHours") as? Int ?? 2 {
        didSet { UserDefaults.standard.set(idleHours, forKey: "harborIdleHours") }
    }
    private(set) var lastActive: [Int32: TimeInterval] = [:]
    private(set) var conflicts: [Conflict] = []
    var dismissed: Set<String> = []
    /// The "port is taken" banner: first conflict that was not dismissed.
    var banner: Conflict? { conflicts.first { !dismissed.contains($0.id) } }
    var showOther = false
    var isOpen = false { didSet { if isOpen != oldValue { restartLoop() } } }
    var launchAtLogin = SMAppService.mainApp.status == .enabled

    @ObservationIgnored var onCount: (Int) -> Void = { _ in }
    @ObservationIgnored var onShowIntro: () -> Void = {}
    @ObservationIgnored var onSettings: () -> Void = {}
    @ObservationIgnored var onHotKey: (KitHotKey?) -> Void = { _ in }
    @ObservationIgnored var onTick: (Engine.Snapshot) -> Void = { _ in }
    @ObservationIgnored private let engine = Engine()
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var busy = false
    @ObservationIgnored private var lastTick = Date.distantPast
    /// Owners that just stopped for good: a scan that began before the stop must not bring their row back.
    @ObservationIgnored private var stopped: [String: Date] = [:]
    private let live: Bool

    init(live: Bool = true) {
        self.live = live; shown = !live; counted = !live
        showDocker = live ? UserDefaults.standard.object(forKey: "harborShowDocker") as? Bool ?? true : true
    }

    /// Dev servers idle for at least the threshold.
    var idleRows: [PortRow] { idleHours == 0 ? [] : dev.filter { idleFor($0) >= Double(idleHours) * 3600 } }
    func idleFor(_ row: PortRow) -> TimeInterval { lastActive[row.pid].map { IdleTracker.elapsed(since: $0) } ?? 0 }

    /// QA only.
    func loadWatch(lastActive: [Int32: TimeInterval], conflicts: [Conflict]) { self.lastActive = lastActive; self.conflicts = conflicts }

    /// Dev servers, not ports: one process on two ports is one server.
    var serverCount: Int { Set(dev.map(\.ownerKey)).count }

    var devMemory: UInt64 { dev.reduce(0) { $0 + (stats[$1.pid]?.bytes ?? 0) } }

    /// QA only: fixed data, no scanning.
    func load(_ rows: [PortRow], stats: [Int32: Stat] = [:]) {
        self.stats = stats
        apply(rows)
    }

    // MARK: refresh

    func start() { restartLoop() }

    /// Dock lights at dusk: berth LEDs switch on one by one down the board.
    func dusk(step: Double = 0.11) {
        ledsLit = 0
        Task {
            for n in 1...max(1, dev.count + 1) {
                try? await Task.sleep(for: .seconds(step))
                ledsLit = n
            }
            ledsLit = Int.max
        }
    }

    /// Every berth LED on, off, on within about 140 ms.
    func flicker() {
        Task {
            for v in [Int.max, 0, Int.max] { ledsLit = v; try? await Task.sleep(for: .milliseconds(46)) }
            ledsLit = Int.max
        }
    }

    /// Called when the cursor enters the status item, so data is fresh by the time of the click.
    func prewarm() {
        if Date().timeIntervalSince(lastTick) > 1.5 { refresh() }
    }

    /// Every 2 s while the panel is open (CPU needs the short interval), every 15 s otherwise.
    private func restartLoop() {
        loop?.cancel()
        guard live else { return }
        let open = isOpen
        let interval: Duration = open ? .seconds(2) : .seconds(15)
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshNow()
                try? await Task.sleep(for: interval, tolerance: open ? .milliseconds(200) : .seconds(3))
            }
        }
    }

    func refresh() { Task { await refreshNow() } }

    private func refreshNow() async {
        guard live, !busy else { return }
        busy = true
        let requestedDocker = showDocker
        let snap = await engine.tick(showDocker: requestedDocker)
        busy = false
        guard requestedDocker == showDocker else { refresh(); return }
        lastTick = Date()
        onTick(snap)
        if stats != snap.stats { stats = snap.stats }
        lastActive = snap.lastActive
        if snap.conflicts != conflicts { withAnimation(KitMotion.list) { conflicts = snap.conflicts } }
        apply(snap.rows)
    }

    private func apply(_ rows: [PortRow]) {
        stopped = stopped.filter { Date().timeIntervalSince($0.value) < 4 }
        let kinds = rows.filter { (showDocker || $0.container == nil) && stopped[$0.ownerKey] == nil }.map { ($0, Classifier.classify($0)) }
        let newDev = kinds.filter { $0.1 == .dev }.map(\.0).sorted { $0.port < $1.port }
        let newOther = kinds.filter { $0.1 == .other }.map(\.0).sorted { $0.name.lowercased() < $1.name.lowercased() }
        let ids = { (r: [PortRow]) in r.map(\.id) }
        if ids(newDev) != ids(dev) || ids(newOther) != ids(other) {
            withAnimation(KitMotion.list) { dev = newDev; other = newOther }
        } else if newDev != dev || newOther != other {
            dev = newDev; other = newOther
        }
        hasData = true
        let alive = Set((dev + other).map(\.ownerKey))
        let kept = states.filter { alive.contains($0.key) }
        if kept != states { states = kept }
        if let confirming, !other.contains(where: { $0.id == confirming }),
           !dev.contains(where: { $0.id == confirming && ports(of: $0).count > 1 }) { self.confirming = nil }
        if dev.isEmpty { confirmAll = false }
        if idleRows.isEmpty { confirmIdle = false }
        onCount(serverCount)
    }

    // MARK: actions (each one runs only from a click)

    func open(_ row: PortRow) { NSWorkspace.shared.open(row.url) }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func reveal(_ row: PortRow) {
        guard !row.cwd.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: row.cwd)])
    }

    private func ports(of row: PortRow) -> [Int] {
        Set((dev + other).filter { $0.ownerKey == row.ownerKey }.map(\.port)).sorted()
    }

    func alsoPorts(_ row: PortRow) -> String? {
        let others = ports(of: row).filter { $0 != row.port }
        return others.isEmpty ? nil : "Also " + others.map(String.init).joined(separator: ", ")
    }

    func stopPrompt(_ row: PortRow) -> String? {
        let ports = ports(of: row).map(String.init)
        guard ports.count > 1 else { return nil }
        let tool = row.tool
        return "Stop \(tool)? It serves \(ports.formatted(.list(type: .and).locale(Locale(identifier: "en_US"))))."
    }

    func requestStop(_ row: PortRow, isOther: Bool) {
        if isOther || ports(of: row).count > 1 { confirming = row.id; return }
        stop(row)
    }

    func requestNoticeStop(holderKey: String) async {
        guard live else { return }
        apply(await engine.currentListeners(showDocker: showDocker))
        guard let row = (dev + other).first(where: { PortNotice.key(for: $0) == holderKey }) else { return }
        let isOther = other.contains(row)
        if isOther { showOther = true }
        requestStop(row, isOther: isOther)
    }

    /// Drops every pending question ("Stop all?", the row prompt). The panel does this on every close.
    func dismissPrompts() { confirming = nil; confirmAll = false; confirmIdle = false }

    /// Escape: closes an open question first and says so; false means nothing was open, so the panel closes.
    func escape() -> Bool {
        guard confirming != nil || confirmAll || confirmIdle else { return false }
        withAnimation(KitMotion.list) { dismissPrompts() }
        return true
    }

    var stoppingCount: Int { Set(states.compactMap { if case .stopping = $0.value { $0.key } else { nil } }).count }

    func stop(_ row: PortRow, sound: Bool = true) {
        confirming = nil
        if sound { KitSound.play(.thunk) }
        withAnimation(KitMotion.soft) { states[row.ownerKey] = .stopping(since: Date()) }
        Task {
            switch await Stopper.terminate(row) {
            case .gone:
                states[row.ownerKey] = .gone
                // let the strip finish draining, then collapse the row
                try? await Task.sleep(for: .milliseconds(350))
                withAnimation(KitMotion.list) { removeRows(of: row.ownerKey) }
            case .stuck:
                withAnimation(KitMotion.soft) { states[row.ownerKey] = .stuck }
                KitSound.play(.error)
            case .stale:
                states[row.ownerKey] = nil
            }
            refresh()
        }
    }

    func forceQuit(_ row: PortRow) {
        KitSound.play(.thunk)
        guard Stopper.forceKill(row) else { states[row.ownerKey] = nil; refresh(); return }
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            withAnimation(KitMotion.list) { removeRows(of: row.ownerKey, confirmedGone: !Scanner.isAlive(row.pid)) }
            refresh()
        }
    }

    func stopAllDev() {
        confirmAll = false
        KitSound.play(.thunk)
        for row in dev where states[row.ownerKey] == nil { stop(row, sound: false) }
    }

    func stopIdle() {
        confirmIdle = false
        KitSound.play(.thunk)
        for row in idleRows where states[row.ownerKey] == nil { stop(row, sound: false) }
    }

    /// "Stop copper-shop" on the banner: same stop as the row key, only from a click.
    func stopHolder(_ c: Conflict) {
        guard let row = dev.first(where: { $0.id == c.holder.id }) else { return }
        requestStop(row, isOther: false)
    }

    func removeRows(of owner: String, confirmedGone: Bool = true) {
        if confirmedGone { stopped[owner] = Date() }
        dev.removeAll { $0.ownerKey == owner }
        other.removeAll { $0.ownerKey == owner }
        states[owner] = nil
        onCount(serverCount)
    }

    func setLaunchAtLogin(_ on: Bool) {
        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } } catch {}
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
