import Foundation
import Testing
@testable import Earl

// E-1: renames patch the notes in place.
struct NotesPatchTests {
    static func speaker(_ id: String, _ track: String = "Them", name: String? = nil,
                        source: Speaker.NameSource? = nil, seconds: Double = 10) -> Speaker {
        Speaker(id: id, track: track, name: name, nameSource: source, embedding: [1, 0], seconds: seconds)
    }

    static func attendee(_ name: String, me: Bool = false) -> Attendee {
        Attendee(name: name, email: nil, isMe: me)
    }

    // MARK: Whole words

    @Test func speakerTwoIsNotSpeakerTwentyOne() {
        let text = "Speaker 2 asked Speaker 21 about Speaker 2."
        #expect(NotesPatch.replacing(["Speaker 2"], with: "Tom", in: text) == "Tom asked Speaker 21 about Tom.")
    }

    @Test func wordBoundariesWithUmlauts() {
        let text = "Jürgen and Jürgenmeier met; Über-Jürgen came, and so did Jürgen."
        #expect(NotesPatch.replacing(["Jürgen"], with: "Jörg", in: text)
            == "Jörg and Jürgenmeier met; Über-Jörg came, and so did Jörg.")
        // A letter with an umlaut is part of the word: "Tom" isn't inside "Tomä".
        #expect(NotesPatch.replacing(["Tom"], with: "Ben", in: "Tomä and Tom") == "Tomä and Ben")
    }

    @Test func caseSensitive() {
        #expect(NotesPatch.replacing(["Mark"], with: "Lena", in: "Mark will mark the bug") == "Lena will mark the bug")
    }

    @Test func possessives() {
        #expect(NotesPatch.replacing(["Speaker 2"], with: "Tom", in: "Speaker 2's deck and Speaker 2s Folien")
            == "Tom's deck and Toms Folien")
        #expect(NotesPatch.replacing(["Sarah"], with: "Tom", in: "Sarahs Entwurf, Sarah’s draft") == "Toms Entwurf, Tom’s draft")
        // Any other letter after the label means another word.
        #expect(NotesPatch.replacing(["Sarah"], with: "Tom", in: "Sarahson") == "Sarahson")
    }

    @Test func nothingMatchedIsIdentical() {
        let text = "## Summary\n- Nothing about anyone.\n"
        #expect(NotesPatch.replacing(["Speaker 3"], with: "Tom", in: text) == text)
        let out = NotesPatch.rename(summary: text, headline: "A headline", title: "Weekly", from: ["Speaker 3"], to: "Tom")
        #expect(out.summary == text && out.headline == "A headline" && out.title == "Weekly")
    }

    @Test func alreadyTheNewNameStays() {
        #expect(NotesPatch.replacing(["Sarah"], with: "Sarah Chen", in: "Sarah Chen and Sarah")
            == "Sarah Chen and Sarah Chen")
    }

    @Test func ownersKeepTheirTicks() {
        let summary = """
            ## Action items
            - [x] Speaker 2: Send the deck to Speaker 21
            - [ ] **Speaker 2**: Book the room
            - [ ] Me: Ask Speaker 2 about the budget
            """
        let out = NotesPatch.replacing(["Speaker 2"], with: "Tom", in: summary)
        #expect(out == """
            ## Action items
            - [x] Tom: Send the deck to Speaker 21
            - [ ] **Tom**: Book the room
            - [ ] Me: Ask Tom about the budget
            """)
        let items = ActionItems.parse(out, meetingID: "m")
        #expect(items.map(\.done) == [true, false, false])
        #expect(items.map(\.owner) == ["Tom", "Tom", "Me"])
        // The Reminders key is the text without the owner, so it survives the rename.
        let before = ActionItems.parse(summary, meetingID: "m")
        #expect(items[0].key == before[0].key && items[1].key == before[1].key)
    }

    // MARK: From a speaker edit

    @Test func renameUnnamed() {
        let before = [Self.speaker("S1", name: "Priya"), Self.speaker("S2")]
        let after = SpeakerEdit.rename(before, id: "S2", to: "Tom", source: .confirmed)
        #expect(NotesPatch.renames(before: before, after: after) == [.init(labels: ["Speaker 2"], name: "Tom")])
    }

    @Test func confirmChangesNothing() {
        let before = [Self.speaker("S1", name: "Sarah", source: .guessed), Self.speaker("S2")]
        let after = SpeakerEdit.rename(before, id: "S1", to: "Sarah", source: .confirmed)
        #expect(NotesPatch.renames(before: before, after: after).isEmpty)
    }

    @Test func clearPutsBackSpeakerN() {
        // Even when the voice is alone on its track, the notes say "Speaker N", not "Them".
        let before = [Self.speaker("S3", name: "Sarah", source: .guessed)]
        let after = SpeakerEdit.rename(before, id: "S3", to: nil, source: nil)
        #expect(NotesPatch.renames(before: before, after: after) == [.init(labels: ["Sarah"], name: "Speaker 3")])
    }

    @Test func mergeGivesTheTargetsName() {
        let before = [Self.speaker("S1", name: "Priya Raman"), Self.speaker("S2"), Self.speaker("S3")]
        let merged = SpeakerEdit.merge(turns: [], speakers: before, from: "S2", into: "S1").speakers
        let renames = NotesPatch.renames(before: before, after: merged, mergedInto: ["S2": "S1"])
        #expect(renames == [.init(labels: ["Speaker 2"], name: "Priya Raman")])
        // An unnamed target takes the merged voice's name, and its own label goes too.
        let named = [Self.speaker("S1"), Self.speaker("S2", name: "Sarah"), Self.speaker("S3")]
        let into = SpeakerEdit.merge(turns: [], speakers: named, from: "S2", into: "S3").speakers
        #expect(NotesPatch.renames(before: named, after: into, mergedInto: ["S2": "S3"])
            == [.init(labels: ["Speaker 3"], name: "Sarah")])
    }

    @Test func firstNameWhenUnique() {
        let before = [Self.speaker("S1", name: "Sarah Becker", source: .guessed), Self.speaker("S2", name: "Priya")]
        let after = SpeakerEdit.rename(before, id: "S1", to: "Tom Klein", source: .confirmed)
        let renames = NotesPatch.renames(before: before, after: after,
                                         attendees: [Self.attendee("Sarah Becker"), Self.attendee("Tom Klein")])
        #expect(renames == [.init(labels: ["Sarah Becker"], name: "Tom Klein"), .init(labels: ["Sarah"], name: "Tom")])
        var meeting = Meeting(id: "m", folder: URL(fileURLWithPath: "/tmp/m"),
                              info: MeetingInfo(title: "Sync with Sarah", titleIsDefault: false, startedAt: Date(),
                                                duration: 60, status: .done),
                              turns: [], summary: "- Sarah Becker presented. Sarah's numbers were good.\n- [ ] Sarah: Send it",
                              files: [])
        meeting.info.headline = "Sarah wins the budget"
        let out = NotesPatch.patched(meeting, renames: renames)
        #expect(out.summary == "- Tom Klein presented. Tom's numbers were good.\n- [ ] Tom: Send it")
        #expect(out.info.headline == "Tom wins the budget")
        #expect(out.info.title == "Sync with Tom")
    }

    @Test func firstNameNotWhenShared() {
        // Another Sarah among the attendees: a bare "Sarah" could be her.
        let before = [Self.speaker("S1", name: "Sarah Becker")]
        let after = SpeakerEdit.rename(before, id: "S1", to: "Tom", source: .confirmed)
        let renames = NotesPatch.renames(before: before, after: after,
                                         attendees: [Self.attendee("Sarah Becker"), Self.attendee("Sarah Chen")])
        #expect(renames == [.init(labels: ["Sarah Becker"], name: "Tom")])
        // Nor when another speaker has it.
        let two = [Self.speaker("S1", name: "Sarah Becker"), Self.speaker("S2", name: "Sarah")]
        let renamed = SpeakerEdit.rename(two, id: "S1", to: "Tom", source: .confirmed)
        #expect(NotesPatch.renames(before: two, after: renamed) == [.init(labels: ["Sarah Becker"], name: "Tom")])
    }

    @Test func youAreNeverRelabelled() {
        let before = [Self.speaker("S1", "Me", seconds: 100), Self.speaker("S2", "Me", seconds: 5)]
        let after = SpeakerEdit.rename(before, id: "S2", to: "Kim", source: .confirmed)
        #expect(NotesPatch.renames(before: before, after: after) == [.init(labels: ["Speaker 2"], name: "Kim")])
    }

    @Test func calendarTitleStays() {
        var info = MeetingInfo(title: "1:1 Speaker 2", titleIsDefault: false, startedAt: Date(), duration: 60, status: .done)
        info.calendarTitle = "1:1 Speaker 2"
        let meeting = Meeting(id: "m", folder: URL(fileURLWithPath: "/tmp/m"), info: info, turns: [],
                              summary: "- Speaker 2 joined", files: [])
        let out = NotesPatch.patched(meeting, renames: [.init(labels: ["Speaker 2"], name: "Tom")])
        #expect(out.summary == "- Tom joined" && out.info.title == "1:1 Speaker 2")
    }

    // MARK: Saving

    @Test func savingPatchesNotesKeepsTicksAndMarksNothingStale() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("earl-e1-\(UUID().uuidString)")
            .appendingPathComponent("2026-01-01_100000")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let store = MeetingStore(root: dir.deletingLastPathComponent())
        var info = MeetingInfo(title: "Planning", titleIsDefault: false, startedAt: Date(), duration: 60, status: .done)
        info.headline = "Speaker 2 takes the launch"
        try store.save(info, in: dir)
        let speakers = [Self.speaker("S1", name: "Priya"), Self.speaker("S2")]
        let turns = [Turn(start: 0, end: 1, speaker: "Them", text: "Hi", speakerID: "S1"),
                     Turn(start: 1, end: 2, speaker: "Them", text: "Hello", speakerID: "S2")]
        try store.saveTranscript(turns, in: dir)
        try store.saveSpeakers(speakers, in: dir)
        let summary = """
            ## Action items
            - [x] Speaker 2: Send the deck
            - [ ] Priya: Ask Speaker 2 for the numbers
            """
        try store.saveSummary(summary, in: dir)
        let old = ActionItems.parse(summary, meetingID: dir.lastPathComponent)
        TodoFiles.record(old[0], done: true, in: dir)
        TodoFiles.saveReminders([old[1].key: "reminder-1"], in: dir)

        var meeting = try #require(store.load(dir))
        let before = (turns: meeting.turns, speakers: meeting.speakers)
        meeting.speakers = SpeakerEdit.rename(meeting.speakers, id: "S2", to: "Tom", source: .confirmed)
        try NotesPatch.saveSpeakerEdit(meeting, before: before, mergedInto: [:], store: store)

        let saved = try #require(store.load(dir))
        #expect(saved.summary == """
            ## Action items
            - [x] Tom: Send the deck
            - [ ] Priya: Ask Tom for the numbers
            """)
        #expect(saved.info.headline == "Tom takes the launch")
        #expect(saved.info.namesChangedSinceSummary == nil)
        let items = ActionItems.parse(saved.summary, meetingID: dir.lastPathComponent)
        // The tick record and the reminder follow the item whose words changed.
        #expect(TodoFiles.loadDone(in: dir).map(\.key) == [items[0].key])
        #expect(TodoFiles.loadReminders(in: dir) == [items[1].key: "reminder-1"])
        // And a later Summarize Again still re-ticks it.
        let again = TodoFiles.keepingTicks("## Action items\n- [ ] Tom: Send the deck", in: dir)
        #expect(again.contains("- [x] Tom: Send the deck"))
    }
}
