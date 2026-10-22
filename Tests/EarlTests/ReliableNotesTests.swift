import Foundation
import Testing
@testable import Earl

/// A fake LM Studio at http://earl-mock.test (R2-7): the native model list,
/// load and unload, and chat completions that answer from a script.
final class MockLMStudio: URLProtocol, @unchecked Sendable {
    static let host = "earl-mock.test"
    static let baseURL = "http://\(host)/v1"
    static let model = "test/model-27b"

    struct State {
        var loadedContext: Int? = 8192
        var reasons = true
        var loadFails = false
        var rejectReasoningEffort = false
        /// Q-3: a server that doesn't know `response_format`/`json_schema`.
        var rejectResponseFormat = false
        var shrinkAfterFirstChat: Int?
        /// Answers for chat requests, in order; the last one repeats.
        var replies: [String] = []
        var loads: [Int] = []
        var unloads = 0
        var chats: [[String: Any]] = []
    }

    nonisolated(unsafe) private static var state = State()
    private static let lock = NSLock()
    private static let registered: Void = { URLProtocol.registerClass(MockLMStudio.self) }()

    static func reset(_ change: (inout State) -> Void = { _ in }) {
        _ = registered
        lock.withLock { state = State(); change(&state) }
    }
    static var current: State { lock.withLock { state } }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == host }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let path = request.url?.path ?? ""
        let body = Self.body(of: request)
        var status = 200
        var reply: Data
        switch path {
        case "/api/v1/models":
            let s = Self.current
            var model: [String: Any] = [
                "type": "llm", "key": Self.model, "params_string": "27B", "size_bytes": 17_000_000_000,
                "max_context_length": 131072,
                "loaded_instances": s.loadedContext.map { [["id": Self.model, "config": ["context_length": $0]]] } ?? [],
            ]
            if s.reasons { model["capabilities"] = ["reasoning": ["allowed_options": ["off", "on"], "default": "on"]] }
            reply = Self.json(["models": [model]])
        case "/api/v1/models/load":
            let context = body["context_length"] as? Int ?? 0
            let fails = Self.lock.withLock { () -> Bool in
                Self.state.loads.append(context)
                if !Self.state.loadFails { Self.state.loadedContext = context }
                return Self.state.loadFails
            }
            if fails {
                status = 500
                reply = Self.json(["error": ["message": "Not enough memory"]])
            } else {
                reply = Self.json(["status": "loaded", "load_config": ["context_length": context]])
            }
        case "/api/v1/models/unload":
            Self.lock.withLock { Self.state.unloads += 1; Self.state.loadedContext = nil }
            reply = Self.json(["instance_id": Self.model])
        case "/v1/chat/completions":
            let (text, rejectReason) = Self.lock.withLock { () -> (String, String?) in
                if Self.state.rejectReasoningEffort && body["reasoning_effort"] != nil { return ("", "reasoning_effort") }
                if Self.state.rejectResponseFormat && body["response_format"] != nil { return ("", "response_format") }
                Self.state.chats.append(body)
                if let shrink = Self.state.shrinkAfterFirstChat { Self.state.loadedContext = shrink; Self.state.shrinkAfterFirstChat = nil }
                let text = Self.state.replies.isEmpty ? "" : Self.state.replies.count > 1 ? Self.state.replies.removeFirst() : Self.state.replies[0]
                return (text, nil)
            }
            if let rejectReason {
                status = 400
                reply = Self.json(["error": ["message": "Unknown parameter: \(rejectReason)"]])
            } else if body["stream"] as? Bool == true {
                let chunk = Self.json(["choices": [["delta": ["content": text]]]])
                reply = Data(("data: " + String(decoding: chunk, as: UTF8.self) + "\n\ndata: [DONE]\n\n").utf8)
            } else {
                reply = Self.json(["choices": [["message": ["content": text]]]])
            }
        default:
            status = 404
            reply = Data()
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func json(_ object: Any) -> Data { (try? JSONSerialization.data(withJSONObject: object)) ?? Data() }

    private static func body(of request: URLRequest) -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 65536)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            stream.close()
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
}

@Suite(.serialized)
struct ReliableNotesTests {
    static let valid = "TITLE: Release planning\n\n## Summary\n- We planned the release.\n\n## Action items\n- [ ] Tom: write the notes"

    static func summarizer() -> Summarizer {
        var s = Summarizer()
        s.baseURL = MockLMStudio.baseURL
        s.model = MockLMStudio.model
        s.vocabulary = []
        s.reasoning = true // the mock model thinks: its answer needs room
        return s
    }

