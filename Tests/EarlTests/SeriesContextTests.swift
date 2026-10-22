import Foundation
import Testing
@testable import Earl

/// S-1: notes that remember.
struct SeriesContextTests {
    static let base = Date(timeIntervalSince1970: 1_790_000_000) // a Tuesday morning in 2026

    static func meeting(_ id: String, title: String? = "Daily Team", day: Double, minutes: Double = 10,
                        summary: String = "## Summary\n- x", headline: String? = nil) -> Meeting {
        var info = MeetingInfo(title: title ?? "Call", titleIsDefault: false,
                               startedAt: base.addingTimeInterval(day * 86_400), duration: minutes * 60, status: .done,
                               calendarEventID: title == nil ? nil : "E", calendarTitle: title)
        info.headline = headline
        return Meeting(id: id, folder: URL(fileURLWithPath: "/tmp/\(id)"), info: info, turns: [], summary: summary, files: [])
    }

    // MARK: SeriesContext

    @Test func nilWithoutSeriesOrEarlierNotes() {
        let a = Self.meeting("a", title: nil, day: 0), b = Self.meeting("b", title: nil, day: 1)
        #expect(SeriesContext.text(for: b, in: [a, b], userName: nil) == nil)
        let first = Self.meeting("c", day: 0)
        #expect(SeriesContext.text(for: first, in: [first], userName: nil) == nil)
        let empty = Self.meeting("d", day: -1, summary: "")
        #expect(SeriesContext.text(for: first, in: [empty, first], userName: nil) == nil)
    }

    @Test func lastTimeAndOpenTodosNewestFirst() throws {
        let older = Self.meeting("o", day: -2, summary: """
            ## Decisions
            - Old decision
            ## Action items
            - [ ] Tom: Old open task
            - [x] Tom: Old ticked task
            """)
        let last = Self.meeting("l", day: -1, summary: """
            ## Summary
            - Talked
            ## Decisions
            - Ship on Friday
            ## Action items
            - [ ] Me: Send the patch list
            - [x] Sarah: Done already
            ## Open questions
            - Who owns QA?
            """, headline: "Friday it is")
        let today = Self.meeting("t", day: 0)
        let text = try #require(SeriesContext.text(for: today, in: [older, last, today], userName: "Alex"))
        #expect(text.hasPrefix(SeriesContext.heading))
        #expect(text.contains("Friday it is"))
        #expect(text.contains("- Ship on Friday"))
        #expect(text.contains("- Who owns QA?"))
        #expect(!text.contains("Old decision")) // only last time's decisions
        #expect(text.contains("Alex: Send the patch list"))
        #expect(text.contains("Tom: Old open task"))
        #expect(!text.contains("Old ticked task")) // ticks only from last time
        let open = try #require(text.range(of: "Open to-dos:"))
        let ticked = try #require(text.range(of: "Ticked off as done since:\n- Sarah: Done already"))
        #expect(open.lowerBound < ticked.lowerBound) // a ticked one is never listed as open
        let newer = try #require(text.range(of: "Send the patch list"))
        let old = try #require(text.range(of: "Old open task"))
        #expect(newer.lowerBound < old.lowerBound)
    }

    @Test func limitsTodosAgeAndLength() throws {
        let many = (1...20).map { "- [ ] Tom: Task number \($0) " + String(repeating: "word ", count: 30) }.joined(separator: "\n")
        let last = Self.meeting("l", day: -1, summary: "## Action items\n" + many)
        let stale = Self.meeting("s", day: -40, summary: "## Action items\n- [ ] Tom: Ancient task")
        let today = Self.meeting("t", day: 0)
        let text = try #require(SeriesContext.text(for: today, in: [stale, last, today], userName: nil))
        #expect(text.count <= SeriesContext.maxChars)
        #expect(!text.contains("Ancient task"))
        #expect(text.contains("Task number 1 "))
        #expect(!text.contains("Task number 13 "))
        // Only stale meetings: nothing.
        #expect(SeriesContext.text(for: today, in: [stale, today], userName: nil) == nil)
    }

    @Test func onlyTheLastThreeMeetingsGiveTodos() throws {
        let tasks = ["", "Order the cables", "Write the release mail", "Call the vendor", "Plan the offsite"]
        let ms = (1...4).map { Self.meeting("m\($0)", day: -Double($0), summary: "## Action items\n- [ ] Tom: \(tasks[$0])") }
        let today = Self.meeting("t", day: 0)
        let text = try #require(SeriesContext.text(for: today, in: ms + [today], userName: nil))
        #expect(text.contains("Call the vendor"))
        #expect(!text.contains("Plan the offsite"))
        #expect(SeriesContext.prepare(for: today, in: ms + [today], userName: nil).log.hasPrefix("Series: 3 earlier meetings, "))
    }

