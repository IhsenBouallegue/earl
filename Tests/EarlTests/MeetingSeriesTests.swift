import Foundation
import Testing
@testable import Earl

struct MeetingSeriesTests {
    private func meeting(_ id: String, calendarTitle: String?, eventID: String? = "E", day: Int,
                         title: String = "Notes title") -> Meeting {
        let info = MeetingInfo(title: title, titleIsDefault: false,
                               startedAt: Date(timeIntervalSince1970: Double(day) * 86_400), duration: 600,
                               status: .done, calendarEventID: calendarTitle == nil ? nil : eventID,
                               calendarTitle: calendarTitle)
        return Meeting(id: id, folder: URL(fileURLWithPath: "/tmp/\(id)"), info: info, turns: [],
                       summary: "## Summary\n- x", files: [])
    }

    @Test func keyIgnoresCancelledPrefixAndPunctuation() {
        #expect(MeetingSeries.key(title: "Abgesagt: Release Preview") == "release preview")
        #expect(MeetingSeries.key(title: "Guild WF – Weekly") == MeetingSeries.key(title: "Guild WF - Weekly"))
        #expect(MeetingSeries.key(title: "  ") == nil)
        #expect(MeetingSeries.key(title: nil) == nil)
    }

    @Test func meetingsWithoutCalendarFormNoSeries() {
        let a = meeting("a", calendarTitle: nil, day: 1), b = meeting("b", calendarTitle: nil, day: 2)
        #expect(MeetingSeries.groups([a, b]).isEmpty)
        #expect(MeetingSeries.earlier(than: b, in: [a, b]).isEmpty)
    }

    @Test func earlierIsNewestFirstAndSameSeriesOnly() {
        let d1 = meeting("d1", calendarTitle: "Daily KICC", day: 1)
        let d2 = meeting("d2", calendarTitle: "Daily KICC", eventID: "other", day: 2)
        let w = meeting("w", calendarTitle: "Weekly", day: 2)
        let d3 = meeting("d3", calendarTitle: "Daily KICC", day: 3)
        #expect(MeetingSeries.earlier(than: d3, in: [d1, d2, w, d3]).map(\.id) == ["d2", "d1"])
        #expect(MeetingSeries.earlier(than: d3, in: [d1, d2, w, d3], limit: 1).map(\.id) == ["d2"])
        #expect(MeetingSeries.groups([d1, d2, w, d3]).keys.sorted() == ["daily kicc"])
        #expect(MeetingSeries.past(forEventTitle: "Daily KICC", in: [d1, d2, w, d3]).map(\.id) == ["d3", "d2", "d1"])
    }

    @Test func displayNameDropsPrefix() {
        #expect(MeetingSeries.displayName([meeting("a", calendarTitle: "Abgesagt: Release Preview", day: 1)])
                == "Release Preview")
    }
}
