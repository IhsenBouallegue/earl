import Foundation
import Testing
@testable import Earl

struct NotesEngineTests {
    static func lm(_ key: String, _ gb: Double, type: String = "llm") -> LMStudioModel {
        let json = #"{"type":"\#(type)","key":"\#(key)","size_bytes":\#(Int64(gb * 1e9)),"params_string":"4B"}"#
        return try! JSONDecoder().decode(LMStudioModel.self, from: Data(json.utf8))
    }
    let gb16: UInt64 = 16 << 30
    var empty = FoundServers(userURL: nil, lmStudioModels: nil, lmStudioInstalled: false, ollamaModels: nil, builtInDownloaded: [])

    @Test func userURLAlwaysWins() {
        var f = empty; f.userURL = "http://team-box:8080/v1"; f.lmStudioModels = [Self.lm("google/gemma-4-e4b", 5)]
        #expect(NotesEngine.choose(f, memory: gb16, preferredModel: nil) == .custom(url: "http://team-box:8080/v1"))
    }

    @Test func lmStudioWithModelsIsUsed() {
        var f = empty; f.lmStudioModels = [Self.lm("google/gemma-4-e4b", 5)]
        #expect(NotesEngine.choose(f, memory: gb16, preferredModel: nil) == .lmStudio(model: "google/gemma-4-e4b"))
    }

    @Test func lmStudioWithOnlyEmbeddingsIsSkipped() {
        var f = empty; f.lmStudioModels = [Self.lm("nomic-embed", 0.3, type: "embedding")]
        f.ollamaModels = [OllamaModel(name: "qwen3:14b", size: 7_000_000_000)]
        #expect(NotesEngine.choose(f, memory: gb16, preferredModel: nil) == .ollama(model: "qwen3:14b"))
    }

    @Test func lmStudioInstalledButOffStillCounts() {
        // Earl starts LM Studio's server itself (Summarizer.startLMStudioServer).
        var f = empty; f.lmStudioInstalled = true; f.lmStudioModels = nil
        f.builtInDownloaded = []
        #expect(NotesEngine.choose(f, memory: gb16, preferredModel: "google/gemma-4-e4b") == .lmStudio(model: "google/gemma-4-e4b"))
    }

    @Test func preferredModelKeptWhenPresent() {
        var f = empty; f.lmStudioModels = [Self.lm("a/small", 3), Self.lm("b/big", 6)]
        #expect(NotesEngine.choose(f, memory: gb16, preferredModel: "a/small") == .lmStudio(model: "a/small"))
    }

    @Test func ollamaPicksLargestThatFits() {
        var f = empty
        f.ollamaModels = [OllamaModel(name: "llama3:70b", size: 40_000_000_000), OllamaModel(name: "qwen3:14b", size: 7_000_000_000)]
        #expect(NotesEngine.choose(f, memory: gb16, preferredModel: nil) == .ollama(model: "qwen3:14b"))
    }

    @Test func nothingFoundMeansBuiltInOrNone() {
        #expect(NotesEngine.choose(empty, memory: gb16, preferredModel: nil) == .none)
        var f = empty; f.builtInDownloaded = [BuiltInModel.forMemory(gb16)]
        #expect(NotesEngine.choose(f, memory: gb16, preferredModel: nil) == .builtIn(model: BuiltInModel.forMemory(gb16)))
    }

    @Test func lmStudioModelWithoutParamsIsStillUsed() {
        let json = #"{"type":"llm","key":"odd/model","size_bytes":3000000000}"#
        let m = try! JSONDecoder().decode(LMStudioModel.self, from: Data(json.utf8))
        var f = empty; f.lmStudioModels = [m]
        #expect(NotesEngine.choose(f, memory: gb16, preferredModel: nil) == .lmStudio(model: "odd/model"))
    }

    @Test func lmStudioModelTooBigIsStillUsed() {
        var f = empty; f.lmStudioModels = [Self.lm("big/one", 20)]
        #expect(NotesEngine.choose(f, memory: gb16, preferredModel: nil) == .lmStudio(model: "big/one"))
    }

