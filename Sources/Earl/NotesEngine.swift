import Foundation
import Synchronization

/// A model as `ollama` lists it (`/api/tags`).
struct OllamaModel: Decodable, Equatable {
    var name: String
    var size: Int64
}

/// D-3: the note writer Earl downloads when a Mac has no LM Studio or Ollama
/// models, one per memory tier, chosen by the notes eval (docs/benchmarks.md).
/// Run by the bundled llama-server (BuiltInServer).
struct BuiltInModel: Equatable, Hashable, Sendable {
    let id: String
    let name: String
    let file: String
    let url: URL
    let sha256: String
    let bytes: Int64
    /// The smallest Mac (GB of memory) this tier is for.
    let minMemoryGB: Int

    init(id: String, name: String, repo: String, file: String, sha256: String, bytes: Int64, minMemoryGB: Int) {
        self.id = id
        self.name = name
        self.file = file
        url = URL(string: "https://huggingface.co/\(repo)/resolve/main/\(file)")!
        self.sha256 = sha256
        self.bytes = bytes
        self.minMemoryGB = minMemoryGB
    }

    // The 8/16/32 GB tiers ship at ~98.9 % owners (no model under 27B reached 100 %): docs/benchmarks.md, D-3.
    static let all: [BuiltInModel] = [
        // Notes eval, 2026-10-14 (docs/benchmarks.md): the best owners and German per tier.
        BuiltInModel(id: "qwen3.5-4b", name: "Qwen3.5 4B", repo: "lmstudio-community/Qwen3.5-4B-GGUF",
                     file: "Qwen3.5-4B-Q4_K_M.gguf",
                     sha256: "25082a7dd3776cc3c741c6347d3bd04523f05796607b3fbc32fa3a25dfa1418c",
                     bytes: 2_707_513_696, minMemoryGB: 8),
        BuiltInModel(id: "qwen3.5-9b", name: "Qwen3.5 9B", repo: "lmstudio-community/Qwen3.5-9B-GGUF",
                     file: "Qwen3.5-9B-Q4_K_M.gguf",
                     sha256: "cd76ec205963b3b33350093e6904d9de16c4e666fd104e1f632d25c7f15f2a13",
                     bytes: 5_627_044_256, minMemoryGB: 16),
        BuiltInModel(id: "gemma-4-12b", name: "Gemma 4 12B", repo: "lmstudio-community/gemma-4-12B-it-GGUF",
                     file: "gemma-4-12B-it-Q4_K_M.gguf",
                     sha256: "95d83ba36642b1f385fb906b5962a71763361be3bac930a709945f72d97473f8",
                     bytes: 7_381_382_944, minMemoryGB: 32),
        BuiltInModel(id: "qwen3.8-27b", name: "Qwen3.8 27B", repo: "lmstudio-community/Qwen3.8-27B-GGUF",
                     file: "Qwen3.8-27B-Q4_K_M.gguf",
                     sha256: "e00082f779fa385cee8c68a3ec8833a75778cc87272240b942f74e0b8243e520",
                     bytes: 16_810_714_336, minMemoryGB: 64),
    ]

    /// The tier for this much memory: the largest whose `minMemoryGB` it
    /// reaches; below the smallest tier, the smallest.
    static func forMemory(_ bytes: UInt64) -> BuiltInModel {
        let gb = Int((Double(bytes) / 1_073_741_824).rounded())
        let tiers = all.sorted { $0.minMemoryGB < $1.minMemoryGB }
        return tiers.last { $0.minMemoryGB <= gb } ?? tiers[0]
    }

    /// The one to run among those on disk: this Mac's tier, else the largest
    /// that suits its memory. nil when none suits it (a larger tier's file
    /// would swap), so the right-size download is offered instead.
    static func best(of downloaded: [BuiltInModel], memory: UInt64) -> BuiltInModel? {
        downloaded.filter { fits($0, memory: memory) }.max { $0.minMemoryGB < $1.minMemoryGB }
    }

    /// This tier or a smaller one: a larger tier's model would make this Mac swap.
    static func fits(_ model: BuiltInModel, memory: UInt64) -> Bool {
        model.minMemoryGB <= forMemory(memory).minMemoryGB
    }

    static let needsMoreMemory = "This notes writer needs a Mac with more memory."

    /// "Use a File I Have…" with a built-in model's file: why it can't be added
    /// on this Mac, or nil when it can.
    static func importRefusal(_ model: BuiltInModel, memory: UInt64) -> String? {
        fits(model, memory: memory) ? nil : needsMoreMemory
    }

    static func matching(sha256: String) -> BuiltInModel? { all.first { $0.sha256 == sha256 } }

    var displayName: String { name }
    /// "5.3 GB", as Finder counts.
    var approxSize: String { OnboardingCopy.size(bytes) }
    /// Where the file lives: `models/llm/` beside the transcription models.
    var path: URL { Prefs.modelsDir.appendingPathComponent("llm/\(file)") }
    /// The model file for the built-in server; nil until it's all there
    /// (a file of another size is a leftover, not the model).
    var fileURL: URL? { isComplete(fileSize: Self.size(of: path)) ? path : nil }