    // MARK: MeetingKind

    @Test func meetingKinds() {
        #expect(MeetingKind.decide(title: "Daily KICC", minutes: 15, seriesDates: [], voices: nil, attendees: 6) == .standup)
        #expect(MeetingKind.decide(title: "Team Stand-up", minutes: 20, seriesDates: [], voices: nil, attendees: nil) == .standup)
        #expect(MeetingKind.decide(title: "Jour fixe", minutes: 25, seriesDates: [], voices: nil, attendees: nil) == .standup)
        #expect(MeetingKind.decide(title: "Daily scrum", minutes: 50, seriesDates: [], voices: nil, attendees: nil) == .general)
        let week = (0..<3).map { Self.base.addingTimeInterval(Double($0) * 86_400) }
        #expect(MeetingKind.decide(title: "Sync", minutes: 15, seriesDates: week, voices: nil, attendees: nil) == .standup)
        #expect(MeetingKind.decide(title: "Sync", minutes: 15, seriesDates: Array(week.prefix(2)), voices: nil, attendees: nil) == .general)
        #expect(MeetingKind.decide(title: "Ahsan <> Sarah", minutes: 30, seriesDates: [], voices: nil, attendees: nil) == .oneOnOne)
        #expect(MeetingKind.decide(title: "1:1 Priya", minutes: 45, seriesDates: [], voices: nil, attendees: nil) == .oneOnOne)
        #expect(MeetingKind.decide(title: "Catch-up", minutes: 45, seriesDates: [], voices: 2, attendees: nil) == .oneOnOne)
        #expect(MeetingKind.decide(title: "Catch-up", minutes: 45, seriesDates: [], voices: nil, attendees: 2) == .oneOnOne)
        #expect(MeetingKind.decide(title: "Workshop", minutes: 47, seriesDates: [], voices: 5, attendees: 8) == .general)
    }

    // MARK: Prompt

    @Test func promptHasContextAndRuleOnlyWithContext() {
        var p = NotesPrompt()
        let plain = p.final(intro: "", material: "Transcript:\n\nhello")
        #expect(!plain.contains(NotesPrompt.noCopyRule))
        #expect(!plain.contains("## Since last time"))
        #expect(!p.part(1, of: 2, intro: "", chunk: "x").contains(NotesPrompt.noCopyRule))

        p.seriesContext = SeriesContext.heading + "\n\n- Ship on Friday"
        let withContext = p.final(intro: "", material: "Transcript:\n\nhello")
        #expect(withContext.contains(NotesPrompt.noCopyRule))
        #expect(withContext.contains("## Since last time"))
        let context = withContext.range(of: "Ship on Friday")!, transcript = withContext.range(of: "Transcript:")!
        #expect(context.lowerBound < transcript.lowerBound)
        let part = p.part(1, of: 2, intro: "", chunk: "x")
        #expect(part.components(separatedBy: "Ship on Friday").count == 2) // once
    }

    @Test func promptShapedByKind() {
        var p = NotesPrompt()
        p.kind = .standup
        let standup = p.final(intro: "", material: "m")
        #expect(standup.contains("## Round the table"))
        #expect(!standup.contains("## Summary"))
        #expect(NotesCheck.isValid("## Round the table\n- Nina: export bug"))
        p.kind = .oneOnOne
        p.userName = "Alex"
        let one = p.final(intro: "", material: "m")
        #expect(one.contains("## Summary") && one.contains("what they owe"))
        #expect(!NotesPrompt().final(intro: "", material: "m").contains("one-to-one"))
    }

    // MARK: Front page

    @Test func frontPageParsesNewHeadings() {
        let en = FrontPageNotes.parse("## Round the table\n- Nina: bug\n\n## Since last time\n- Done: patch list\n", meetingID: "m")
        #expect(en.summary == ["Nina: bug"])
        #expect(en.since == ["Done: patch list"])
        let de = FrontPageNotes.parse("## Runde\n- Nina: Bug\n\n## Seit dem letzten Mal\n- Erledigt: Liste\n", meetingID: "m")
        #expect(de.summary == ["Nina: Bug"])
        #expect(de.since == ["Erledigt: Liste"])
        #expect(FrontPageNotes.kind(of: "Since last time") == .since)
        #expect(!FrontPageNotes.parse("## Since last time\n- x", meetingID: "m").isEmpty)
    }

    @Test func doneItemsAreRecognised() {
        #expect(SinceLastTime.isDone("Done: sent the patch list"))
        #expect(SinceLastTime.isDone("Patch list sent (erledigt)"))
        #expect(!SinceLastTime.isDone("Patch list not done yet"))
        #expect(!SinceLastTime.isDone("Staging access is noch nicht erledigt"))
        #expect(!SinceLastTime.isDone("Staging access still open"))
    }
}
