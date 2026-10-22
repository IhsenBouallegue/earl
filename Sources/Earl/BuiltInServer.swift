import Darwin
import Foundation
import os

/// D-3: the built-in notes engine. llama.cpp's `llama-server`, shipped in
/// Earl.app/Contents/Helpers, run on demand for colleagues without LM Studio
/// or Ollama. Listens on 127.0.0.1 only, and stops after five idle minutes.
/// The running llama-server, as BuiltInServer sees it (a fake in tests).
protocol ServerProcess: AnyObject {
    var isRunning: Bool { get }
    var processIdentifier: Int32 { get }
    func terminate()
}

extension Process: ServerProcess {}

actor BuiltInServer {
    static let shared = BuiltInServer(executable: Prefs.bundledHelper("llama-server"),
                                      pidFile: Prefs.supportDir.appendingPathComponent("llama-server.pid"),
                                      log: Prefs.supportDir.appendingPathComponent("llama-server.log"))

    static let notDownloaded = "The notes writer isn't downloaded yet."
    static let stopped = "The built-in notes writer stopped. Try again."
    static let idleLimit: TimeInterval = 5 * 60

    struct Running: Equatable {
        var model: String
        var context: Int
    }

    /// Where to send requests, and the key they need (a new one per start).
    struct Endpoint: Equatable, Sendable {
        var url: String
        var key: String
    }

    /// Starts the executable with these arguments and environment.
    typealias Launcher = @Sendable (_ arguments: [String], _ environment: [String: String]) throws -> any ServerProcess
    /// True once `GET <root>/health` answers 200.
    typealias HealthCheck = @Sendable (_ root: String) async -> Bool

    private let executable: String?
    private let pidFile: URL
    /// llama-server's errors (it runs at error level only); gone when it stops.
    private let log: URL
    private let launch: Launcher
    private let healthy: HealthCheck

    private var process: (any ServerProcess)?
    private var running: Running?
    private var endpoint: Endpoint?
    /// A start in progress, so concurrent callers share it.
    private var starting: (config: Running, task: Task<Endpoint, Error>)?
    private var lastUse = Date()
    private var inFlight = 0 { didSet { let n = inFlight; Self.leaseCount.withLock { $0 = n } } }
    /// D-4: a mirror of `inFlight` that anyone may read without awaiting; an update never installs under a lease.
    nonisolated static let leaseCount = OSAllocatedUnfairLock(initialState: 0)
    nonisolated static var isServing: Bool { leaseCount.withLock { $0 > 0 } }
    /// Callers waiting for every request to finish before a restart.
    private var drained: [CheckedContinuation<Void, Never>] = []
    /// The restart they're waiting for; new requests wait for it too.
    private var pending: Running?
    private var idleTimer: Task<Void, Never>?
    private var orphanCleared = false
    /// True while Earl is processing a meeting; set by AppState.
    private var appBusy: (@MainActor @Sendable () -> Bool)?

    init(executable: String?, pidFile: URL, log: URL,
         launch: Launcher? = nil, healthy: HealthCheck? = nil) {
        self.executable = executable
        self.pidFile = pidFile
        self.log = log
        self.launch = launch ?? { arguments, environment in
            guard let executable else {
                throw PipelineError.message("Earl's built-in notes writer is missing. Reinstall Earl.")
            }
            try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: log.path, contents: nil) // truncate
            let logHandle = try FileHandle(forWritingTo: log)
            defer { try? logHandle.close() }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: executable)
            p.arguments = arguments
            p.environment = environment
            p.standardOutput = logHandle
            p.standardError = logHandle
            p.standardInput = FileHandle.nullDevice
            try p.run()
            return p
        }
        self.healthy = healthy ?? Self.health
    }

    /// The command line: local only, the model's whole context, one request at a
    /// time, and errors only in the log (its info level names what's being written up).
    static func arguments(model: String, context: Int, port: Int) -> [String] {
        ["-m", model, "-c", String(context), "--host", "127.0.0.1", "--port", String(port),
         "-ngl", "999", "-fa", "on", "--jinja", "--no-webui", "-np", "1", "--log-verbosity", "1"]
    }

    /// Earl's environment, plus: a key every request needs (other apps on this Mac
    /// can't use the server), no /slots (it shows the meeting being written up),
    /// and answers to browsers only from localhost pages (llama-server allows every
    /// origin by default).
    static func environment(_ base: [String: String], apiKey: String) -> [String: String] {
        base.merging(["LLAMA_ARG_CORS_ORIGINS": "localhost", "LLAMA_ARG_ENDPOINT_SLOTS": "0",
                      "LLAMA_API_KEY": apiKey]) { _, new in new }
    }

    /// 32 random bytes, hex.
    static func newKey() -> String {
        var g = SystemRandomNumberGenerator()
        return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &g)) }.joined()
    }

    static func canReuse(_ running: Running?, model: String, context: Int) -> Bool {
        guard let running else { return false }
        return running.model == model && running.context >= context
    }

    static func shouldStop(lastUse: Date, now: Date, inFlight: Int, appBusy: Bool) -> Bool {
        inFlight == 0 && !appBusy && now.timeIntervalSince(lastUse) >= idleLimit
    }

    func setAppBusy(_ check: @escaping @MainActor @Sendable () -> Bool) {
        appBusy = check
    }

    // MARK: Running

    static let waiting = "Waiting for the notes writer…"
    static let startingStatus = "Starting the built-in notes writer…"

    /// Returns the endpoint of a server for `model` with at least `context`
    /// tokens, starting one if needed, **with a lease taken** in the same actor
    /// turn: the server can't stop or restart until the caller's `end()`.
    ///
    /// A restart for more context waits until every lease on the old server has
    /// ended. While it waits (`pending`), new requests don't start on the old
    /// server either, so a steady trickle of small requests can't hold it off.
    /// It never restarts for less. `status` hears "Waiting…" and "Starting…".
    ///
    /// Rule: no await between reading and changing state. An await lets other
    /// callers (and `end()`) into the actor, so a check made before it is stale
    /// after it. The only awaits here are the waits themselves, each followed by
    /// `continue` to look again; status messages go out without waiting.
    func ensure(model: URL, context: Int,
                status: (@Sendable (String) async -> Void)? = nil) async throws -> Endpoint {
        // Sent in order, never awaited here.
        var lastStatus: Task<Void, Never>?
        func tell(_ message: String) {
            guard let status else { return }
            lastStatus = Task { [previous = lastStatus] in
                await previous?.value
                await status(message)
            }
        }
        clearOrphan()
        var want = Running(model: model.path, context: context)
        while true {
            lastUse = Date()
            if pending == nil, let endpoint, process?.isRunning == true,
               Self.canReuse(running, model: want.model, context: want.context) {
                inFlight += 1 // the lease, in the same turn as the check
                return endpoint
            }
            if let (config, task) = starting, Self.canReuse(config, model: want.model, context: want.context) {
                do {
                    _ = try await task.value
                } catch is CancellationError where !Task.isCancelled {
                    // superseded by a start with more context
                }
                continue // take the lease above, or look again
            }
            if inFlight > 0 {
                // Requests still run on the old server: restart once they're done.
                pending = Self.merged(pending, want)
                tell(Self.waiting)
                await withCheckedContinuation { drained.append($0) }
                if Task.isCancelled {
                    if drained.isEmpty { pending = nil }
                    throw CancellationError()
                }
                continue // things may have changed while waiting
            }
            // Nothing runs: (re)start, big enough for everyone who waited.
            want = Self.merged(pending, want)
            pending = nil
            starting?.task.cancel() // superseded; it ends through cancellation
            stop()
            tell(Self.startingStatus)
            let task = Task { try await self.start(want) }
            starting = (want, task)
            do {
                _ = try await task.value
                if starting?.task == task { starting = nil }
            } catch is CancellationError where !Task.isCancelled {
                // superseded: look again
            } catch {
                if starting?.task == task { starting = nil }
                throw error
            }
        }
    }

    /// The restart that serves both: the larger context for the same model; else the newer request.
    static func merged(_ pending: Running?, _ want: Running) -> Running {
        guard let pending, pending.model == want.model else { return want }
        return Running(model: want.model, context: max(pending.context, want.context))
    }

    /// Once per launch, before the first start: a server left by a crash goes.
    func clearOrphan() {
        guard !orphanCleared else { return }
        orphanCleared = true
        Self.killOrphan(pidFile: pidFile)
    }

    private func start(_ want: Running) async throws -> Endpoint {
        guard FileManager.default.fileExists(atPath: want.model) else { throw PipelineError.message(Self.notDownloaded) }
        let port = try Self.freePort()
        let key = Self.newKey()
        let p = try launch(Self.arguments(model: want.model, context: want.context, port: port),
                           Self.environment(ProcessInfo.processInfo.environment, apiKey: key))
        process = p
        running = want
        if let executable {
            try? Self.record(pid: p.processIdentifier, executable: executable)
                .write(to: pidFile, atomically: true, encoding: .utf8)
        }

        /// Only this start's own server: a newer one may have replaced it.
        func giveUp(_ message: String?) throws -> Never {
            // The log stays: it says why it didn't start.
            if process === p { stop(keepLog: true) } else if p.isRunning { p.terminate() }
            if let message { throw PipelineError.message(message) }
            throw CancellationError()
        }
        let root = "http://127.0.0.1:\(port)"
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            if Task.isCancelled { try giveUp(nil) }
            guard p.isRunning else {
                try giveUp("The built-in notes writer stopped while starting. See llama-server.log in Earl's support folder.")
            }
            if await healthy(root) {
                if Task.isCancelled || process !== p { try giveUp(nil) }
                let e = Endpoint(url: root + "/v1", key: key)
                endpoint = e
                lastUse = Date()
                startIdleTimer()
                return e
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        try giveUp("The built-in notes writer didn't start within two minutes.")
    }

    /// /health needs no key.
    private static func health(_ root: String) async -> Bool {
        guard let url = URL(string: root + "/health") else { return false }
        var req = URLRequest(url: url, timeoutInterval: 1)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (_, response) = try? await URLSession.shared.data(for: req) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    /// Stops the server and deletes its log, unless a failed start needs it read.
    func stop(keepLog: Bool = false) {
        if !keepLog { try? FileManager.default.removeItem(at: log) }
        idleTimer?.cancel()
        idleTimer = nil
        if let process {
            if process.isRunning {
                process.terminate()
                // Give it a moment to exit, then make sure.
                let pid = process.processIdentifier
                for _ in 0..<20 where process.isRunning { usleep(50_000) }
                if process.isRunning { kill(pid, SIGKILL) }
            }
            // Only our own server's record: with none running, the file may name a crash's orphan.
            try? FileManager.default.removeItem(at: pidFile)
        }
        process = nil
        running = nil
        endpoint = nil
    }

    // MARK: Idle

    /// A lease from `ensure` ends; while any is held, the server never stops or restarts.
    func end() {
        inFlight = max(0, inFlight - 1)
        lastUse = Date()
        if inFlight == 0 {
            let waiting = drained
            drained = []
            waiting.forEach { $0.resume() }
        }
    }

    /// The model file the server is running now, if it is.
    var runningModel: String? { process?.isRunning == true ? running?.model : nil }

    /// D-3: its model was deleted. Stop at once when nothing uses the server
    /// (no request, no meeting being processed); else the idle stop does it.
    func stopUnlessBusy() async {
        guard process != nil else { return }
        let busy = await appBusy?() ?? false
        if Self.canStopNow(inFlight: inFlight, appBusy: busy) { stop() }
    }

    static func canStopNow(inFlight: Int, appBusy: Bool) -> Bool { inFlight == 0 && !appBusy }

    /// D-3: a recording starts on a Mac of 16 GB or less; an idle server's
    /// memory goes back to transcription (`stopUnlessBusy`).
    static func stopsForRecording(memory: UInt64) -> Bool {
        Int((Double(memory) / 1_073_741_824).rounded()) <= 16
    }

    func stopIfIdle() async {
        guard process != nil else { return }
        let busy = await appBusy?() ?? false
        if Self.shouldStop(lastUse: lastUse, now: Date(), inFlight: inFlight, appBusy: busy) {
            NSLog("Earl: stopping the built-in notes writer after \(Int(Self.idleLimit / 60)) idle minutes")
            stop()
        }
    }

    private func startIdleTimer() {
        idleTimer?.cancel()
        idleTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                await self?.stopIfIdle()
            }
        }
    }

    // MARK: Ports and PIDs

    /// A port nothing listens on: bind to port 0 on 127.0.0.1 and read what the system chose.
    static func freePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw PipelineError.message("Couldn't find a free port for the notes writer.") }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, len) == 0 && getsockname(fd, $0, &len) == 0
            }
        }
        guard ok else { throw PipelineError.message("Couldn't find a free port for the notes writer.") }
        return Int(UInt16(bigEndian: addr.sin_port))
    }

    struct Record: Equatable {
        var pid: pid_t
        var path: String
    }

    /// The PID file: the process ID, then the executable, so a reused PID is never mistaken for ours.
    static func record(pid: pid_t, executable: String) -> String { "\(pid)\n\(executable)\n" }

    static func parseRecord(_ text: String) -> Record? {
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.count >= 2, let pid = pid_t(lines[0]), pid > 0, !lines[1].isEmpty else { return nil }
        return Record(pid: pid, path: lines[1])
    }

    /// The running process is the llama-server Earl started: same executable,
    /// named llama-server; or Earl's own wherever Earl.app now is (an update
    /// moved it). Never another app's llama-server.
    static func isOurServer(running: String?, recorded: String) -> Bool {
        guard let running, running.hasSuffix("/llama-server") else { return false }
        if running.hasSuffix(bundledSuffix) { return true }
        return URL(fileURLWithPath: running).resolvingSymlinksInPath().path
            == URL(fileURLWithPath: recorded).resolvingSymlinksInPath().path
    }
    static let bundledSuffix = "/Earl.app/Contents/Helpers/llama-server"

    /// The executable of a running process, or nil when there is none.
    static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard n > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// A server left behind (Earl crashed, or is quitting): kill it when the
    /// PID file names a running llama-server Earl started, never anything else.
    /// Clears the file either way. True when it killed one.
    @discardableResult
    nonisolated static func killOrphan(pidFile: URL) -> Bool {
        defer { try? FileManager.default.removeItem(at: pidFile) }
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8),
              let r = parseRecord(text),
              isOurServer(running: executablePath(of: r.pid), recorded: r.path) else { return false }
        NSLog("Earl: stopping a llama-server left behind (pid \(r.pid))")
        kill(r.pid, SIGTERM)
        for _ in 0..<20 where kill(r.pid, 0) == 0 { usleep(50_000) }
        if kill(r.pid, 0) == 0 { kill(r.pid, SIGKILL) }
        return true
    }

    /// At quit, without waiting on the actor: the shared server's PID file.
    nonisolated static func killOrphan() {
        killOrphan(pidFile: Prefs.supportDir.appendingPathComponent("llama-server.pid"))
    }
}
