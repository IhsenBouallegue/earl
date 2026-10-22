import Testing
@testable import Earl

struct DiagnosticsTests {
    @Test func reportHasFactsButNoMeetingContent() {
        let snap = DiagnosticsSnapshot(version: "0.5.0", build: "130", macOS: "26.7", chip: "Apple M3 Pro", memoryGB: 36,
                                       bundlePath: "/Users/anna/Applications/Earl.app",
                                       whisperPath: "/Users/anna/Applications/Earl.app/Contents/Helpers/whisper-cli",
                                       whisperVersion: "1.9.5", models: ["ggml-large-v3-turbo.bin": 1_624_555_275],
                                       vad: true, speakerModels: false, mic: "granted", screenAudio: "not asked",
                                       llmURL: "http://localhost:1234/v1", llmReachable: false, llmKind: "LM Studio",
                                       llmModel: "google/gemma-4-e4b", meetingCount: 12,
                                       recentErrors: ["whisper-cli failed (exit code 3)."])
        let r = Diagnostics.report(snap)
        #expect(r.contains("Earl 0.5.0 (130)"))
        #expect(r.contains("Screen & System Audio: not asked"))
        #expect(r.contains("whisper-cli failed (exit code 3)."))
        #expect(r.contains("/Users/~/Applications/Earl.app"))   // user name masked
        #expect(!r.contains("anna"))
    }

    @Test func errorsAreMaskedAndCut() {
        let long = "/Users/bob/x.wav " + String(repeating: "a", count: 300)
        let snap = DiagnosticsSnapshot(version: "dev", build: "dev", macOS: "26", chip: "?", memoryGB: 8, bundlePath: "", whisperPath: "",
                                       whisperVersion: nil, models: [:], vad: false, speakerModels: false, mic: "", screenAudio: "",
                                       llmURL: "", llmReachable: false, llmKind: "not running", llmModel: "", meetingCount: 0,
                                       recentErrors: [long])
        let r = Diagnostics.report(snap)
        #expect(!r.contains("bob"))
        #expect(!r.contains(String(repeating: "a", count: 201)))
    }

    private func snap(url: String = "", errors: [String]) -> DiagnosticsSnapshot {
        DiagnosticsSnapshot(version: "dev", build: "dev", macOS: "26", chip: "?", memoryGB: 8, bundlePath: "", whisperPath: "",
                            whisperVersion: nil, models: [:], vad: false, speakerModels: false, mic: "", screenAudio: "",
                            llmURL: url, llmReachable: false, llmKind: "not running", llmModel: "", meetingCount: 0,
                            recentErrors: errors)
    }

    @Test func serverReplyBodyNeverSurvives() {
        let r = Diagnostics.report(snap(errors: [
            "AI server returned HTTP 400: {\"error\":\"bad\",\"input\":\"Anna said the merger closes Friday\"}",
            "AI server stalled: Anna said the merger closes Friday"]))
        #expect(r.contains("AI server returned HTTP 400"))
        #expect(!r.contains("merger"))
        #expect(!r.contains("Anna"))
    }

    @Test func urlCredentialsAreMasked() {
        let r = Diagnostics.report(snap(url: "http://user:secret@host:1234/v1",
                                        errors: ["Invalid AI server URL http://user:secret@host/v1"]))
        #expect(!r.contains("secret"))
        #expect(!r.contains("user:"))
        #expect(r.contains("host:1234/v1"))
    }

    @Test func maskHappensBeforeTheCut() {
        let e = String(repeating: "a", count: 190) + " /Users/bobby/x.wav"
        #expect(!Diagnostics.report(snap(errors: [e])).contains("bobby"))
    }

    @Test func externalTextAfterAColonIsDropped() {
        let r = Diagnostics.report(snap(errors: [
            "LM Studio couldn't load google/gemma-4-e4b: Anna said the merger closes Friday",
            "whisper-cli failed (exit code 3)."]))
        #expect(r.contains("LM Studio couldn't load google/gemma-4-e4b"))
        #expect(!r.contains("merger"))
        #expect(r.contains("whisper-cli failed (exit code 3)."))
    }
}
