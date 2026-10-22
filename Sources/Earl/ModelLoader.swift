import Foundation

// R2-7: Earl loads the summary model itself, with a context large enough for
// the meeting. LM Studio's on-demand ("JIT") loading uses a small default
// context, and the context of a model the user loaded can be anything.

/// A model as LM Studio's native v1 API reports it: size, parameter count,
/// reasoning options and the context of each loaded instance.
struct LMStudioModel: Decodable, Hashable, Identifiable {
    struct Quantization: Decodable, Hashable {
        var name: String?
        var bits_per_weight: Double?
    }
    struct Instance: Decodable, Hashable {
        struct Config: Decodable, Hashable { var context_length: Int? }
        var id: String
        var config: Config?
    }
    struct Capabilities: Decodable, Hashable {
        struct Reasoning: Decodable, Hashable {
            var allowed_options: [String]?
            var `default`: String?
        }
        var reasoning: Reasoning?
    }

    var type: String?
    var key: String
    var display_name: String?
    var architecture: String?
    var quantization: Quantization?
    var size_bytes: Int64?
    var params_string: String?
    var loaded_instances: [Instance]?
    var max_context_length: Int?
    var capabilities: Capabilities?

    var id: String { key }
    var isLLM: Bool { type != "embedding" && type != "embeddings" && !key.contains("embed") }
    var isLoaded: Bool { !(loaded_instances ?? []).isEmpty }
    /// The context of the loaded instance, if any.
    var loadedContext: Int? { loaded_instances?.first?.config?.context_length }
    /// True when the model thinks before answering unless told not to.
    var reasons: Bool {
        guard let r = capabilities?.reasoning else { return false }
        return (r.default ?? "on") != "off"
    }
    /// Billions of parameters, from "27B", "4B", "E4B" or the model name.
    var billions: Double? { Self.billions(params: params_string, id: key) }

    static func billions(params: String?, id: String) -> Double? {
        // "27B", "3.8B", "e4b", "qwen3-30b-a3b" (the first "<n>b" is the total).
        guard let pattern = try? Regex<(Substring, Substring)>(#"(?i)(?:^|[^a-z0-9.])e?(\d+(?:\.\d+)?)b(?:$|[^a-z])"#)
        else { return nil }
        for text in [params, id.split(separator: "/").last.map(String.init)].compactMap({ $0 }) {
            if let m = text.firstMatch(of: pattern), let n = Double(m.1) { return n }
        }
        return nil
    }
}

enum LMStudioModels {
    /// Leaves room for the prompt's instructions around the transcript.
    static let promptTokens = 600
    /// The written notes.
    static let answerTokens = 3000
    /// What a reasoning model thinks before it answers (3–4k on Qwen 27B).
    static let reasoningTokens = 4000
    /// Never ask for less; small contexts only save a little memory.
    static let minContext = 16_384
    /// LM Studio prints a memory "safe_ceiling" in its log but has no API for
    /// it, so stay within a size that fits comfortably next to other apps.
    static let maxContext = 65_536

    /// Tokens a summary needs in one pass: ~3 characters per token.
    static func tokensNeeded(transcriptChars: Int, reasons: Bool) -> Int {
        transcriptChars / 3 + promptTokens + answerTokens + (reasons ? reasoningTokens : 0)
    }

    /// The context to load with: `needed` rounded up to a power of two,
    /// within 16k and the smaller of the model's maximum and the safe cap.
    static func contextToLoad(needed: Int, modelMax: Int?) -> Int {
        let cap = min(modelMax ?? maxContext, maxContext)
        var c = minContext
        while c < needed && c < cap { c *= 2 }
        return min(c, cap)
    }

    // MARK: - API

    static func root(_ baseURL: String) -> String {
        let t = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        return t.hasSuffix("/v1") ? String(t.dropLast(3)) : t
    }

    /// All models, or nil when the server isn't LM Studio (or is off).
    static func list(baseURL: String, timeout: TimeInterval = 3) async -> [LMStudioModel]? {
        struct List: Decodable { let models: [LMStudioModel] }
        guard let url = URL(string: root(baseURL) + "/api/v1/models") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let list = try? JSONDecoder().decode(List.self, from: data) else { return nil }
        return list.models
    }

    static func model(baseURL: String, id: String) async -> LMStudioModel? {
        await list(baseURL: baseURL)?.first { $0.key == id }
    }

