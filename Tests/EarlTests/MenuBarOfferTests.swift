import Foundation
import Testing
@testable import Earl

// U-5: the words of the call offer and the times in the menu bar's recent list.
struct MenuBarOfferTests {
    func event(_ title: String, attendees: [String]) -> CalendarCandidate {
        CalendarCandidate(id: title, title: title, start: Date(), end: Date().addingTimeInterval(1800), isAllDay: false,
                          attendeeCount: attendees.count, myStatus: .accepted, urls: [], organizer: nil,
                          attendees: attendees.map { Attendee(name: $0, email: nil, isMe: false) }
                              + [Attendee(name: "Alex Smith", email: nil, isMe: true)],
                          calendarName: nil)
    }

    @Test func callOfferNamesTheMeeting() {
        let parts = OfferCopy.callParts(app: "Teams", event: event("Weekly sync", attendees: ["Priya Patel"]))
        #expect(parts.fact == "Teams is using your mic")
        #expect(parts.title == "Weekly sync")
        #expect(parts.with == "with Priya")
    }

    @Test func callOfferWithoutEventIsJustTheFact() {
        let parts = OfferCopy.callParts(app: "Zoom", event: nil)
        #expect(parts.fact == "Zoom is using your mic.")
        #expect(parts.title == nil)
        #expect(OfferCopy.callParts(app: "Zoom", event: event("  ", attendees: [])).title == nil)
    }

    @Test func callOfferWithoutOtherPeople() {
        let parts = OfferCopy.callParts(app: "Teams", event: event("Focus", attendees: []))
        #expect(parts.title == "Focus")
        #expect(parts.with == nil)
    }

    @Test func stopOfferSaysWhatIsSafe() {
        #expect(OfferCopy.stopLine(app: "Teams") == "Teams let go of the mic. Earl is still recording.")
        #expect(OfferCopy.stopLine(app: nil) == "Earl is still recording.")
    }

    @Test func recentTimes() {
        let cal = Calendar.current
        let now = cal.date(bySettingHour: 15, minute: 0, second: 0, of: Date())!
        let morning = cal.date(bySettingHour: 9, minute: 30, second: 0, of: now)!
        #expect(MenuBarFormat.when(morning, now: now, calendar: cal) == morning.formatted(date: .omitted, time: .shortened))
        let yesterday = cal.date(byAdding: .day, value: -1, to: morning)!
        #expect(MenuBarFormat.when(yesterday, now: now, calendar: cal) == "Yesterday")
        let threeDays = cal.date(byAdding: .day, value: -3, to: morning)!
        #expect(MenuBarFormat.when(threeDays, now: now, calendar: cal) == threeDays.formatted(.dateTime.weekday(.abbreviated)))
        let old = cal.date(byAdding: .day, value: -20, to: morning)!
        #expect(MenuBarFormat.when(old, now: now, calendar: cal) == old.formatted(.dateTime.day().month(.abbreviated)))
    }
}
