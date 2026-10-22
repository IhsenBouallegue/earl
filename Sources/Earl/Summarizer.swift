import Foundation

/// A model as reported by the local AI server.
struct LLMModel: Identifiable, Hashable, Decodable {
    let id: String
    var type: String?
    var publisher: String?
    var arch: String?
    var quantization: String?
    var state: String?
    var maxContextLength: Int?
    var loadedContextLength: Int?
    var compatibilityType: String?

    var isLoaded: Bool { state == "loaded" }
    var isEmbedding: Bool { type == "embeddings" || id.contains("embed") }

    enum CodingKeys: String, CodingKey {
        case id, type, publisher, arch, quantization, state
        case maxContextLength = "max_context_length"
        case loadedContextLength = "loaded_context_length"
        case compatibilityType = "compatibility_type"
    }
}

/// Summarizes transcripts with a local LLM through an OpenAI-compatible
/// endpoint (LM Studio by default; Ollama works too at http://localhost:11434/v1),
/// streaming the answer as it is written.
struct Summarizer {
    /// D-3: the backend Earl chose (LM Studio, Ollama, built in, or the user's own server).
    var baseURL = NotesEngine.baseURL(for: NotesEngine.current) ?? Prefs.llmURL
    var model = NotesEngine.model(for: NotesEngine.current, fallback: Prefs.llmModel)
    /// Which backend `model` belongs to; Ollama needs its context raised per model.
    var backend = NotesEngine.current
    /// D-3: the context the built-in server needs for this meeting, once known.
    var builtInContext: Int?
    /// D-3: the server that runs the built-in note writer (its own in a test harness).
    var builtInServer = BuiltInServer.shared
    /// A server already running with this context, nothing to load (the notes
    /// eval against a llama-server started by hand, D-3 Task 5).
    var fixedContext: Int?
    /// Terms whose spelling the notes should follow (R1-3).
    var vocabulary = WhisperPrompt.fitting(Prefs.vocabularyTerms)

    /// The words sent for notes (R2-7).
    var prompt = NotesPrompt()
    /// Let reasoning models think before writing (R2-7), per model in
    /// Settings, off by default. Off sends `reasoning_effort: "none"`.
    var reasoning = Prefs.notesThinking(NotesEngine.model(for: NotesEngine.current, fallback: Prefs.llmModel))

    struct Result {
        var title: String?
        var markdown: String
        /// U-2: what happened, in one sentence, for the front page.
        var headline: String?
        var tokensPerSecond: Double?
        /// R2-7: the context the model ran with, and whether Earl loaded it.
        var context: Int?
        var loadedByEarl = false
        /// D-3: something the notes' reader should know, e.g. that the context
        /// couldn't be raised. Not shown yet; Earl logs it.
        var warning: String?
    }

    enum Event {
        /// What the model is doing right now, e.g. "Loading model…".
        case status(String)
        /// A new generation started; the previous text should be cleared.
        case newPass(label: String)
        /// Streaming progress of the current pass: the visible text so far,
        /// characters of reasoning (models that think before answering), and speed.
        case progress(text: String, thinkingChars: Int, tokens: Int, perSecond: Double)
    }

    typealias Handler = @MainActor (Event) -> Void

    /// A JSON schema for `answer` (Q-3), sent as `response_format:
    /// {type: "json_schema", json_schema: {name, strict: true, schema}}`.
    /// `schema` is the schema body (an object with "type", "properties", …).
    struct AnswerSchema {
        var name: String
        var schema: [String: Any]
    }

    /// `context` (R2-1) names the meeting, its participants and who "Me" is.
    func summarize(_ transcript: String, context: SummaryContext? = nil,
                   onEvent: @escaping Handler) async throws -> Result {
        let intro = (context?.line ?? "") + vocabularyLine
        var prompt = self.prompt
        if prompt.userName == nil { prompt.userName = context?.userName }
        await onEvent(.status("Checking \(model)…"))

        // R2-7: load the model with a context that fits the meeting, rather
        // than whatever LM Studio's on-demand loading picks.
        let contextChars = prompt.seriesBlock.count // S-1: earlier meetings take room too
        let prepared = await prepare(transcriptChars: transcript.count + contextChars, onEvent: onEvent)
        // D-3: Ollama's derived model, for this summary only (not stored in Prefs).
        var run = self
        if let derived = prepared?.model { run.model = derived }
        if case .builtIn = backend { run.builtInContext = prepared?.context } // one start serves every pass
        return try await run.write(transcript, intro: intro, prompt: prompt, contextChars: contextChars,
                                   prepared: prepared, onEvent: onEvent)
    }

