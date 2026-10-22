import Foundation

// V-1: one name, one speaker, across every source. Each source already kept
// its own names unique (voice memory, `AddressedNames`, `acceptDetailed`),
// but nothing checked them against each other: on a real daily, voice
// memory named S2 and direct address then gave S1 the same person.

enum NameCollisions {
    /// Who said so, weakest first: a name from a stronger source wins.
    enum Source: Int, Comparable {
        case model, addressed, voice, confirmed

        static func < (a: Source, b: Source) -> Bool { a.rawValue < b.rawValue }

        /// The words used in the log ("S2 has this name by voice").
        var label: String {
            switch self {
            case .model: return "from the model"
            case .addressed: return "from who was addressed"
            case .voice: return "by voice"
            case .confirmed: return "confirmed"
            }
        }

        /// A name already on a speaker. A guess saved earlier can't say which
        /// guesser made it, so it counts as the stronger of the two.
        init?(_ source: Speaker.NameSource?) {
            switch source {
            case .confirmed: self = .confirmed
            case .voice: self = .voice
            case .guessed: self = .addressed
            case nil: return nil
            }
        }
    }

    struct Drop: Equatable {
        var guess: SpeakerNameGuesser.Guess
        /// The speaker who keeps the name, and why.
        var holder: String
        var holderSource: Source

        var reason: String { "\(holder) has this name \(holderSource.label)" }
    }

    /// Keeps the guesses whose name no stronger (or earlier, equally strong)
    /// claim holds. Names already on `speakers` are never taken away; only
    /// the guesses lose. Within one source, the guessers have already made
    /// their names unique, so ties there go to the lower speaker number for
    /// a stable answer.
    static func resolve(speakers: [Speaker],
                        guesses: [(source: Source, guesses: [String: SpeakerNameGuesser.Guess])])
        -> (kept: [String: SpeakerNameGuesser.Guess], dropped: [String: Drop]) {
        var claims: [(id: String, name: String, source: Source)] = speakers.compactMap { s in
            guard let name = s.name, !name.isEmpty, let source = Source(s.nameSource) else { return nil }
            return (s.id, name, source)
        }
        let named = Set(claims.map(\.id))
        var kept: [String: SpeakerNameGuesser.Guess] = [:]
        var dropped: [String: Drop] = [:]
        typealias Entry = (id: String, guess: SpeakerNameGuesser.Guess, source: Source)
        var entries: [Entry] = []
        for group in guesses {
            for (id, guess) in group.guesses { entries.append((id, guess, group.source)) }
        }
        let ordered = entries.sorted { (a: Entry, b: Entry) -> Bool in
            if a.source != b.source { return a.source > b.source }
            return speakerOrder(a.id, b.id)
        }
        for entry in ordered where !named.contains(entry.id) && kept[entry.id] == nil {
            if let holder = claims.first(where: { $0.id != entry.id && samePerson($0.name, entry.guess.name) }) {
                // A weaker guess for a speaker someone else's guess already
                // covers is reported once, against the strongest holder.
                if dropped[entry.id] == nil {
                    dropped[entry.id] = Drop(guess: entry.guess, holder: holder.id, holderSource: holder.source)
                }
                continue
            }
            kept[entry.id] = entry.guess
            dropped[entry.id] = nil
            claims.append((entry.id, entry.guess.name, entry.source))
        }
        return (kept, dropped)
    }

    /// Whether two names stand for the same person: the same name once case
    /// and diacritics are gone, or a lone first name and a full name that
    /// starts with it ("Daniel" and "Daniel Falk"). Two different full
    /// names with the same first name are two people.
    static func samePerson(_ a: String, _ b: String) -> Bool {
        let x = NameMatch.normalize(a).split(separator: " ").map(String.init)
        let y = NameMatch.normalize(b).split(separator: " ").map(String.init)
        guard let xf = x.first, let yf = y.first else { return false }
        if x == y { return true }
        return (x.count == 1 || y.count == 1) && xf == yf
    }

    /// The `Guessed names:` log line: the kept names as before, then each
    /// dropped one with why ("S1 = Daniel Falk (dropped: S2 has this
    /// name by voice)").
    static func logLine(kept: [String: SpeakerNameGuesser.Guess], dropped: [String: Drop]) -> String {
        let entries = kept.map { (id: $0.key, text: "\($0.key) = \($0.value.name)") }
            + dropped.map { (id: $0.key, text: "\($0.key) = \($0.value.guess.name) (dropped: \($0.value.reason))") }
        guard !entries.isEmpty else { return "none" }
        return entries.sorted { speakerOrder($0.id, $1.id) }.map(\.text).joined(separator: ", ")
    }

    /// S2 before S10.
    private static func speakerOrder(_ a: String, _ b: String) -> Bool {
        let x = Int(a.dropFirst()) ?? 0, y = Int(b.dropFirst()) ?? 0
        return x != y ? x < y : a < b
    }
}