    func isComplete(fileSize: Int64?) -> Bool { fileSize == bytes }

    /// The most context the built-in server runs this model with: on Macs of
    /// 16 GB or less, 32k, so the cache leaves room for everything else (a
    /// longer meeting is read in parts). nil: the usual cap.
    var contextCap: Int? { minMemoryGB <= 16 ? 32_768 : nil }

    static func size(of url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
    }
    /// The built-in models whose file is on this Mac.
    static var downloaded: [BuiltInModel] { all.filter { $0.fileURL != nil } }
}

enum NotesBackend: Equatable {
    case custom(url: String)
    case lmStudio(model: String)
    case ollama(model: String)
    case builtIn(model: BuiltInModel)
    case none
}

extension NotesBackend {
    var isBuiltIn: Bool { if case .builtIn = self { true } else { false } }
}

struct FoundServers: Equatable {
    var userURL: String?
    var lmStudioModels: [LMStudioModel]?
    var lmStudioInstalled: Bool
    var ollamaModels: [OllamaModel]?
    var builtInDownloaded: [BuiltInModel]
    /// The notes model was chosen in Settings (not just the default).
    var llmModelStored = false
}

/// Which engine writes the notes: the user's own server, a colleague's
/// LM Studio or Ollama models, else the built-in one.
enum NotesEngine {
    static let lmStudioURL = "http://localhost:1234"
    static let ollamaURL = "http://localhost:11434"

    static func choose(_ f: FoundServers, memory: UInt64, preferredModel: String?) -> NotesBackend {
        if let url = f.userURL { return .custom(url: url) }
        let ollama = ollamaChoice(f.ollamaModels ?? [], memory: memory,
                                  preferred: preferredModel.map { OllamaContext.base(of: $0, among: f.ollamaModels ?? []) })

        if let models = f.lmStudioModels {
            let llms = models.filter(\.isLLM)
            if let preferredModel, llms.contains(where: { $0.key == preferredModel }) {
                return .lmStudio(model: preferredModel)
            }
            if let best = ModelAdvice.recommended(models, memory: memory) { return .lmStudio(model: best) }
            // Nothing is recommended (no parsable size, or none fits): still use
            // what they have, the smallest first, rather than offer a download.
            if let smallest = llms.min(by: { ($0.size_bytes ?? .max, $0.key) < ($1.size_bytes ?? .max, $1.key) }) {
                return .lmStudio(model: smallest.key)
            }
        } else if f.lmStudioInstalled, !pickedOllamaModel(preferredModel, f.ollamaModels ?? []),
                  f.llmModelStored || ollama == nil {
            // LM Studio is off: Earl starts it, unless Ollama runs with models
            // and nothing in Settings asks for an LM Studio model. A model picked
            // in Settings that Ollama runs is an Ollama choice.
            return .lmStudio(model: preferredModel ?? Prefs.defaultLLMModel)
        }

        if let ollama { return .ollama(model: ollama) }
        if let built = BuiltInModel.best(of: f.builtInDownloaded, memory: memory) { return .builtIn(model: built) }
        return .none
    }

    /// The preferred model if present, else the largest whose weights fit in
    /// 45 % of memory (ties: first name alphabetically), else the smallest.
    /// Embedding models never write notes, and Earl's own larger-context
    /// copies (OllamaContext) are never chosen: Earl makes them from the base.
    private static func ollamaChoice(_ all: [OllamaModel], memory: UInt64, preferred: String?) -> String? {
        let models = usableOllamaModels(all)
        if let preferred, models.contains(where: { $0.name == preferred }) { return preferred }
        let fitting = models
            .filter { Double($0.size) <= Double(memory) * 0.45 }
            .sorted { ($0.size, $1.name) > ($1.size, $0.name) }
        if let best = fitting.first { return best.name }
        return models.min { ($0.size, $0.name) < ($1.size, $1.name) }?.name
    }

    /// Ollama's models Earl may write notes with: no embedding models, no Earl copies.
    private static func usableOllamaModels(_ all: [OllamaModel]) -> [OllamaModel] {
        all.filter { !$0.name.lowercased().contains("embed") && !OllamaContext.isDerived($0.name) }
    }

    /// Whether the model picked in Settings (a copy maps back to its base) is one Ollama runs.
    private static func pickedOllamaModel(_ preferred: String?, _ all: [OllamaModel]) -> Bool {
        guard let preferred else { return false }
        let base = OllamaContext.base(of: preferred, among: all)
        return usableOllamaModels(all).contains { $0.name == base }
    }

    // MARK: Applying the choice

    /// The backend in use: what `discover` and `choose` found last. Until the
    /// first look, what the settings say (the user's URL, else LM Studio),
    /// so nothing changes for anyone before Earl has checked.
    static var current: NotesBackend {
        get { cache.withLock { $0 ?? fallback } }
        set { cache.withLock { $0 = newValue } }
    }
    private static let cache = Mutex<NotesBackend?>(nil)

