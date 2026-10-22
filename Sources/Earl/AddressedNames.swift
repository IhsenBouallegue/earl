import Foundation

// Q-3: names from who was addressed ("Tom, can you…", "Kam was bei dir,
// Matt?"), worked out from the transcript alone, no LLM. The model was slow
// and unreliable at exactly this pattern (see the Q-3 spec), even though
// `SpeakerNameGuesser.support` already counts it — but only to confirm the
// model's guesses, never to propose one itself.

enum AddressedNames {
    /// Names for `candidates` (speaker IDs) from who addresses whom in
    /// `turns`. Pure and synchronous: no LLM.
    static func guesses(turns: [Turn], candidates: [String], attendees: [Attendee], userName: String?)
        -> [String: SpeakerNameGuesser.Guess] {
        guard !turns.isEmpty, !candidates.isEmpty else { return [:] }
        let others = attendees.filter { !$0.isMe }

        var yourNames = Set<String>(), yourFirstNames = Set<String>()
        for name in [userName].compactMap({ $0 }) + attendees.filter(\.isMe).map(\.name) {
            yourNames.insert(name.lowercased())
            if let first = name.split(separator: " ").first { yourFirstNames.insert(String(first).lowercased()) }
        }
        // Your own name never goes to anyone (reuses `accept`'s guard).
        func isYourWord(_ word: String) -> Bool {
            let lower = word.lowercased()
            return yourNames.contains(lower) || yourFirstNames.contains(lower)
                || yourFirstNames.contains { NameMatch.matches(spoken: word, name: $0) }
        }

        // word said -> speakerID it was said to/by -> how many times, plus
        // the first quoted sentence, for evidence.
        var tally: [String: [String: Int]] = [:]
        var evidence: [String: [String: String]] = [:]
        func cast(_ word: String, for target: Turn?, sentence: String) {
            // "Me" turns cast votes but never receive one.
            guard let target, !target.isMe, let speakerID = target.speakerID, !isYourWord(word) else { return }
            tally[word, default: [:]][speakerID, default: 0] += 1
            if evidence[word]?[speakerID] == nil { evidence[word, default: [:]][speakerID] = sentence }
        }

        for (i, turn) in turns.enumerated() {
            // A self-introduction votes for the speaker's own turn.
            for word in selfIntroductions(in: turn.text) {
                cast(word, for: turn, sentence: sentence(around: word, in: turn.text) ?? turn.text)
            }
            for occurrence in vocatives(in: turn.text) {
                // A vocative near the end votes for the speaker of the next
                // turn by someone else, if it follows within 5 s.
                if occurrence.nearEnd, turns.indices.contains(i + 1), isOther(turns[i + 1], turn),
                   turns[i + 1].start - turn.end < 5 {
                    cast(occurrence.word, for: turns[i + 1], sentence: occurrence.sentence)
                }
                // A vocative near the start votes for the speaker of the
                // previous turn by someone else.
                if occurrence.first8, i > 0, isOther(turns[i - 1], turn) {
                    cast(occurrence.word, for: turns[i - 1], sentence: occurrence.sentence)
                }
            }
        }

        // Resolve each word said to a name: an attendee's full name (fuzzy
        // first-name match; unresolved or ambiguous words are ignored), or,
        // when the meeting has no attendees, the word itself, if it was said
        // at least twice to the same speaker and clears the usual guards.
        var nameTally: [String: [String: Int]] = [:]
        var nameEvidence: [String: [String: String]] = [:]
        let transcript = turns.map(\.text).joined(separator: "\n")
        let standIns = candidates.map { Speaker(id: $0, track: "Them", embedding: [], seconds: 0) }

        for (word, bySpeaker) in tally {
            if !others.isEmpty {
                let matches = others.filter { attendee in
                    guard let first = attendee.name.split(separator: " ").first.map(String.init) else { return false }
                    return NameMatch.matches(spoken: word, name: first)
                }
                guard matches.count == 1 else { continue }
                let name = matches[0].name
                for (speakerID, count) in bySpeaker {
                    nameTally[name, default: [:]][speakerID, default: 0] += count
                    if nameEvidence[name]?[speakerID] == nil { nameEvidence[name, default: [:]][speakerID] = evidence[word]?[speakerID] }
                }
            } else {
                let eligible = bySpeaker.filter { $0.value >= 2 }
                guard !eligible.isEmpty else { continue }
                let asGuesses = eligible.mapValues { _ in SpeakerNameGuesser.Guess(name: word, evidence: "") }
                let accepted = SpeakerNameGuesser.accept(asGuesses, speakers: standIns, attendees: [], userName: userName,
                                                         transcript: transcript)
                for speakerID in accepted.keys {
                    nameTally[word, default: [:]][speakerID] = bySpeaker[speakerID]
                    nameEvidence[word, default: [:]][speakerID] = evidence[word]?[speakerID]
                }
            }
        }

        return decide(nameTally, evidence: nameEvidence, candidates: Set(candidates))
    }

    /// A candidate gets the name with the most votes when that name has at
    /// least one vote and strictly more than any other name for this
    /// candidate, and this candidate is also where that name got the most
    /// votes (one name, one speaker).
    private static func decide(_ tally: [String: [String: Int]], evidence: [String: [String: String]],
                               candidates: Set<String>) -> [String: SpeakerNameGuesser.Guess] {
        var out: [String: SpeakerNameGuesser.Guess] = [:]
        for (name, bySpeaker) in tally {
            let inCandidates = bySpeaker.filter { candidates.contains($0.key) }
            guard let (speakerID, count) = inCandidates.max(by: { $0.value < $1.value }) else { continue }
            let runnerUp = inCandidates.filter { $0.key != speakerID }.values.max() ?? 0
            guard count > runnerUp else { continue }
            let namesForSpeaker = tally.compactMapValues { $0[speakerID] }
            guard let (topName, topCount) = namesForSpeaker.max(by: { $0.value < $1.value }) else { continue }
            let namesRunnerUp = namesForSpeaker.filter { $0.key != topName }.values.max() ?? 0
            guard topName == name, topCount > namesRunnerUp else { continue }
            out[speakerID] = SpeakerNameGuesser.Guess(name: name, evidence: evidence[name]?[speakerID] ?? "")
        }
        return out
    }

