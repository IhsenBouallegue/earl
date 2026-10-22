import Foundation
import Testing
@testable import Earl

/// D-4: every release must read what earlier releases wrote.
/// The fixtures are synthetic (made with the app's own encoders) and pin the 0.5 formats.
struct CompatTests {
    static let root = Bundle.module.url(forResource: "Fixtures/compat-0.5", withExtension: nil)!
    static let meetingA = root.appendingPathComponent("meeting-a")

    @Test func meetingFrom05Loads() throws {
        let m = try #require(MeetingStore.load(folder: Self.meetingA))
        #expect(m.info.status == .done)
        #expect(m.info.attendees?.count == 3)
        #expect(m.info.headline != nil)
        #expect(!m.turns.isEmpty)
        #expect(!m.speakers.isEmpty)
        #expect(m.speakers.first?.embedding.count == 4)
        #expect(!m.summary.isEmpty)
    }

    @Test func todosAndQuestionsFrom05Load() throws {
        #expect(!TodoFiles.loadDone(in: Self.meetingA).isEmpty)
        let answers = AskHistory.load(Self.meetingA.appendingPathComponent("questions.json"))
        #expect(answers.count == 1)
        #expect(answers.first?.citations.count == 1)
    }

    @Test func unknownFieldsAreIgnored() throws {
        // A newer Earl added a field; an older one must still read the meeting.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.copyItem(at: Self.meetingA, to: dir)
        let url = dir.appendingPathComponent("meeting.json")
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        json["fieldFromTheFuture"] = ["x": 1]
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        #expect(MeetingStore.load(folder: dir)?.info.status == .done)
    }

    @Test func unreadableMeetingIsShownNotHidden() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{\"title\": 42}".utf8).write(to: dir.appendingPathComponent("meeting.json"))
        let m = try #require(MeetingStore.load(folder: dir))
        #expect(m.info.status == .failed)
        #expect(m.info.error == MeetingStore.unreadableMessage)
        #expect(m.turns.isEmpty)
    }

    @Test func folderWithoutMeetingJSONIsNotAMeeting() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        #expect(MeetingStore.load(folder: dir) == nil)
    }

    @Test func voiceLibraryFrom05Loads() throws {
        let data = try Data(contentsOf: Self.root.appendingPathComponent("voices.json"))
        let voices = try VoiceStore.decode(data)
        #expect(voices.first?.samples.first?.count == 4)
    }

    // MARK: - An unreadable meeting is never written to

    private func unreadableFolder() throws -> (URL, Data) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let bytes = Data("{\"title\": 42, \"futureField\": [1,2,3]}".utf8)
        try bytes.write(to: dir.appendingPathComponent("meeting.json"))
        return (dir, bytes)
    }

    @Test func canWriteOnlyWhenMeetingJSONIsMissingOrValid() throws {
        let (bad, _) = try unreadableFolder()
        #expect(!MeetingStore.canWrite(folder: bad))
        #expect(MeetingStore.canWrite(folder: Self.meetingA))
        #expect(MeetingStore.canWrite(folder: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
    }

    @Test func unreadableMeetingIsMarkedAndStoreRefusesToWrite() throws {
        let (dir, bytes) = try unreadableFolder()
        let m = try #require(MeetingStore.load(folder: dir))
        #expect(m.isUnreadable)
        let store = MeetingStore(root: dir.deletingLastPathComponent())
        #expect(throws: (any Error).self) { try store.save(m.info, in: dir) }
        #expect(throws: (any Error).self) { try store.saveTranscript([], in: dir) }
        #expect(throws: (any Error).self) { try store.saveSummary("x", in: dir) }
        #expect(throws: (any Error).self) {
            try store.saveSpeakers([Speaker(id: "S1", track: "Them", name: nil, nameSource: nil, embedding: [], seconds: 1)],
                                   in: dir, textOnly: false)
        }
        store.saveMarkdown(m)
        store.deleteAudio(in: dir)
        #expect(try Data(contentsOf: dir.appendingPathComponent("meeting.json")) == bytes)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(names == ["meeting.json"])
    }

    @Test func readableMeetingIsNotMarked() throws {
        #expect(try #require(MeetingStore.load(folder: Self.meetingA)).isUnreadable == false)
    }
}
