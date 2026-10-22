import Foundation
import Testing
@testable import Earl

/// D-2: a model file is installed only when its checksum matches.
struct ModelFilesTests {
    func temp(_ bytes: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data(bytes.utf8).write(to: url)
        return url
    }

    @Test func hashOfKnownBytes() throws {
        // printf abc | shasum -a 256
        #expect(try ModelFiles.sha256(of: temp("abc"))
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func proxyPageIsRejected() throws {
        let page = try temp("<html>Access denied by proxy</html>")
        #expect(throws: PipelineError.self) {
            try ModelFiles.verify(page, sha256: WhisperModelOption.all[0].sha256)
        }
    }

    @Test func everyOptionHasAChecksum() {
        for o in WhisperModelOption.all + [WhisperModelOption.vad] {
            #expect(o.sha256.count == 64)
            #expect(o.bytes > 0)
        }
    }

    @Test func vadPathIsThePrefsPath() {
        #expect(WhisperModelOption.vad.path == Prefs.vadModel)
    }

    @Test func importMatchesByHashNotName() throws {
        let file = try temp("abc")
        let match = WhisperModelOption.matching(sha256: try ModelFiles.sha256(of: file),
                                                in: [.init(file: "x.bin", name: "X", approxSize: "", note: "",
                                                           sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
                                                           bytes: 3)])
        #expect(match?.file == "x.bin")
    }

    static let abc = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

    func folder() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test func installOntoItselfKeepsTheFile() throws {
        let dir = try folder()
        let f = dir.appendingPathComponent("m.bin")
        try Data("abc".utf8).write(to: f)
        try ModelFiles.install(from: f, to: f, sha256: Self.abc)
        #expect(try String(contentsOf: f, encoding: .utf8) == "abc")
    }

    @Test func installPlacesAMatchingFile() throws {
        let dir = try folder()
        let src = try temp("abc")
        let dest = dir.appendingPathComponent("m.bin")
        try ModelFiles.install(from: src, to: dest, sha256: Self.abc)
        #expect(try String(contentsOf: dest, encoding: .utf8) == "abc")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["m.bin"])
    }

    @Test func installReplacesAnExistingFile() throws {
        let dir = try folder()
        let dest = dir.appendingPathComponent("m.bin")
        try Data("old".utf8).write(to: dest)
        try ModelFiles.install(from: temp("abc"), to: dest, sha256: Self.abc)
        #expect(try String(contentsOf: dest, encoding: .utf8) == "abc")
    }

    @Test func badSourceLeavesExistingFileAndNoTemp() throws {
        let dir = try folder()
        let dest = dir.appendingPathComponent("m.bin")
        try Data("good".utf8).write(to: dest)
        #expect(throws: PipelineError.self) {
            try ModelFiles.install(from: temp("<html>proxy</html>"), to: dest, sha256: Self.abc)
        }
        #expect(try String(contentsOf: dest, encoding: .utf8) == "good")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["m.bin"])
    }

    // MARK: Whisper preference after an import

    @Test func importingATranscriptionModelChoosesItWhenTheChosenOneIsGone() {
        let compact = WhisperModelOption.all.last!
        #expect(Engine.whisperPreference(afterImporting: compact, chosenExists: false) == compact.path)
    }

    @Test func importingKeepsAChosenModelThatExists() {
        #expect(Engine.whisperPreference(afterImporting: WhisperModelOption.all.last!, chosenExists: true) == nil)
    }

    @Test func importingSilenceDetectionNeverChangesTheChoice() {
        #expect(Engine.whisperPreference(afterImporting: .vad, chosenExists: false) == nil)
    }
}
