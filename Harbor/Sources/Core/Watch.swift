import Darwin
import Foundation

/// A dev-looking process of the user that has no listening port (yet).
struct Silent: Hashable, Sendable {
    let pid: Int32
    let name: String
    let args: String
    let env: [String]
}

/// "Port 3000 is taken by copper-shop": `silent` wants `port`, `holder` already listens on it.
struct Conflict: Hashable, Sendable, Identifiable {
    let port: Int
    let holder: PortRow
    let wanter: Int32
    var id: String { "\(wanter):\(port)" }
    var holderName: String { holder.project.isEmpty ? holder.name : holder.project }
}

struct PortNotice {
    let title: String
    let holderKey: String?

    init(_ conflict: Conflict) {
        let row = conflict.holder
        let tool = row.tool
        title = "Port \(conflict.port) is taken by \(tool)" + (row.project.isEmpty ? "" : " (\(row.project))")
        holderKey = Self.key(for: row)
    }

    static func key(for row: PortRow) -> String? {
        if row.container != nil { return row.id }
        guard let started = row.started, Classifier.classify(row) != .hidden else { return nil }
        return "\(row.id):\(started.timeIntervalSince1970):\(row.exePath)"
    }
}

struct PortNoticeDebounce {
    var lastSent: [String: TimeInterval] = [:]

    func allows(_ port: Int, now: TimeInterval) -> Bool {
        lastSent[String(port)].map { now - $0 >= 600 } ?? true
    }

    /// Drops entries past the cooldown; the app calls this before every check, so a saved file never grows.
    mutating func prune(now: TimeInterval) { lastSent = lastSent.filter { now - $0.value < 600 } }

    mutating func record(_ port: Int, now: TimeInterval) {
        lastSent = lastSent.filter { now - $0.value < 600 }
        lastSent[String(port)] = now
    }
}

enum Watch {
    /// Port a dev command asks for: `--port N`, `--port=N`, `-p N`, `-pN`, `PORT=N` in the environment,
    /// else the vite (5173) or next (3000) default. nil when nothing says.
    static func wantedPort(args: String, env: [String]) -> Int? {
        let toks = args.split(separator: " ").map(String.init)
        for (i, t) in toks.enumerated() {
            if t.hasPrefix("--port="), let n = Int(t.dropFirst(7)) { return n }
            if (t == "--port" || t == "-p"), i + 1 < toks.count, let n = Int(toks[i + 1]) { return n }
            if t.hasPrefix("-p"), t.count > 2, let n = Int(t.dropFirst(2)) { return n }
        }
        if let e = env.first(where: { $0.hasPrefix("PORT=") }), let n = Int(e.dropFirst(5)) { return n }
        let names = Set(toks.map { ($0 as NSString).lastPathComponent })
        if names.contains("vite") { return 5173 }
        if names.contains("next") { return 3000 }
        return nil
    }

    /// Conflicts for processes that have been silent long enough. A holder that is the wanter's own child
    /// (npm -> vite) or parent is not a conflict.
    static func conflicts(silent: [Silent], rows: [PortRow], parent: (Int32) -> Int32) -> [Conflict] {
        func ancestors(_ pid: Int32) -> Set<Int32> {
            guard pid > 0 else { return [] }
            var out = Set<Int32>(), p = parent(pid)
            while p > 1, out.insert(p).inserted { p = parent(p) }
            return out
        }
        var found: [Conflict] = []
        for s in silent {
            guard let port = wantedPort(args: s.args, env: s.env),
                  let holder = rows.first(where: { $0.port == port && $0.pid != s.pid }),
                  !ancestors(holder.pid).contains(s.pid), !ancestors(s.pid).contains(holder.pid) else { continue }
            found.append(Conflict(port: port, holder: holder, wanter: s.pid))
        }
        return found
    }
}

/// How long each server has done nothing: CPU under 1% and no new TCP connection accepted.
struct IdleTracker {
    static let cpuLimit = 1.0
    private var lastActive: [Int32: TimeInterval] = [:]
    private var lastConns: [Int32: Int] = [:]