    @Test func ollamaNothingFitsFallsBackToSmallest() {
        var f = empty
        f.ollamaModels = [OllamaModel(name: "llama3:70b", size: 40_000_000_000), OllamaModel(name: "mid:30b", size: 20_000_000_000)]
        #expect(NotesEngine.choose(f, memory: gb16, preferredModel: nil) == .ollama(model: "mid:30b"))
    }

    @Test func ollamaEmbeddingsOnlyCountsAsAbsent() {
        var f = empty; f.ollamaModels = [OllamaModel(name: "nomic-embed-text:latest", size: 300_000_000)]
        #expect(NotesEngine.choose(f, memory: gb16, preferredModel: nil) == .none)
    }

    // MARK: Earl's own Ollama copies, LM Studio off

    /// Earl's larger-context copy lists at its base's size and would win the
    /// name tie-break; it's never chosen, so the base gets its context raised.
    @Test func derivedOllamaCopyIsNeverChosen() {
        var f = empty
        f.ollamaModels = [OllamaModel(name: "qwen3:14b", size: 7_000_000_000),
                          OllamaModel(name: "earl/qwen3-14b-32k:latest", size: 7_000_000_000)]
        #expect(NotesEngine.choose(f, memory: gb16, preferredModel: nil) == .ollama(model: "qwen3:14b"))
        // A stored setting naming the copy maps back to its base.
        #expect(NotesEngine.choose(f, memory: gb16, preferredModel: "earl/qwen3-14b-32k") == .ollama(model: "qwen3:14b"))
        #expect(NotesEngine.choose(f, memory: gb16, preferredModel: "earl/qwen3-14b-32k:latest") == .ollama(model: "qwen3:14b"))
        // Only copies: nothing for Ollama.
        f.ollamaModels = [OllamaModel(name: "earl/qwen3-14b-32k:latest", size: 7_000_000_000)]
        #expect(NotesEngine.choose(f, memory: gb16, preferredModel: nil) == .none)
    }