    /// Loads `id` with `context` tokens. REST first (LM Studio 0.4+), then
    /// the `lms` CLI. Returns the context LM Studio actually used, if it says.
    static func load(baseURL: String, id: String, context: Int) async throws -> Int? {
        if let url = URL(string: root(baseURL) + "/api/v1/models/load") {
            var req = URLRequest(url: url, timeoutInterval: 600)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": id, "context_length": context, "echo_load_config": true,
            ] as [String: Any])
            struct Reply: Decodable {
                struct Config: Decodable { var context_length: Int? }
                var status: String?
                var load_config: Config?
            }
            if let (data, response) = try? await URLSession.shared.data(for: req) {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 200, let reply = try? JSONDecoder().decode(Reply.self, from: data) {
                    return reply.load_config?.context_length ?? context
                }
                // 404: an older LM Studio without the endpoint; try the CLI.
                // Anything else is a real refusal, e.g. not enough memory.
                if status != 404 {
                    struct Failure: Decodable { struct E: Decodable { var message: String? }; var error: E? }
                    let message = (try? JSONDecoder().decode(Failure.self, from: data))?.error?.message
                        ?? String(decoding: data.prefix(300), as: UTF8.self)
                    throw PipelineError.message("LM Studio couldn't load \(id): \(message)")
                }
            }
        }
        guard Summarizer.hasLMStudio else { return nil }
        try await ProcessRunner.run(Summarizer.lmsPath, ["load", id, "--context-length", String(context), "-y"])
        return await model(baseURL: baseURL, id: id)?.loadedContext
    }

    /// Unloads one instance, so it can be loaded again with a larger context.
    static func unload(baseURL: String, instance: String) async {
        if let url = URL(string: root(baseURL) + "/api/v1/models/unload") {
            var req = URLRequest(url: url, timeoutInterval: 60)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: ["instance_id": instance])
            if let (_, response) = try? await URLSession.shared.data(for: req),
               (response as? HTTPURLResponse)?.statusCode == 200 { return }
        }
        if Summarizer.hasLMStudio { try? await ProcessRunner.run(Summarizer.lmsPath, ["unload", instance]) }
    }

    // MARK: - Making sure

    struct Prepared: Equatable {
        /// The context the model is loaded with, when known.
        var context: Int?
        /// Earl loaded it for this request.
        var loadedByEarl: Bool
        var reasons: Bool
        /// D-3 (Ollama): the derived model to send requests to.
        var model: String?
        /// D-3: the context couldn't be raised.
        var warning: String?
    }

    /// Makes sure `id` is loaded with at least `needed` tokens of context,
    /// (re)loading only that model, and only when its context is too small.
    /// Other models, and a large enough instance the user loaded, stay as they are.
    /// Not LM Studio: returns nil and the request goes out as before.
    /// `reasoning: false` when the request turns thinking off.
    static func prepare(baseURL: String, id: String, transcriptChars: Int, reasoning: Bool = true,
                        status: @escaping @MainActor (String) -> Void) async -> Prepared? {
        guard let info = await model(baseURL: baseURL, id: id) else { return nil }
        let reasons = info.reasons && reasoning
        let needed = tokensNeeded(transcriptChars: transcriptChars, reasons: reasons)
        if let current = info.loadedContext, current >= needed {
            return Prepared(context: current, loadedByEarl: false, reasons: reasons)
        }
        let target = contextToLoad(needed: needed, modelMax: info.max_context_length)
        // Already as large as it may get: chunking handles the rest.
        if let current = info.loadedContext, current >= target {
            return Prepared(context: current, loadedByEarl: false, reasons: reasons)
        }
        let name = id.split(separator: "/").last.map(String.init) ?? id
        await status("Loading \(name) with \(target / 1024)k context…")
        for instance in info.loaded_instances ?? [] { await unload(baseURL: baseURL, instance: instance.id) }
        do {
            let loaded = try await load(baseURL: baseURL, id: id, context: target)
            // Ask again: the load reply may not say, and MLX models report their maximum.
            let context = await model(baseURL: baseURL, id: id)?.loadedContext ?? loaded
            return Prepared(context: context, loadedByEarl: true, reasons: reasons)
        } catch {
            NSLog("Earl: \(error.localizedDescription)")
            // Fall back to LM Studio's on-demand loading, with its small default context.
            return Prepared(context: nil, loadedByEarl: false, reasons: reasons)
        }
    }
}
