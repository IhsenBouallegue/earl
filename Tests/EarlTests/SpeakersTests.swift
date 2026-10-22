import Foundation
import Testing
@testable import Earl

struct SpeakersTests {
    static func words(_ list: [(String, Double, Double)]) -> [TimedWord] {
        list.map { TimedWord(text: " " + $0.0, start: $0.1, end: $0.2) }
    }

    static func phrase(_ list: [(String, Double, Double)]) -> Phrase {
        let words = words(list)
        return Phrase(turn: Turn(start: words.first!.start, end: words.last!.end, speaker: "Them",
                                 text: words.map(\.text).joined().trimmingCharacters(in: .whitespaces)),
                      words: words)
    }

    // MARK: Assignment

    @Test func assignsMajorityVoice() {
        let d = Diarization(segments: [(0, 3, 0), (3, 10, 1)], speakers: [])
        // 2.0 s of voice 0 and 1.0 s of voice 1: under the split threshold for voice 1.
        let p = Self.phrase([("Hello", 1, 2), ("there", 2, 3), ("friend", 3, 4)])
        let out = SpeakerAssignment.assign([p], to: d)
        #expect(out.count == 1)
        #expect(out[0].speaker == 0)
        #expect(out[0].turn.text == "Hello there friend")
    }

    @Test func splitsSegmentSpanningTwoVoices() {
        let d = Diarization(segments: [(0, 3, 0), (3.2, 7, 1)], speakers: [])
        let p = Self.phrase([("Are", 0.2, 0.6), ("we", 0.6, 1.0), ("ready", 1.0, 2.8),
                             ("Yes", 3.3, 3.8), ("we", 3.8, 4.2), ("are", 4.2, 6.5)])
        let out = SpeakerAssignment.assign([p], to: d)
        #expect(out.map(\.speaker) == [0, 1])
        #expect(out.map(\.turn.text) == ["Are we ready", "Yes we are"])
        #expect(out[1].turn.start == 3.3)
        #expect(out[0].turn.end == 2.8)
    }

    @Test func foldsStrayWordIntoNeighbour() {
        // "so" falls in voice 1's time but is too short to be its own turn.
        let d = Diarization(segments: [(0, 2, 0), (2, 2.3, 1), (2.3, 4, 0), (4, 8, 1)], speakers: [])
        let p = Self.phrase([("one", 0, 1), ("two", 1, 2), ("so", 2, 2.3), ("three.", 2.3, 4),
                             ("Four", 4.1, 6), ("five", 6, 8)])
        let out = SpeakerAssignment.assign([p], to: d)
        #expect(out.map(\.speaker) == [0, 1])
        #expect(out[0].turn.text == "one two so three.")
    }

    @Test func segmentOutsideVoicesTakesNearestOrNone() {
        let d = Diarization(segments: [(0, 2, 0), (10, 12, 1)], speakers: [])
        let near = Self.phrase([("hi", 2.5, 3)])
        let far = Self.phrase([("hm", 5.5, 6)])
        let out = SpeakerAssignment.assign([near, far], to: d)
        #expect(out[0].speaker == 0)
        #expect(out[1].speaker == nil)
    }

    @Test func numbersVoicesByFirstAppearance() {
        let turns = [
            Turn(start: 0, end: 1, speaker: "Them", text: "a", speakerID: "system#1"),
            Turn(start: 2, end: 3, speaker: "Them", text: "b", speakerID: "system#0"),
            Turn(start: 4, end: 5, speaker: "Them", text: "c", speakerID: "system#1"),
            Turn(start: 6, end: 7, speaker: "Them", text: "d", speakerID: nil),
        ]
        let voices: [String: (track: String, embedding: [Float], seconds: Double)] = [
            "system#0": ("Them", [0.1], 1), "system#1": ("Them", [0.2], 2), "system#2": ("Them", [0.3], 3),
        ]
        let out = SpeakerAssignment.number(turns, voices: voices)
        #expect(out.turns.map(\.speakerID) == ["S1", "S2", "S1", nil])
        #expect(out.speakers.map(\.id) == ["S1", "S2"])
        #expect(out.speakers[0].embedding == [0.2])
        #expect(out.speakers[0].seconds == 2)
    }