    /// About 12k tokens of transcript at ~3 characters per token.
    static let longTranscript = (0..<400).map { "[00:\($0 % 60)] Speaker \($0 % 3 + 1): " + String(repeating: "word ", count: 17) }
        .joined(separator: "\n")

    // MARK: Context

    @Test func contextSizes() {
        #expect(LMStudioModels.tokensNeeded(transcriptChars: 36000, reasons: true) == 12000 + 600 + 3000 + 4000)
        #expect(LMStudioModels.contextToLoad(needed: 19600, modelMax: 262144) == 32768)
        #expect(LMStudioModels.contextToLoad(needed: 5000, modelMax: 131072) == 16384)
        #expect(LMStudioModels.contextToLoad(needed: 300_000, modelMax: 262144) == 65536)
        #expect(LMStudioModels.contextToLoad(needed: 20000, modelMax: 8192) == 8192)
    }

    @Test func parameterCounts() {
        #expect(LMStudioModel.billions(params: "27B", id: "x") == 27)
        #expect(LMStudioModel.billions(params: nil, id: "google/gemma-4-e4b") == 4)
        #expect(LMStudioModel.billions(params: nil, id: "qwen/qwen3.8-27b") == 27)
        #expect(LMStudioModel.billions(params: nil, id: "qwen/qwen3-30b-a3b") == 30)
        #expect(LMStudioModel.billions(params: nil, id: "llama-3.2-3b-instruct") == 3)
        #expect(LMStudioModel.billions(params: nil, id: "mistral-nemo") == nil)
    }

    @Test func recommendsStrongestModelThatFits() throws {
        let json = """
            {"models": [
             {"type":"llm","key":"qwen/qwen3.8-27b","params_string":"27B","size_bytes":17742039110,"quantization":{"name":"Q4_K_M","bits_per_weight":4}},
             {"type":"llm","key":"prism-ml/bonsai-27b","params_string":"27B","size_bytes":8521076756,"quantization":{"name":"2bit","bits_per_weight":2}},
             {"type":"llm","key":"google/gemma-4-e4b","params_string":"4B","size_bytes":6861935454,"quantization":{"name":"4bit","bits_per_weight":4}},
             {"type":"embedding","key":"text-embedding-nomic","size_bytes":84106624}
            ]}
            """
        struct List: Decodable { let models: [LMStudioModel] }
        let models = try JSONDecoder().decode(List.self, from: Data(json.utf8)).models
        let gb: UInt64 = 1 << 30
        #expect(ModelAdvice.recommended(models, memory: 96 * gb) == "qwen/qwen3.8-27b")
        #expect(ModelAdvice.recommended(models, memory: 32 * gb) == "prism-ml/bonsai-27b")
        #expect(ModelAdvice.recommended(models, memory: 16 * gb) == "google/gemma-4-e4b")
        #expect(ModelAdvice.recommended(models, memory: 8 * gb) == nil)
        #expect(ModelAdvice.sizeText(models[0]).hasPrefix("27B · Q4_K_M · "))
    }

    // MARK: Checking answers

    @Test func validation() {
        #expect(!NotesCheck.isValid(""))
        #expect(!NotesCheck.isValid("   \n"))
        #expect(!NotesCheck.isValid("TITLE: Weekly sync"))
        #expect(!NotesCheck.isValid("TITLE: Weekly sync\n\n## Summary\n"))
        #expect(!NotesCheck.isValid("We talked about the release and some other things."))
        #expect(NotesCheck.isValid(Self.valid))
        #expect(NotesCheck.isValid("## Summary\n- Short meeting."))
    }

    @Test func dropsGemmaPlainTextThinking() {
        let raw = "Here's a thinking process:\n1. Analyze\n<channel|>TITLE: Sync\n\n## Summary\n- Done."
        let (text, thinking) = Summarizer.visible(raw)
        #expect(text == "TITLE: Sync\n\n## Summary\n- Done.")
        #expect(thinking > 20)
        #expect(Summarizer.parse(text).title == "Sync")
        #expect(Summarizer.visible("<think>hm</think>Hi").text == "Hi")
    }

    // MARK: Prompt

