import Foundation

struct Checkout: Hashable, Sendable {
    let branch: String
    let linked: Bool

    static func cwd(_ output: String, pid: Int32) -> String? {
        var matchesPID = false, matchesCWD = false
        for field in output.split(separator: "\n") {
            switch field.first {
            case "p": matchesPID = field.dropFirst() == String(pid); matchesCWD = false
            case "f": matchesCWD = field == "fcwd"
            case "n" where matchesPID && matchesCWD && field.dropFirst().first == "/": return String(field.dropFirst())
            default: break
            }
        }
        return nil
    }

    static func lookup(pid: Int32) -> Checkout? {
        let deadline = DispatchTime.now() + 1
        func run(_ path: String, _ args: [String]) -> String? {
            guard DispatchTime.now() < deadline else { return nil }
            let process = Process(), output = Pipe(), done = DispatchSemaphore(value: 0)
            process.executableURL = URL(fileURLWithPath: path); process.arguments = args
            process.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C", "GIT_OPTIONAL_LOCKS": "0"]
            process.standardInput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            process.standardOutput = output; process.terminationHandler = { _ in done.signal() }
            guard (try? process.run()) != nil else { return nil }
            guard done.wait(timeout: deadline) == .success else {
                if process.isRunning { process.terminate() }
                return nil
            }
            guard process.terminationStatus == 0 else { return nil }
            return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }
        return lookup(pid: pid, run: run)
    }

    static func lookup(pid: Int32, run: (String, [String]) -> String?) -> Checkout? {
        guard let listing = run("/usr/sbin/lsof", ["-a", "-p", String(pid), "-d", "cwd", "-Fn"]),
              let dir = cwd(listing, pid: pid) else { return nil }
        let git = ["-C", dir]
        guard let paths = run("/usr/bin/git", git + ["rev-parse", "--path-format=absolute", "--absolute-git-dir", "--git-common-dir"])?.split(separator: "\n"),
              paths.count == 2 else { return nil }
        let branch = run("/usr/bin/git", git + ["symbolic-ref", "--short", "HEAD"])
            ?? run("/usr/bin/git", git + ["rev-parse", "--short", "HEAD"]).map { "detached \($0)" }
        guard let name = branch?.trimmingCharacters(in: .newlines), !name.isEmpty else { return nil }
        return Checkout(branch: name, linked: paths[0] != paths[1])
    }
}