    private func write(_ transcript: String, intro: String, prompt: NotesPrompt, contextChars: Int,
                       prepared: LMStudioModels.Prepared?, onEvent: @escaping Handler) async throws -> Result {
        let contextTokens: Int
        let reserve: Int
        if let prepared {
            contextTokens = prepared.context ?? 4096
            reserve = LMStudioModels.promptTokens + LMStudioModels.answerTokens
                + (prepared.reasons ? LMStudioModels.reasoningTokens : 0)
        } else {
            // Not LM Studio: fit the transcript into what the server reports.
            let info = await Self.modelInfo(baseURL: baseURL, id: model)
            if let info, !info.isLoaded {
                await onEvent(.status("LM Studio is loading \(model)…"))
            }
            contextTokens = info?.loadedContextLength ?? 4096
            reserve = 2500
        }
        // ~3 characters per token keeps us on the safe side.
        let chunkChars = max(4000, (contextTokens - reserve) * 3 - contextChars) // S-1

        var speeds: [Double] = []
        let material: String
        if transcript.count > chunkChars {
            let chunks = Self.split(transcript, limit: chunkChars)
            var notes: [String] = []
            for (i, chunk) in chunks.enumerated() {
                let label = "Reading part \(i + 1) of \(chunks.count)"
                await onEvent(.newPass(label: label))
                let (text, speed) = try await checkedChat(
                    prompt.part(i + 1, of: chunks.count, intro: intro, chunk: chunk), label: label,
                    transcriptChars: transcript.count, valid: { !$0.isEmpty }, onEvent: onEvent)
                notes.append(text)
                if let speed { speeds.append(speed) }
            }
            material = "Notes taken from each part of the meeting, in order:\n\n" + notes.joined(separator: "\n\n---\n\n")
        } else {
            material = "Transcript:\n\n" + transcript
        }

        await onEvent(.newPass(label: "Writing the summary"))
        let (output, speed) = try await checkedChat(
            prompt.final(intro: intro, material: material), label: "Writing the summary",
            transcriptChars: transcript.count, valid: NotesCheck.isValid, onEvent: onEvent)
        if let speed { speeds.append(speed) }

        var result = Self.parse(output)
        if prompt.kind.isListening { result.markdown = NotesTidy.withoutInvitations(result.markdown) } // K-1
        result.tokensPerSecond = speeds.isEmpty ? nil : speeds.reduce(0, +) / Double(speeds.count)
        result.context = prepared?.context
        result.loadedByEarl = prepared?.loadedByEarl ?? false
        result.warning = prepared?.warning
        return result
    }

    /// Loads the model with enough context for a transcript of this length
    /// (R2-7). nil when the server isn't LM Studio.
    func prepare(transcriptChars: Int, onEvent: Handler?) async -> LMStudioModels.Prepared? {
        if let fixedContext { return LMStudioModels.Prepared(context: fixedContext, loadedByEarl: false, reasons: reasoning) }
        if case .builtIn(let m) = backend { // D-3: the server starts with this context on the first request
            return LMStudioModels.Prepared(context: builtInContext ?? Self.builtInContext(chars: transcriptChars, reasons: reasoning, model: m),
                                           loadedByEarl: true, reasons: reasoning)
        }
        if await isOllama() { return await prepareOllama(transcriptChars: transcriptChars, onEvent: onEvent) }
        return await LMStudioModels.prepare(baseURL: baseURL, id: model, transcriptChars: transcriptChars,
                                     reasoning: reasoning) { status in
            onEvent?(.status(status))
        }
    }

    /// Ollama by choice, or a custom URL that answers like Ollama (D-3).
    private func isOllama() async -> Bool {
        switch backend {
        case .ollama: true
        case .custom: await OllamaContext.isOllamaServer(baseURL: baseURL)
        default: false
        }
    }