    @Test func languageAndPerspective() {
        #expect(NotesLanguage.resolve(setting: "auto", detected: "de") == "de")
        #expect(NotesLanguage.resolve(setting: "auto", detected: nil) == nil)
        #expect(NotesLanguage.resolve(setting: "auto", detected: "auto") == nil)
        #expect(NotesLanguage.resolve(setting: "en", detected: "de") == "en")

        var prompt = NotesPrompt()
        prompt.language = "de"
        prompt.userName = "Ahsan"
        let text = prompt.final(intro: "", material: "Transcript:\n\n[00:00] Me: Hallo")
        let language = try! #require(text.range(of: "Write the notes in German."))
        let format = try! #require(text.range(of: "Write the meeting notes in exactly this format"))
        #expect(language.upperBound < format.lowerBound)
        #expect(text.contains("point of view of Ahsan ('Me')"))
        #expect(text.contains("belongs to the person who agreed to do it"))
        #expect(!NotesPrompt.standardSystem.contains("same language"))

        prompt.language = nil
        #expect(prompt.final(intro: "", material: "").contains("same language as the transcript"))
    }

    // Q-3: notes keep an unbacked "Speaker N" label instead of guessing an
    // invitee by elimination or role, including for action item owners.
    @Test func systemPromptKeepsUnbackedSpeakerLabels() {
        #expect(NotesPrompt.standardSystem.contains("may not all have spoken"))
        #expect(NotesPrompt.standardSystem.contains("action item owners"))
        #expect(NotesPrompt.standardSystem.contains("Labels like \"Speaker 2\""))
    }

    // MARK: Mocked server

    @Test func reloadsSmallContextInsteadOfFailing() async throws {
        MockLMStudio.reset { $0.loadedContext = 8192; $0.replies = [Self.valid] }
        var statuses: [String] = []
        let result = try await Self.summarizer().summarize(Self.longTranscript) { event in
            if case .status(let s) = event { statuses.append(s) }
        }
        let state = MockLMStudio.current
        #expect(state.loads == [32768])
        #expect(state.unloads == 1)
        #expect(state.chats.count == 1) // fits in one pass now, no chunking
        #expect(result.context == 32768)
        #expect(result.loadedByEarl)
        #expect(result.title == "Release planning")
        #expect(statuses.contains("Loading model-27b with 32k context…"))
    }

    @Test func thinkingOffNeedsLessContextAndSaysSo() async throws {
        MockLMStudio.reset { $0.loadedContext = 8192; $0.replies = [Self.valid] }
        var s = Self.summarizer()
        s.reasoning = false
        // 10k tokens: 16k without thinking, where thinking would need 32k.
        _ = try await s.summarize(String(Self.longTranscript.prefix(30000))) { _ in }
        #expect(MockLMStudio.current.loads == [16384])
        #expect(MockLMStudio.current.chats.first?["reasoning_effort"] as? String == "none")
    }

    @Test func keepsLargeEnoughModelAsItIs() async throws {
        MockLMStudio.reset { $0.loadedContext = 65536; $0.replies = [Self.valid] }
        let result = try await Self.summarizer().summarize(Self.longTranscript) { _ in }
        #expect(MockLMStudio.current.loads.isEmpty)
        #expect(MockLMStudio.current.unloads == 0)
        #expect(result.context == 65536)
        #expect(!result.loadedByEarl)
    }

    @Test func loadsModelThatIsNotLoaded() async throws {
        MockLMStudio.reset { $0.loadedContext = nil; $0.replies = [Self.valid] }
        _ = try await Self.summarizer().summarize("[00:00] Me: Short meeting.") { _ in }
        #expect(MockLMStudio.current.loads == [16384])
        #expect(MockLMStudio.current.unloads == 0)
    }

    @Test func chunksWhenLoadingFails() async throws {
        MockLMStudio.reset { $0.loadedContext = 8192; $0.loadFails = true; $0.replies = ["- a note", Self.valid] }
        let result = try await Self.summarizer().summarize(Self.longTranscript) { _ in }
        // Unknown context after the failed load: small chunks, then the final pass.
        #expect(MockLMStudio.current.chats.count > 2)
        #expect(result.title == "Release planning")
    }

    @Test func retriesEmptyAnswerOnce() async throws {
        MockLMStudio.reset { $0.loadedContext = 32768; $0.replies = ["", Self.valid] }
        let result = try await Self.summarizer().summarize("[00:00] Me: Hello.") { _ in }
        #expect(MockLMStudio.current.chats.count == 2)
        #expect(result.markdown.hasPrefix("## Summary"))
    }