    static var fallback: NotesBackend {
        userURL(stored: Prefs.llmURL).map { .custom(url: $0) } ?? .lmStudio(model: Prefs.llmModel)
    }

    /// Looks for servers on this Mac, chooses, and remembers the choice.
    @discardableResult
    static func resolve() async -> NotesBackend {
        let found = await discover()
        let backend = choose(found, memory: ProcessInfo.processInfo.physicalMemory, preferredModel: Prefs.llmModel)
        current = backend
        return backend
    }

    /// The server URL a user typed: the stored one when it isn't empty or the default.
    static func userURL(stored: String?) -> String? {
        guard let stored, !stored.isEmpty, stored != Prefs.defaultLLMURL else { return nil }
        return stored
    }

    /// The OpenAI-compatible base URL (…/v1). nil for the built-in engine,
    /// whose server picks its port when it starts (BuiltInServer.ensure), and
    /// when nothing writes notes.
    static func baseURL(for backend: NotesBackend) -> String? {
        switch backend {
        case .custom(let url): url
        case .lmStudio: lmStudioURL + "/v1"
        case .ollama: ollamaURL + "/v1"
        case .builtIn, .none: nil
        }
    }

    /// The model to ask for; `fallback` (the setting) when the backend doesn't name one.
    static func model(for backend: NotesBackend, fallback: String) -> String {
        switch backend {
        case .lmStudio(let m), .ollama(let m): m
        case .builtIn(let m): m.id
        case .custom, .none: fallback
        }
    }

    /// The Summaries card's first line: "Using LM Studio · gemma-4-e4b".
    static func label(_ backend: NotesBackend) -> String {
        switch backend {
        case .lmStudio(let m): "Using LM Studio · \(m.split(separator: "/").last.map(String.init) ?? m)"
        case .ollama(let m): "Using Ollama · \(m)"
        case .builtIn(let m): "Built in · \(m.displayName)"
        case .custom(let url): "Using \(URLComponents(string: url).flatMap { c in c.host.map { h in c.port.map { "\(h):\($0)" } ?? h } } ?? url)"
        case .none: "Nothing writes notes yet"
        }
    }

    static let noWriter = "No notes writer is set up yet. Finish getting ready, or turn notes off."

    /// The job's first status line.
    static func connecting(_ backend: NotesBackend) -> String {
        switch backend {
        case .lmStudio: "Connecting to LM Studio…"
        case .ollama: "Connecting to Ollama…"
        case .builtIn: "Starting the note writer…"
        case .custom, .none: "Connecting to the notes server…"
        }
    }

    /// For diagnostics.
    static func kind(_ backend: NotesBackend) -> String {
        switch backend {
        case .lmStudio: "LM Studio"
        case .ollama: "Ollama"
        case .builtIn: "Built in"
        case .custom: "Custom server"
        case .none: "None"
        }
    }

    // MARK: Discovery

    /// Asks LM Studio and Ollama on this Mac, side by side, a second each,
    /// and looks for built-in models on disk. Never anything beyond localhost.
    static func discover(lmStudioURL: String = lmStudioURL, ollamaURL: String = ollamaURL,
                         lmStudioInstalled: Bool = Summarizer.hasLMStudio,
                         builtIn: [BuiltInModel] = BuiltInModel.downloaded,
                         userURL: String? = NotesEngine.userURL(stored: Prefs.llmURL),
                         llmModelStored: Bool = Prefs.llmModelStored) async -> FoundServers {
        async let lm: [LMStudioModel]? = isLocal(lmStudioURL) ? LMStudioModels.list(baseURL: lmStudioURL, timeout: 1) : nil
        async let ollama: [OllamaModel]? = ollamaTags(ollamaURL)
        return FoundServers(userURL: userURL, lmStudioModels: await lm, lmStudioInstalled: lmStudioInstalled,
                            ollamaModels: await ollama, builtInDownloaded: builtIn, llmModelStored: llmModelStored)
    }

    static func isLocal(_ url: String) -> Bool {
        guard let host = URLComponents(string: url)?.host?.lowercased() else { return false }
        return ["localhost", "127.0.0.1", "::1"].contains(host)
    }

    /// `GET /api/tags`: nil when Ollama isn't running.
    private static func ollamaTags(_ base: String) async -> [OllamaModel]? {
        guard isLocal(base), let url = URL(string: base + "/api/tags") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 1)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return ollamaModels(from: data)
    }

    static func ollamaModels(from data: Data) -> [OllamaModel]? {
        struct Tags: Decodable { let models: [OllamaModel] }
        return try? JSONDecoder().decode(Tags.self, from: data).models
    }
}

extension SetupState {
    /// Notes are ready when they're turned off ("Not Now") or something writes them.
    static func notesReady(summariesEnabled: Bool, backend: NotesBackend) -> Bool {
        !summariesEnabled || backend != .none
    }
}
