import Foundation

// Q-2: the exact-word match `SpeakerNameGuesser` used to use for corroboration
// and attendee mapping missed short forms ("Isa" for Isabelle) and whisper's
// misspellings of names ("Mathias" for Matthias, "Asan" for Ahsan), so real
// guesses were dropped or never mapped to the invited attendee.

enum NameMatch {
    /// Whether `spoken`, a single word said in the transcript, could be `name`
    /// (usually a first name): equal once diacritics and case are gone, a
    /// short form of it, or one of whisper's near-miss spellings.
    static func matches(spoken: String, name: String) -> Bool {
        let s = normalize(spoken), n = normalize(name)
        guard !s.isEmpty, !n.isEmpty else { return false }
        if s == n { return true }
        // Sentence-initial capitals make common words look like names ("Then"
        // would be a short form of Theodore, "Mir" of Miriam). A word that is
        // exactly the name still counts above.
        guard !commonWords.contains(s) else { return false }
        // Short form: at least 3 letters, shorter than the name, same first
        // three letters ("Isa"/"Isab" → Isabelle, "Max" → Maximilian). "Joe"
        // doesn't reach "Joseph" this way ("Joe" vs "Jos"), which is fine:
        // the spec would rather miss a name than guess it wrong.
        if s.count >= 3, s.count < n.count, s.prefix(3) == n.prefix(3) { return true }
        // Misspelling: allow a small edit distance, more room for longer
        // names. Names under 4 letters must be exact (too easy to collide).
        // The first letter must still agree: it's the strongest cue for a
        // name, and it's what keeps "Anna" from matching "Hanna" (decided
        // below) while still letting "Asan" match "Ahsan" (same first
        // letter, silent h in the middle).
        guard n.count >= 4, s.first == n.first else { return false }
        let limit = n.count <= 5 ? 1 : 2
        return editDistance(Array(s), Array(n), limit: limit) <= limit
    }

    /// Frequent English and German words of 3+ letters that start like a
    /// first name. Only fuzzy matches are blocked; "Will" said as a name at
    /// the start of a line still needs the exact name.
    static let commonWords: Set<String> = [
        "the", "then", "them", "they", "there", "these", "this", "that", "than", "thanks", "thank",
        "and", "are", "was", "were", "will", "with", "what", "when", "where", "who", "why", "yes",
        "but", "can", "could", "did", "does", "don", "for", "from", "have", "has", "had", "here",
        "how", "just", "let", "like", "may", "maybe", "mean", "more", "much", "not", "now", "okay",
        "one", "our", "out", "really", "right", "see", "she", "should", "some", "sorry", "sure",
        "all", "also", "any", "ask", "back", "because", "been", "being", "both", "even", "every",
        "der", "die", "das", "dem", "den", "des", "aber", "auch", "auf", "aus", "bei",
        "bin", "bis", "dann", "darf", "doch", "eine", "einen", "einer", "genau", "gut", "habe",
        "haben", "hier", "ich", "ihr", "ist", "jetzt", "kann", "mal", "man", "mehr", "mein", "mich",
        "mir", "mit", "muss", "nach", "nein", "nicht", "noch", "nur", "oder", "schon", "sehr",
        "sie", "sind", "und", "uns", "von", "war", "weil", "wenn", "wie", "wir", "wird",
        "zum", "zur", "danke", "super", "alles", "klar", "vielleicht",
    ]

    /// Lowercased, with diacritics folded away (é→e, ö→o) and ß spelled ss,
    /// since Unicode's own folding leaves ß alone.
    static func normalize(_ s: String) -> String {
        s.replacingOccurrences(of: "ß", with: "ss")
            .folding(options: .diacriticInsensitive, locale: nil)
            .lowercased()
    }

    /// Levenshtein distance, capped: once every remaining possibility is past
    /// `limit` the exact number stops mattering, so this can bail out early.
    private static func editDistance(_ a: [Character], _ b: [Character], limit: Int) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        if abs(a.count - b.count) > limit { return limit + 1 }
        var dp = Array(0...b.count)
        for i in 1...a.count {
            var prev = dp[0]
            dp[0] = i
            for j in 1...b.count {
                let temp = dp[j]
                dp[j] = a[i - 1] == b[j - 1] ? prev : 1 + Swift.min(dp[j - 1], dp[j], prev)
                prev = temp
            }
        }
        return dp[b.count]
    }
}
