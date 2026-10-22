import Foundation
import Testing
@testable import Earl

struct CalendarMatcherTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

    func event(_ id: String, from start: Double, to end: Double, people: Int = 3,
               status: CalendarCandidate.Response = .accepted, allDay: Bool = false,
               urls: [String] = []) -> CalendarCandidate {
        CalendarCandidate(id: id, title: id, start: at(start), end: at(end), isAllDay: allDay,
                          attendeeCount: people, myStatus: status, urls: urls, organizer: nil,
                          attendees: [], calendarName: nil)
    }

    func best(_ events: [CalendarCandidate], _ minute: Double, callApp: String? = nil) -> String? {
        CalendarMatcher.best(from: events, at: at(minute), callApp: callApp)?.id
    }

    @Test func ongoingEventMatches() {
        #expect(best([event("standup", from: -5, to: 10)], 0) == "standup")
    }

    @Test func nothingWhenNothingIsNear() {
        let events = [event("earlier", from: -90, to: -30), event("later", from: 30, to: 60)]
        #expect(best(events, 0) == nil)
    }

    @Test func earlyStartStillMatches() {
        // Recording started 10 minutes before the event.
        #expect(best([event("planning", from: 10, to: 70)], 0) == "planning")
        // But not 20 minutes before.
        #expect(best([event("planning", from: 20, to: 80)], 0) == nil)
    }

    @Test func ongoingBeatsStartingSoon() {
        let events = [event("next", from: 5, to: 35, people: 8), event("now", from: -20, to: 10, people: 2)]
        #expect(best(events, 0) == "now")
    }

    @Test func overlapGoesToClosestStart() {
        // Two ongoing events with the same score: the one that started most recently.
        let events = [event("workshop", from: -120, to: 120), event("sync", from: -3, to: 27)]
        #expect(best(events, 0) == "sync")
    }

    @Test func declinedEventsAreSkipped() {
        let events = [event("declined", from: -2, to: 30, status: .declined),
                      event("accepted", from: -25, to: 5)]
        #expect(best(events, 0) == "accepted")
    }

    @Test func allDayAndSoloEventsAreSkipped() {
        let events = [event("holiday", from: -600, to: 800, people: 0, allDay: true),
                      event("focus", from: -10, to: 50, people: 0),
                      event("1:1", from: 5, to: 35, people: 1)]
        #expect(best(events, 0) == "1:1")
    }

    @Test func excludedEventsCountWhenNothingElseMatches() {
        #expect(best([event("focus", from: -10, to: 50, people: 0)], 0) == "focus")
        #expect(best([event("declined", from: -10, to: 50, status: .declined)], 0) == "declined")
        // A timed event still beats an all-day one.
        let events = [event("holiday", from: -600, to: 800, people: 0, allDay: true),
                      event("focus", from: -10, to: 50, people: 0)]
        #expect(best(events, 0) == "focus")
    }

    @Test func callAppLinkBonus() {
        let zoom = event("zoom", from: -5, to: 25, urls: ["https://acme.zoom.us/j/123"])
        let teams = event("teams", from: -5, to: 25, urls: ["https://teams.microsoft.com/l/meetup-join/abc"])
        #expect(best([zoom, teams], 0, callApp: "Microsoft Teams") == "teams")
        #expect(best([teams, zoom], 0, callApp: "zoom.us") == "zoom")
    }

    @Test func acceptedBeatsTentative() {
        let events = [event("maybe", from: -5, to: 25, status: .tentative), event("yes", from: -5, to: 25)]
        #expect(best(events, 0) == "yes")
    }

    @Test func callAppServices() {
        #expect(CalendarMatcher.service(forCallApp: "Microsoft Teams") == .teams)
        #expect(CalendarMatcher.service(forCallApp: "zoom.us") == .zoom)
        #expect(CalendarMatcher.service(forCallApp: "Google Chrome") == .meet)
        #expect(CalendarMatcher.service(forCallApp: "Slack") == nil)
        #expect(CalendarMatcher.service(forCallApp: nil) == nil)
    }

    @Test func upNext() {
        let soon = event("planning", from: 4, to: 64)
        #expect(CalendarMatcher.upNext(from: [soon], at: at(0))?.id == "planning")
        #expect(CalendarMatcher.startText(soon, at: at(0)) == "in 4 min")
        #expect(CalendarMatcher.startText(soon, at: at(4)) == "now")
        // Too far out, solo, or declined: nothing.
        #expect(CalendarMatcher.upNext(from: [event("later", from: 15, to: 45)], at: at(0)) == nil)
        #expect(CalendarMatcher.upNext(from: [event("focus", from: 2, to: 60, people: 0)], at: at(0)) == nil)
        #expect(CalendarMatcher.upNext(from: [event("no", from: 2, to: 60, status: .declined)], at: at(0)) == nil)
    }
}

