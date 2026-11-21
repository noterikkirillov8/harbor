import Darwin
import Foundation

enum Stopper {
    enum Outcome { case gone, stuck, stale }

    static func isSame(_ row: PortRow, ports: (Int32) -> [Int] = Scanner.listeningPorts,
                       path: (Int32) -> String = Scanner.exePath, start: (Int32) -> Date? = Scanner.startTime) -> Bool {
        guard row.pid > 0, row.container == nil, !Docker.isProxy(row), let started = row.started else { return false }
        return ports(row.pid).contains(row.port) && path(row.pid) == row.exePath && start(row.pid) == started
    }

    static func terminate(_ row: PortRow, timeout: Double = 3) async -> Outcome {
        if let container = row.container {
            guard await Docker.published(hasProxy: true).contains(where: { $0.id == row.id }) else { return .stale }
            return await Docker.stop(container) ? .gone : .stuck
        }
        guard isSame(row) else { return .stale }
        kill(row.pid, SIGTERM)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !Scanner.isAlive(row.pid) || Scanner.startTime(row.pid) != row.started { return .gone }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return isSame(row) ? .stuck : .stale
    }

    /// SIGKILL, only on an explicit second click.
    @discardableResult static func forceKill(_ row: PortRow) -> Bool {
        guard isSame(row) else { return false }
        return kill(row.pid, SIGKILL) == 0
    }
}
