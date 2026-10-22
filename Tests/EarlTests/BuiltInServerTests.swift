import Foundation
import Testing
@testable import Earl

/// D-3: the built-in notes engine, llama.cpp's llama-server inside Earl.app.
struct BuiltInServerTests {
    @Test func argumentsAreLocalOnlyWithContext() {
        let a = BuiltInServer.arguments(model: "/m.gguf", context: 32768, port: 52100)
        #expect(a == ["-m", "/m.gguf", "-c", "32768", "--host", "127.0.0.1", "--port", "52100",
                      "-ngl", "999", "-fa", "on", "--jinja", "--no-webui", "-np", "1", "--log-verbosity", "1"])
    }

    /// Errors only in the log, and the log goes with the server: it never keeps
    /// what was written up. A failed start keeps it, to say why.
    @Test func logGoesWhenTheServerStops() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("earl-log-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appendingPathComponent("llama-server.log")
        let model = dir.appendingPathComponent("m.gguf")
        FileManager.default.createFile(atPath: model.path, contents: Data("x".utf8))
        let launcher = FakeLauncher()
        let server = launcher.server(dir: dir)
        let e = try await server.ensure(model: model, context: 16384)
        #expect(!e.key.isEmpty)
        await server.end()
        FileManager.default.createFile(atPath: log.path, contents: Data("E something\n".utf8))
        await server.stop()
        #expect(!FileManager.default.fileExists(atPath: log.path))
        FileManager.default.createFile(atPath: log.path, contents: Data("E failed to load model\n".utf8))
        await server.stop(keepLog: true)
        #expect(FileManager.default.fileExists(atPath: log.path))
    }

    /// 16 GB or less: an idle server stops when a recording starts.
    @Test func smallMacsStopAnIdleServerForRecording() {
        #expect(BuiltInServer.stopsForRecording(memory: 8 << 30))
        #expect(BuiltInServer.stopsForRecording(memory: 16 << 30))
        #expect(!BuiltInServer.stopsForRecording(memory: 24 << 30))
        #expect(!BuiltInServer.stopsForRecording(memory: 96 << 30))
        // Only with no lease and no meeting being processed (stopUnlessBusy).
        #expect(BuiltInServer.canStopNow(inFlight: 0, appBusy: false))
        #expect(!BuiltInServer.canStopNow(inFlight: 1, appBusy: false))
    }

    @Test func onlyEarlCanUseItAndItShowsNoMeetings() {
        let env = BuiltInServer.environment(["PATH": "/usr/bin"], apiKey: "k")
        // llama-server allows every origin by default; a page that guessed the port could read meetings.
        #expect(env["LLAMA_ARG_CORS_ORIGINS"] == "localhost")
        #expect(env["LLAMA_ARG_ENDPOINT_SLOTS"] == "0") // /slots shows the prompt being processed
        #expect(env["LLAMA_API_KEY"] == "k")
        #expect(env["PATH"] == "/usr/bin")
        let a = BuiltInServer.newKey(), b = BuiltInServer.newKey()
        #expect(a.count == 64 && a != b)
    }

    @Test func reusesARunningServerWithEnoughContext() {
        let running = BuiltInServer.Running(model: "/a.gguf", context: 32768)
        #expect(BuiltInServer.canReuse(running, model: "/a.gguf", context: 16384))
        #expect(BuiltInServer.canReuse(running, model: "/a.gguf", context: 32768))
        #expect(!BuiltInServer.canReuse(running, model: "/a.gguf", context: 65536))
        #expect(!BuiltInServer.canReuse(running, model: "/b.gguf", context: 16384))
        #expect(!BuiltInServer.canReuse(nil, model: "/a.gguf", context: 16384))
    }

    @Test func stopsOnlyAfterFiveIdleMinutesWithNothingGoingOn() {
        let last = Date(timeIntervalSince1970: 1_000_000)
        let soon = last.addingTimeInterval(4 * 60)
        let later = last.addingTimeInterval(5 * 60 + 1)
        #expect(!BuiltInServer.shouldStop(lastUse: last, now: soon, inFlight: 0, appBusy: false))
        #expect(BuiltInServer.shouldStop(lastUse: last, now: later, inFlight: 0, appBusy: false))
        // Never while a request is being served or a meeting is being processed.
        #expect(!BuiltInServer.shouldStop(lastUse: last, now: later, inFlight: 1, appBusy: false))
        #expect(!BuiltInServer.shouldStop(lastUse: last, now: later, inFlight: 0, appBusy: true))
    }

    @Test func onlyKillsTheLlamaServerEarlStarted() {
        let ours = "/Applications/Earl.app/Contents/Helpers/llama-server"
        #expect(BuiltInServer.isOurServer(running: ours, recorded: ours))
        // A reused PID: something else now, or another app's llama-server (LM Studio's).
        #expect(!BuiltInServer.isOurServer(running: "/usr/bin/ssh", recorded: ours))
        #expect(!BuiltInServer.isOurServer(
            running: "/Users/me/.lmstudio/extensions/backends/llama.cpp/llama-server", recorded: ours))
        #expect(!BuiltInServer.isOurServer(running: "/opt/not-llama-server-wrapper", recorded: "/opt/not-llama-server-wrapper"))
        #expect(!BuiltInServer.isOurServer(running: nil, recorded: ours))
        // D-4: an update moved Earl.app; its own llama-server still counts, wherever it is.
        #expect(BuiltInServer.isOurServer(running: "/Users/me/Applications/Earl.app/Contents/Helpers/llama-server",
                                          recorded: ours))
        #expect(BuiltInServer.isOurServer(running: "/private/var/folders/x/T/Earl.app/Contents/Helpers/llama-server",
                                          recorded: ours))
        #expect(!BuiltInServer.isOurServer(running: "/Applications/LM Studio.app/Contents/Resources/llama-server",
                                           recorded: ours))
        #expect(!BuiltInServer.isOurServer(running: "/Applications/NotEarl.app/Contents/Helpers/llama-server",
                                           recorded: ours))
        #expect(!BuiltInServer.isOurServer(running: "/Applications/Earl.app/Contents/Helpers/llama-server-old",
                                           recorded: ours))
    }

    @Test func pidFileHoldsThePIDAndThePath() {
        let r = BuiltInServer.record(pid: 4242, executable: "/A/llama-server")
        #expect(BuiltInServer.parseRecord(r)?.pid == 4242)
        #expect(BuiltInServer.parseRecord(r)?.path == "/A/llama-server")
        #expect(BuiltInServer.parseRecord("") == nil)
        #expect(BuiltInServer.parseRecord("0\n/A/llama-server") == nil)
        #expect(BuiltInServer.parseRecord("-1\n/A/llama-server") == nil)
        #expect(BuiltInServer.parseRecord("abc\n/A/llama-server") == nil)
        #expect(BuiltInServer.parseRecord("4242") == nil) // no path: can't tell whose it is
    }

    @Test func freePortIsUsable() throws {
        let port = try BuiltInServer.freePort()
        #expect(port > 1024 && port < 65536)
    }

    @Test func orphanKillLeavesUnrelatedProcessesAlone() throws {
        // Our own PID and path in the file: this test runner isn't llama-server, so it lives on.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("earl-test-\(UUID()).pid")
        let me = ProcessInfo.processInfo.arguments[0]
        try BuiltInServer.record(pid: getpid(), executable: me).write(to: file, atomically: true, encoding: .utf8)
        #expect(BuiltInServer.killOrphan(pidFile: file) == false)
        #expect(!FileManager.default.fileExists(atPath: file.path)) // a stale file is cleared
    }

    @Test func noHelperWithoutTheApp() {
        #expect(Prefs.bundledHelper("llama-server") == nil)
    }

    @Test func builtInWithoutAFileFailsClearly() async {
        var s = Summarizer()
        // Not the catalog's: its file may well be on this Mac.
        s.backend = .builtIn(model: BuiltInModel(id: "missing", name: "Missing", repo: "earl/none", file: "earl-missing.gguf",
                                                 sha256: "", bytes: 1, minMemoryGB: 16))
        s.baseURL = "http://127.0.0.1:9/v1" // never reached
        let error = await #expect(throws: PipelineError.self) {
            _ = try await s.answer(system: "s", prompt: "p")
        }
        #expect(error?.localizedDescription == BuiltInServer.notDownloaded)
    }

    @Test func builtInHasNoURLUntilItRuns() {
        #expect(NotesEngine.baseURL(for: .builtIn(model: BuiltInModel.all[0])) == nil)
    }
}

