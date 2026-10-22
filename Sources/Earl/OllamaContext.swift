import Foundation
import Synchronization

/// D-3: Ollama's OpenAI endpoint has no context parameter and runs a model
/// with its `num_ctx`, so a long meeting is silently cut. Earl makes a
/// derived model with the context it needs (it shares the weights, so it
/// costs no disk) and sends that summary's requests to it.
enum OllamaContext {
    static let prefix = "earl/"

    /// "qwen3:14b" at 32768 → "earl/qwen3-14b-32k".
    static func derivedName(model: String, context: Int) -> String {
        let base = model.lowercased().map { $0 == "/" || $0 == ":" ? "-" : String($0) }.joined()
        return "\(prefix)\(base)-\(context / 1024)k"
    }

    static func isDerived(_ model: String) -> Bool { model.hasPrefix(prefix) }

    /// A derived name without Earl's prefix and context suffix:
    /// "earl/qwen3-14b-32k:latest" → "qwen3-14b". Other names unchanged.
    static func stripped(_ model: String) -> String {
        guard isDerived(model) else { return model }
        var s = String(model.dropFirst(prefix.count))
        if s.hasSuffix(":latest") { s.removeLast(":latest".count) }
        if let dash = s.lastIndex(of: "-"), case let size = s[s.index(after: dash)...],
           size.hasSuffix("k"), size.count > 1, size.dropLast().allSatisfy(\.isNumber) {
            s = String(s[..<dash])
        }
        return s
    }

    /// The model a derived one was made from, among those Ollama lists
    /// (a stored setting may name the copy). Not derived: unchanged.
    static func base(of model: String, among models: [OllamaModel]) -> String {
        guard isDerived(model) else { return model }
        let key = stripped(model)
        func flat(_ name: String) -> String {
            name.lowercased().map { $0 == "/" || $0 == ":" ? "-" : String($0) }.joined()
        }
        let bases = models.map(\.name).filter { !isDerived($0) }
        return bases.first { flat($0) == key }
            ?? bases.first { $0.hasSuffix(":latest") && flat(String($0.dropLast(":latest".count))) == key }
            ?? key
    }

    /// `model_info["<arch>.context_length"]` from an `/api/show` reply.
    static func contextLength(inShow data: Data) -> Int? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let info = json["model_info"] as? [String: Any] else { return nil }
        return info.first { $0.key.hasSuffix(".context_length") }?.value as? Int
    }

    /// The server root for a base URL: "http://box:11434/v1" -> "http://box:11434".
    static func root(_ baseURL: String) -> String { LMStudioModels.root(baseURL) }

    /// Whether an `/api/tags` reply is Ollama's (it lists `models`).
    static func isTagsReply(_ data: Data) -> Bool {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["models"] is [Any]
    }

    /// What the probe learned per server root: a yes is kept for good, a no for
    /// 60 s (the server may just be down or slow right now).
    struct ProbeCache {
        static let negativeLifetime: TimeInterval = 60
        private var entries: [String: (answer: Bool, at: Date)] = [:]

        /// nil when the server should be probed (again).
        func lookup(root: String, now: Date) -> Bool? {
            guard let e = entries[root] else { return nil }
            if e.answer { return true }
            return now.timeIntervalSince(e.at) < Self.negativeLifetime ? false : nil
        }
        mutating func store(root: String, answer: Bool, now: Date) { entries[root] = (answer, now) }
    }

    private static let probed = Mutex(ProbeCache())

    /// A user-typed URL may point at Ollama (this Mac or a team box). Asks
    /// `/api/tags` once per URL (2 s) and remembers the answer.
    static func isOllamaServer(baseURL: String) async -> Bool {
        let root = root(baseURL)
        if let known = probed.withLock({ $0.lookup(root: root, now: Date()) }) { return known }
        var answer = false
        if let url = URL(string: root + "/api/tags") {
            let req = URLRequest(url: url, timeoutInterval: 2)
            if let (data, response) = try? await URLSession.shared.data(for: req),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                answer = isTagsReply(data)
            }
        }
        probed.withLock { $0.store(root: root, answer: answer, now: Date()) }
        return answer
    }

    /// One `/api/create` per derived name at a time; a second caller waits for the first.
    private actor Creations {
        var inFlight: [String: Task<Void, Error>] = [:]
        func create(_ name: String, _ work: @escaping @Sendable () async throws -> Void) async throws {
            if let running = inFlight[name] { return try await running.value }
            let task = Task { try await work() }
            inFlight[name] = task
            defer { inFlight[name] = nil }
            try await task.value
        }
    }
    private static let creations = Creations()

    enum Failure: Error { case request(String) }

    /// The model to send this meeting's requests to, and its context. Reuses
    /// a derived model that already exists; creates it otherwise.
    static func prepare(model: String, transcriptChars: Int, reasons: Bool,
                        baseURL: String = NotesEngine.ollamaURL,
                        onCreate: (@Sendable () async -> Void)? = nil) async throws -> (model: String, context: Int) {
        let root = root(baseURL)
        let needed = LMStudioModels.tokensNeeded(transcriptChars: transcriptChars, reasons: reasons)
        let max = (try? await post(root + "/api/show", ["model": model])).flatMap { contextLength(inShow: $0) }
        let context = LMStudioModels.contextToLoad(needed: needed, modelMax: max)
        let name = derivedName(model: model, context: context)
        if try await exists(name, root: root) { return (name, context) }
        await onCreate?()
        try await creations.create(name) {
            _ = try await post(root + "/api/create", [
                "model": name, "from": model, "parameters": ["num_ctx": context], "stream": false,
            ])
        }
        return (name, context)
    }

    private static func exists(_ name: String, root: String) async throws -> Bool {
        guard let url = URL(string: root + "/api/tags") else { throw Failure.request("bad URL") }
        let (data, _) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 5))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let names = (json?["models"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        // Ollama lists "earl/x:latest".
        return names.contains { $0 == name || $0 == name + ":latest" }
    }

    private static func post(_ urlString: String, _ body: [String: Any]) async throws -> Data {
        guard let url = URL(string: urlString) else { throw Failure.request("bad URL") }
        var req = URLRequest(url: url, timeoutInterval: 120)
        req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw Failure.request(String(data: data, encoding: .utf8) ?? "HTTP error")
        }
        return data
    }
}
