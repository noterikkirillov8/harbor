import Darwin
import Foundation

/// One listening TCP port and the process that owns it.
struct PortRow: Hashable, Sendable, Identifiable {
    let pid: Int32
    let port: Int
    let name: String      // executable name
    let exePath: String
    let cwd: String
    let args: String      // full command line
    let started: Date?
    var container: Docker.Container? = nil
    var checkout: Checkout? = nil
    var ownerKey: String { container.map { "\($0.socket):\($0.id)" } ?? "\(pid):\(started?.timeIntervalSince1970 ?? 0)" }
    var id: String { "\(ownerKey):\(port)" }

    var url: URL { URL(string: "http://localhost:\(port)")! }
    /// Folder name of the project the process runs from ("" when it runs from /).
    var project: String { cwd == "/" || cwd.isEmpty ? "" : (cwd as NSString).lastPathComponent }
}

enum Scanner {
    /// Listening ports of the current user, read straight from libproc: no subprocess, no root,
    /// safe to call from any background thread (never from the main actor).
    static func scan() -> [PortRow] {
        let uid = getuid()
        var rows: [PortRow] = []
        for pid in allPids() {
            let ports = listeningPorts(pid)
            guard !ports.isEmpty, owner(pid) == uid else { continue }
            let path = exePath(pid)
            guard !path.isEmpty else { continue }     // process went away
            let name = (path as NSString).lastPathComponent
            let line = args(pid) ?? name
            let dir = cwd(pid), start = startTime(pid)
            for port in ports {
                rows.append(PortRow(pid: pid, port: port, name: name, exePath: path, cwd: dir, args: line, started: start))
            }
        }
        return rows
    }

    static func allPids() -> [Int32] {
        let count = proc_listallpids(nil, 0)   // a number of pids, not bytes (newest first)
        guard count > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(count) + 64)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        return got > 0 ? Array(pids.prefix(Int(got))).filter { $0 > 0 } : []
    }

    /// Sorted, unique TCP ports this pid listens on (IPv4 and IPv6 collapse). Empty without access.
    static func listeningPorts(_ pid: Int32) -> [Int] {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return [] }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.stride + 4)
        let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * MemoryLayout<proc_fdinfo>.stride))
        guard got > 0 else { return [] }
        var ports = Set<Int>()
        for fd in fds.prefix(Int(got) / MemoryLayout<proc_fdinfo>.stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var si = socket_fdinfo()
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &si, Int32(MemoryLayout<socket_fdinfo>.size)) == Int32(MemoryLayout<socket_fdinfo>.size),
                  si.psi.soi_kind == Int32(SOCKINFO_TCP), si.psi.soi_proto.pri_tcp.tcpsi_state == Int32(TSI_S_LISTEN) else { continue }
            let port = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: si.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport)))
            if port > 0 { ports.insert(port) }
        }
        return ports.sorted()
    }

    static func owner(_ pid: Int32) -> uid_t? {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { return nil }
        return info.pbi_uid
    }

    /// Full command line from KERN_PROCARGS2.
    static func args(_ pid: Int32) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }
        return parseProcArgs(Array(buf.prefix(size)))
    }

    /// KERN_PROCARGS2 layout: Int32 argc, exec path, NUL padding, then argc NUL-separated arguments.
    static func parseProcArgs(_ b: [UInt8]) -> String? {
        guard b.count > 4 else { return nil }
        let argc = Int(b[0]) | Int(b[1]) << 8 | Int(b[2]) << 16 | Int(b[3]) << 24
        var i = 4
        while i < b.count, b[i] != 0 { i += 1 }        // exec path
        while i < b.count, b[i] == 0 { i += 1 }        // padding
        var out: [String] = []
        while out.count < argc, i < b.count {
            var j = i
            while j < b.count, b[j] != 0 { j += 1 }
            out.append(String(decoding: b[i..<j], as: UTF8.self))
            i = j + 1
        }
        return out.isEmpty ? nil : out.joined(separator: " ")
    }

    /// "/opt/homebrew/bin/node /Users/me/app/node_modules/.bin/vite --port 3000" -> "node vite --port 3000".
    static func shortCommand(_ args: String, limit: Int = 70) -> String {
        let short = args.split(separator: " ").map { tok -> String in
            tok.hasPrefix("/") || tok.hasPrefix("./") ? ((tok as NSString).lastPathComponent) : String(tok)
        }.joined(separator: " ")
        return short.count > limit ? String(short.prefix(limit - 1)) + "…" : short
    }

    /// "now", "7 min", "3 h 12 min", "2 days".
    static func uptime(from start: Date?, now: Date = Date()) -> String {
        guard let start else { return "" }
        return uptime(seconds: now.timeIntervalSince(start))
    }

    static func uptime(seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "now" }
        if s < 3600 { return "\(s / 60) min" }
        if s < 86400 { return s % 3600 / 60 == 0 ? "\(s / 3600) h" : "\(s / 3600) h \(s % 3600 / 60) min" }
        return s / 86400 == 1 ? "1 day" : "\(s / 86400) days"
    }

    private static let runners: Set<String> = ["node", "bun", "deno", "tsx", "ts-node", "ruby", "php", "java", "npm", "pnpm", "yarn"]

    /// What the process is, for the row's second line: "vite", "next dev", "python http.server".
    static func tool(name: String, args: String) -> String {
        let toks = shortCommand(args, limit: 200).split(separator: " ").map(String.init)
        let isPython = name.lowercased().hasPrefix("python")
        if isPython {
            if let m = toks.firstIndex(of: "-m"), m + 1 < toks.count { return "python " + toks[m + 1] }
            return toks.dropFirst().first(where: { !$0.hasPrefix("-") }).map { "python " + $0 } ?? "python"
        }
        guard runners.contains(name.lowercased()) else { return name }
        let rest = toks.dropFirst().filter { !$0.hasPrefix("-") }
        guard let first = rest.first else { return name }
        if rest.count > 1, Int(rest[1]) == nil, rest[1].count <= 8 { return first + " " + rest[1] }
        return first
    }

    // MARK: libproc

    static func exePath(_ pid: Int32) -> String {
        var buf = [UInt8](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return "" }
        return String(decoding: buf.prefix(while: { $0 != 0 }), as: UTF8.self)
    }

    static func cwd(_ pid: Int32) -> String {
        var info = proc_vnodepathinfo()
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, Int32(MemoryLayout<proc_vnodepathinfo>.size)) > 0 else { return "" }
        return withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    static func startTime(_ pid: Int32) -> Date? {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000)
    }

    /// False for exited processes and for zombies that were not reaped yet.
    static func isAlive(_ pid: Int32) -> Bool {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { return false }
        return info.pbi_status != UInt32(SZOMB)
    }
}
