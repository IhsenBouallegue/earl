import Foundation
import Testing
@testable import Earl

/// D-3 Task 5: the built-in note writers, one per memory tier (chosen by the notes eval).
struct BuiltInModelTests {
    static func gb(_ n: UInt64) -> UInt64 { n << 30 }
    static let tier8 = BuiltInModel.all.first { $0.minMemoryGB == 8 }!
    static let tier16 = BuiltInModel.all.first { $0.minMemoryGB == 16 }!
    static let tier32 = BuiltInModel.all.first { $0.minMemoryGB == 32 }!
    static let tier64 = BuiltInModel.all.first { $0.minMemoryGB == 64 }!

    @Test func memoryMapsToTiers() {
        #expect(BuiltInModel.forMemory(Self.gb(4)) == Self.tier8) // below the smallest tier: the smallest
        #expect(BuiltInModel.forMemory(Self.gb(8)) == Self.tier8)
        #expect(BuiltInModel.forMemory(Self.gb(12)) == Self.tier8)
        #expect(Self.tier8.id == "qwen3.5-4b")
        #expect(BuiltInModel.forMemory(Self.gb(16)) == Self.tier16)
        #expect(BuiltInModel.forMemory(Self.gb(24)) == Self.tier16)
        #expect(BuiltInModel.forMemory(Self.gb(32)) == Self.tier32)
        #expect(BuiltInModel.forMemory(Self.gb(48)) == Self.tier32)
        #expect(BuiltInModel.forMemory(Self.gb(64)) == Self.tier64)
        #expect(BuiltInModel.forMemory(Self.gb(128)) == Self.tier64)
    }

    @Test func catalogIsWellFormed() {
        #expect(Set(BuiltInModel.all.map(\.minMemoryGB)) == [8, 16, 32, 64])
        #expect(Set(BuiltInModel.all.map(\.sha256)).count == BuiltInModel.all.count)
        #expect(Set(BuiltInModel.all.map(\.id)).count == BuiltInModel.all.count)
        for m in BuiltInModel.all {
            #expect(m.sha256.count == 64 && m.sha256.allSatisfy(\.isHexDigit))
            #expect(m.url.absoluteString == "https://huggingface.co/\(m.url.pathComponents[1])/\(m.url.pathComponents[2])/resolve/main/\(m.file)")
            #expect(m.file.hasSuffix(".gguf"))
            #expect(m.path.path.hasSuffix("/models/llm/\(m.file)"))
        }
        // The plan's size limits: ≤ 7 GB for 16 GB Macs, ≤ 14 GB for 32 GB Macs.
        #expect(Self.tier8.bytes <= 3_500_000_000)
        #expect(Self.tier16.bytes <= 7_000_000_000)
        #expect(Self.tier32.bytes <= 14_000_000_000)
    }

    @Test func bestOfDownloaded() {
        let m16 = Self.gb(16), m64 = Self.gb(64)
        #expect(BuiltInModel.best(of: [], memory: m16) == nil)
        #expect(BuiltInModel.best(of: BuiltInModel.all, memory: m16) == Self.tier16)
        #expect(BuiltInModel.best(of: BuiltInModel.all, memory: m64) == Self.tier64)
        // This Mac's tier isn't there: the largest that suits it.
        #expect(BuiltInModel.best(of: [Self.tier16, Self.tier32], memory: m64) == Self.tier32)
        #expect(BuiltInModel.best(of: [Self.tier64, Self.tier8], memory: m16) == Self.tier8)
        // Only larger tiers on disk: none (it would swap); the right-size download is offered.
        #expect(BuiltInModel.best(of: [Self.tier64], memory: m16) == nil)
        #expect(BuiltInModel.best(of: [Self.tier64, Self.tier32], memory: m16) == nil)
        #expect(BuiltInModel.best(of: [Self.tier16], memory: Self.gb(8)) == nil)
    }

    @Test func tooLargeForThisMacMeansNothingWritesNotes() {
        let f = FoundServers(userURL: nil, lmStudioModels: nil, lmStudioInstalled: false, ollamaModels: nil,
                             builtInDownloaded: [Self.tier64])
        #expect(NotesEngine.choose(f, memory: Self.gb(16), preferredModel: nil) == .none)
    }

