import Foundation
import Testing
@testable import Earl

/// P-1: what "Keep only the text" deletes, and what it leaves alone.
struct PrivacyTests {
    static func meeting(_ id: String, audio: Int64 = 0, transcribed: Bool = true, voiceprint: Bool = false) -> Meeting {
        let turns = transcribed ? [Turn(start: 0, end: 2, speaker: "Them", text: "Hallo zusammen.", speakerID: "S1")] : []
        let speakers = [Speaker(id: "S1", track: "Them", name: "Anna", nameSource: .confirmed,
                                embedding: voiceprint ? [0.1, 0.2] : [], seconds: 30, avatar: "glasses")]
        let files = audio > 0 ? [MeetingFile(name: "system-16k.wav", bytes: audio), MeetingFile(name: "summary.md", bytes: 9)]
                              : [MeetingFile(name: "summary.md", bytes: 9)]
        return Meeting(id: id, folder: URL(fileURLWithPath: "/nonexistent/earl-privacy/\(id)"),
                       info: MeetingInfo(title: id, titleIsDefault: false, startedAt: Date(), duration: 60, status: .done),
                       turns: turns, summary: "", files: files, speakers: speakers)
    }

    @Test func voiceprintsGoNamesStay() {
        let s = Privacy.withoutVoiceprints(Self.meeting("a", voiceprint: true).speakers)
        #expect(s.first?.embedding.isEmpty == true)
        #expect(s.first?.name == "Anna")
        #expect(s.first?.nameSource == .confirmed)
        #expect(s.first?.avatar == "glasses")
        #expect(s.first?.seconds == 30)
    }

    @Test func cleanupFindsAudioAndVoiceprints() {
        let meetings = [
            Self.meeting("audio", audio: 1000),
            Self.meeting("prints", voiceprint: true),
            Self.meeting("both", audio: 500, voiceprint: true),
            Self.meeting("clean"),
        ]
        let c = Privacy.cleanup(of: meetings, skipping: [], rememberedVoices: 2)
        #expect(c.audioIDs == ["audio", "both"])
        #expect(c.audioBytes == 1500)
        #expect(c.voiceprintIDs == ["prints", "both"])
        #expect(c.rememberedVoices == 2)
        #expect(!c.isEmpty)
    }

    @Test func untranscribedAudioIsKeptForRetry() {
        let c = Privacy.cleanup(of: [Self.meeting("crashed", audio: 1000, transcribed: false)], skipping: [], rememberedVoices: 0)
        #expect(c.audioIDs.isEmpty)
        #expect(c.isEmpty)
    }

    @Test func busyMeetingsAreSkipped() {
        let meetings = [Self.meeting("recording", audio: 1000, voiceprint: true), Self.meeting("done", audio: 1000)]
        let c = Privacy.cleanup(of: meetings, skipping: ["recording"], rememberedVoices: 0)
        #expect(c.audioIDs == ["done"])
        #expect(c.voiceprintIDs.isEmpty)
    }

    @Test func summaryReadsAsOneSentence() {
        var c = Privacy.Cleanup(audioIDs: ["a"], audioBytes: 0, voiceprintIDs: ["a", "b"], rememberedVoices: 1)
        #expect(c.summary.hasPrefix("the audio of 1 meeting ("))
        #expect(c.summary.hasSuffix("), voice fingerprints in 2 meetings and 1 remembered voice"))
        c = Privacy.Cleanup(voiceprintIDs: ["a"])
        #expect(c.summary == "voice fingerprints in 1 meeting")
        #expect(Privacy.Cleanup().summary == "")
    }

    @Test func savingWithTextOnlyDropsVoiceprints() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("earl-privacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = MeetingStore(root: folder)
        let speakers = Self.meeting("a", voiceprint: true).speakers
        try store.saveSpeakers(speakers, in: folder, textOnly: false)
        #expect(store.loadSpeakers(in: folder).first?.embedding == [0.1, 0.2])
        try store.saveSpeakers(speakers, in: folder, textOnly: true)
        #expect(store.loadSpeakers(in: folder).first?.embedding.isEmpty == true)
        #expect(store.loadSpeakers(in: folder).first?.name == "Anna")
    }
}
