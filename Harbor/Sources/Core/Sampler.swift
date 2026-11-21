import Darwin
import Foundation

/// Cumulative CPU time and current memory of one process, from `proc_pid_rusage` (no root, no spawn).
struct ProcUsage: Sendable, Equatable {
    var cpuNs: UInt64
    var footprint: UInt64   // physical footprint, what Activity Monitor calls "Memory"
}

enum Sampler {
    private static let timebase: mach_timebase_info_data_t = {
        var t = mach_timebase_info_data_t()
        mach_timebase_info(&t)
        return t
    }()

    static func read(_ pid: Int32) -> ProcUsage? {
        var info = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard rc == 0 else { return nil }
        let ticks = info.ri_user_time &+ info.ri_system_time   // mach time units (not ns on Apple silicon)
        return ProcUsage(cpuNs: ticks &* UInt64(timebase.numer) / UInt64(timebase.denom), footprint: info.ri_phys_footprint)
    }

    static func nowNs() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
}

/// Turns two readings of cumulative CPU time into a percentage. 100 = one full core, so a
/// multi-threaded process can exceed 100.
struct CpuTracker {
    private var last: [Int32: (cpuNs: UInt64, at: UInt64)] = [:]

    static func percent(cpuDeltaNs: UInt64, wallDeltaNs: UInt64) -> Double {
        wallDeltaNs == 0 ? 0 : Double(cpuDeltaNs) / Double(wallDeltaNs) * 100
    }

    /// CPU % per pid since its previous reading. A pid seen for the first time has no entry yet;
    /// pids missing from `samples` are forgotten, so a reused pid starts fresh.
    mutating func update(_ samples: [Int32: ProcUsage], at now: UInt64) -> [Int32: Double] {
        var out: [Int32: Double] = [:]
        var next: [Int32: (cpuNs: UInt64, at: UInt64)] = [:]
        for (pid, u) in samples {
            if let p = last[pid], now > p.at, u.cpuNs >= p.cpuNs {
                out[pid] = Self.percent(cpuDeltaNs: u.cpuNs - p.cpuNs, wallDeltaNs: now - p.at)
            }
            next[pid] = (u.cpuNs, now)
        }
        last = next
        return out
    }
}

enum Fmt {
    /// "312 MB", "1.2 GB". Binary units, the way Activity Monitor shows memory.
    static func memory(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / 1_048_576
        if mb < 1 { return "< 1 MB" }
        if mb < 1024 { return "\(Int(mb.rounded())) MB" }
        return String(format: "%.1f GB", mb / 1024)
    }
}
