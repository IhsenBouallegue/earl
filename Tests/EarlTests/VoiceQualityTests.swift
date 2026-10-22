import AVFoundation
import Foundation
import Testing
@testable import Earl

/// V-1: stretched words and silent call tracks.
struct VoiceQualityTests {
    static func word(_ text: String, _ start: Double, _ end: Double) -> TimedWord {
        TimedWord(text: " " + text, start: start, end: end)
    }

    // MARK: Stretched words

    @Test func sentenceStartIsMovedToTheEndOfItsSpan() {
        // "Fine." took the 3.7 s pause before it: it was said right before "Let's".
        let fixed = StretchedWords.fix([Self.word("Fine.", 61.1, 64.8), Self.word("Let's", 64.8, 65.0)])
        #expect(fixed[0].end == 64.8)
        #expect(abs(fixed[0].start - (64.8 - StretchedWords.spokenLength("Fine."))) < 1e-9)
        #expect(fixed[1] == Self.word("Let's", 64.8, 65.0))
    }

    @Test func lowercaseSentenceEndStaysAtTheStart() {
        // "time." ends what was said before the pause.
        let fixed = StretchedWords.fix([Self.word("free", 240.2, 240.5), Self.word("time.", 240.5, 242.6)])
        #expect(fixed[1].start == 240.5)
        #expect(abs(fixed[1].end - (240.5 + StretchedWords.spokenLength("time."))) < 1e-9)
    }

    @Test func midSentenceWordGoesToTheEndAndNormalWordsStay() {
        let words = [Self.word("we", 10, 10.2), Self.word("take-home", 10.2, 34.6), Self.word("exercise", 34.6, 35.1)]
        let fixed = StretchedWords.fix(words)
        #expect(fixed[0] == words[0] && fixed[2] == words[2])
        #expect(fixed[1].end == 34.6 && fixed[1].start > 33)
        // A long but plausible word (under 2 s) is left alone.
        let slow = [Self.word("Regressionstests", 5, 6.8)]
        #expect(StretchedWords.fix(slow) == slow)
    }

    @Test func spokenLengthStaysInBounds() {
        #expect(StretchedWords.spokenLength("I") == 0.25)
        #expect(StretchedWords.spokenLength("Donaudampfschifffahrtsgesellschaft") == 1.2)
    }

    @Test func aStretchedMicWordNoLongerSpansTheOtherSide() throws {
        // A one-word "Mhm." that VAD stretched over 70 s used to start a
        // "Me" turn at 706 s, ahead of everything "Them" said until 777 s.
        let json = """
            {"result": {"language": "de"}, "transcription": [
              {"offsets": {"from": 700000, "to": 700400}, "text": " Okay."},
              {"offsets": {"from": 700400, "to": 777900}, "text": " Mhm."},
              {"offsets": {"from": 777900, "to": 778300}, "text": " Ja,"},
              {"offsets": {"from": 778300, "to": 778700}, "text": " okay."}]}
            """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("earl-stretch-\(UUID().uuidString).json")
        try json.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let phrases = try Transcriber.parsePhrases(url, speaker: "Me").phrases
        #expect(phrases.map(\.turn.text) == ["Okay.", "Mhm.", "Ja, okay."])
        #expect(phrases[1].turn.start > 777)
    }

    // MARK: Silent call tracks

    static func wav(_ samples: [Float]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("earl-silent-\(UUID().uuidString).wav")
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for (i, s) in samples.enumerated() { buffer.floatChannelData![0][i] = s }
        try file.write(from: buffer)
        return url
    }

    @Test func digitalSilenceIsSilentAndQuietSpeechIsNot() throws {
        let silent = try Self.wav([Float](repeating: 0, count: 200_000))
        defer { try? FileManager.default.removeItem(at: silent) }
        #expect(SilentTrack.isSilent(silent) == true)

        // A quiet track (about −50 dBFS) with one short sound near the end.
        var samples = [Float](repeating: 0, count: 200_000)
        for i in 190_000..<190_400 { samples[i] = 0.003 * sin(Float(i) * 0.3) }
        let quiet = try Self.wav(samples)
        defer { try? FileManager.default.removeItem(at: quiet) }
        #expect(SilentTrack.isSilent(quiet) == false)

        #expect(SilentTrack.isSilent(URL(fileURLWithPath: "/nonexistent.wav")) == nil)
    }
}
