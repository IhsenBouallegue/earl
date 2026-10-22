import Foundation
import Testing
@testable import Earl

/// FluidAudio's resource bundle is not shipped in Earl.app (strict signing
/// forbids it at the app root) and only FluidAudio's TTS reads it. So Earl must
/// never use FluidAudio's TTS.
struct BundleSafetyTests {
    @Test func earlNeverUsesFluidAudioTTS() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources/Earl")
        let pattern = try Regex(#"\b(Tts[A-Z]\w*|TTS[A-Z]\w*|KokoroTts\w*|KokoroAne\w*|LuxTts\w*|NeuTts\w*|PocketTTS\w*|StyleTTS2\w*|Supertonic3\w*|ChatterboxTts\w*)"#)
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        var scanned = 0
        for case let url as URL in files where url.pathExtension == "swift" {
            scanned += 1
            let text = try String(contentsOf: url, encoding: .utf8)
            if let m = text.firstMatch(of: pattern) { offenders.append("\(url.lastPathComponent): \(m.output[0].substring ?? "")") }
        }
        #expect(scanned > 0)
        #expect(offenders.isEmpty, "FluidAudio TTS used: \(offenders)")
    }
}
