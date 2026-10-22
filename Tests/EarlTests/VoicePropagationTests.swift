import Foundation
import Testing
@testable import Earl

// W-1: a confirmed name spreads to the same voice in other meetings.
struct VoicePropagationTests {
    static let sarahPrint: [Float] = [1, 0, 0]
    static let sarah = Voice(name: "Sarah Chen", samples: [sarahPrint], sources: ["src/S2"], meetings: 1)

    static func speaker(_ id: String, name: String? = nil, source: Speaker.NameSource? = nil,
                        embedding: [Float] = [0, 1, 0], seconds: Double = 60) -> Speaker {
        Speaker(id: id, track: "Them", name: name, nameSource: source, embedding: embedding, seconds: seconds)
    }

    static func meeting(_ id: String, daysAgo: Double, series: String? = nil, status: MeetingStatus = .done,
                        speakers: [Speaker]) -> Meeting {
        var info = MeetingInfo(title: series ?? "Call \(id)", titleIsDefault: false,
                               startedAt: Date(timeIntervalSinceNow: -daysAgo * 86400), duration: 600, status: status)
        info.calendarTitle = series
        info.calendarEventID = series.map { "ev-\($0)" }
        return Meeting(id: id, folder: URL(fileURLWithPath: "/tmp/\(id)"), info: info, turns: [], summary: "", files: [],
                       speakers: speakers)
    }

    // MARK: Where to look

    @Test func seriesFirstThenSixtyDays() {
        let source = Self.meeting("src", daysAgo: 0, series: "Weekly", speakers: [Self.speaker("S1")])
        let meetings = [
            source,
            Self.meeting("recent", daysAgo: 3, speakers: [Self.speaker("S1")]),
            Self.meeting("oldSeries", daysAgo: 200, series: "Weekly", speakers: [Self.speaker("S1")]),
            Self.meeting("newSeries", daysAgo: 7, series: "weekly", speakers: [Self.speaker("S1")]),
            Self.meeting("tooOld", daysAgo: 61, speakers: [Self.speaker("S1")]),
            Self.meeting("busy", daysAgo: 1, speakers: [Self.speaker("S1")]),
            Self.meeting("failed", daysAgo: 1, status: .failed, speakers: [Self.speaker("S1")]),
            Self.meeting("noVoices", daysAgo: 1, speakers: []),
        ]
        let ids = VoicePropagation.targets(sourceID: "src", in: meetings, skip: ["busy"]).map(\.id)
        #expect(ids == ["newSeries", "oldSeries", "recent"])
    }

    // MARK: Matching

    @Test func namesUnnamedAndGuessedVoicesNeverConfirmedOrVoiceNamed() {
        let match = { (speakers: [Speaker]) in
            VoicePropagation.match(Self.sarah, speakers: speakers, attendees: [])?.speakerID
        }
        #expect(match([Self.speaker("S1"), Self.speaker("S2", embedding: Self.sarahPrint)]) == "S2")
        #expect(match([Self.speaker("S2", name: "Sam", source: .guessed, embedding: Self.sarahPrint)]) == "S2")
        // Its own guess of Sarah doesn't block it.
        #expect(match([Self.speaker("S2", name: "Sarah", source: .guessed, embedding: Self.sarahPrint)]) == "S2")
        #expect(match([Self.speaker("S2", name: "Sam", source: .confirmed, embedding: Self.sarahPrint)]) == nil)
        #expect(match([Self.speaker("S2", name: "Sam", source: .voice, embedding: Self.sarahPrint)]) == nil)
        // Too little talk to judge, as in recognition.
        #expect(match([Self.speaker("S2", embedding: Self.sarahPrint, seconds: 5)]) == nil)
    }

    @Test func collisionsWin() {
        // Another voice already is Sarah there: the name stays where it is.
        let speakers = [Self.speaker("S1", name: "Sarah", source: .confirmed),
                        Self.speaker("S2", embedding: Self.sarahPrint)]
        #expect(VoicePropagation.match(Self.sarah, speakers: speakers, attendees: []) == nil)
        let guessed = [Self.speaker("S1", name: "Sarah", source: .guessed),
                       Self.speaker("S2", embedding: Self.sarahPrint)]
        #expect(VoicePropagation.match(Self.sarah, speakers: guessed, attendees: []) == nil)
    }

    @Test func thresholdIsAttendeeAware() {
        // cos ≈ 0.72: between the invited (0.70) and the strict (0.75) threshold.
        let near: [Float] = [0.72, 0.694, 0]
        let speakers = [Self.speaker("S2", embedding: near)]
        #expect(VoicePropagation.match(Self.sarah, speakers: speakers, attendees: []) == nil)
        let invited = [Attendee(name: "Sarah Chen", email: nil, isMe: false)]
        #expect(VoicePropagation.match(Self.sarah, speakers: speakers, attendees: invited)?.speakerID == "S2")
    }

    @Test func planOnePerMeeting() {
        let meetings = [
            Self.meeting("src", daysAgo: 0, speakers: []),
            Self.meeting("a", daysAgo: 2, speakers: [Self.speaker("S1", embedding: [0.9, 0.1, 0]),
                                                     Self.speaker("S2", embedding: Self.sarahPrint)]),
            Self.meeting("b", daysAgo: 4, speakers: [Self.speaker("S1")]),
        ]
        let changes = VoicePropagation.plan(voices: [Self.sarah], sourceID: "src", in: meetings, skip: [])
        #expect(changes.map(\.meetingID) == ["a"])
        #expect(changes.first?.speakerID == "S2")
        #expect(changes.first?.evidence == "1 meeting")
    }

