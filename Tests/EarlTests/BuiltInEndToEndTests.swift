import Darwin
import Foundation
import Testing
@testable import Earl

/// D-3 Task 5: notes through the built-in engine, as Earl writes them: the
/// `.builtIn` backend chosen from what's on disk, the bundled llama-server
/// started and stopped by BuiltInServer. Needs the 16 GB tier's model in
/// `Prefs.modelsDir/llm/` and the app built with `EARL_RELEASE=1 ./build.sh`:
///
///     EARL_LIVE_BUILTIN=1 ./test.sh --filter BuiltInEndToEndTests
struct BuiltInEndToEndTests {
    static let enabled = ProcessInfo.processInfo.environment["EARL_LIVE_BUILTIN"] != nil
    static let helper = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../build/Earl.app/Contents/Helpers/llama-server").standardized.path

    @Test(.enabled(if: enabled, "Set EARL_LIVE_BUILTIN to write notes with the built-in engine"))
    func notesThroughTheBuiltInEngine() async throws {
        let memory: UInt64 = 16 << 30
        // A Mac with no LM Studio or Ollama (nothing listens on port 9), the model on disk.
        let found = await NotesEngine.discover(lmStudioURL: "http://127.0.0.1:9", ollamaURL: "http://127.0.0.1:9",
                                               lmStudioInstalled: false, userURL: nil)
        let backend = NotesEngine.choose(found, memory: memory, preferredModel: Prefs.defaultLLMModel)
        let model = BuiltInModel.forMemory(memory)
        #expect(backend == .builtIn(model: model))
        try #require(model.fileURL != nil, "Put \(model.file) in \(Prefs.modelsDir.path)/llm/")
        try #require(FileManager.default.isExecutableFile(atPath: Self.helper), "Build with EARL_RELEASE=1 ./build.sh")

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("earl-builtin-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pidFile = dir.appendingPathComponent("llama-server.pid")
        let server = BuiltInServer(executable: Self.helper, pidFile: pidFile, log: dir.appendingPathComponent("llama-server.log"))

        var s = Summarizer()
        s.backend = backend
        s.model = NotesEngine.model(for: backend, fallback: "")
        s.reasoning = Prefs.notesThinking(s.model)
        s.builtInServer = server
        s.vocabulary = []
        let c = NotesEvalTests.makeCase(preset: "realistic", seed: 1, minutes: 2)
        let started = Date()
        var pid: pid_t?
        var running: String?
        let result = try await s.summarize(c.meeting.transcriptText, context: SummaryContext(c.meeting.info)) { _ in
            // While it writes: the process the PID file names, and where it runs from.
            if pid == nil, let text = try? String(contentsOf: pidFile, encoding: .utf8),
               let r = BuiltInServer.parseRecord(text) {
                pid = r.pid
                running = BuiltInServer.executablePath(of: r.pid)
            }
        }
        let seconds = Date().timeIntervalSince(started)
        print("[builtin] backend \(backend), model file \(model.fileURL!.path)")
        print("[builtin] llama-server pid \(pid.map(String.init) ?? "?"), running \(running ?? "?")")
        print("[builtin] \(Int(seconds)) s, context \(result.context ?? 0), \(Int(result.tokensPerSecond ?? 0)) tok/s")
        print("[builtin] title: \(result.title ?? "")\n\(result.markdown)")

        let p = try #require(pid)
        #expect(running == Self.helper)
        #expect(kill(p, 0) == 0) // still up: it stops after five idle minutes, or when Earl quits
        #expect(result.markdown.contains("[ ]"))
        #expect(!result.markdown.contains("<think>"))

        await server.stop() // what the idle timer and quitting do
        #expect(kill(p, 0) != 0)
        #expect(!FileManager.default.fileExists(atPath: pidFile.path))
        print("[builtin] stopped: \(kill(p, 0) != 0)")
    }
}
