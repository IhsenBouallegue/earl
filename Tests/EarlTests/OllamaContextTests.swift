import Foundation
import Testing
@testable import Earl

struct OllamaContextTests {
    @Test func derivedNameIsStableAndLegal() {
        #expect(OllamaContext.derivedName(model: "qwen3:14b", context: 32768) == "earl/qwen3-14b-32k")
        #expect(OllamaContext.derivedName(model: "hf.co/org/Model:Q4_K_M", context: 16384) == "earl/hf.co-org-model-q4_k_m-16k")
    }
    @Test func contextUsesTheSharedSizing() {
        // ~9k-token meeting → 16k, same rounding as LM Studio.
        #expect(LMStudioModels.contextToLoad(needed: LMStudioModels.tokensNeeded(transcriptChars: 27_000, reasons: false),
                                             modelMax: nil) == 16_384)
    }
    @Test func aDerivedModelIsNotDerivedAgain() {
        #expect(OllamaContext.isDerived("earl/qwen3-14b-32k"))
        #expect(!OllamaContext.isDerived("qwen3:14b"))
    }
    @Test func modelMaxComesFromModelInfo() throws {
        let json = #"{"model_info":{"general.architecture":"qwen3","qwen3.context_length":40960,"qwen3.block_count":36}}"#
        #expect(OllamaContext.contextLength(inShow: Data(json.utf8)) == 40960)
        #expect(OllamaContext.contextLength(inShow: Data("{}".utf8)) == nil)
    }
    @Test func aCustomURLGivesTheServerRoot() {
        #expect(OllamaContext.root("http://box.local:11434/v1") == "http://box.local:11434")
        #expect(OllamaContext.root("http://localhost:11434/v1/") == "http://localhost:11434")
    }
    @Test func onlyOllamaAnswersTagsWithModels() {
        #expect(OllamaContext.isTagsReply(Data(#"{"models":[{"name":"qwen3:4b"}]}"#.utf8)))
        #expect(OllamaContext.isTagsReply(Data(#"{"models":[]}"#.utf8)))
        #expect(!OllamaContext.isTagsReply(Data(#"{"data":[]}"#.utf8)))
        #expect(!OllamaContext.isTagsReply(Data("<html>".utf8)))
    }
    @Test func aFailedProbeIsRetriedAfterAMinuteButASuccessIsKept() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        var cache = OllamaContext.ProbeCache()
        #expect(cache.lookup(root: "http://a", now: t0) == nil)
        cache.store(root: "http://a", answer: false, now: t0)
        cache.store(root: "http://b", answer: true, now: t0)
        #expect(cache.lookup(root: "http://a", now: t0 + 59) == false)
        #expect(cache.lookup(root: "http://a", now: t0 + 61) == nil)
        #expect(cache.lookup(root: "http://b", now: t0 + 86_400) == true)
    }
}
