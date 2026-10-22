import Foundation

// Q-1: Whisper conditioning on its own previous text sometimes decodes a
// loop ("you have a mapping on the, you have a mapping on the, …") or the
// same passage twice a few seconds apart. Both are cleaned up per track,
// before `Transcriber.buildTurns` merges the tracks, so cross-talk between
// "Me" and "Them" is never mistaken for a repeat.
enum TranscriptCleanup {
    /// A sentence needs at least this many words to count as a real repeat;
    /// short exchanges ("Yes, yes.", "Tschüss. Tschüss.") are kept.
    static let minRepeatWords = 6
    /// How long a repeated sentence is remembered before it's allowed again.
    static let repeatWindow: Double = 30

    /// Cleans one track's turns, in the order Whisper produced them.
    static func clean(_ turns: [Turn]) -> [Turn] {
        var seen: [(words: [String], end: Double)] = []
        var out: [Turn] = []
        for turn in turns.sorted(by: { $0.start < $1.start }) {
            var turn = turn
            turn.text = dropRepeatedSentences(collapseLoops(turn.text), start: turn.start, end: turn.end, seen: &seen)
            guard !turn.text.isEmpty else { continue }
            out.append(turn)
        }
        return out
    }

    /// A run of 2–8 words repeated 3 or more times in a row collapses to one
    /// copy, keeping the first copy's original words (case and punctuation
    /// as Whisper wrote them).
    static func collapseLoops(_ text: String) -> String {
        let tokens = text.split(separator: " ").map(String.init)
        guard tokens.count >= 6 else { return text }
        var out: [String] = []
        var i = 0
        while i < tokens.count {
            let maxUnit = min(8, (tokens.count - i) / 3)
            var collapsed = false
            if maxUnit >= 2 {
                for length in stride(from: maxUnit, through: 2, by: -1) {
                    let unit = tokens[i..<(i + length)].map(normalizeToken)
                    var repeats = 1
                    while i + length * (repeats + 1) <= tokens.count,
                          tokens[(i + length * repeats)..<(i + length * (repeats + 1))].map(normalizeToken) == unit {
                        repeats += 1
                    }
                    if repeats >= 3 {
                        out.append(contentsOf: tokens[i..<(i + length)])
                        i += length * repeats
                        collapsed = true
                        break
                    }
                }
            }
            if !collapsed {
                out.append(tokens[i])
                i += 1
            }
        }
        return out.joined(separator: " ")
    }

    /// Splits `text` into sentences (each sentence keeps its trailing `.`,
    /// `!` or `?`), drops one that already appeared, normalised, on this
    /// track within the last `repeatWindow` seconds and has at least
    /// `minRepeatWords` words, and remembers the sentences kept.
    private static func dropRepeatedSentences(_ text: String, start: Double, end: Double,
                                              seen: inout [(words: [String], end: Double)]) -> String {
        seen.removeAll { start - $0.end > repeatWindow }
        var kept: [String] = []
        for part in sentences(of: text) {
            let words = part.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
            if words.count >= minRepeatWords, seen.contains(where: { $0.words == words }) { continue }
            if words.count >= minRepeatWords { seen.append((words, end)) }
            kept.append(part)
        }
        return kept.joined(separator: " ")
    }

    private static func sentences(of text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if ".!?".contains(ch) {
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { result.append(trimmed) }
                current = ""
            }
        }
        let trimmed = current.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { result.append(trimmed) }
        return result
    }

    private static func normalizeToken(_ token: String) -> String {
        token.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