    @Test func newlyConfirmedNames() {
        let before = [Self.speaker("S1", name: "Tom", source: .confirmed), Self.speaker("S2", name: "Sarah", source: .guessed),
                      Self.speaker("S3")]
        let after = [Self.speaker("S1", name: "Tom", source: .confirmed), Self.speaker("S2", name: "Sarah", source: .confirmed),
                     Self.speaker("S3", name: "Ben", source: .confirmed)]
        #expect(VoicePropagation.newlyConfirmed(before: before, after: after) == ["Sarah", "Ben"])
    }

    @Test func message() {
        #expect(VoicePropagation.message(names: ["Sarah"], meetings: 3) == "Also named Sarah in 3 other meetings")
        #expect(VoicePropagation.message(names: ["Sarah", "Tom"], meetings: 1) == "Also named Sarah and Tom in 1 other meeting")
    }

    // MARK: Saving and undoing

    @Test func applyPatchesNotesLogsAndUndoRestores() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("earl-w1-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        var m = try store.create(startedAt: Date(timeIntervalSinceNow: -86400), microphone: nil)
        m.info.status = .done
        m.info.title = "Speaker 2 joins the pilot"
        m.info.headline = "Speaker 2 takes the pilot"
        let summary = "## Summary\n- Speaker 2 wants a pilot.\n\n## Action items\n- [ ] Speaker 2: Send the pilot plan\n"
        let turns = [Turn(start: 0, end: 5, speaker: "Them", text: "Let's run a pilot.", speakerID: "S2"),
                     Turn(start: 5, end: 9, speaker: "Them", text: "Sure.", speakerID: "S1")]
        let speakers = [Self.speaker("S1"), Self.speaker("S2", embedding: Self.sarahPrint)]
        try store.save(m.info, in: m.folder)
        try store.saveSummary(summary, in: m.folder)
        try store.saveTranscript(turns, in: m.folder)
        try store.saveSpeakers(speakers, in: m.folder)

        let loaded = try #require(store.load(m.folder))
        let changes = VoicePropagation.plan(voices: [Self.sarah], sourceID: "src", in: [loaded], skip: [])
        let undos = VoicePropagation.apply(changes, sourceID: "src", store: store)
        #expect(undos.count == 1)

        let after = try #require(store.load(m.folder))
        let s2 = try #require(after.speakers.first { $0.id == "S2" })
        #expect(s2.name == "Sarah Chen")
        #expect(s2.nameSource == .voice)
        #expect(after.summary.contains("- Sarah Chen wants a pilot."))
        #expect(after.summary.contains("- [ ] Sarah Chen: Send the pilot plan"))
        #expect(after.info.headline == "Sarah Chen takes the pilot")
        #expect(after.info.title == "Sarah Chen joins the pilot")
        let log = try String(contentsOf: m.folder.appendingPathComponent("whisper.log"), encoding: .utf8)
        #expect(log.contains("Named by voice from src: S2 = Sarah Chen (1.00)"))
        let markdown = try String(contentsOf: m.folder.appendingPathComponent("transcript.md"), encoding: .utf8)
        #expect(markdown.contains("Sarah Chen:** Let's run a pilot."))

        VoicePropagation.undo(undos, store: store)
        let undone = try #require(store.load(m.folder))
        #expect(undone.speakers == speakers)
        #expect(undone.summary == summary)
        #expect(undone.info.headline == "Speaker 2 takes the pilot")
        #expect(undone.info.title == "Speaker 2 joins the pilot")
    }

    @Test func undoKeepsWhatChangedSince() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("earl-w1-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        var m = try store.create(startedAt: Date(), microphone: nil)
        m.info.status = .done
        try store.save(m.info, in: m.folder)
        try store.saveSummary("- Speaker 2 agreed.", in: m.folder)
        try store.saveSpeakers([Self.speaker("S2", embedding: Self.sarahPrint)], in: m.folder)
        let loaded = try #require(store.load(m.folder))
        let undos = VoicePropagation.apply(
            VoicePropagation.plan(voices: [Self.sarah], sourceID: "src", in: [loaded], skip: []), sourceID: "src", store: store)
        // You renamed her by hand and edited the notes meanwhile.
        try store.saveSpeakers([Self.speaker("S2", name: "Sara", source: .confirmed, embedding: Self.sarahPrint)], in: m.folder)
        try store.saveSummary("- Sara agreed, mostly.", in: m.folder)
        VoicePropagation.undo(undos, store: store)
        let now = try #require(store.load(m.folder))
        #expect(now.speakers.first?.name == "Sara")
        #expect(now.summary == "- Sara agreed, mostly.")
    }

    @Test func applySkipsVoicesNamedMeanwhile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("earl-w1-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        var m = try store.create(startedAt: Date(), microphone: nil)
        m.info.status = .done
        try store.save(m.info, in: m.folder)
        try store.saveSpeakers([Self.speaker("S2", embedding: Self.sarahPrint)], in: m.folder)
        let changes = VoicePropagation.plan(voices: [Self.sarah], sourceID: "src", in: [try #require(store.load(m.folder))],
                                            skip: [])
        try store.saveSpeakers([Self.speaker("S2", name: "Tom", source: .confirmed, embedding: Self.sarahPrint)], in: m.folder)
        #expect(VoicePropagation.apply(changes, sourceID: "src", store: store).isEmpty)
        #expect(store.load(m.folder)?.speakers.first?.name == "Tom")
    }
}
