import Foundation
import Testing
@testable import Earl

// E-1: editing a line of the notes by hand.
struct NotesEditingTests {
    static let summary = """
        ## Summary
        - The team reviewed the launch plan.
        - Drop-off fell from 31 % to 18 %.
        - Translation needs the copy by Wednesday.

        ## Decisions
        1. Ship on **Friday**

        ## Action items
        - [ ] Sarah: Send the deck to the client
          - [x] **Tom**: Book the room
        - [ ] Update the changelog
        """

    static var lines: [String] { summary.components(separatedBy: "\n") }

    @Test func partsOfALine() {
        let todo = NotesEdit.parts("  - [x] **Tom**: Book the room")
        #expect(todo.lead == "  - [x] " && todo.owner == "Tom" && todo.ownerRaw == "**Tom**: " && todo.text == "Book the room")
        let bullet = NotesEdit.parts("- Note: this stays whole")
        #expect(bullet.lead == "- " && bullet.owner == nil && bullet.text == "Note: this stays whole")
        let numbered = NotesEdit.parts("1. Ship on **Friday**")
        #expect(numbered.lead == "1. " && numbered.text == "Ship on **Friday**")
        let plain = NotesEdit.parts("Just a line")
        #expect(plain.lead == "" && plain.text == "Just a line")
    }

    @Test func editKeepsBulletAndOwner() throws {
        let i = try #require(NotesEdit.lineIndex(of: "Ship on **Friday**", in: Self.summary))
        #expect(i == 6)
        let out = NotesEdit.replacingText(ofLine: i, in: Self.summary, with: "Ship on Monday")
        #expect(out.components(separatedBy: "\n")[6] == "1. Ship on Monday")

        let item = try #require(ActionItems.parse(Self.summary, meetingID: "m").first { $0.owner == "Tom" })
        let j = try #require(NotesEdit.lineIndex(of: item, in: Self.summary))
        let edited = NotesEdit.replacingText(ofLine: j, in: Self.summary, with: "Book the big room")
        #expect(edited.components(separatedBy: "\n")[j] == "  - [x] **Tom**: Book the big room")
        let again = try #require(ActionItems.parseLine(edited.components(separatedBy: "\n")[j], meetingID: "m", index: j))
        #expect(again.done && again.owner == "Tom")
        // Everything else is untouched.
        var expected = Self.lines
        expected[j] = "  - [x] **Tom**: Book the big room"
        #expect(edited == expected.joined(separator: "\n"))
    }

    @Test func emptyDeletesTheLine() throws {
        let i = try #require(NotesEdit.lineIndex(of: "Drop-off fell from 31 % to 18 %.", in: Self.summary))
        let out = NotesEdit.replacingText(ofLine: i, in: Self.summary, with: "  \n ")
        var expected = Self.lines
        expected.remove(at: i)
        #expect(out == expected.joined(separator: "\n"))
    }

    @Test func pastedNewlinesBecomeSpaces() throws {
        let i = try #require(NotesEdit.lineIndex(of: "The team reviewed the launch plan.", in: Self.summary))
        let out = NotesEdit.replacingText(ofLine: i, in: Self.summary, with: "Two\nlines")
        #expect(out.components(separatedBy: "\n")[i] == "- Two lines")
    }

    @Test func ownerChange() throws {
        let items = ActionItems.parse(Self.summary, meetingID: "m")
        let sarah = try #require(items.first { $0.owner == "Sarah" })
        let out = NotesEdit.settingOwner(ofLine: sarah.line, in: Self.summary, to: "Speaker 3")
        #expect(out.components(separatedBy: "\n")[sarah.line] == "- [ ] Speaker 3: Send the deck to the client")
        // A to-do without an owner gets one.
        let changelog = try #require(items.first { $0.owner == nil })
        let given = NotesEdit.settingOwner(ofLine: changelog.line, in: Self.summary, to: "Me")
        let item = try #require(ActionItems.parseLine(given.components(separatedBy: "\n")[changelog.line], meetingID: "m",
                                                      index: changelog.line))
        #expect(item.owner == "Me" && item.text == "Update the changelog" && item.key == changelog.key)
        // Plain bullets have no owner to set.
        #expect(NotesEdit.settingOwner(ofLine: 1, in: Self.summary, to: "Me") == Self.summary)
    }

    @Test func lineFoundAgainWhenNotesMoved() throws {
        let item = try #require(ActionItems.parse(Self.summary, meetingID: "m").first { $0.owner == "Sarah" })
        let shifted = "## Intro\n- Added later\n" + Self.summary
        #expect(NotesEdit.lineIndex(of: item, in: shifted) == item.line + 2)
        #expect(NotesEdit.lineIndex(of: "Missing line", in: Self.summary) == nil)
        // A to-do's line isn't a plain bullet.
        #expect(NotesEdit.lineIndex(of: "[ ] Update the changelog", in: Self.summary) == nil)
    }

    @Test func briefingGoesIntoTheFirstBullet() {
        let used = ["The team reviewed the launch plan.", "Drop-off fell from 31 % to 18 %."]
        let out = NotesEdit.replacingBriefing(used, in: Self.summary, with: "We reviewed the plan; drop-off fell.")
        var expected = Self.lines
        expected[1] = "- We reviewed the plan; drop-off fell."
        expected.remove(at: 2)
        #expect(out == expected.joined(separator: "\n"))
        let notes = FrontPageNotes.parse(out, meetingID: "m")
        #expect(notes.summary == ["We reviewed the plan; drop-off fell.", "Translation needs the copy by Wednesday."])
    }

    @Test func editedTodoKeepsItsTickRecord() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("earl-e1-edit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = dir.lastPathComponent
        let tom = try #require(ActionItems.parse(Self.summary, meetingID: id).first { $0.owner == "Tom" })
        TodoFiles.record(tom, done: true, in: dir)
        TodoFiles.saveReminders([tom.key: "r1"], in: dir)
        let edited = NotesEdit.replacingText(ofLine: tom.line, in: Self.summary, with: "Book the big room for Thursday")
        let new = try #require(ActionItems.parseLine(edited.components(separatedBy: "\n")[tom.line], meetingID: id,
                                                     index: tom.line))
        TodoFiles.rekey([(tom, new)], in: dir)
        #expect(TodoFiles.loadDone(in: dir) == [.init(key: new.key, text: "Book the big room for Thursday")])
        #expect(TodoFiles.loadReminders(in: dir) == [new.key: "r1"])
    }

    @Test func ownersAreTheCast() {
        let speakers = [Speaker(id: "S1", track: "Them", name: "Priya Raman", nameSource: .confirmed, embedding: [], seconds: 9),
                        Speaker(id: "S2", track: "Them", embedding: [], seconds: 5)]
        let turns = [Turn(start: 0, end: 1, speaker: "Me", text: "Hi"),
                     Turn(start: 1, end: 2, speaker: "Them", text: "Hi", speakerID: "S1"),
                     Turn(start: 2, end: 3, speaker: "Them", text: "Yo", speakerID: "S2")]
        let meeting = Meeting(id: "m", folder: URL(fileURLWithPath: "/tmp/m"),
                              info: MeetingInfo(title: "T", titleIsDefault: true, startedAt: Date(), duration: 1, status: .done),
                              turns: turns, summary: "", files: [], speakers: speakers)
        #expect(NotesEdit.owners(in: meeting) == ["Priya Raman", "Speaker 2"])
        #expect(NotesEdit.yourOwnerLabel(userName: nil) == "Me")
        #expect(NotesEdit.yourOwnerLabel(userName: "Alex Morgan") == "Alex Morgan")
    }
}