/// Runs the bundled llama-server for real (build it with tools/build-llama.sh):
///     EARL_LIVE_LLAMA_MODEL=/path/to/model.gguf ./test.sh --filter BuiltInServerLiveTests
struct BuiltInServerLiveTests {
    static let env = ProcessInfo.processInfo.environment
    static let executable = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../vendor/bin/llama-server").standardized.path

    @Test(.enabled(if: env["EARL_LIVE_LLAMA_MODEL"] != nil, "Set EARL_LIVE_LLAMA_MODEL to a GGUF"))
    func ensureHealthStopAndOrphan() async throws {
        let model = URL(fileURLWithPath: Self.env["EARL_LIVE_LLAMA_MODEL"]!)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("earl-llama-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pidFile = dir.appendingPathComponent("llama-server.pid")
        let server = BuiltInServer(executable: Self.executable, pidFile: pidFile,
                                   log: dir.appendingPathComponent("llama-server.log"))

        let e = try await server.ensure(model: model, context: 16384)
        #expect(e.url.hasPrefix("http://127.0.0.1:") && e.url.hasSuffix("/v1"))
        let root = String(e.url.dropLast(3))
        func status(_ path: String, key: String?) async throws -> Int {
            var req = URLRequest(url: URL(string: root + path)!)
            if let key { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
            let (_, r) = try await URLSession.shared.data(for: req)
            return (r as? HTTPURLResponse)?.statusCode ?? 0
        }
        #expect(try await status("/health", key: nil) == 200) // no key needed to check it's up
        #expect(try await status("/v1/models", key: nil) == 401)
        #expect(try await status("/v1/models", key: e.key) == 200)
        #expect(try await status("/slots", key: e.key) != 200)
        // Same model, smaller context: the same server.
        #expect(try await server.ensure(model: model, context: 8192) == e)
        await server.end()
        await server.end()
        let pid = try #require(BuiltInServer.parseRecord(String(contentsOf: pidFile, encoding: .utf8))?.pid)
        #expect(kill(pid, 0) == 0)

        await server.stop()
        #expect(kill(pid, 0) != 0)
        #expect(!FileManager.default.fileExists(atPath: pidFile.path))

        // A crash leaves the server and its PID file behind: the next launch kills it.
        _ = try await server.ensure(model: model, context: 16384)
        await server.end()
        let orphan = try #require(BuiltInServer.parseRecord(String(contentsOf: pidFile, encoding: .utf8))?.pid)
        #expect(BuiltInServer.killOrphan(pidFile: pidFile))
        try await Task.sleep(for: .seconds(1))
        #expect(kill(orphan, 0) != 0)
        await server.stop()
        try? FileManager.default.removeItem(at: dir)
    }
}

/// Lines collected from several tasks.
final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ line: String) { lock.withLock { lines.append(line) } }
    var all: [String] { lock.withLock { lines } }
}