    @Test func failsVisiblyAfterSecondEmptyAnswer() async throws {
        for bad in ["", "TITLE: Weekly sync"] {
            MockLMStudio.reset { $0.loadedContext = 32768; $0.replies = [bad] }
            await #expect(throws: PipelineError.self) {
                _ = try await Self.summarizer().summarize("[00:00] Me: Hello.") { _ in }
            }
            #expect(MockLMStudio.current.chats.count == 2)
        }
    }

    @Test func retriesAfterContextShrank() async throws {
        // The first answer is empty because LM Studio reloaded the model with 4k meanwhile.
        MockLMStudio.reset { $0.loadedContext = 32768; $0.shrinkAfterFirstChat = 4096; $0.replies = ["", Self.valid] }
        let result = try await Self.summarizer().summarize("[00:00] Me: Hello.") { _ in }
        #expect(MockLMStudio.current.loads == [16384])
        #expect(MockLMStudio.current.chats.count == 2)
        #expect(result.title == "Release planning")
    }

    @Test func answerRetriesAndSkipsReasoning() async throws {
        MockLMStudio.reset { $0.loadedContext = 32768; $0.replies = ["", "{\"S1\": null}"] }
        let text = try await Self.summarizer().answer(system: "s", prompt: "p", maxTokens: 2000, reasoning: false)
        #expect(text == "{\"S1\": null}")
        let chats = MockLMStudio.current.chats
        #expect(chats.count == 2)
        #expect(chats[0]["reasoning_effort"] as? String == "none")
        #expect(chats[0]["max_tokens"] as? Int == 2000)

        MockLMStudio.reset { $0.loadedContext = 32768; $0.replies = [""] }
        await #expect(throws: PipelineError.self) {
            _ = try await Self.summarizer().answer(system: "s", prompt: "p", reasoning: false)
        }
    }

    @Test func answerWorksWithServersWithoutReasoningEffort() async throws {
        MockLMStudio.reset { $0.rejectReasoningEffort = true; $0.replies = ["ok"] }
        let text = try await Self.summarizer().answer(system: "s", prompt: "p", reasoning: false)
        #expect(text == "ok")
        #expect(MockLMStudio.current.chats.first?["reasoning_effort"] == nil)
    }

    // MARK: JSON schema (Q-3)

    static let namesSchema = Summarizer.AnswerSchema(name: "speaker_names", schema: [
        "type": "object",
        "properties": ["S1": ["anyOf": [["type": "null"], ["type": "object"]]]],
        "required": ["S1"],
    ])

    @Test func answerSendsTheSchemaAsResponseFormat() async throws {
        MockLMStudio.reset { $0.replies = ["{\"S1\": null}"] }
        let text = try await Self.summarizer().answer(system: "s", prompt: "p", reasoning: false, schema: Self.namesSchema)
        #expect(text == "{\"S1\": null}")
        let sent = try #require(MockLMStudio.current.chats.first?["response_format"] as? [String: Any])
        #expect(sent["type"] as? String == "json_schema")
        let jsonSchema = try #require(sent["json_schema"] as? [String: Any])
        #expect(jsonSchema["name"] as? String == "speaker_names")
        #expect(jsonSchema["strict"] as? Bool == true)
        #expect(jsonSchema["schema"] != nil)
    }

    @Test func answerFallsBackWithoutSchemaOn400() async throws {
        MockLMStudio.reset { $0.rejectResponseFormat = true; $0.replies = ["ok"] }
        let text = try await Self.summarizer().answer(system: "s", prompt: "p", reasoning: false, schema: Self.namesSchema)
        #expect(text == "ok")
        #expect(MockLMStudio.current.chats.first?["response_format"] == nil)
    }

    @Test func callersWithoutASchemaAreUnaffected() async throws {
        MockLMStudio.reset { $0.replies = ["ok"] }
        let text = try await Self.summarizer().answer(system: "s", prompt: "p", reasoning: false)
        #expect(text == "ok")
        #expect(MockLMStudio.current.chats.first?["response_format"] == nil)
    }

    // MARK: Saved data

    @Test func oldMeetingJSONStillLoads() throws {
        let json = #"{"title":"T","titleIsDefault":true,"startedAt":0,"duration":60,"status":"done"}"#
        let info = try JSONDecoder().decode(MeetingInfo.self, from: Data(json.utf8))
        #expect(info.summaryContext == nil)
        #expect(NotesContextText.text(info) == nil)
        var loaded = info
        loaded.summaryContext = 32768
        loaded.summaryContextByEarl = true
        #expect(NotesContextText.text(loaded) == "Loaded with 32k context by Earl")
    }
}