    // MARK: Turns

    @Test func buildTurnsKeepsVoicesApart() {
        let segments = [
            Turn(start: 0, end: 2, speaker: "Them", text: "One.", speakerID: "S1"),
            Turn(start: 2.5, end: 4, speaker: "Them", text: "Two.", speakerID: "S2"),
            Turn(start: 4.5, end: 6, speaker: "Them", text: "Three.", speakerID: "S2"),
        ]
        let turns = Transcriber.buildTurns(from: segments)
        #expect(turns.map(\.text) == ["One.", "Two. Three."])
        #expect(turns.map(\.speakerID) == ["S1", "S2"])
    }

    @Test func liveWordsJoinIntoLines() {
        var live: [Turn] = []
        for (i, w) in ["Hello", "there.", "How", "are", "you?"].enumerated() {
            Transcriber.appendLive(Turn(start: Double(i) * 0.4, end: Double(i) * 0.4 + 0.3, speaker: "Them", text: w),
                                   to: &live)
        }
        #expect(live.map(\.text) == ["Hello there.", "How are you?"])
    }

    @Test func parsesWordOutputIntoPhrases() throws {
        let json = """
            {"result": {"language": "en"}, "transcription": [
              {"offsets": {"from": 0, "to": 100}, "text": ""},
              {"offsets": {"from": 100, "to": 400}, "text": " Hello"},
              {"offsets": {"from": 400, "to": 800}, "text": " there."},
              {"offsets": {"from": 900, "to": 1200}, "text": " Next"},
              {"offsets": {"from": 1200, "to": 1500}, "text": " one"},
              {"offsets": {"from": 3000, "to": 3500}, "text": " [BLANK_AUDIO]"},
              {"offsets": {"from": 4000, "to": 4500}, "text": " Later"}
            ]}
            """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("earl-words-\(UUID()).json")
        try json.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let parsed = try Transcriber.parsePhrases(url, speaker: "Them")
        #expect(parsed.language == "en")
        #expect(parsed.phrases.map(\.turn.text) == ["Hello there.", "Next one", "Later"])
        #expect(parsed.phrases[1].turn.start == 0.9)
        #expect(parsed.phrases[1].turn.end == 1.5)
        #expect(parsed.phrases[1].words.count == 2)
    }

    // MARK: Names

    static func meeting(turns: [Turn], speakers: [Speaker]) -> Meeting {
        Meeting(id: "m", folder: URL(fileURLWithPath: "/tmp/m"),
                info: MeetingInfo(title: "T", titleIsDefault: false, startedAt: Date(timeIntervalSince1970: 0),
                                  duration: 60, status: .done),
                turns: turns, summary: "", files: [], speakers: speakers)
    }

    @Test func displayNames() {
        let speakers = [
            Speaker(id: "S1", track: "Them", embedding: [], seconds: 10),
            Speaker(id: "S2", track: "Them", name: "Sarah", nameSource: .confirmed, embedding: [], seconds: 5),
            Speaker(id: "S3", track: "Them", embedding: [], seconds: 3),
        ]
        let m = Self.meeting(turns: [], speakers: speakers)
        #expect(m.displayName(for: Turn(start: 0, end: 1, speaker: "Them", text: "", speakerID: "S1")) == "Speaker 1")
        #expect(m.displayName(for: Turn(start: 0, end: 1, speaker: "Them", text: "", speakerID: "S2")) == "Sarah")
        #expect(m.displayName(for: Turn(start: 0, end: 1, speaker: "Them", text: "", speakerID: nil)) == "Them")
        #expect(m.displayName(for: Turn(start: 0, end: 1, speaker: "Me", text: "")) == "Me")
    }