struct MeetingLinkTests {
    @Test func findsLinksInEachField() {
        let links = MeetingLink.find(in: [
            nil,
            "Room 4.12; https://acme.zoom.us/j/9876543210?pwd=abc",
            "Join: <https://teams.microsoft.com/l/meetup-join/19%3ameeting_x%40thread.v2/0?context=%7b%22Tid%22%7d>",
        ])
        #expect(links == [
            "https://acme.zoom.us/j/9876543210?pwd=abc",
            "https://teams.microsoft.com/l/meetup-join/19%3ameeting_x%40thread.v2/0?context=%7b%22Tid%22%7d",
        ])
    }

    @Test func recognisesAllServices() {
        let text = """
            meet.google.com/abc-defg-hij. Or https://teams.live.com/meet/123, \
            https://acme.webex.com/meet/sarah
            """
        let links = MeetingLink.find(in: [text])
        #expect(links == ["https://meet.google.com/abc-defg-hij", "https://teams.live.com/meet/123",
                          "https://acme.webex.com/meet/sarah"])
        #expect(links.map(MeetingLink.service) == [.meet, .teams, .webex])
    }

    @Test func ignoresOtherLinksAndDuplicates() {
        #expect(MeetingLink.find(in: ["https://example.com/agenda", "zoom.us/pricing"]).isEmpty)
        #expect(MeetingLink.find(in: ["https://meet.google.com/x", "https://meet.google.com/x"]).count == 1)
    }

    @Test func unwrapsOutlookSafeLinks() {
        let wrapped = "https://eur02.safelinks.protection.outlook.com/?url=https%3A%2F%2Fteams.microsoft.com%2Fl%2Fmeetup-join%2Fabc&data=05%7C01"
        #expect(MeetingLink.find(in: ["Join here: \(wrapped)"]) == ["https://teams.microsoft.com/l/meetup-join/abc"])
    }
}

struct AttendeeNameTests {
    @Test func nameFromEmail() {
        #expect(AttendeeName.fromEmail("sarah.mueller@x.com") == "Sarah Mueller")
        #expect(AttendeeName.fromEmail("TOM_BAKER@x.com") == "Tom Baker")
        #expect(AttendeeName.fromEmail("anna-lena.schmidt+work@x.com") == "Anna Lena Schmidt")
        #expect(AttendeeName.fromEmail("jdoe2@x.com") == "Jdoe2")
        #expect(AttendeeName.fromEmail("not an address") == nil)
    }

    @Test func displayPrefersTheName() {
        #expect(AttendeeName.display(name: "Sarah Müller", email: "sm@x.com") == "Sarah Müller")
        #expect(AttendeeName.display(name: "  ", email: "sarah.mueller@x.com") == "Sarah Mueller")
        #expect(AttendeeName.display(name: "sarah.mueller@x.com", email: nil) == "Sarah Mueller")
        #expect(AttendeeName.display(name: "Mueller, Sarah", email: nil) == "Sarah Mueller")
        #expect(AttendeeName.display(name: nil, email: nil) == nil)
    }

    @Test func emailFromParticipantURL() {
        #expect(AttendeeName.email(from: URL(string: "mailto:sarah.mueller@x.com")) == "sarah.mueller@x.com")
        #expect(AttendeeName.email(from: URL(string: "mailto:sarah%2Bwork@x.com")) == "sarah+work@x.com")
        #expect(AttendeeName.email(from: URL(string: "https://x.com")) == nil)
    }
}