    /// Ollama: a derived copy of the model with room for the meeting. On failure
    /// the base model runs as before, with a warning.
    private func prepareOllama(transcriptChars: Int, onEvent: Handler?) async -> LMStudioModels.Prepared? {
        // Already the derived model (a retry on a copy): nothing more to do.
        if OllamaContext.isDerived(model) { return nil }
        do {
            let name = model
            let r = try await OllamaContext.prepare(model: model, transcriptChars: transcriptChars, reasons: reasoning,
                                                    baseURL: baseURL) {
                await onEvent?(.status("Giving \(name) room for the whole meeting…"))
            }
            return LMStudioModels.Prepared(context: r.context, loadedByEarl: false, reasons: reasoning, model: r.model)
        } catch {
            NSLog("Earl: Ollama context for \(model): \(error)")
            return LMStudioModels.Prepared(context: nil, loadedByEarl: false, reasons: reasoning,
                                           warning: "Notes may miss the start of long meetings: Ollama couldn't raise its context.")
        }
    }

    /// One pass that never accepts an unusable answer (R2-7). An empty answer
    /// is what a model loaded with too small a context gives back, so check
    /// the model (reloading it if its context shrank), try once more, then fail.
    private func checkedChat(_ text: String, label: String, transcriptChars: Int, valid: (String) -> Bool,
                             onEvent: @escaping Handler) async throws -> (String, Double?) {
        let first = try await chat(text, onEvent: onEvent)
        if valid(first.0) { return first }
        await onEvent(.status("The model returned nothing usable. Checking it…"))
        _ = await prepare(transcriptChars: transcriptChars, onEvent: onEvent)
        await onEvent(.newPass(label: label + ", second try"))
        let second = try await chat(text, onEvent: onEvent)
        guard valid(second.0) else { throw PipelineError.message(NotesCheck.emptyMessage) }
        return second
    }

    /// One line with the vocabulary for the user message, or nothing (R1-3).
    var vocabularyLine: String {
        vocabulary.isEmpty ? "" : "Correct spellings of names and terms: \(vocabulary.joined(separator: ", ")).\n\n"
    }

    /// A tiny request to check that the server and model answer, used by the Test button.
    func test(onEvent: @escaping Handler) async throws -> Double? {
        await onEvent(.newPass(label: "Test"))
        return try await chat("In one short sentence, say hello and name one thing you're good at.",
                              onEvent: onEvent).1
    }

    static func parse(_ output: String) -> Result {
        var lines = output.components(separatedBy: "\n")
        let title = take("TITLE:", from: &lines)
        let headline = take("HEADLINE:", from: &lines) // U-2
        return Result(title: title, markdown: lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
                      headline: headline)
    }