    @Test func singleVoiceStaysThem() {
        let m = Self.meeting(turns: [], speakers: [Speaker(id: "S1", track: "Them", embedding: [], seconds: 10)])
        #expect(m.displayName(for: Turn(start: 0, end: 1, speaker: "Them", text: "", speakerID: "S1")) == "Them")
    }

    @Test func mainVoiceOnMicIsMe() {
        let speakers = [
            Speaker(id: "S1", track: "Me", embedding: [], seconds: 30),
            Speaker(id: "S2", track: "Me", embedding: [], seconds: 5),
        ]
        let me = Turn(start: 0, end: 1, speaker: "Me", text: "", speakerID: "S1")
        let guest = Turn(start: 0, end: 1, speaker: "Me", text: "", speakerID: "S2")
        #expect(Speaker.displayName(for: me, in: speakers) == "Me")
        #expect(Speaker.isMe(me, in: speakers))
        #expect(Speaker.displayName(for: guest, in: speakers) == "Speaker 2")
        #expect(!Speaker.isMe(guest, in: speakers))
    }

    @Test func exportsUseDisplayNames() {
        let turns = [
            Turn(start: 0, end: 2, speaker: "Them", text: "Hi.", speakerID: "S1"),
            Turn(start: 3, end: 5, speaker: "Them", text: "Hello.", speakerID: "S2"),
            Turn(start: 6, end: 7, speaker: "Me", text: "Hey."),
        ]
        let speakers = [Speaker(id: "S1", track: "Them", embedding: [], seconds: 2),
                        Speaker(id: "S2", track: "Them", embedding: [], seconds: 2)]
        let m = Self.meeting(turns: turns, speakers: speakers)
        #expect(m.transcriptText == "[00:00] Speaker 1: Hi.\n[00:03] Speaker 2: Hello.\n[00:06] Me: Hey.")
        #expect(m.markdown.contains("**[00:03] Speaker 2:** Hello."))
    }

    @Test func oldMeetingsLookTheSame() throws {
        // A transcript.json from before R2-2 has no speakerID.
        let json = #"[{"start":0,"end":2,"speaker":"Them","text":"Hi."},{"start":3,"end":4,"speaker":"Me","text":"Yo."}]"#
        let turns = try JSONDecoder().decode([Turn].self, from: Data(json.utf8))
        #expect(turns.allSatisfy { $0.speakerID == nil })
        let m = Self.meeting(turns: turns, speakers: [])
        #expect(m.transcriptText == "[00:00] Them: Hi.\n[00:03] Me: Yo.")
        // And it saves back without a speakerID key.
        let saved = String(decoding: try JSONEncoder().encode(turns), as: UTF8.self)
        #expect(!saved.contains("speakerID"))
    }

    // MARK: speakers.json

    @Test func speakersFileRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("earl-speakers-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingStore(root: dir.deletingLastPathComponent())
        let speakers = [
            Speaker(id: "S1", track: "Them", embedding: [0.01, -0.5], seconds: 312.4),
            Speaker(id: "S2", track: "Them", name: "Sarah", nameSource: .confirmed, embedding: [0.2], seconds: 12),
        ]
        try store.saveSpeakers(speakers, in: dir)
        #expect(store.loadSpeakers(in: dir) == speakers)

        // The shared contract's field names.
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("speakers.json")))
        let first = (raw as? [[String: Any]])?.last
        #expect(first?["nameSource"] as? String == "confirmed")
        #expect(Set(first?.keys.map { $0 } ?? []) == ["id", "track", "name", "nameSource", "embedding", "seconds"])

        // Transcribing again without separation removes the file.
        try store.saveSpeakers([], in: dir)
        #expect(store.loadSpeakers(in: dir).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("speakers.json").path))
    }
}