    static func elapsed(since lastActive: TimeInterval, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> TimeInterval {
        now - lastActive
    }

    /// `samples`: pid to (cpu %, established connections on its listening ports). Returns last-active time per pid;
    /// a pid's idle time is `now - lastActive`. First sight counts as active so a fresh Harbor never claims idleness.
    mutating func update(_ samples: [Int32: (cpu: Double?, conns: Int)], now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> [Int32: TimeInterval] {
        var active: [Int32: TimeInterval] = [:], conns: [Int32: Int] = [:]
        for (pid, s) in samples {
            var last = lastActive[pid] ?? now
            if let c = s.cpu, c >= Self.cpuLimit { last = now }
            if let prev = lastConns[pid], s.conns > prev { last = now }
            active[pid] = last; conns[pid] = s.conns
        }
        lastActive = active; lastConns = conns
        return active
    }
}

extension Scanner {
    /// Established TCP connections whose local port is one of `ports`, among this process's own sockets
    /// (a server holds the accepted ends, so a new client shows up as one more here).
    static func establishedCount(_ pid: Int32, ports: Set<Int>) -> Int {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return 0 }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.stride + 4)
        let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * MemoryLayout<proc_fdinfo>.stride))
        guard got > 0 else { return 0 }
        var n = 0
        for fd in fds.prefix(Int(got) / MemoryLayout<proc_fdinfo>.stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var si = socket_fdinfo()
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &si, Int32(MemoryLayout<socket_fdinfo>.size)) == Int32(MemoryLayout<socket_fdinfo>.size),
                  si.psi.soi_kind == Int32(SOCKINFO_TCP), si.psi.soi_proto.pri_tcp.tcpsi_state == Int32(TSI_S_ESTABLISHED) else { continue }
            if ports.contains(Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: si.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport)))) { n += 1 }
        }
        return n
    }

    static func parent(_ pid: Int32) -> Int32 {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { return 0 }
        return Int32(info.pbi_ppid)
    }

    /// Environment strings after the arguments in KERN_PROCARGS2 (readable for our own processes only).
    static func parseProcEnv(_ b: [UInt8]) -> [String] {
        guard b.count > 4 else { return [] }
        let argc = Int(b[0]) | Int(b[1]) << 8 | Int(b[2]) << 16 | Int(b[3]) << 24
        var i = 4
        while i < b.count, b[i] != 0 { i += 1 }
        while i < b.count, b[i] == 0 { i += 1 }
        var skipped = 0
        while skipped < argc, i < b.count {
            while i < b.count, b[i] != 0 { i += 1 }
            i += 1; skipped += 1
        }
        var out: [String] = []
        while i < b.count {
            var j = i
            while j < b.count, b[j] != 0 { j += 1 }
            if j > i { out.append(String(decoding: b[i..<j], as: UTF8.self)) }
            i = j + 1
        }
        return out
    }

    private static let watched: Set<String> = ["node", "bun", "deno", "tsx", "ts-node", "npm", "pnpm", "yarn", "ruby", "php", "uvicorn", "gunicorn", "flask", "rails", "puma"]

    /// Dev processes of this user that listen on nothing (excluding `listening` pids).
    static func silentDev(excluding listening: Set<Int32>) -> [Silent] {
        let uid = getuid()
        var out: [Silent] = []
        for pid in allPids() where !listening.contains(pid) {
            let path = exePath(pid)
            let name = (path as NSString).lastPathComponent
            guard !path.isEmpty, watched.contains(name.lowercased()) || name.lowercased().hasPrefix("python"), owner(pid) == uid else { continue }
            var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
            var size = 0
            guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { continue }
            var buf = [UInt8](repeating: 0, count: size)
            guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, let line = parseProcArgs(Array(buf.prefix(size))) else { continue }
            out.append(Silent(pid: pid, name: name, args: line, env: parseProcEnv(Array(buf.prefix(size)))))
        }
        return out
    }
}
