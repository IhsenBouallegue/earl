import Foundation

/// Q-1: a 30 s recording that's just "Yeah." doesn't need a full set of
/// notes. Kept separate from `AppState` so the rule can be tested on its own.
enum NotesGate {
    static let minWords = 25
    static let minDuration: TimeInterval = 45

    /// Whether the meeting has enough said in it to be worth summarizing.
    static func worthNotes(turns: [Turn], duration: TimeInterval) -> Bool {
        duration >= minDuration && wordCount(turns) >= minWords
    }

    static func wordCount(_ turns: [Turn]) -> Int {
        turns.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
    }
}
