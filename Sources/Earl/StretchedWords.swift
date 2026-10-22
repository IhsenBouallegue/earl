import Foundation

// V-1: with --vad, whisper's one-word segments tile the timeline, so a word
// next to a stretch of silence VAD cut out gets the whole silence. On a real
// 46-minute call, 151 words lasted over 3 s and together covered 2,500 s;
// one "Mhm." on the mic ran for 71 s. Such a word glues two phrases across
// the pause, so lines land in the wrong place, a turn swallows the other
// side's reply, and click-to-play starts seconds early.
//
// On synthetic meetings, where the truth is known, 19 of 20 such words were
// placed right by one rule: a word that starts a sentence (a capital, or no
// sentence end) was really said at the end of its span, right before the
// next words; a lowercase word that ends a sentence ("time.") was said at
// the start, right after the previous ones.
enum StretchedWords {
    /// Longer than this, a single word is a stretched one. Even slow speech
    /// says a long German compound in well under two seconds.
    static let maxSeconds = 2.0

    static func fix(_ words: [TimedWord]) -> [TimedWord] {
        words.enumerated().map { index, word in
            let length = word.end - word.start
            guard length > maxSeconds else { return word }
            let text = word.text.trimmingCharacters(in: .whitespaces)
            let said = spokenLength(text)
            var fixed = word
            let endsSentence = text.last.map { ".?!".contains($0) } ?? false
            // A sentence starts after a full stop, not at a capital: German
            // capitalises every noun ("…das Wartungsfenster.").
            let previous = index > 0 ? words[index - 1].text.trimmingCharacters(in: .whitespaces) : ""
            let startsSentence = previous.isEmpty || ".?!".contains(previous.last!)
            if endsSentence && !startsSentence {
                fixed.end = word.start + said
            } else {
                fixed.start = word.end - said
            }
            return fixed
        }
    }

    /// About how long it takes to say `text`: 75 ms a letter, within
    /// 0.25–1.2 s.
    static func spokenLength(_ text: String) -> Double {
        let letters = text.filter(\.isLetter).count
        return min(1.2, max(0.25, 0.15 + 0.075 * Double(letters)))
    }
}
