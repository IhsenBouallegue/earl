import Testing
@testable import Earl

struct NameMatchTests {
    // The spec's table. "Anna"/"Hanna" and "Tom"/"Tim" are close calls,
    // resolved below with the reasoning documented at each row.
    static let cases: [(spoken: String, name: String, match: Bool)] = [
        ("Matthias", "Matthias", true),
        ("Mathias", "Matthias", true),
        ("Isa", "Isabelle", true),
        ("Isab", "Isabelle", true),
        ("Asan", "Ahsan", true),
        ("Lance", "Lenz", false), // too far (edit distance 3): fine to miss
        ("Jan", "Jana", true), // short form
        ("Tom", "Tim", false), // both 3 letters: names under 4 letters must be equal
        // Decided: no. Edit distance is 1 (insert "h"), but the first letter
        // differs (a vs h), and requiring the first letter to agree is what
        // keeps "Asan" matching "Ahsan" (same first letter, a silent h in the
        // middle) while not matching two people who just happen to be one
        // edit apart, like Anna and Hanna, where the initial sound is
        // actually different. False positives here would give one person's
        // name to another, which the spec calls worse than a miss.
        ("Anna", "Hanna", false),
        ("Mark", "Markus", true), // short form
        ("Max", "Maximilian", true), // short form
        // short form needs the same first 3 letters ("ben" vs "ber"); edit
        // distance is 2, over the limit of 1 for a 5-letter name
        ("Ben", "Bernd", false),
    ]

    @Test func table() {
        for c in Self.cases {
            #expect(NameMatch.matches(spoken: c.spoken, name: c.name) == c.match, "\(c.spoken) vs \(c.name)")
        }
    }

    @Test func caseInsensitive() {
        #expect(NameMatch.matches(spoken: "MATTHIAS", name: "matthias"))
        #expect(NameMatch.matches(spoken: "isa", name: "ISABELLE"))
    }

    @Test func diacriticsAreFolded() {
        #expect(NameMatch.matches(spoken: "Rene", name: "René"))
        #expect(NameMatch.matches(spoken: "Bjorn", name: "Björn"))
        #expect(NameMatch.matches(spoken: "Strasse", name: "Straße")) // ß → ss
    }

    @Test func emptyNeverMatches() {
        #expect(!NameMatch.matches(spoken: "", name: "Tom"))
        #expect(!NameMatch.matches(spoken: "Tom", name: ""))
        #expect(!NameMatch.matches(spoken: "", name: ""))
    }
}

@Suite("Q-2 capitalised mentions")
struct NameMentionCaseTests {
    @Test func lowercaseWordsDontCount() {
        #expect(!SpeakerNameGuesser.mentions("Theodore", in: "Then the plan is fine"))
        #expect(!SpeakerNameGuesser.introduces("Miriam", in: "Ich bin mir nicht sicher"))
        #expect(!SpeakerNameGuesser.mentions("Will", in: "I will do it"))
    }
    @Test func capitalisedShortFormsCount() {
        #expect(SpeakerNameGuesser.mentions("Isabelle", in: "Isa, you were raising your hand"))
        #expect(SpeakerNameGuesser.introduces("Miriam", in: "Hallo, ich bin Miri"))
        #expect(SpeakerNameGuesser.mentions("Matthias", in: "thanks mathias"))
    }
}
