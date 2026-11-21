import Foundation

enum Docker {
    struct Container: Hashable, Sendable {
        let id: String
        let image: String
        let socket: String
    }

    private struct Listing: Decodable {
        let ID, Names, Image, Ports: String
    }

    static func parse(_ output: String, socket: String) -> [PortRow] {
        let decoder = JSONDecoder()
        return output.split(whereSeparator: \.isNewline).flatMap { line -> [PortRow] in
            guard let item = try? decoder.decode(Listing.self, from: Data(line.utf8)),
                  [12, 64].contains(item.ID.count), item.ID.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  !item.Names.isEmpty, !item.Image.isEmpty else { return [] }
            var ports = Set<Int>()
            for mapping in item.Ports.components(separatedBy: ",") {
                let sides = mapping.trimmingCharacters(in: .whitespaces).components(separatedBy: "->")
                guard sides.count == 2, sides[1].hasSuffix("/tcp"),
                      let host = sides[0].components(separatedBy: ":").last else { continue }
                let range = host.components(separatedBy: "-")
                guard range.count <= 2, let first = Int(range[0]), let last = Int(range.last!),
                      first > 0, first <= last, last <= 65535 else { continue }
                ports.formUnion(first...last)
            }
            let container = Container(id: item.ID, image: item.Image, socket: socket)
            return ports.sorted().map { PortRow(pid: 0, port: $0, name: item.Names, exePath: "", cwd: "", args: "", started: nil, container: container) }
        }
    }

    static func isProxy(_ row: PortRow) -> Bool {
        row.name == "com.docker.backend" || row.name == "vpnkit" || row.exePath.contains("/OrbStack.app/")
    }

    static func published(hasProxy: Bool) async -> [PortRow] {
        let home = NSHomeDirectory()
        var sockets = ["\(home)/.docker/run/docker.sock", "\(home)/.orbstack/run/docker.sock"]
        if hasProxy { sockets.append("/var/run/docker.sock") }
        let local = Set(sockets.filter { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path })
        return await withTaskGroup(of: [PortRow].self) { group in
            for socket in local {
                group.addTask {
                    guard let output = await run(["ps", "--format", "{{json .}}"], socket: socket, timeout: 2) else { return [] }
                    return parse(output, socket: socket)
                }
            }
            var rows: [PortRow] = []
            for await batch in group { rows += batch }
            return rows
        }
    }

    static func stop(_ container: Container) async -> Bool {
        await run(["stop", container.id], socket: container.socket, timeout: 30) != nil
    }

    private static func run(_ args: [String], socket: String, timeout: Double) async -> String? {
        let candidates = ["/usr/local/bin/docker", "/opt/homebrew/bin/docker", NSHomeDirectory() + "/.docker/bin/docker",
                          "/Applications/Docker.app/Contents/Resources/bin/docker", "/Applications/OrbStack.app/Contents/MacOS/xbin/docker"]
        guard let cli = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else { return nil }
        let process = Process(), output = Pipe(), done = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = ["--host", "unix://" + socket] + args
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardOutput = output
        process.terminationHandler = { _ in done.signal() }
        guard (try? process.run()) != nil else { return nil }
        let data = Task.detached { output.fileHandleForReading.readDataToEndOfFile() }
        let deadline = DispatchTime.now() + timeout
        let finished = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { continuation.resume(returning: done.wait(timeout: deadline) == .success) }
        }
        guard finished else {
            if process.isRunning { process.terminate() }
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: await data.value, as: UTF8.self)
    }
}
