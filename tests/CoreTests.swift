import Foundation

// Logic tests for Harbor's scanner, classifier and stopper. Only starts processes it creates itself.
@main
struct CoreTests {
    nonisolated(unsafe) static var failures = 0
    static func check(_ ok: Bool, _ name: String) {
        print(ok ? "PASS \(name)" : "FAIL \(name)")
        if !ok { failures += 1 }
    }

    static func spawn(_ exe: String, _ args: [String], in dir: String) throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: dir)
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run()
        return p
    }

    static func idleChecks() {
        var idleT = IdleTracker()
        let t0: TimeInterval = 1_000_000
        _ = idleT.update([1: (nil, 0), 2: (0.2, 0)], now: t0)
        let la1 = idleT.update([1: (0.0, 0), 2: (50, 0)], now: t0 + 3600)
        check(la1[1] == t0 && la1[2] == t0 + 3600, "idle: low CPU keeps last-active, busy CPU resets it")
        let la2 = idleT.update([1: (0.5, 1), 2: (0.1, 0)], now: t0 + 7200)
        check(la2[1] == t0 + 7200 && la2[2] == t0 + 3600, "idle: a new connection resets, same count does not")
        let la3 = idleT.update([1: (0.5, 1), 3: (0, 0)], now: t0 + 7300)
        check(la3[1] == t0 + 7200 && la3[3] == t0 + 7300 && la3[2] == nil, "idle: held connection is not new, new pid starts active, gone pid dropped")

        var wall = t0 + 7300, slept: TimeInterval = 0
        let uptime = { wall - slept }
        wall += 60
        wall += 8 * 3600; slept += 8 * 3600
        let wake = idleT.update([3: (0, 0)], now: uptime())
        check(wake[3].map { IdleTracker.elapsed(since: $0, now: uptime()) } == 60, "idle: eight hours asleep count as zero; one awake minute remains")
        wall += 60
        check(wake[3].map { IdleTracker.elapsed(since: $0, now: uptime()) } == 120, "idle: awake time resumes after sleep")
    }

    static func databaseAddressChecks() {
        func address(_ name: String, _ port: Int) -> String? {
            Classifier.databaseAddress(PortRow(pid: 1, port: port, name: name, exePath: "/bin/\(name)", cwd: "/", args: "", started: nil))
        }
        check([5432, 3306, 6379, 27017].allSatisfy { address("proxy", $0) == "localhost:\($0)" }, "classifier: database ports copy localhost:port")
        check(["postgres", "mysqld", "redis-server", "mongod"].allSatisfy { address($0, 15432) == "localhost:15432" }, "classifier: database processes copy their actual port")
        check(address("node", 3000) == nil && address("mongod-helper", 3000) == nil, "classifier: web and nonmatching processes keep browser action")
    }

    @MainActor static func sharedPortChecks() {
        func listener(_ pid: Int32, _ port: Int) -> PortRow {
            PortRow(pid: pid, port: port, name: "node", exePath: "/bin/node", cwd: "/", args: "node /x/.bin/vite", started: nil)
        }
        let model = HarborModel(live: false)
        let first = listener(41, 3000), second = listener(41, 3001), independent = listener(42, 3002)
        model.load([second, independent, first])
        check(model.alsoPorts(first) == "Also 3001" && model.alsoPorts(second) == "Also 3000" && model.alsoPorts(independent) == nil, "model: each row names only its sibling ports")
        check(model.stopPrompt(second) == "Stop vite? It serves 3000 and 3001." && model.stopPrompt(independent) == nil, "model: Stop names the tool and every port in order")
        model.requestStop(second, isOther: false)
        check(model.confirming == second.id && model.states.isEmpty, "model: first Stop asks on the selected row without stopping")
        model.load([first, independent])
        check(model.confirming == nil && model.alsoPorts(first) == nil, "model: a closed port clears its confirmation and sibling hint")
    }

    @MainActor static func countChecks() {
        func listener(_ pid: Int32, _ port: Int) -> PortRow {
            PortRow(pid: pid, port: port, name: "node", exePath: "/bin/node", cwd: "/", args: "node /x/.bin/vite", started: nil)
        }
        let model = HarborModel(live: false)
        model.load([listener(61, 3000), listener(61, 3001), listener(62, 3002)])
        check(model.dev.count == 3 && model.serverCount == 2, "count: one server on two ports is one running")
    }

    static func debounceChecks() {
        var d = PortNoticeDebounce(lastSent: ["3000": 10, "3001": 500, "3002": 900])
        d.prune(now: 700)
        check(d.lastSent.keys.sorted() == ["3001", "3002"], "port notice: old entries are dropped on read, not only on write")
    }

    static func argvChecks() {
        var raw: [UInt8] = [3, 0, 0, 0]
        for part in ["/opt/homebrew/bin/node", "", "/opt/homebrew/bin/node", "/Users/e/My App/node_modules/.bin/vite", "--port"] { raw += Array(part.utf8) + [0] }
        let argv = Scanner.parseProcArgv(raw)
        check(argv == ["/opt/homebrew/bin/node", "/Users/e/My App/node_modules/.bin/vite", "--port"], "argv: arguments keep their spaces")
        check(Scanner.shortCommand(argv: argv!) == "node vite --port" && Scanner.tool(name: "node", args: argv!.joined(separator: " "), argv: argv) == "vite", "argv: a path with spaces shortens to its last component")
        check(Scanner.tool(name: "node", args: "node /Users/e/My App/node_modules/.bin/vite") != "vite", "argv: the plain string cannot do this, so the real argv is used")
    }

    @MainActor static func promptChecks() {
        func listener(_ pid: Int32, _ port: Int) -> PortRow {
            PortRow(pid: pid, port: port, name: "node", exePath: "/bin/node", cwd: "/", args: "node /x/.bin/vite", started: nil)
        }
        let a = listener(51, 3000), b = listener(52, 3001), c = listener(52, 3002)
        let model = HarborModel(live: false)
        model.load([a, b, c])
        check(!model.escape(), "escape: nothing open means the panel closes")
        model.confirmAll = true
        check(model.escape() && !model.confirmAll && !model.escape(), "escape: first press closes Stop all, second closes the panel")
        model.confirmIdle = true; model.confirming = a.id
        model.dismissPrompts()
        check(!model.confirmIdle && model.confirming == nil && !model.confirmAll, "close: every pending question is dropped, idle one too")
        model.removeRows(of: b.ownerKey)
        model.load([a, b, c])
        check(model.dev == [a], "stop: a scan that began before the stop cannot bring the row back")
        model.removeRows(of: a.ownerKey, confirmedGone: false)
        model.load([a])
        check(model.dev == [a], "stop: a force quit that did not kill leaves the row")
        model.states = [a.ownerKey: .stopping(since: Date()), b.ownerKey: .stopping(since: Date()), "x": .stuck]
        check(model.stoppingCount == 2, "header: counts servers being stopped")
    }

    static func portNoticeChecks() {
        func holder(_ cwd: String, started: Double = 10) -> PortRow {
            PortRow(pid: 41, port: 3000, name: "node", exePath: "/bin/node", cwd: cwd,
                    args: "node /bin/vite --port 3000", started: Date(timeIntervalSince1970: started))
        }
        let notice = PortNotice(Conflict(port: 3000, holder: holder("/Projects/Driftwood"), wanter: 42))
        check(notice.title == "Port 3000 is taken by vite (Driftwood)", "port notice: names port, tool and project")
        check(PortNotice(Conflict(port: 3000, holder: holder("/"), wanter: 42)).title == "Port 3000 is taken by vite", "port notice: omits absent project")
        check(notice.holderKey != nil && notice.holderKey != PortNotice.key(for: holder("/Projects/Driftwood", started: 20)), "port notice: reused pid cannot match Stop it")
        var debounce = PortNoticeDebounce()
        check(debounce.allows(3000, now: 10), "port notice: first collision allowed")
        debounce.record(3000, now: 10)
        check(!debounce.allows(3000, now: 10) && !debounce.allows(3000, now: 609.99) && debounce.allows(3001, now: 11), "port notice: cooldown is per port")
        check(PortNoticeDebounce(lastSent: debounce.lastSent).allows(3000, now: 610), "port notice: eligible again at ten minutes")
    }

    @MainActor static func dockerChecks() {
        let listing = """
            {"Command":"postgres","ID":"24abcde01234","Image":"postgres:16","Names":"paper-db","Ports":"127.0.0.1:15432->5432/tcp, [::1]:15432->5432/tcp, 5433/tcp","State":"running"}
            {"Command":"serve","ID":"56abcde01234","Image":"paper-web:2","Names":"paper-web","Ports":"0.0.0.0:8000-8001->80-81/tcp, :::8000-8001->80-81/tcp, 127.0.0.1:5353->53/udp","State":"running"}
            {"ID":"78abcde01234","Image":"paper-worker:1","Names":"paper-worker","Ports":"8080/tcp"}
            invalid
            """
        let rows = Docker.parse(listing, socket: "/demo/docker.sock")
        check(rows.map(\.port) == [15432, 8000, 8001], "docker: published TCP host ports only; ranges expanded, dual-stack duplicates removed")
        guard let database = rows.first, let web = rows.last else { return }
        check(database.name == "paper-db" && database.container?.image == "postgres:16" && database.container?.id == "24abcde01234", "docker: container name, image and stop ID match the listing")
        check(!Stopper.isSame(database) && database.ownerKey != web.ownerKey, "docker: independent stop targets, never a signalable process")
        let native = PortRow(pid: 42, port: 3000, name: "node", exePath: "/bin/node", cwd: "/", args: "node", started: nil)
        let model = HarborModel(live: false)
        model.load(rows + [native])
        check(model.dev.count == 4 && model.alsoPorts(database) == nil && model.alsoPorts(web) == "Also 8000", "docker: visible by default, sibling ports grouped by container")
        model.showDocker = false
        model.load(rows + [native])
        check(model.dev == [native] && model.other.isEmpty, "docker: disabled switch hides containers and preserves native listeners")
    }

    static func worktreeChecks() {
        check(Checkout.cwd("p20\nfcwd\nn/wrong\np41\nfcwd\nn/tmp/Paper Kite\n", pid: 41) == "/tmp/Paper Kite", "cwd: selects requested PID and preserves spaces")
        check(Checkout.cwd("p41\nftxt\nn/bin/node\n", pid: 41) == nil && Checkout.cwd("p42\nfcwd\nn/tmp\n", pid: 41) == nil, "cwd: rejects other descriptors and PIDs")
        func checkout(_ dirs: String?, branch: String?) -> Checkout? {
            Checkout.lookup(pid: 41) { tool, args in
                if tool == "/usr/sbin/lsof", args == ["-a", "-p", "41", "-d", "cwd", "-Fn"] { return "p41\nfcwd\nn/demo/paper kite\n" }
                guard tool == "/usr/bin/git", args.prefix(2) == ["-C", "/demo/paper kite"] else { return nil }
                if args.last == "--git-common-dir" { return dirs }
                return args.contains("symbolic-ref") ? branch : "abc1234\n"
            }
        }
        let common = "/demo/paper-kite/.git"
        check(checkout("\(common)/worktrees/tide\n\(common)\n", branch: "feature/tide\n") == Checkout(branch: "feature/tide", linked: true), "checkout: linked worktree shows its own branch")
        check(checkout("\(common)\n\(common)\n", branch: "main\n") == Checkout(branch: "main", linked: false), "checkout: main checkout shows branch without tag")
        check(checkout(nil, branch: nil) == nil && checkout("\(common)\n\(common)\n", branch: nil)?.branch == "detached abc1234", "checkout: absent repo and detached HEAD handled")
        let started = Date(timeIntervalSince1970: 100.25)
        let row = PortRow(pid: 41, port: 4173, name: "node", exePath: "/bin/node", cwd: "/", args: "", started: started)
        func owns(_ pid: Int32, _ port: Int, _ time: Date?) -> Bool {
            Stopper.isSame(row, ports: { $0 == pid ? [port] : [] }, path: { _ in row.exePath }, start: { _ in time })
        }
        check(owns(41, 4173, started), "Stop: same PID, start time and port match")
        check(!owns(42, 4173, started) && !owns(41, 5173, started), "Stop: rejects reassigned or closed port")
        check(!owns(41, 4173, started.addingTimeInterval(0.125)) && !owns(41, 4173, nil), "Stop: rejects reused PID and unknown start time")
    }

    static func main() async throws {
        worktreeChecks()
        dockerChecks()
        if ProcessInfo.processInfo.environment["HARBOR_TEST_DOCKER_ONLY"] == "1" { exit(failures == 0 ? 0 : 1) }
        portNoticeChecks()
        if ProcessInfo.processInfo.environment["HARBOR_TEST_PORT_NOTICES_ONLY"] == "1" { exit(failures == 0 ? 0 : 1) }
        sharedPortChecks()
        promptChecks()
        countChecks()
        argvChecks()
        debounceChecks()
        if ProcessInfo.processInfo.environment["HARBOR_TEST_SHARED_PORTS_ONLY"] == "1" { exit(failures == 0 ? 0 : 1) }
        databaseAddressChecks()
        if ProcessInfo.processInfo.environment["HARBOR_TEST_DATABASE_ONLY"] == "1" { exit(failures == 0 ? 0 : 1) }
        idleChecks()
        if ProcessInfo.processInfo.environment["HARBOR_TEST_IDLE_ONLY"] == "1" { exit(failures == 0 ? 0 : 1) }
        // parsing and formatting
        var raw: [UInt8] = [3, 0, 0, 0]
        raw += Array("/opt/homebrew/bin/node".utf8) + [0, 0, 0]
        raw += Array("node".utf8) + [0] + Array("/x/node_modules/.bin/vite".utf8) + [0] + Array("--port=1".utf8) + [0]
        raw += Array("HOME=/Users/me".utf8) + [0]
        check(Scanner.parseProcArgs(raw) == "node /x/node_modules/.bin/vite --port=1", "procargs: argc strings only, env dropped")
        check(Scanner.parseProcArgs([1, 0]) == nil, "procargs: short buffer")
        check(Scanner.allPids().contains(1), "pids: the list reaches the oldest process (launchd)")
        check(Scanner.shortCommand("/opt/homebrew/bin/node /Users/e/app/node_modules/.bin/vite --port 3000") == "node vite --port 3000", "short command")
        let now = Date()
        check(Scanner.uptime(from: now.addingTimeInterval(-3 * 3600 - 12 * 60), now: now) == "3 h 12 min", "uptime hours")
        check(Scanner.uptime(from: now.addingTimeInterval(-7 * 60), now: now) == "7 min" && Scanner.uptime(from: now.addingTimeInterval(-3 * 3600), now: now) == "3 h"
              && Scanner.uptime(from: now.addingTimeInterval(-86400 * 2), now: now) == "2 days" && Scanner.uptime(from: now, now: now) == "now", "uptime units")
        check(Scanner.tool(name: "node", args: "node /x/.bin/vite --port 5293") == "vite"
              && Scanner.tool(name: "node", args: "/opt/homebrew/bin/node /x/.bin/next dev -p 3000") == "next dev"
              && Scanner.tool(name: "Python", args: "/L/Python -m http.server 8000") == "python http.server"
              && Scanner.tool(name: "Spotify", args: "/Applications/Spotify.app/x") == "Spotify", "tool names")
        check(Fmt.memory(312 * 1_048_576) == "312 MB" && Fmt.memory(1_288_490_189) == "1.2 GB" && Fmt.memory(100) == "< 1 MB", "memory format")

        // CPU sampler maths and tracker
        check(CpuTracker.percent(cpuDeltaNs: 500, wallDeltaNs: 1000) == 50 && CpuTracker.percent(cpuDeltaNs: 5, wallDeltaNs: 0) == 0, "cpu percent maths")
        var tracker = CpuTracker()
        let first = tracker.update([1: ProcUsage(cpuNs: 1_000, footprint: 1)], at: 1_000)
        let second = tracker.update([1: ProcUsage(cpuNs: 1_500, footprint: 1), 2: ProcUsage(cpuNs: 9, footprint: 1)], at: 2_000)
        check(first.isEmpty && second[1] == 50 && second[2] == nil, "tracker: no value on first reading, delta after")
        _ = tracker.update([2: ProcUsage(cpuNs: 10, footprint: 1)], at: 3_000)
        let reused = tracker.update([1: ProcUsage(cpuNs: 2_000_000, footprint: 1)], at: 4_000)
        check(reused[1] == nil, "tracker: forgotten pid starts fresh (reused pid)")

        // classifier fixtures
        func row(_ path: String, _ cwd: String) -> PortRow {
            PortRow(pid: 1, port: 1, name: (path as NSString).lastPathComponent, exePath: path, cwd: cwd, args: "", started: nil)
        }
        let home = "/Users/me"
        check(Classifier.classify(row("/opt/homebrew/bin/node", "/"), home: home) == .dev, "node anywhere is dev")
        check(Classifier.classify(row("/tmp/mything", home + "/Projects/x"), home: home) == .dev, "cwd under home is dev")
        check(Classifier.classify(row("/Applications/Spotify.app/Contents/MacOS/Spotify", "/"), home: home) == .other, "app is other")
        check(Classifier.classify(row("/Applications/X.app/Contents/MacOS/X", home + "/Projects/x"), home: home) == .other, "app launched from project is other")
        check(Classifier.classify(row("/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter", "/"), home: home) == .hidden, "/System hidden")
        check(Classifier.classify(row("/usr/libexec/rapportd", "/"), home: home) == .hidden, "/usr/libexec hidden")
        check(Classifier.classify(row("/Library/Frameworks/Python.framework/Versions/3.13/Resources/Python.app/Contents/MacOS/Python", "/"), home: home) == .dev, "python is dev")

        // port guesses
        check(Watch.wantedPort(args: "node vite --port 5293 --host", env: []) == 5293
              && Watch.wantedPort(args: "node next dev -p 4000", env: []) == 4000
              && Watch.wantedPort(args: "node server.js", env: ["HOME=/x", "PORT=8080"]) == 8080
              && Watch.wantedPort(args: "node /x/.bin/vite", env: []) == 5173
              && Watch.wantedPort(args: "node /x/.bin/next dev", env: []) == 3000
              && Watch.wantedPort(args: "node x.js --port=9000", env: []) == 9000
              && Watch.wantedPort(args: "node x.js", env: []) == nil, "port guesses: flags, env, vite and next defaults")
        var env: [UInt8] = [2, 0, 0, 0] + Array("/bin/node".utf8) + [0, 0] + Array("node".utf8) + [0] + Array("x.js".utf8) + [0] + Array("PORT=3000".utf8) + [0] + Array("A=b".utf8) + [0]
        check(Scanner.parseProcEnv(env) == ["PORT=3000", "A=b"], "procargs: environment after the arguments")
        env = []
        let holder = PortRow(pid: 10, port: 3000, name: "node", exePath: "/n", cwd: "/Users/e/copper-shop", args: "", started: nil)
        let wanter = Silent(pid: 20, name: "node", args: "node next dev", env: [])
        let tree: [Int32: Int32] = [10: 5, 20: 6, 30: 10, 40: 20]
        check(Watch.conflicts(silent: [wanter], rows: [holder], parent: { tree[$0] ?? 0 }).first?.holderName == "copper-shop", "conflict: port held by another row")
        check(Watch.conflicts(silent: [Silent(pid: 40, name: "npm", args: "npm vite --port 3000", env: [])], rows: [PortRow(pid: 20, port: 3000, name: "node", exePath: "/n", cwd: "/", args: "", started: nil)], parent: { tree[$0] ?? 0 }).isEmpty,
              "conflict: own parent or child is not a conflict")
        check(Watch.conflicts(silent: [Silent(pid: 20, name: "node", args: "node x.js", env: [])], rows: [holder], parent: { _ in 0 }).isEmpty, "conflict: no wanted port, no banner")

        // two throwaway listeners
        let tmp = NSTemporaryDirectory() + "harbor-test-\(getpid())"
        let (a, b) = (tmp + "/harbor-test-a", tmp + "/harbor-test-b")
        for d in [a, b] { try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true) }
        let py = "/usr/bin/python3"
        let pa = try spawn(py, ["-m", "http.server", "0", "--bind", "127.0.0.1"], in: a)
        let pb = try spawn(py, ["-m", "http.server", "0", "--bind", "127.0.0.1"], in: b)
        defer { for p in [pa, pb] where p.isRunning { p.terminate() }; try? FileManager.default.removeItem(atPath: tmp) }

        func find(_ p: Process) async -> PortRow? {
            for _ in 0..<80 {
                // the python3 shim may exec the real interpreter under the same pid
                if let r = Scanner.scan().first(where: { $0.pid == p.processIdentifier }) { return r }
                try? await Task.sleep(for: .milliseconds(100))
            }
            return nil
        }
        let ra = await find(pa), rb = await find(pb)
        check(ra != nil && rb != nil, "scanner finds both listeners")
        guard let ra, let rb else { pa.terminate(); pb.terminate(); exit(1) }   // exit() skips defer
        check(ra.port != rb.port && ra.port > 0, "distinct ports")
        let real = { (s: String) in URL(fileURLWithPath: s).resolvingSymlinksInPath().path }
        check(real(ra.cwd) == real(a) && real(rb.cwd) == real(b), "cwd matches folder")
        check(ra.project == "harbor-test-a", "project name")
        check(Classifier.classify(ra) == .dev, "listener classified as dev")
        check(ra.started != nil && ra.args.contains("http.server"), "start time and args")

        // established connections on a real listener
        let base = Scanner.establishedCount(ra.pid, ports: [ra.port])
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET), sin_port: UInt16(ra.port).bigEndian,
                               sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        try? await Task.sleep(for: .milliseconds(400))
        check(rc == 0 && Scanner.establishedCount(ra.pid, ports: [ra.port]) > base, "established count sees a new client connection")
        close(sock)

        // sampler on real processes: our own busy loop vs an idle sleeper
        let busy = try spawn("/bin/sh", ["-c", "while :; do :; done"], in: tmp)
        let idle = try spawn("/bin/sleep", ["30"], in: tmp)
        defer { for p in [busy, idle] where p.isRunning { p.terminate() } }
        try? await Task.sleep(for: .milliseconds(300))
        var tr = CpuTracker()
        func sample() -> [Int32: ProcUsage] {
            var m: [Int32: ProcUsage] = [:]
            for p in [busy, idle] { if let u = Sampler.read(p.processIdentifier) { m[p.processIdentifier] = u } }
            return m
        }
        _ = tr.update(sample(), at: Sampler.nowNs())
        try? await Task.sleep(for: .milliseconds(1000))
        let cpu = tr.update(sample(), at: Sampler.nowNs())
        let busyCpu = cpu[busy.processIdentifier] ?? -1, idleCpu = cpu[idle.processIdentifier] ?? -1
        check(busyCpu > 40 && busyCpu < 130, "busy loop reads as CPU-bound (\(Int(busyCpu))%)")
        check(idleCpu >= 0 && idleCpu < 5, "sleeping process reads near 0% (\(String(format: "%.1f", idleCpu))%)")
        check((Sampler.read(idle.processIdentifier)?.footprint ?? 0) > 100_000, "memory footprint is read")
        check(Sampler.read(999_999) == nil, "missing pid gives no sample")
        busy.terminate(); idle.terminate(); busy.waitUntilExit(); idle.waitUntilExit()

        // stop one through Harbor's stop function
        let gone = await Stopper.terminate(ra)
        pa.waitUntilExit()
        check(gone == .gone && !Scanner.isAlive(ra.pid), "terminate stops the listener")
        check(Scanner.scan().contains { $0.pid == rb.pid } && !Scanner.scan().contains { $0.pid == ra.pid }, "other listener untouched")

        // SIGTERM ignored -> stuck, then force kill
        let sh = try spawn(py, ["-c", "import signal,socket,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); s=socket.socket(); s.bind(('127.0.0.1',0)); s.listen(); time.sleep(30)"], in: tmp)
        guard let stubborn = await find(sh) else { throw CocoaError(.executableRuntimeMismatch) }
        let stopped = await Stopper.terminate(stubborn, timeout: 1)
        check(stopped == .stuck, "ignored SIGTERM reports still alive")
        Stopper.forceKill(stubborn)
        sh.waitUntilExit()
        check(!Scanner.isAlive(stubborn.pid), "force kill works")

        // pid reuse guard
        let wrong = PortRow(pid: pb.processIdentifier, port: 0, name: "x", exePath: "/bin/nothing", cwd: "", args: "", started: nil)
        check(!Stopper.isSame(wrong), "pid with other program is not signalled")

        introFlowChecks { check($0, $1) }

        // exit() below skips every defer: stop the listener that is still up, or each run leaks one
        pb.terminate(); pb.waitUntilExit(); try? FileManager.default.removeItem(atPath: tmp)
        print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