    /// Whether `a` and `b` are different speakers (by voice ID, or by track
    /// when a voice ID is missing).
    private static func isOther(_ a: Turn, _ b: Turn) -> Bool {
        if let aID = a.speakerID, let bID = b.speakerID { return aID != bID }
        return a.speaker != b.speaker
    }

    // MARK: - Finding vocatives

    /// One capitalised word used to address someone, found in a turn's text.
    private struct Occurrence {
        var word: String
        var sentence: String
        /// Within the first 8 words of the turn.
        var first8: Bool
        /// Within the turn's last sentence, or its last 25 words.
        var nearEnd: Bool
    }

    /// A word (letters, apostrophes and hyphens) plus whatever punctuation
    /// immediately follows it in the original token.
    private struct Token {
        var core: String
        var trailing: Character?
    }

    private static func tokenize(_ text: String) -> [Token] {
        text.split(separator: " ").map { raw in
            var t = Substring(raw)
            while let f = t.first, !f.isLetter { t.removeFirst() }
            var core = ""
            while let f = t.first, f.isLetter || f == "'" || f == "-" || f == "\u{2019}" {
                core.append(f)
                t.removeFirst()
            }
            return Token(core: core, trailing: t.first)
        }
    }

    /// Leading filler words that can come right before a vocative at the
    /// start of a sentence ("Aber Matthias, …", "Thanks, Tom.").
    private static let leadingWords: Set<String> = ["aber", "also", "and", "so", "okay", "ja", "hey", "thanks", "danke"]

    /// Vocatives in `text`: a capitalised word followed by `,` `?` `!` or the
    /// end of the turn, that either starts a sentence (allowing one short
    /// leading word) or follows a comma.
    private static func vocatives(in text: String) -> [Occurrence] {
        let rawWords = text.split(separator: " ").map(String.init)
        let tokens = tokenize(text)
        guard !tokens.isEmpty else { return [] }
        let total = tokens.count

        let boundaryIdx = tokens.indices.filter { i in
            if let t = tokens[i].trailing, ".!?".contains(t) { return true }
            return false
        }
        let sentenceStarts = Set([0] + boundaryIdx.map { $0 + 1 }.filter { $0 < total })
        let lastSentenceStart = sentenceStarts.max() ?? 0
        let nearEndThreshold = min(lastSentenceStart, max(0, total - 25))

        var out: [Occurrence] = []
        for i in tokens.indices {
            let token = tokens[i]
            guard token.core.count >= 2, let first = token.core.first, first.isUppercase else { continue }
            let isLast = i == total - 1
            let terminatorOK = token.trailing == "," || token.trailing == "?" || token.trailing == "!"
                || (isLast && (token.trailing == nil || token.trailing == "."))
            guard terminatorOK else { continue }

            let isSentenceStart = sentenceStarts.contains(i)
            let leadingOneWord = i > 0 && sentenceStarts.contains(i - 1) && leadingWords.contains(tokens[i - 1].core.lowercased())
            let leadingTwoWords = i > 1 && sentenceStarts.contains(i - 2)
                && tokens[i - 2].core.lowercased() == "thank" && tokens[i - 1].core.lowercased() == "you"
            let startsSentence = isSentenceStart || leadingOneWord || leadingTwoWords
            let followsComma = i > 0 && tokens[i - 1].trailing == ","
            guard startsSentence || followsComma else { continue }

            let sentenceStart = sentenceStarts.filter { $0 <= i }.max() ?? 0
            let sentenceEnd = min(boundaryIdx.first { $0 >= i } ?? (total - 1), total - 1)
            let sentence = rawWords[sentenceStart...max(sentenceStart, sentenceEnd)].joined(separator: " ")

            out.append(Occurrence(word: token.core, sentence: sentence, first8: i < 8, nearEnd: i >= nearEndThreshold))
        }
        return out
    }

    /// Self-introduced names ("I'm Tom", "ich bin Tom") with the sentence
    /// they're said in, for evidence.
    private static func selfIntroductions(in text: String) -> [String] {
        SpeakerNameGuesser.selfIntroducedNames(in: text)
    }

    /// The sentence in `text` containing the first occurrence of `word` (as a
    /// whole, capitalised token), or `nil` if it can't be found.
    private static func sentence(around word: String, in text: String) -> String? {
        let tokens = tokenize(text)
        let rawWords = text.split(separator: " ").map(String.init)
        guard let i = tokens.firstIndex(where: { $0.core == word }) else { return nil }
        let boundaryIdx = tokens.indices.filter { idx in
            if let t = tokens[idx].trailing, ".!?".contains(t) { return true }
            return false
        }
        let sentenceStarts = [0] + boundaryIdx.map { $0 + 1 }.filter { $0 < tokens.count }
        let start = sentenceStarts.filter { $0 <= i }.max() ?? 0
        let end = min(boundaryIdx.first { $0 >= i } ?? (tokens.count - 1), tokens.count - 1)
        return rawWords[start...max(start, end)].joined(separator: " ")
    }
}
