import Foundation
import Testing
@testable import Earl

/// S-2: Earl's brief, assembled from earlier notes of a series.
struct BriefTests {
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    /// Thursday, Oct 8 2026, 9:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_791_450_000)

    private func meeting(_ id: String, daysAgo: Double, summary: String, title: String = "Daily",
                         speakers: [Speaker] = [], attendees: [Attendee]? = nil) -> Meeting {
        var info = MeetingInfo(title: title, titleIsDefault: false,
                               startedAt: now.addingTimeInterval(-daysAgo * 86_400), duration: 900,
                               status: .done, calendarEventID: "E-\(id)", calendarTitle: title)
        info.attendees = attendees
        return Meeting(id: id, folder: URL(fileURLWithPath: "/tmp/\(id)"), info: info, turns: [],
                       summary: summary, files: [], speakers: speakers)
    }

    private func event(_ title: String = "Daily", attendees: [Attendee] = []) -> CalendarCandidate {
        CalendarCandidate(id: "next", title: title, start: now.addingTimeInterval(600),
                          end: now.addingTimeInterval(2400), isAllDay: false, attendeeCount: attendees.count,
                          myStatus: .accepted, urls: [], organizer: nil, attendees: attendees, calendarName: nil)
    }

    private func make(_ members: [Meeting], event: CalendarCandidate? = nil) -> Brief {
        Brief.make(event: event, series: members, userName: "Alex Morgan", now: now, calendar: cal)
    }

    @Test func todosDedupeKeepingTheNewestAndSplitMineFromOthers() {
        let old = meeting("a", daysAgo: 7, summary: """
            - [ ] Me: Send the pricing deck to finance
            - [ ] Dominik: Check the server logs
            """)
        let new = meeting("b", daysAgo: 2, summary: """
            - [ ] Alex: Send the pricing deck to finance.
            - [ ] Dominik: Order the new laptops
            """)
        let brief = make([old, new])
        #expect(brief.yours.map(\.meetingID) == ["b"])
        #expect(brief.others.map(\.text) == ["Order the new laptops", "Check the server logs"])
        #expect(brief.lastMeeting?.id == "b")
        #expect(brief.history.map(\.id) == ["b", "a"])
    }

    @Test func aTaskTickedLaterIsNotOpen() {
        let old = meeting("a", daysAgo: 7, summary: "- [ ] Me: Write the release notes")
        let new = meeting("b", daysAgo: 1, summary: "- [x] Me: Write the release notes")
        #expect(make([old, new]).yours.isEmpty)
    }

    @Test func onlyTheLastThreeMeetingsWithinThirtyDays() {
        let ancient = meeting("z", daysAgo: 40, summary: "- [ ] Me: Something from long ago")
        let tasks = ["Renew the domain", "Plan the offsite", "Fix the printer", "Answer the auditors"]
        let m = (1...4).map { meeting("m\($0)", daysAgo: Double($0), summary: "- [ ] Me: \(tasks[$0 - 1])") }
        let brief = make(m + [ancient])
        #expect(brief.yours.map(\.meetingID) == ["m1", "m2", "m3"])
        #expect(make([ancient]).yours.isEmpty)
    }

    @Test func limitsToEightEach() {
        let lines = (1...12).map { "- [ ] Me: Distinct task \(["alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel", "india", "juliet", "kilo", "lima"][$0 - 1])" }
        let questions = (1...7).map { "- Question \($0)?" }.joined(separator: "\n")
        let brief = make([meeting("a", daysAgo: 1, summary: lines.joined(separator: "\n") + "\n## Open questions\n" + questions)])
        #expect(brief.yours.count == 8)
        #expect(brief.questions.count == 5)
    }

