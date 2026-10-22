import Testing
@testable import Earl

/// Q-1: Whisper conditioning on its own previous text sometimes gets stuck in
/// a loop, or decodes the same passage twice a few seconds apart.
struct TranscriptCleanupTests {
    // MARK: Loops inside a phrase

    @Test func collapsesALoopOfThreeOrMoreRepeats() {
        let text = "you have a mapping on the, you have a mapping on the, you have a mapping on the"
        #expect(TranscriptCleanup.collapseLoops(text) == "you have a mapping on the,")
    }

    @Test func collapsesALoopEvenWithVaryingPunctuation() {
        // Normalised comparison, but the first copy's own text is kept.
        let text = "no way, no way, no way, no way, that's wild."
        #expect(TranscriptCleanup.collapseLoops(text) == "no way, that's wild.")
    }

    @Test func keepsTwoRepeatsAsIsNotALoop() {
        let text = "you have a mapping on the, you have a mapping on the"
        #expect(TranscriptCleanup.collapseLoops(text) == text)
    }

    @Test func keepsASingleWordRepeatedEvenManyTimes() {
        // The rule is 2-8 word runs; a single repeated word is left alone.
        let text = "no no no no no, I meant Tuesday"
        #expect(TranscriptCleanup.collapseLoops(text) == text)
    }

    @Test func collapsesALongerUnitToo() {
        let unit = "we should really think about this some more"
        let text = "\(unit), \(unit), \(unit), \(unit)"
        #expect(TranscriptCleanup.collapseLoops(text) == "\(unit),")
    }

    // MARK: Passages decoded twice

    @Test func dropsALongSentenceRepeatedSoonAfter() {
        let turns = [
            Turn(start: 122, end: 125, speaker: "Them", text: "So the plan is we ship on Friday."),
            Turn(start: 127, end: 130, speaker: "Them", text: "So the plan is we ship on Friday."),
        ]
        let cleaned = TranscriptCleanup.clean(turns)
        #expect(cleaned.map(\.text) == ["So the plan is we ship on Friday."])
    }

    @Test func keepsARepeatedSentenceOutsideTheWindow() {
        let turns = [
            Turn(start: 0, end: 3, speaker: "Them", text: "So the plan is we ship on Friday."),
            Turn(start: 40, end: 43, speaker: "Them", text: "So the plan is we ship on Friday."),
        ]
        let cleaned = TranscriptCleanup.clean(turns)
        #expect(cleaned.map(\.text) == ["So the plan is we ship on Friday.", "So the plan is we ship on Friday."])
    }

    @Test func keepsShortRepeatsLikePeopleActuallySay() {
        let turns = [
            Turn(start: 0, end: 1, speaker: "Them", text: "Tschüss."),
            Turn(start: 1.5, end: 2, speaker: "Them", text: "Tschüss."),
            Turn(start: 3, end: 4, speaker: "Me", text: "Yes, yes."),
        ]
        let cleaned = TranscriptCleanup.clean(turns)
        #expect(cleaned.map(\.text) == ["Tschüss.", "Tschüss.", "Yes, yes."])
    }

    @Test func dropsOnlyTheRepeatedSentenceWithinAPhrase() {
        let turns = [
            Turn(start: 0, end: 3, speaker: "Them", text: "So the plan is we ship on Friday."),
            Turn(start: 5, end: 9, speaker: "Them", text: "So the plan is we ship on Friday. Any questions on that?"),
        ]
        let cleaned = TranscriptCleanup.clean(turns)
        #expect(cleaned.map(\.text) == ["So the plan is we ship on Friday.", "Any questions on that?"])
    }

    @Test func eachCallStartsFreshSoOnlyOneTracksHistoryIsCompared() {
        // Transcriber calls `clean` once per track; nothing carries over
        // between two separate meetings (or, here, two separate calls), so a
        // sentence that just happens to repeat elsewhere isn't dropped.
        let them = TranscriptCleanup.clean([Turn(start: 0, end: 3, speaker: "Them", text: "So the plan is we ship on Friday.")])
        let me = TranscriptCleanup.clean([Turn(start: 1, end: 4, speaker: "Me", text: "So the plan is we ship on Friday.")])
        #expect(them.map(\.text) == ["So the plan is we ship on Friday."])
        #expect(me.map(\.text) == ["So the plan is we ship on Friday."])
    }

    @Test func dropsAPhraseThatBecomesEmpty() {
        let turns = [
            Turn(start: 0, end: 3, speaker: "Them", text: "So the plan is we ship on Friday."),
            Turn(start: 5, end: 8, speaker: "Them", text: "So the plan is we ship on Friday."),
        ]
        #expect(TranscriptCleanup.clean(turns).count == 1)
    }
}