/// A llama-server that starts and stops on command.
final class FakeServerProcess: ServerProcess, @unchecked Sendable {
    private let lock = NSLock()
    private var _running = true
    private var _ready = false
    let processIdentifier: Int32
    let port: String
    init(pid: Int32, port: String) { processIdentifier = pid; self.port = port }
    var isRunning: Bool { lock.withLock { _running } }
    var ready: Bool {
        get { lock.withLock { _ready } }
        set { lock.withLock { _ready = newValue } }
    }
    func terminate() { lock.withLock { _running = false } }
}

final class FakeLauncher: @unchecked Sendable {
    private let lock = NSLock()
    private var _launched: [FakeServerProcess] = []
    /// Servers come up healthy at once unless this is false.
    let readyAtOnce: Bool
    init(readyAtOnce: Bool = true) { self.readyAtOnce = readyAtOnce }
    var launched: [FakeServerProcess] { lock.withLock { _launched } }

    func server(dir: URL) -> BuiltInServer {
        BuiltInServer(executable: "/fake/llama-server", pidFile: dir.appendingPathComponent("llama-server.pid"),
                      log: dir.appendingPathComponent("llama-server.log"),
                      launch: { args, _ in
                          let port = args[args.firstIndex(of: "--port")! + 1]
                          return self.lock.withLock {
                              let p = FakeServerProcess(pid: Int32(90_000 + self._launched.count), port: port)
                              p.ready = self.readyAtOnce
                              self._launched.append(p)
                              return p
                          }
                      },
                      healthy: { root in
                          self.lock.withLock { self._launched.first { root.hasSuffix(":" + $0.port) }?.ready ?? false }
                      })
    }
}

