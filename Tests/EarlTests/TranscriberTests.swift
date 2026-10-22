import Foundation
import Testing
@testable import Earl

struct TranscriberTests {
    @Test func parsesLiveSegment() {
        let turn = Transcriber.parseSegment("[00:01:02.500 --> 00:01:05.000]  Hello there", speaker: "Them")
        #expect(turn?.start == 62.5)
        #expect(turn?.end == 65)
        #expect(turn?.text == "Hello there")
    }

    @Test func skipsNoiseSegments() {
        #expect(Transcriber.parseSegment("[00:00:00.000 --> 00:00:02.000]  [BLANK_AUDIO]", speaker: "Me") == nil)
    }

    @Test func dropsEchoedMicSegments() {
        let segments = [
            Turn(start: 0, end: 4, speaker: "Them", text: "Let's ship the release on Friday"),
            Turn(start: 0.3, end: 4.2, speaker: "Me", text: "let's ship the release on friday"),
            Turn(start: 6, end: 8, speaker: "Me", text: "Sounds good to me"),
        ]
        let turns = Transcriber.buildTurns(from: segments)
        #expect(turns.map(\.speaker) == ["Them", "Me"])
        #expect(turns.last?.text == "Sounds good to me")
    }

    @Test func mergesConsecutiveTurnsOfSameSpeaker() {
        let segments = [
            Turn(start: 0, end: 2, speaker: "Them", text: "One."),
            Turn(start: 3, end: 5, speaker: "Them", text: "Two."),
        ]
        #expect(Transcriber.buildTurns(from: segments).map(\.text) == ["One. Two."])
    }

    // MARK: Mic phrases from a long word-level segment (Q-1)

    /// Word-level output (`-ml 1 -sow`), as whisper-cli writes it: one
    /// "segment" per word, offsets in ms.
    private static func wordJSON(_ words: [(text: String, from: Int, to: Int)]) -> String {
        let segments = words.map { "{\"offsets\": {\"from\": \($0.from), \"to\": \($0.to)}, \"text\": \"\($0.text)\"}" }
        return "{\"result\": {\"language\": \"en\"}, \"transcription\": [\(segments.joined(separator: ","))]}"
    }

    private static func write(_ json: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("earl-phrases-\(UUID().uuidString).json")
        try json.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func longMicSegmentBreaksIntoPhrasesOnAPause() throws {
        // A pause of more than 1 s (600 ms -> 2000 ms) starts a new phrase,
        // and a sentence end always does too, regardless of the gap.
        let url = try Self.write(Self.wordJSON([
            (" Hello", 0, 300), (" there", 300, 600),
            (" How", 2000, 2200), (" are", 2200, 2400), (" you?", 2400, 2700),
            (" Great", 2750, 3050),
        ]))
        defer { try? FileManager.default.removeItem(at: url) }
        let parsed = try Transcriber.parsePhrases(url, speaker: "Me")
        #expect(parsed.phrases.map { $0.turn.text } == ["Hello there", "How are you?", "Great"])
        // Without a diarizer every phrase is a plain "Me" turn (R2-2's contract).
        #expect(parsed.phrases.allSatisfy { $0.turn.speakerID == nil && $0.turn.speaker == "Me" })
    }

    @Test func inventedLabelLeavesThePhraseWordsToo() throws {
        // SpeakerAssignment.split rebuilds text from the words, so the label
        // must go from them as well, not only from the phrase text.
        let url = try Self.write(Self.wordJSON([
            (" Alex", 0, 200), (" Weber:", 200, 400), (" Ja,", 500, 700), (" genau.", 700, 1000),
        ]))
        defer { try? FileManager.default.removeItem(at: url) }
        let phrases = try Transcriber.parsePhrases(url, speaker: "Them", promptWords: ["alex", "weber"]).phrases
        #expect(phrases.map { $0.turn.text } == ["Ja, genau."])
        #expect(phrases.first?.words.map(\.text).joined() == " Ja, genau.")
        #expect(phrases.first?.turn.start == 0.5)
    }

    @Test func micPhrasesDontSwallowAnInterjection() throws {
        // Old behaviour (one long undiarized "Me" segment) would have stamped
        // all of this at 0-0.6 and cut "Them" out of the timeline. Phrases fix
        // that: the interjection lands between two "Me" turns in order.
        let url = try Self.write(Self.wordJSON([
            (" Hello", 0, 300), (" there", 300, 600),
            (" How", 2000, 2200), (" are", 2200, 2400), (" you?", 2400, 2700),
        ]))
        defer { try? FileManager.default.removeItem(at: url) }
        let phrases = try Transcriber.parsePhrases(url, speaker: "Me").phrases
        let them = Turn(start: 1.0, end: 1.9, speaker: "Them", text: "Sure, one sec.")
        let turns = Transcriber.buildTurns(from: phrases.map { $0.turn } + [them])
        #expect(turns.map(\.speaker) == ["Me", "Them", "Me"])
        #expect(turns.map(\.text) == ["Hello there", "Sure, one sec.", "How are you?"])
    }
}
