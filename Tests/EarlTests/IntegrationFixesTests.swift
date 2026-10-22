import Foundation
import Testing
@testable import Earl

/// Fixes from the review of the butler wave, where S-1, S-2, E-1 and V-1 meet.
struct IntegrationFixesTests {
    static let base = Date(timeIntervalSince1970: 1_790_000_000)

    static func meeting(_ id: String, day: Double, summary: String) -> Meeting {
        let info = MeetingInfo(title: "Daily Team", titleIsDefault: false,
                               startedAt: base.addingTimeInterval(day * 86_400), duration: 600, status: .done,
                               calendarEventID: "E", calendarTitle: "Daily Team")
        return Meeting(id: id, folder: URL(fileURLWithPath: "/tmp/\(id)"), info: info, turns: [], summary: summary, files: [])
    }

    @Test func doneSinceLastTimeClosesAnOlderTodo() {
        let monday = Self.meeting("mon", day: -2, summary: "## Action items\n- [ ] Tom: send the patch list\n- [ ] Tom: book the room")
        let tuesday = Self.meeting("tue", day: -1, summary: "## Since last time\n- Done: Tom sent the patch list to Sarah.\n## Summary\n- x")
        let (mine, others) = Brief.openTodos(in: [tuesday, monday], userName: "Alex", now: Self.base)
        #expect(mine.isEmpty)
        #expect(others.map(\.text) == ["book the room"])
    }

    @Test func seriesContextListsATaskOnceAndNotWhenTickedLater() throws {
        let older = Self.meeting("o", day: -3, summary: "## Action items\n- [ ] Tom: send deck\n- [ ] Sarah: fix export")
        let middle = Self.meeting("m", day: -2, summary: "## Action items\n- [x] Tom: send deck\n- [ ] Sarah: fix export")
        let last = Self.meeting("l", day: -1, summary: "## Action items\n- [ ] Sarah: fix export")
        let today = Self.meeting("t", day: 0, summary: "")
        let text = try #require(SeriesContext.text(for: today, in: [older, middle, last, today], userName: nil))
        #expect(text.components(separatedBy: "fix export").count == 2) // once
        #expect(!text.contains("Tom: send deck (set")) // ticked on the middle meeting
    }

    @Test func aSharedNameIsNotRewrittenInTheNotes() {
        func speaker(_ id: String, _ name: String?, _ source: Speaker.NameSource?) -> Speaker {
            Speaker(id: id, track: "Them", name: name, nameSource: source, embedding: [], seconds: 60)
        }
        // S1 wrongly guessed "Sarah", and S2 was named Sarah too: renaming S1
        // to Tom must not turn the real Sarah's lines into Tom's.
        let before = [speaker("S1", "Sarah", .guessed), speaker("S2", "Sarah", .confirmed)]
        let after = [speaker("S1", "Tom", .confirmed), speaker("S2", "Sarah", .confirmed)]
        #expect(NotesPatch.renames(before: before, after: after).isEmpty)
    }

    @Test func aCapitalisedGermanNounAtTheEndOfASentenceKeepsItsPlace() {
        let words = [TimedWord(text: "wir", start: 0, end: 0.2), TimedWord(text: "brauchen", start: 0.2, end: 0.6),
                     TimedWord(text: "das", start: 0.6, end: 0.8), TimedWord(text: "Wartungsfenster.", start: 0.8, end: 20.8)]
        let fixed = StretchedWords.fix(words)
        #expect(fixed[3].start == 0.8) // said right after "das", the pause comes after
        #expect(fixed[3].end < 3)
    }

    @Test func briefLeadCountsTodosWithoutAnOwner() {
        let last = Self.meeting("l", day: -1, summary: "## Action items\n- [ ] book the room")
        let brief = Brief.make(event: nil, series: [last], userName: "Alex", now: Self.base)
        #expect(!brief.lead.contains("clean"))
    }

    @Test func searchFoldsAccents() {
        let m = Self.meeting("x", day: 0, summary: "- Die Prüfung ist am Freitag")
        #expect(m.matches("prufung"))
        #expect(m.matches("Prüfung"))
    }
}

extension IntegrationFixesTests {
    @Test func aTaskCarriedOverASeriesIsListedOnce() {
        let older = Self.meeting("o", day: -7, summary: "## Action items\n- [ ] Send the comparison to Priya\n- [ ] Tom: order cables")
        let newer = Self.meeting("n", day: -1, summary: "## Action items\n- [ ] Send the comparison to Priya")
        let today = Self.meeting("t", day: 0, summary: "## Since last time\n- Done: Tom ordered the cables.")
        let gone = SeriesTodos.superseded(in: [older, newer, today])
        #expect(gone == ["o#1", "o#2"])
    }
}
