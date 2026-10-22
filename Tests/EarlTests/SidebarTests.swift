import Foundation
import Testing
@testable import Earl

/// U-3: the sidebar's day headings and the faces on other people's to-dos.
struct SidebarTests {
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return c
    }()

    private func date(_ day: Int, _ hour: Int = 10) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour))!
    }

    @Test func dayHeadings() {
        let now = date(25, 15) // a Friday
        #expect(SidebarDay.label(for: date(25, 9), now: now, calendar: calendar) == "Today")
        #expect(SidebarDay.label(for: date(24), now: now, calendar: calendar) == "Yesterday")
        let tuesday = SidebarDay.label(for: date(22), now: now, calendar: calendar)
        #expect(tuesday != "Today" && tuesday != "Yesterday" && !tuesday.contains("2026"))
        #expect(SidebarDay.label(for: date(12), now: now, calendar: calendar).contains("2026"))
    }

    private let speakers = [
        Speaker(id: "S1", track: "Them", name: "Priya Raman", nameSource: .confirmed, embedding: [], seconds: 71),
        Speaker(id: "S2", track: "Them", name: "Sarah", nameSource: .guessed, embedding: [], seconds: 43),
        Speaker(id: "S3", track: "Them", name: nil, nameSource: nil, embedding: [], seconds: 20),
    ]

    @Test func ownerFaceMatchesTheVoice() {
        let looks = SpeakerFaces.looks(for: speakers)
        #expect(TodoOwner.look(for: "Priya", in: speakers) == looks["S1"])
        #expect(TodoOwner.look(for: "priya raman", in: speakers) == looks["S1"])
        #expect(TodoOwner.look(for: "Sarah", in: speakers) == looks["S2"])
        #expect(TodoOwner.look(for: "Speaker 3", in: speakers) == looks["S3"])
    }

    @Test func unknownOwnerHasNoVoice() {
        #expect(TodoOwner.look(for: "Jordan", in: speakers) == nil)
        #expect(TodoOwner.look(for: "", in: speakers) == nil)
        #expect(TodoOwner.look(for: "Priya", in: []) == nil)
    }
}