    /// "Use a File I Have…" with a larger tier's file: refused, in plain words.
    @Test func importRefusesALargerTier() {
        #expect(BuiltInModel.importRefusal(Self.tier64, memory: Self.gb(16)) == "This notes writer needs a Mac with more memory.")
        #expect(BuiltInModel.importRefusal(Self.tier32, memory: Self.gb(16)) != nil)
        #expect(BuiltInModel.importRefusal(Self.tier16, memory: Self.gb(16)) == nil)
        #expect(BuiltInModel.importRefusal(Self.tier8, memory: Self.gb(16)) == nil)
        #expect(BuiltInModel.importRefusal(Self.tier64, memory: Self.gb(96)) == nil)
    }

    /// A file of another size (a leftover, a partial copy) doesn't count as the model.
    @Test func onlyTheWholeFileCounts() {
        #expect(Self.tier16.isComplete(fileSize: Self.tier16.bytes))
        #expect(!Self.tier16.isComplete(fileSize: Self.tier16.bytes - 1))
        #expect(!Self.tier16.isComplete(fileSize: nil))
    }

    /// Deleting the model in use stops its server, unless something is using it.
    @Test func deletedModelStopsTheServerWhenFree() {
        #expect(BuiltInServer.canStopNow(inFlight: 0, appBusy: false))
        #expect(!BuiltInServer.canStopNow(inFlight: 1, appBusy: false))
        #expect(!BuiltInServer.canStopNow(inFlight: 0, appBusy: true))
    }

    @Test func chooseUsesTheTierForThisMac() {
        let f = FoundServers(userURL: nil, lmStudioModels: nil, lmStudioInstalled: false, ollamaModels: nil,
                             builtInDownloaded: [Self.tier64, Self.tier16])
        #expect(NotesEngine.choose(f, memory: Self.gb(16), preferredModel: nil) == .builtIn(model: Self.tier16))
        #expect(NotesEngine.choose(f, memory: Self.gb(96), preferredModel: nil) == .builtIn(model: Self.tier64))
        #expect(NotesEngine.model(for: .builtIn(model: Self.tier16), fallback: "x") == Self.tier16.id)
    }

    /// A Mac with no LM Studio or Ollama and the file on disk: built in.
    @Test func discoveredBuiltInIsChosen() async {
        let found = await NotesEngine.discover(lmStudioURL: "http://127.0.0.1:9", ollamaURL: "http://127.0.0.1:9",
                                               lmStudioInstalled: false, builtIn: [Self.tier16], userURL: nil)
        #expect(NotesEngine.choose(found, memory: Self.gb(16), preferredModel: "google/gemma-4-e4b") == .builtIn(model: Self.tier16))
    }

    /// "Use a File I Have…" takes the note writer's GGUF too, by its checksum.
    @Test func importMatchesTheNoteWriter() {
        let item = Engine.ModelFile.matching(sha256: Self.tier32.sha256)
        #expect(item?.destination == Self.tier32.path)
        #expect(item?.url == Self.tier32.url)
        #expect(Engine.ModelFile.matching(sha256: WhisperModelOption.all[0].sha256)?.file == WhisperModelOption.all[0].file)
        #expect(Engine.ModelFile.matching(sha256: String(repeating: "0", count: 64)) == nil)
    }

    @Test func onboardingNamesThisMacsModel() {
        let model = BuiltInModel.forMemory(ProcessInfo.processInfo.physicalMemory)
        #expect(OnboardingCopy.notes.primary == "Download (\(model.approxSize))")
        #expect(OnboardingCopy.notes.body.contains(model.displayName))
    }

    /// Chosen with thinking off, and run that way: every request says `reasoning_effort: "none"`.
    @Test func builtInNeverThinks() {
        for m in BuiltInModel.all { #expect(!Prefs.notesThinking(m.id)) }
    }

    /// On 8 and 16 GB Macs the server never runs past 32k; a longer meeting is read in parts.
    @Test func smallMacsCapTheContext() {
        let long = 400_000 // characters: far past 64k tokens
        #expect(Self.tier8.contextCap == 32_768)
        #expect(Self.tier16.contextCap == 32_768)
        #expect(Self.tier32.contextCap == nil)
        #expect(Self.tier64.contextCap == nil)
        #expect(Summarizer.builtInContext(chars: long, reasons: false, model: Self.tier8) == 32_768)
        #expect(Summarizer.builtInContext(chars: long, reasons: false, model: Self.tier16) == 32_768)
        #expect(Summarizer.builtInContext(chars: long, reasons: false, model: Self.tier32) == LMStudioModels.maxContext)
        #expect(Summarizer.builtInContext(chars: 1_000, reasons: false, model: Self.tier8) == LMStudioModels.minContext)
    }
}