    @Test func leadVariants() {
        let tuesday = now.addingTimeInterval(-2 * 86_400)
        #expect(EarlVoice.brief(yours: 2, others: ["Dominik"], last: tuesday, now: now, calendar: cal)
                == "Two of yours are still open from Tuesday, and Dominik owes one.")
        #expect(EarlVoice.brief(yours: 1, others: ["Dominik", "Sarah Klein"], last: tuesday, now: now, calendar: cal)
                == "One of yours is still open from Tuesday. Dominik and Sarah owe one each.")
        let clean = EarlVoice.brief(yours: 0, others: [], last: now.addingTimeInterval(-86_400), now: now, calendar: cal)
        #expect(clean.hasSuffix("from yesterday. You go in clean."))
        #expect(EarlVoice.brief(yours: 0, others: ["Dominik", "Dominik"], last: tuesday, now: now, calendar: cal)
                == "Nothing of yours is open from Tuesday. Dominik owes two.")
        #expect(EarlVoice.brief(yours: 0, others: [], last: nil, now: now, calendar: cal) == "First of these. I'll take notes.")
        #expect(EarlVoice.brief(yours: 12, others: [], last: tuesday, now: now, calendar: cal).hasPrefix("12 of yours"))
    }

    @Test func dayPhrases() {
        #expect(EarlVoice.dayPhrase(now.addingTimeInterval(-3600), now: now, calendar: cal) == "earlier today")
        #expect(EarlVoice.dayPhrase(now.addingTimeInterval(-86_400), now: now, calendar: cal) == "yesterday")
        #expect(EarlVoice.dayPhrase(now.addingTimeInterval(-2 * 86_400), now: now, calendar: cal) == "Tuesday")
        #expect(EarlVoice.dayPhrase(now.addingTimeInterval(-10 * 86_400), now: now, calendar: cal) == "Sep 28")
    }

    @Test func noMembersIsAFirstTime() {
        let brief = make([], event: event())
        #expect(brief.lead == "First of these. I'll take notes.")
        #expect(brief.title == "Daily")
        #expect(brief.lastMeeting == nil)
    }

    @Test func peopleWhoSpokeLastTimeComeFirst() {
        let speakers = [Speaker(id: "S1", track: "Them", name: "Sarah Klein", nameSource: .confirmed, embedding: [],
                                seconds: 60)]
        let last = meeting("a", daysAgo: 1, summary: "- x", speakers: speakers)
        let attendees = [Attendee(name: "Alex Morgan", email: nil, isMe: true),
                         Attendee(name: "Tom Becker", email: "tom@example.com", isMe: false),
                         Attendee(name: "Sarah Klein", email: nil, isMe: false)]
        let brief = Brief.make(event: event(attendees: attendees), series: [last], userName: "Alex Morgan", now: now,
                               isVoiceKnown: { name, _ in name == "Tom Becker" }, calendar: cal)
        #expect(brief.people.map(\.name) == ["Sarah Klein", "Tom Becker"])
        #expect(brief.people.map(\.spokeLastTime) == [true, false])
        #expect(brief.people.map(\.voiceKnown) == [false, true])
    }

    @Test func nudgeOncePerOccurrence() {
        let e = event()
        // Ten minutes before: due; once sent, never again for that occurrence.
        #expect(BriefNudgeRules.due([e], now: now, sent: []).map(\.id) == ["next"])
        let sent: Set<String> = [BriefNudgeRules.occurrence(e)]
        #expect(BriefNudgeRules.due([e], now: now.addingTimeInterval(60), sent: sent).isEmpty)
        // The next day's occurrence of the same event is a new one.
        var tomorrow = e
        tomorrow.start = e.start.addingTimeInterval(86_400)
        #expect(BriefNudgeRules.occurrence(tomorrow) != BriefNudgeRules.occurrence(e))
        // Too early, and too late.
        #expect(BriefNudgeRules.due([e], now: now.addingTimeInterval(-120), sent: []).isEmpty)
        #expect(BriefNudgeRules.due([e], now: e.start, sent: []).isEmpty)
        #expect(BriefNudgeRules.nextWake([e], now: now.addingTimeInterval(-120)) == e.start.addingTimeInterval(-600))
    }

    @Test func nudgeOnlyWithSomethingOpen() {
        let clean = make([meeting("a", daysAgo: 1, summary: "- [x] Me: Done thing")], event: event())
        let open = make([meeting("a", daysAgo: 1, summary: "- [ ] Tom: Open thing")], event: event())
        #expect(!BriefNudgeRules.worthNudging(clean))
        #expect(BriefNudgeRules.worthNudging(open))
        #expect(!BriefNudgeRules.worthNudging(nil))
    }

    @Test func callAppFromLink() {
        #expect(BriefFormat.callApp(urls: ["https://teams.microsoft.com/l/meetup-join/x"]) == "Teams")
        #expect(BriefFormat.callApp(urls: ["https://example.zoom.us/j/1"]) == "Zoom")
        #expect(BriefFormat.callApp(urls: ["https://meet.google.com/abc"]) == "Meet")
        #expect(BriefFormat.callApp(urls: ["https://meet.example.com/abc"]) == nil)
    }
}