    /// Removes the first "KEY: value" line and returns its value, without
    /// the quotes and Markdown some models wrap it in.
    private static func take(_ key: String, from lines: inout [String]) -> String? {
        guard let i = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).uppercased().hasPrefix(key) })
        else { return nil }
        let raw = lines[i].trimmingCharacters(in: .whitespaces).dropFirst(key.count)
        lines.remove(at: i)
        let value = raw.trimmingCharacters(in: CharacterSet(charactersIn: " *\"'#"))
        return value.isEmpty ? nil : value
    }

    private static func split(_ text: String, limit: Int) -> [String] {
        var chunks: [String] = []
        var current = ""
        for line in text.components(separatedBy: "\n") {
            if !current.isEmpty && current.count + line.count > limit {
                chunks.append(current)
                current = ""
            }
            current += line + "\n"
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    // MARK: - Streaming chat

    private func chat(_ prompt: String, onEvent: @escaping Handler) async throws -> (String, Double?) {
        try await withServer(chars: self.prompt.system.count + prompt.count, onEvent: onEvent) { server in
            try await stream(prompt, server: server, onEvent: onEvent)
        }
    }

    /// D-3: the built-in server's context for a request of `chars` characters,
    /// within the model's cap (a longer meeting is read in parts).
    static func builtInContext(chars: Int, reasons: Bool, model: BuiltInModel) -> Int {
        LMStudioModels.contextToLoad(needed: LMStudioModels.tokensNeeded(transcriptChars: chars, reasons: reasons),
                                     modelMax: model.contextCap)
    }

    /// Where requests go: the base URL (…/v1) and, for the built-in server, its key.
    struct Server {
        var url: String
        var key: String?

        func authorize(_ req: inout URLRequest) {
            if let key { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        }
    }

    /// Runs `request` against the server, starting LM Studio's once if it isn't running.
    /// D-3: the built-in one starts here, with room for this request (`chars`), or
    /// for the whole meeting when `builtInContext` says so. `ensure` hands back a
    /// lease, so the server never stops or restarts while `request` runs; the
    /// lease ends here.
    private func withServer<T>(chars: Int, onEvent: Handler?, _ request: (Server) async throws -> T) async throws -> T {
        if case .builtIn(let m) = backend {
            guard let file = m.fileURL else { throw PipelineError.message(BuiltInServer.notDownloaded) }
            let context = max(builtInContext ?? 0, Self.builtInContext(chars: chars, reasons: reasoning, model: m))
            let e = try await builtInServer.ensure(model: file, context: context) { status in
                await onEvent?(.status(status))
            }
            do {
                let result = try await request(Server(url: e.url, key: e.key))
                await builtInServer.end()
                return result
            } catch let error as URLError where error.code != .cancelled {
                await builtInServer.end()
                throw PipelineError.message(BuiltInServer.stopped)
            } catch {
                await builtInServer.end()
                throw error
            }
        }
        let server = Server(url: baseURL)
        do {
            return try await request(server)
        } catch let error as URLError where error.code == .cannotConnectToHost || error.code == .networkConnectionLost {
            // LM Studio's server is usually off; try starting it once.
            await onEvent?(.status("Starting LM Studio's server…"))
            if await Self.startLMStudioServer() {
                return try await request(server)
            }
            throw PipelineError.message("""
                Can't reach the local AI server at \(baseURL). Open LM Studio and start the server \
                (Developer tab → Start Server), or run: lms server start
                """)
        }
    }

    // MARK: - Single answer

    /// One non-streaming request for a short, structured answer (R2-3 names
    /// speakers with it). Returns the visible text, without inline reasoning.
    /// The token cap leaves room for reasoning models, which think for
    /// thousands of tokens before a short answer.
    /// `reasoning: false` (R2-7) asks the model not to think first
    /// (`reasoning_effort: "none"`), which turns minutes into seconds.
    /// An empty answer is retried once after checking the model, then throws.
    func answer(system: String, prompt: String, maxTokens: Int = 12000, reasoning: Bool = true,
               schema: AnswerSchema? = nil) async throws -> String {
        // D-3: Ollama runs the derived model that fits this prompt.
        if !OllamaContext.isDerived(model), await isOllama(),
           let derived = await prepareOllama(transcriptChars: system.count + prompt.count, onEvent: nil)?.model {
            var run = self
            run.model = derived
            return try await run.answer(system: system, prompt: prompt, maxTokens: maxTokens, reasoning: reasoning,
                                        schema: schema)
        }
        let first = try await answerOnce(system: system, prompt: prompt, maxTokens: maxTokens, reasoning: reasoning,
                                         schema: schema)
        if !first.isEmpty { return first }
        _ = await prepare(transcriptChars: prompt.count, onEvent: nil)
        let second = try await answerOnce(system: system, prompt: prompt, maxTokens: maxTokens, reasoning: reasoning,
                                          schema: schema)
        guard !second.isEmpty else { throw PipelineError.message("The model \(model) returned nothing, twice.") }
        return second
    }

    private func answerOnce(system: String, prompt: String, maxTokens: Int, reasoning: Bool,
                            schema: AnswerSchema?) async throws -> String {
        // One lease for the request and its fallbacks.
        try await withServer(chars: system.count + prompt.count, onEvent: nil) { server in
            try await answerOnce(system: system, prompt: prompt, maxTokens: maxTokens, reasoning: reasoning,
                                 schema: schema, server: server)
        }
    }

    private func answerOnce(system: String, prompt: String, maxTokens: Int, reasoning: Bool,
                            schema: AnswerSchema?, server: Server) async throws -> String {
        guard let url = URL(string: Self.trimmed(server.url) + "/chat/completions") else {
            throw PipelineError.message("Invalid AI server URL: \(baseURL)")
        }
        func request(effort: Bool, useSchema: Bool) throws -> URLRequest {
            var req = URLRequest(url: url, timeoutInterval: 600)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            server.authorize(&req)
            var body: [String: Any] = [
                "model": model,
                "temperature": 0,
                "max_tokens": maxTokens,
                "stream": false,
                "messages": [
                    ["role": "system", "content": system],
                    ["role": "user", "content": prompt],
                ],
            ]
            if effort { body["reasoning_effort"] = "none" }
            if useSchema, let schema {
                body["response_format"] = [
                    "type": "json_schema",
                    "json_schema": ["name": schema.name, "strict": true, "schema": schema.schema],
                ]
            }
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            return req
        }

        struct Reply: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String? }
                let message: Message?
            }
            let choices: [Choice]?
        }
        var useSchema = schema != nil
        var useEffort = !reasoning
        var (data, response) = try await URLSession.shared.data(for: request(effort: useEffort, useSchema: useSchema))
        var status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // A server that rejects the schema: ask again without it (Q-3), like
        // the reasoning_effort fallback below.
        if status == 400, useSchema {
            let message = String(decoding: data, as: UTF8.self)
            if message.contains("response_format") || message.contains("json_schema") {
                useSchema = false
                (data, response) = try await URLSession.shared.data(for: request(effort: useEffort, useSchema: useSchema))
                status = (response as? HTTPURLResponse)?.statusCode ?? 0
            }
        }
        // A server that doesn't know reasoning_effort: ask again without it.
        if status == 400, useEffort, String(decoding: data, as: UTF8.self).contains("reasoning") {
            useEffort = false
            (data, response) = try await URLSession.shared.data(for: request(effort: useEffort, useSchema: useSchema))
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
        }
        guard status == 200 else {
            throw PipelineError.message("AI server returned HTTP \(status): \(String(decoding: data.prefix(500), as: UTF8.self))")
        }
        let content = try JSONDecoder().decode(Reply.self, from: data).choices?.first?.message?.content ?? ""
        return Self.visible(content).text
    }

    /// S-3: one streamed answer with its own system prompt (Ask Earl).
    /// Starts LM Studio's server if needed; returns the visible text.
    func streamAnswer(system: String, prompt: String, onEvent: @escaping Handler) async throws -> String {
        try await withServer(chars: system.count + prompt.count, onEvent: onEvent) { server in
            try await stream(prompt, system: system, server: server, onEvent: onEvent)
        }.0
    }

    private func stream(_ prompt: String, system: String? = nil, server: Server, // S-3
                        onEvent: @escaping Handler) async throws -> (String, Double?) {
        guard let url = URL(string: Self.trimmed(server.url) + "/chat/completions") else {
            throw PipelineError.message("Invalid AI server URL: \(baseURL)")
        }
        func request(effort: Bool) throws -> URLRequest {
            var req = URLRequest(url: url, timeoutInterval: 900)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            server.authorize(&req)
            var body: [String: Any] = [
                "model": model,
                "temperature": 0.2,
                "stream": true,
                "messages": [
                    ["role": "system", "content": system ?? self.prompt.system], // S-3
                    ["role": "user", "content": prompt],
                ],
            ]
            if effort { body["reasoning_effort"] = "none" } // R2-7
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            return req
        }

        var (bytes, response) = try await URLSession.shared.bytes(for: request(effort: !reasoning))
        var status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 400 && !reasoning {
            // A server that doesn't know reasoning_effort: ask again without it.
            (bytes, response) = try await URLSession.shared.bytes(for: request(effort: false))
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
        }
        guard status == 200 else {
            var body = ""
            for try await line in bytes.lines { body += line; if body.count > 500 { break } }
            throw PipelineError.message("AI server returned HTTP \(status): \(body)")
        }

        struct Chunk: Decodable {
            struct Choice: Decodable {
                struct Delta: Decodable {
                    let content: String?
                    let reasoning_content: String?
                    let reasoning: String?
                }
                let delta: Delta?
            }
            let choices: [Choice]?
        }

        var raw = ""
        var reasoningChars = 0
        var tokens = 0
        var firstToken: Date?
        var lastEmit = Date.distantPast
        let decoder = JSONDecoder()

        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let chunk = try? decoder.decode(Chunk.self, from: Data(payload.utf8)),
                  let delta = chunk.choices?.first?.delta else { continue }

            let reasoning = (delta.reasoning_content ?? "") + (delta.reasoning ?? "")
            let content = delta.content ?? ""
            guard !reasoning.isEmpty || !content.isEmpty else { continue }
            if firstToken == nil { firstToken = Date() }
            tokens += 1
            reasoningChars += reasoning.count
            raw += content

            // Throttle UI updates to ~10 per second, measured from the end of the
            // last update, so a busy UI can never slow down reading the stream.
            if Date().timeIntervalSince(lastEmit) > 0.1 {
                await emit(raw: raw, reasoningChars: reasoningChars, tokens: tokens, since: firstToken, onEvent)
                lastEmit = Date()
            }
        }
        await emit(raw: raw, reasoningChars: reasoningChars, tokens: tokens, since: firstToken, onEvent)

        let speed = firstToken.map { Double(tokens) / max(0.1, Date().timeIntervalSince($0)) }
        return (Self.visible(raw).text, speed)
    }

    private func emit(raw: String, reasoningChars: Int, tokens: Int, since first: Date?, _ onEvent: Handler) async {
        let (text, inlineThinking) = Self.visible(raw)
        let speed = first.map { Double(tokens) / max(0.1, Date().timeIntervalSince($0)) } ?? 0
        await onEvent(.progress(text: text, thinkingChars: reasoningChars + inlineThinking, tokens: tokens, perSecond: speed))
    }

    /// Splits inline `<think>…</think>` reasoning (Qwen and others) from the answer.
    static func visible(_ raw: String) -> (text: String, thinkingChars: Int) {
        // R2-7: with reasoning_effort "none", Gemma 4 still thinks, in plain
        // text, and marks the start of its answer with "<channel|>" (gpt-oss
        // uses "<|message|>"). Everything before the last marker is thinking.
        for marker in ["<channel|>", "<|message|>"] {
            if let m = raw.range(of: marker, options: .backwards) {
                let (text, inner) = visible(String(raw[m.upperBound...]))
                return (text, raw.distance(from: raw.startIndex, to: m.lowerBound) + inner)
            }
        }
        guard let open = raw.range(of: "<think>") else {
            return (raw.trimmingCharacters(in: .whitespacesAndNewlines), 0)
        }
        guard let close = raw.range(of: "</think>", range: open.upperBound..<raw.endIndex) else {
            return ("", raw.distance(from: open.upperBound, to: raw.endIndex))
        }
        let text = String(raw[..<open.lowerBound]) + String(raw[close.upperBound...])
        return (text.trimmingCharacters(in: .whitespacesAndNewlines), raw.distance(from: open.upperBound, to: close.lowerBound))
    }

    // MARK: - Server info

    private static func trimmed(_ url: String) -> String {
        url.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
    }

    /// Server root without the `/v1` suffix, for LM Studio's native API.
    private static func root(_ baseURL: String) -> String {
        let t = trimmed(baseURL)
        return t.hasSuffix("/v1") ? String(t.dropLast(3)) : t
    }

    struct ServerStatus {
        var reachable: Bool
        var isLMStudio: Bool
        var models: [LLMModel]
    }

    /// Lists models. Uses LM Studio's richer native API when available, and
    /// falls back to the OpenAI-compatible list (Ollama and others).
    static func serverStatus(baseURL: String) async -> ServerStatus {
        struct List: Decodable { let data: [LLMModel] }
        func fetch(_ urlString: String) async -> [LLMModel]? {
            guard let url = URL(string: urlString) else { return nil }
            var req = URLRequest(url: url, timeoutInterval: 3)
            req.cachePolicy = .reloadIgnoringLocalCacheData
            guard let (data, response) = try? await URLSession.shared.data(for: req),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let list = try? JSONDecoder().decode(List.self, from: data) else { return nil }
            // D-3: Earl's larger-context copies of Ollama models aren't for picking.
            return list.data.filter { !$0.isEmbedding && !OllamaContext.isDerived($0.id) }
        }
        if let models = await fetch(root(baseURL) + "/api/v0/models") {
            return ServerStatus(reachable: true, isLMStudio: true, models: models)
        }
        if let models = await fetch(trimmed(baseURL) + "/models") {
            return ServerStatus(reachable: true, isLMStudio: false, models: models)
        }
        return ServerStatus(reachable: false, isLMStudio: false, models: [])
    }

    static func modelInfo(baseURL: String, id: String) async -> LLMModel? {
        await serverStatus(baseURL: baseURL).models.first { $0.id == id }
    }

    static let lmsPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".lmstudio/bin/lms").path

    static var hasLMStudio: Bool { FileManager.default.isExecutableFile(atPath: lmsPath) }

    /// Starts LM Studio's local server using its `lms` CLI, if installed.
    @discardableResult
    static func startLMStudioServer() async -> Bool {
        guard hasLMStudio else { return false }
        do {
            try await ProcessRunner.run(lmsPath, ["server", "start"])
            try await Task.sleep(for: .seconds(1))
            return true
        } catch {
            return false
        }
    }
}