/// D-3 review: a restart never cuts off a request, and a superseded start never kills its replacement.
@Suite(.timeLimit(.minutes(1))) // a broken lease rule hangs rather than fails
struct BuiltInServerLifecycleTests {
    let dir: URL
    let model: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("earl-fake-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        model = dir.appendingPathComponent("m.gguf")
        FileManager.default.createFile(atPath: model.path, contents: Data())
    }

    func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func moreContextWaitsForTheLeaseEnsureJustGave() async throws {
        let fake = FakeLauncher()
        let server = fake.server(dir: dir)
        let statuses = Lines()
        // A summary at 16k: ensure returns with its lease already held.
        let first = try await server.ensure(model: model, context: 16384) { statuses.add("1: " + $0) }

        let model = self.model
        // Ask Earl at 32k, issued right after: it must wait for that lease.
        let bigger = Task { try await server.ensure(model: model, context: 32768) { statuses.add("2: " + $0) } }
        try await Task.sleep(for: .milliseconds(300))
        #expect(fake.launched.count == 1)
        #expect(fake.launched[0].isRunning) // the summary keeps its server

        await server.end()
        let e = try await bigger.value
        #expect(fake.launched.count == 2)
        #expect(!fake.launched[0].isRunning)
        #expect(fake.launched[1].isRunning)
        #expect(e != first && e.url.hasSuffix(":\(fake.launched[1].port)/v1"))
        try await waitUntil { statuses.all.count == 3 } // status goes out without holding up ensure
        #expect(statuses.all == ["1: " + BuiltInServer.startingStatus,
                                 "2: " + BuiltInServer.waiting, "2: " + BuiltInServer.startingStatus])
        await server.end()
    }

    @Test func lessContextNeverRestarts() async throws {
        let fake = FakeLauncher()
        let server = fake.server(dir: dir)
        let statuses = Lines()
        let big = try await server.ensure(model: model, context: 32768)
        // No waiting, no start, no status: the running server fits.
        #expect(try await server.ensure(model: model, context: 16384) { statuses.add($0) } == big)
        #expect(statuses.all.isEmpty)
        await server.end()
        await server.end()
        #expect(fake.launched.count == 1)
    }

    @Test func aPendingRestartHoldsBackNewRequests() async throws {
        let fake = FakeLauncher()
        let server = fake.server(dir: dir)
        let model = self.model
        let first = try await server.ensure(model: model, context: 16384) // lease held
        let bigger = Task { try await server.ensure(model: model, context: 32768) }
        try await Task.sleep(for: .milliseconds(100))
        // Fits the old server, but a restart is waiting: it waits too, so leases can't pile up forever.
        let done = Lines()
        let small = Task {
            let e = try await server.ensure(model: model, context: 8192)
            done.add("small")
            return e
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(done.all.isEmpty)

        await server.end() // the first lease ends: restart, then both run on the new server
        let b = try await bigger.value
        let s = try await small.value
        #expect(b == s && b != first)
        #expect(fake.launched.count == 2)
        await server.end()
        await server.end()
    }

    @Test func aCancelledWaiterDoesNotRestart() async throws {
        let fake = FakeLauncher()
        let server = fake.server(dir: dir)
        let model = self.model
        let first = try await server.ensure(model: model, context: 16384)
        let bigger = Task { try await server.ensure(model: model, context: 32768) }
        try await Task.sleep(for: .milliseconds(100))
        bigger.cancel()
        await server.end()
        await #expect(throws: CancellationError.self) { try await bigger.value }
        #expect(fake.launched.count == 1)
        #expect(fake.launched[0].isRunning)
        // Nothing pending any more: a small request uses the old server at once.
        #expect(try await server.ensure(model: model, context: 8192) == first)
        await server.end()
    }

    // Round 3: a status callback that suspends must not open a gap between a check and its change.

    @Test func aWaiterWakesWhenTheLastLeaseEndsDuringItsStatus() async throws {
        let fake = FakeLauncher()
        let server = fake.server(dir: dir)
        let model = self.model
        _ = try await server.ensure(model: model, context: 16384) // lease held
        let entered = Lines()
        let bigger = Task {
            try await server.ensure(model: model, context: 32768) { message in
                entered.add(message)
                try? await Task.sleep(for: .milliseconds(300)) // a slow main actor
            }
        }
        try await waitUntil { entered.all.contains(BuiltInServer.waiting) }
        await server.end() // the last lease ends while "Waiting…" is being shown
        let e = try await bigger.value // must not sleep forever
        #expect(e.url.hasSuffix(":\(fake.launched[1].port)/v1"))
        #expect(fake.launched.count == 2)
        await server.end()
    }

    @Test func racingRestartsStartOneServer() async throws {
        let fake = FakeLauncher()
        let server = fake.server(dir: dir)
        let model = self.model
        _ = try await server.ensure(model: model, context: 16384)
        await server.end()
        let slow: @Sendable (String) async -> Void = { _ in try? await Task.sleep(for: .milliseconds(200)) }
        let a = Task { try await server.ensure(model: model, context: 32768, status: slow) }
        let b = Task { try await server.ensure(model: model, context: 32768, status: slow) }
        let ea = try await a.value, eb = try await b.value
        #expect(ea == eb)
        #expect(fake.launched.count == 2) // the first server, then exactly one restart
        #expect(fake.launched.filter(\.isRunning).count == 1) // nothing left running untracked
        await server.end()
        await server.end()
    }

    @Test func aSupersededStartLeavesTheNewServerAlone() async throws {
        let fake = FakeLauncher(readyAtOnce: false)
        let server = fake.server(dir: dir)
        let model = self.model
        let first = Task { try await server.ensure(model: model, context: 16384) }
        try await waitUntil { fake.launched.count == 1 }
        let second = Task { try await server.ensure(model: model, context: 32768) }
        try await waitUntil { fake.launched.count == 2 }
        #expect(!fake.launched[0].isRunning)

        // The old start notices it was cancelled; the new server must survive that.
        try await Task.sleep(for: .milliseconds(400))
        #expect(fake.launched[1].isRunning)
        fake.launched[1].ready = true
        let e2 = try await second.value
        // The first caller joins the newer start (32k covers its 16k) rather than failing.
        #expect(try await first.value == e2)
        #expect(fake.launched.count == 2)
        #expect(fake.launched[1].isRunning)
    }

    @Test func firstStartStillSeesTheCrashRecord() async throws {
        // A crash left a record behind; the first ensure must read it before anything deletes it.
        let pidFile = dir.appendingPathComponent("llama-server.pid")
        try BuiltInServer.record(pid: getpid(), executable: ProcessInfo.processInfo.arguments[0])
            .write(to: pidFile, atomically: true, encoding: .utf8)
        let server = FakeLauncher().server(dir: dir)
        await server.stop() // nothing of ours runs: the record stays
        #expect(FileManager.default.fileExists(atPath: pidFile.path))
        _ = try await server.ensure(model: model, context: 16384)
        // Cleared (not ours: left alone), then rewritten for the new server.
        let r = try #require(BuiltInServer.parseRecord(String(contentsOf: pidFile, encoding: .utf8)))
        #expect(r.path == "/fake/llama-server")
        await server.stop()
        #expect(!FileManager.default.fileExists(atPath: pidFile.path))
    }
}