    @Test func derivedNamesMapBackToTheirBase() {
        let models = [OllamaModel(name: "qwen3:14b", size: 1), OllamaModel(name: "gemma3:latest", size: 1),
                      OllamaModel(name: "hf.co/org/model:Q4_K_M", size: 1)]
        #expect(OllamaContext.stripped("earl/qwen3-14b-32k") == "qwen3-14b")
        #expect(OllamaContext.stripped("earl/qwen3-14b-64k:latest") == "qwen3-14b")
        #expect(OllamaContext.stripped("qwen3:14b") == "qwen3:14b")
        for m in models {
            for context in [16_384, 32_768, 65_536] {
                #expect(OllamaContext.base(of: OllamaContext.derivedName(model: m.name, context: context), among: models) == m.name)
                #expect(OllamaContext.base(of: OllamaContext.derivedName(model: m.name, context: context) + ":latest",
                                           among: models) == m.name)
            }
        }
        #expect(OllamaContext.base(of: "earl/gemma3-32k", among: models) == "gemma3:latest") // stored without a tag
        #expect(OllamaContext.base(of: "qwen3:14b", among: models) == "qwen3:14b")
    }

    /// LM Studio installed but off, Ollama running with a model: Ollama, unless
    /// a model was picked in Settings (then Earl starts LM Studio for it).
    @Test func ollamaWinsOverLMStudioOffUnlessAModelWasPicked() {
        var f = empty; f.lmStudioInstalled = true
        f.ollamaModels = [OllamaModel(name: "qwen3:14b", size: 7_000_000_000)]
        #expect(NotesEngine.choose(f, memory: gb16, preferredModel: Prefs.defaultLLMModel) == .ollama(model: "qwen3:14b"))
        f.llmModelStored = true
        #expect(NotesEngine.choose(f, memory: gb16, preferredModel: "google/gemma-4-e4b") == .lmStudio(model: "google/gemma-4-e4b"))
        // Ollama with only embeddings or Earl's copies doesn't count.
        f.llmModelStored = false
        f.ollamaModels = [OllamaModel(name: "nomic-embed-text:latest", size: 1), OllamaModel(name: "earl/qwen3-14b-32k:latest", size: 1)]
        #expect(NotesEngine.choose(f, memory: gb16, preferredModel: Prefs.defaultLLMModel) == .lmStudio(model: Prefs.defaultLLMModel))
    }

    /// A model picked in Settings that Ollama runs stays on Ollama, even with
    /// LM Studio installed but off (its stored-model rule must not claim it).
    @Test func ollamaPickedModelStaysOnOllamaWhenLMStudioIsOff() {
        var f = empty; f.lmStudioInstalled = true; f.llmModelStored = true
        f.ollamaModels = [OllamaModel(name: "qwen3:14b", size: 7_000_000_000)]
        #expect(NotesEngine.choose(f, memory: gb16, preferredModel: "qwen3:14b") == .ollama(model: "qwen3:14b"))
    }

    // MARK: Task 2: discovery, applying the choice

    /// The author's Mac: LM Studio running with these models (the live listing,
    /// trimmed), no llmURL stored, qwen3.8-27b chosen, 96 GB.
    static let authorLMStudio = #"""
    {"models":[
     {"type":"llm","key":"qwen/qwen3.8-27b","size_bytes":17742039110,"params_string":"27B","quantization":{"name":"Q4_K_M","bits_per_weight":4}},
     {"type":"llm","key":"prism-ml/bonsai-27b","size_bytes":8521076756,"params_string":"27B","quantization":{"name":"2bit","bits_per_weight":2}},
     {"type":"llm","key":"google/gemma-4-e4b","size_bytes":6861935454,"params_string":"4B","quantization":{"name":"4bit","bits_per_weight":4}},
     {"type":"embedding","key":"text-embedding-nomic-embed-text-v1.5","size_bytes":84106624,"quantization":{"name":"Q4_K_M","bits_per_weight":4}}
    ]}
    """#

    @Test func authorsSetupStaysOnLMStudioAndQwen() throws {
        struct List: Decodable { let models: [LMStudioModel] }
        let models = try JSONDecoder().decode(List.self, from: Data(Self.authorLMStudio.utf8)).models
        let f = FoundServers(userURL: NotesEngine.userURL(stored: nil), lmStudioModels: models, lmStudioInstalled: true,
                             ollamaModels: nil, builtInDownloaded: [])
        let backend = NotesEngine.choose(f, memory: 103_079_215_104, preferredModel: "qwen/qwen3.8-27b")
        #expect(backend == .lmStudio(model: "qwen/qwen3.8-27b"))
        #expect(NotesEngine.baseURL(for: backend) == Prefs.defaultLLMURL) // the same server as before
        #expect(NotesEngine.model(for: backend, fallback: "x") == "qwen/qwen3.8-27b")
    }

    @Test func onlyAChangedURLIsTheUsersOwn() {
        #expect(NotesEngine.userURL(stored: nil) == nil)
        #expect(NotesEngine.userURL(stored: Prefs.defaultLLMURL) == nil)
        #expect(NotesEngine.userURL(stored: "") == nil)
        #expect(NotesEngine.userURL(stored: "http://team-box:8080/v1") == "http://team-box:8080/v1")
    }

    @Test func eachBackendHasItsServer() {
        #expect(NotesEngine.baseURL(for: .lmStudio(model: "a")) == "http://localhost:1234/v1")
        #expect(NotesEngine.baseURL(for: .ollama(model: "a")) == "http://localhost:11434/v1")
        #expect(NotesEngine.baseURL(for: .custom(url: "http://team-box:8080/v1")) == "http://team-box:8080/v1")
        #expect(NotesEngine.baseURL(for: .builtIn(model: BuiltInModel.all[0])) == nil) // D-3 Task 4
        #expect(NotesEngine.baseURL(for: .none) == nil)
    }

    @Test func modelFollowsTheBackend() {
        #expect(NotesEngine.model(for: .ollama(model: "qwen3:4b"), fallback: "g") == "qwen3:4b")
        #expect(NotesEngine.model(for: .custom(url: "http://x/v1"), fallback: "g") == "g")
        #expect(NotesEngine.model(for: .none, fallback: "g") == "g")
    }

    @Test func ollamaTagsDecode() {
        let json = #"{"models":[{"name":"qwen3:4b","model":"qwen3:4b","size":2497293931,"digest":"x","details":{}}]}"#
        #expect(NotesEngine.ollamaModels(from: Data(json.utf8)) == [OllamaModel(name: "qwen3:4b", size: 2_497_293_931)])
        #expect(NotesEngine.ollamaModels(from: Data("nope".utf8)) == nil)
    }

    @Test func discoveryOnlyAsksThisMac() {
        #expect(NotesEngine.isLocal("http://localhost:1234"))
        #expect(NotesEngine.isLocal("http://127.0.0.1:11434/api/tags"))
        #expect(!NotesEngine.isLocal("http://team-box:8080"))
        #expect(!NotesEngine.isLocal("http://localhost.example.com:1234"))
    }

    @Test func closedPortsMeanNothingRunning() async {
        let clock = ContinuousClock()
        let start = clock.now
        let f = await NotesEngine.discover(lmStudioURL: "http://127.0.0.1:9", ollamaURL: "http://127.0.0.1:9",
                                           lmStudioInstalled: false, builtIn: [], userURL: nil)
        #expect(f.lmStudioModels == nil && f.ollamaModels == nil)
        #expect(clock.now - start < .seconds(2.5)) // 1 s timeouts, side by side
    }

    @Test func labels() {
        #expect(NotesEngine.label(.lmStudio(model: "google/gemma-4-e4b")) == "Using LM Studio · gemma-4-e4b")
        #expect(NotesEngine.label(.ollama(model: "qwen3:14b")) == "Using Ollama · qwen3:14b")
        #expect(NotesEngine.label(.builtIn(model: BuiltInModel.all[0])) == "Built in · \(BuiltInModel.all[0].displayName)")
        #expect(NotesEngine.label(.custom(url: "http://team-box:8080/v1")) == "Using team-box:8080")
        #expect(NotesEngine.kind(.lmStudio(model: "a")) == "LM Studio")
        #expect(NotesEngine.kind(.ollama(model: "a")) == "Ollama")
        #expect(NotesEngine.kind(.builtIn(model: BuiltInModel.all[0])) == "Built in")
        #expect(NotesEngine.kind(.custom(url: "u")) == "Custom server")
        #expect(NotesEngine.kind(.none) == "None")
    }

    @Test func notesAreReadyWhenOffOrSomethingWrites() {
        #expect(!SetupState.notesReady(summariesEnabled: true, backend: .none))
        #expect(SetupState.notesReady(summariesEnabled: false, backend: .none))
        #expect(SetupState.notesReady(summariesEnabled: true, backend: .ollama(model: "a")))
    }

    // MARK: Live (EARL_LIVE_NOTES=1): needs LM Studio and `ollama serve` with a model

    static let live = ProcessInfo.processInfo.environment["EARL_LIVE_NOTES"] == "1"

    @Test(.enabled(if: live)) func liveLMStudioIsFoundFirst() async {
        let f = await NotesEngine.discover(userURL: nil)
        #expect(NotesEngine.choose(f, memory: ProcessInfo.processInfo.physicalMemory, preferredModel: "qwen/qwen3.8-27b")
                == .lmStudio(model: "qwen/qwen3.8-27b"))
    }

    @Test(.enabled(if: live)) func liveOllamaIsFoundWithoutLMStudio() async {
        // LM Studio "away": its probe on a closed port, and not installed.
        let f = await NotesEngine.discover(lmStudioURL: "http://127.0.0.1:9", lmStudioInstalled: false, builtIn: [], userURL: nil)
        #expect(f.lmStudioModels == nil)
        #expect(f.ollamaModels?.isEmpty == false)
        let backend = NotesEngine.choose(f, memory: ProcessInfo.processInfo.physicalMemory, preferredModel: nil)
        #expect(backend == .ollama(model: "qwen3:4b"))
        // The server it points at answers the OpenAI model list.
        let status = await Summarizer.serverStatus(baseURL: NotesEngine.baseURL(for: backend)!)
        #expect(status.reachable && status.models.contains { $0.id == "qwen3:4b" })
    }

    @Test func noWriterSaysWhatToDo() {
        #expect(NotesEngine.noWriter == "No notes writer is set up yet. Finish getting ready, or turn notes off.")
        #expect(AskError.noModel.errorDescription?.contains("LM Studio") == false)
    }
}
