import Testing
@testable import Earl

/// Q-1: a 30 s "Yeah." doesn't need a full set of notes.
struct NotesGateTests {
    private func turns(_ texts: [String]) -> [Turn] {
        texts.enumerated().map { Turn(start: Double($0.offset) * 2, end: Double($0.offset) * 2 + 1, speaker: "Me", text: $0.element) }
    }

    @Test func tooFewWordsIsNotWorthNotes() {
        #expect(!NotesGate.worthNotes(turns: turns(["Yeah."]), duration: 30))
    }

    @Test func tooShortIsNotWorthNotesEvenWithManyWords() {
        let text = Array(repeating: "word", count: 40).joined(separator: " ")
        #expect(!NotesGate.worthNotes(turns: turns([text]), duration: 30))
    }

    @Test func enoughWordsAndDurationIsWorthNotes() {
        let text = Array(repeating: "word", count: 40).joined(separator: " ")
        #expect(NotesGate.worthNotes(turns: turns([text]), duration: 60))
    }

    @Test func exactlyAtTheThresholdsCounts() {
        let text = Array(repeating: "word", count: NotesGate.minWords).joined(separator: " ")
        #expect(NotesGate.worthNotes(turns: turns([text]), duration: NotesGate.minDuration))
    }

    @Test func wordCountSumsAcrossTurns() {
        #expect(NotesGate.wordCount(turns(["one two three", "four five"])) == 5)
    }

    @Test func emptyMeetingIsNotWorthNotes() {
        #expect(!NotesGate.worthNotes(turns: [], duration: 3600))
    }
}
