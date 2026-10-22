import Foundation
import Testing
@testable import Earl

// U-2: sorting the notes onto the front page, owners, source turns, the cast
// and the player bar's timeline.
struct FrontPageTests {
    static let notes = """
        ## Summary
        - The team reviewed the new onboarding.
        - Drop-off fell from 31 % to 18 %
        - Sarah found the empty state reads as an error.

        ## Decisions
        - Ship to 20 % on October 6.
        - Keep the old flow for one release.

        ## Action items
        - [ ] Me: Book a usability session with two beta customers
        - [x] Priya: Share the funnel dashboard
        - Follow up with legal

        ## Open questions
        - Do team admins need their own flow?

        ## Risks
        - Translation could slip.
        """

    @Test func sortsSections() {
        let n = FrontPageNotes.parse(Self.notes, meetingID: "m")
        #expect(n.summary.count == 3)
        #expect(n.decisions == ["Ship to 20 % on October 6.", "Keep the old flow for one release."])
        #expect(n.open == ["Do team admins need their own flow?"])
        #expect(n.todos.map(\.owner) == ["Me", "Priya"])
        #expect(n.todos[1].done)
        // The to-do's line index is the one summary.md ticking uses.
        #expect(n.todos[0].line == 10)
        #expect(n.other == [.init(title: "Action items", bullets: ["Follow up with legal"]),
                            .init(title: "Risks", bullets: ["Translation could slip."])])
        #expect(!n.isEmpty)
        #expect(FrontPageNotes.parse("", meetingID: "m").isEmpty)
    }

    @Test func germanHeadingsAndNumberedBullets() {
        let n = FrontPageNotes.parse("## Zusammenfassung\n1. Eins\n## Entscheidungen\n* Zwei\n## Offene Fragen\n• Drei",
                                     meetingID: "m")
        #expect(n.summary == ["Eins"])
        #expect(n.decisions == ["Zwei"])
        #expect(n.open == ["Drei"])
    }

    @Test func briefingIsTwoOrThreeSentences() {
        let n = FrontPageNotes.parse(Self.notes, meetingID: "m")
        let brief = FrontPageNotes.briefing(n.summary)
        // Short bullets: three fit, and each ends as a sentence.
        #expect(brief.count == 3)
        #expect(brief.text.hasPrefix("The team reviewed the new onboarding. Drop-off fell from 31 % to 18 %. Sarah"))
        let longer = Array(repeating: "A bullet that is about seventy characters long, like real summary lines.", count: 3)
        #expect(FrontPageNotes.briefing(longer).count == 2)
        let long = String(repeating: "word ", count: 60)
        #expect(FrontPageNotes.briefing([long, "Second."]).count == 1)
        #expect(FrontPageNotes.briefing(["A.", "B!", "C?", "D."]).count == 3)
        #expect(FrontPageNotes.briefing([]).text.isEmpty)
    }

    static let speakers = [
        Speaker(id: "S1", track: "Them", name: "Priya Raman", nameSource: .confirmed, embedding: [], seconds: 70),
        Speaker(id: "S2", track: "Them", name: "Sarah", nameSource: .guessed, embedding: [], seconds: 40,
                evidence: "Thanks, Sarah"),
        Speaker(id: "S3", track: "Them", embedding: [], seconds: 20),
    ]

    @Test func ownersMatchSpeakers() {
        #expect(FrontPageMatch.speaker(for: "Priya", in: Self.speakers)?.id == "S1")
        #expect(FrontPageMatch.speaker(for: "priya raman", in: Self.speakers)?.id == "S1")
        #expect(FrontPageMatch.speaker(for: "Sarah Chen", in: Self.speakers)?.id == "S2")
        #expect(FrontPageMatch.speaker(for: "Speaker 3", in: Self.speakers)?.id == "S3")
        #expect(FrontPageMatch.speaker(for: "Tom", in: Self.speakers) == nil)
    }

    @Test func sourceTurnNeedsARealMatch() {
        let turns = [
            Turn(start: 12, end: 20, speaker: "Them", text: "Let's decide on the October release."),
            Turn(start: 199, end: 210, speaker: "Me", text: "Agreed. I'll also book a usability session with two beta customers before then."),
            Turn(start: 220, end: 230, speaker: "Them", text: "The empty state looks like an error."),
        ]
        #expect(FrontPageMatch.sourceTurn(for: "Book a usability session with two beta customers", in: turns)?.start == 199)
        // Two shared words out of many isn't enough.
        #expect(FrontPageMatch.sourceTurn(for: "Redesign the empty state so it doesn't look confusing to people", in: turns) == nil)
        #expect(FrontPageMatch.sourceTurn(for: "Call", in: turns) == nil)
    }

    @Test func castInOrderOfFirstSpeech() {
        let turns = [
            Turn(start: 0, end: 5, speaker: "Them", text: "a", speakerID: "S1"),
            Turn(start: 6, end: 9, speaker: "Me", text: "b"),
            Turn(start: 10, end: 12, speaker: "Them", text: "c", speakerID: "S2"),
            Turn(start: 13, end: 15, speaker: "Them", text: "d", speakerID: "S1"),
            Turn(start: 16, end: 18, speaker: "Them", text: "e", speakerID: "S3"),
        ]
        let cast = CastMember.cast(turns: turns, speakers: Self.speakers)
        #expect(cast.map(\.label) == [.name("Priya"), .name("You"), .guess("Sarah"), .unnamed("Speaker 3")])
        #expect(cast[1].isYou && cast[1].look == .me)
        #expect(cast[2].speakerID == "S2")
        #expect(cast[2].help == "Guessed: Thanks, Sarah")
        // Without separated voices: you and the call.
        let plain = CastMember.cast(turns: [Turn(start: 0, end: 1, speaker: "Them", text: "x"),
                                            Turn(start: 2, end: 3, speaker: "Me", text: "y")], speakers: [])
        #expect(plain.map(\.label) == [.name("Them"), .name("You")])
    }

    @Test func timelineJoinsNeighboursOfOneVoice() {
        let turns = [
            Turn(start: 0, end: 5, speaker: "Them", text: "a", speakerID: "S1"),
            Turn(start: 5.5, end: 9, speaker: "Them", text: "b", speakerID: "S1"),
            Turn(start: 12, end: 15, speaker: "Me", text: "c"),
            Turn(start: 20, end: 20, speaker: "Them", text: "empty", speakerID: "S2"),
        ]
        let segments = VoiceTimeline.segments(turns: turns, speakers: Self.speakers)
        #expect(segments.count == 2)
        #expect(segments[0].start == 0 && segments[0].end == 9)
        #expect(segments[1].voice == .you)
        #expect(segments.allSatisfy { $0.height > 0 && $0.height <= 1 })
    }

    @Test func findMatchesIgnoreCaseAndAccents() {
        #expect(PageText.matches("Die Schulung vor dem Rollout", query: "schulung"))
        #expect(PageText.matches("Café", query: "cafe"))
        #expect(!PageText.matches("anything", query: "  "))
    }

    @Test func headingsInTheMeetingsLanguage() {
        #expect(PageWords(language: "de").decided == "Entschieden")
        #expect(PageWords(language: "en").yourTodos == "Your to-dos")
        #expect(PageWords(language: nil).stillOpen == "Still open")
    }
}