struct CalendarInfoTests {
    func info(_ attendees: [Attendee]?) -> MeetingInfo {
        var info = MeetingInfo(title: "Meeting", titleIsDefault: true, startedAt: Date(), duration: 0,
                               status: .done, error: nil)
        info.attendees = attendees
        return info
    }

    let me = Attendee(name: "Ahsan Lefevre", email: nil, isMe: true)
    func person(_ name: String) -> Attendee { Attendee(name: name, email: nil, isMe: false) }

    @Test func attendeeLine() {
        #expect(info(nil).attendeeLine == nil)
        #expect(info([me]).attendeeLine == nil)
        #expect(info([me, person("Sarah Mueller")]).attendeeLine == "with Sarah")
        #expect(info([person("Sarah Mueller"), me, person("Tom Baker")]).attendeeLine == "with Sarah and Tom")
        #expect(info([person("Sarah"), person("Tom"), person("Anna")]).attendeeLine == "with Sarah, Tom and Anna")
        let five = ["Sarah", "Tom", "Anna", "Ben", "Cleo"].map(person)
        #expect(info(five).attendeeLine == "with Sarah, Tom and 3 others")
    }

    @Test func oldMeetingJSONStillLoads() throws {
        let json = #"{"title":"Old","titleIsDefault":false,"startedAt":"2026-01-01T10:00:00Z","duration":60,"status":"done"}"#
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        let info = try d.decode(MeetingInfo.self, from: Data(json.utf8))
        #expect(info.attendees == nil && info.calendarEventID == nil)
    }

    @Test func eventIDRoundTrip() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let id = CalendarEventID.make(externalID: "AAMk|weird=id", occurrence: date)
        let parsed = CalendarEventID.parse(id)
        #expect(parsed?.externalID == "AAMk|weird=id")
        #expect(parsed?.occurrence == date)
        #expect(CalendarEventID.parse("no date") == nil)
    }

    @Test func summaryContextLine() {
        var i = info([me, person("Sarah Mueller")])
        i.calendarTitle = "Sprint Planning"
        let context = SummaryContext(i, userName: nil)
        #expect(context?.line == """
            Meeting: Sprint Planning. Participants: Ahsan Lefevre, Sarah Mueller. \
            'Me' in the transcript is Ahsan Lefevre.\n\n
            """)
        #expect(SummaryContext(info(nil), userName: nil) == nil)
        #expect(SummaryContext(info(nil), userName: "Ahsan")?.line == "'Me' in the transcript is Ahsan.\n\n")
    }

    // Q-3: participants are cleaned the same way the Whisper prompt is, so a
    // mailing list or an "-Extern" suffix doesn't reach the notes model.
    @Test func summaryContextParticipantsAreCleaned() {
        var i = info([me, Attendee(name: "Sam Kowalski -Extern", email: nil, isMe: false),
                     Attendee(name: "Sam Kowalski", email: nil, isMe: false),
                     Attendee(name: "Distribution - ORG - Sales EU", email: nil, isMe: false)])
        i.calendarTitle = "Kickoff"
        let context = SummaryContext(i, userName: nil)
        #expect(context?.line == "Meeting: Kickoff. Participants: Ahsan Lefevre, Sam Kowalski. "
            + "'Me' in the transcript is Ahsan Lefevre.\n\n")
    }

    @Test func whisperPromptIncludesAttendees() {
        let names = info([me, person("Sarah Mueller")]).attendeeNames
        let prompt = WhisperPrompt.build(extraNames: names, vocabulary: ["Skyfield", "ahsan lefevre"])
        // Your own name is already in the vocabulary, so it isn't repeated (Q-1: a sentence, not a bare list).
        // "ahsan lefevre" is lowercase in the vocabulary, so it reads as a term rather than a name.
        #expect(prompt == "Sarah Mueller talks about Skyfield and ahsan lefevre.")
    }
}
