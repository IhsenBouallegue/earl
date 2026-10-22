import Foundation
import Testing
@testable import Earl

struct VocabularyTests {
    // MARK: Parsing

    @Test func splitsOnNewlinesAndCommas() {
        #expect(WhisperPrompt.terms(from: "Skyfield\nKubernetes, OKR\r\nSarah Müller") ==
                ["Skyfield", "Kubernetes", "OKR", "Sarah Müller"])
    }

    @Test func trimsAndDropsEmptyEntries() {
        #expect(WhisperPrompt.terms(from: "  Skyfield  \n\n , ,\n\tKPI \n") == ["Skyfield", "KPI"])
        #expect(WhisperPrompt.terms(from: "") == [])
        #expect(WhisperPrompt.terms(from: " \n , ") == [])
    }

    @Test func dropsCaseInsensitiveDuplicatesKeepingFirstSpelling() {
        #expect(WhisperPrompt.terms(from: "OKR\nokr\nSkyfield\nSKYFIELD, Okr") == ["OKR", "Skyfield"])
    }

    // MARK: Prompt (Q-1: a plain sentence, not "Glossary: A, B, C.")

    @Test func buildsASentenceWithPeopleFirstThenTopics() {
        #expect(WhisperPrompt.build(vocabulary: ["Sarah Müller", "Skyfield", "Kubernetes", "OKR"]) ==
                "Sarah Müller talks about Skyfield, Kubernetes and OKR.")
    }

    @Test func topicsOnlySentence() {
        #expect(WhisperPrompt.build(vocabulary: ["Skyfield", "Kubernetes"]) == "This meeting is about Skyfield and Kubernetes.")
    }

    @Test func peopleOnlySentence() {
        #expect(WhisperPrompt.build(vocabulary: ["Sarah Müller"]) == "Sarah Müller is in this meeting.")
        #expect(WhisperPrompt.build(vocabulary: ["Sarah Müller", "Tom Baker"]) == "Sarah Müller and Tom Baker are in this meeting.")
    }

    @Test func noTermsMeansNoPrompt() {
        #expect(WhisperPrompt.build(vocabulary: []) == nil)
        #expect(WhisperPrompt.build(extraNames: [" ", ""], vocabulary: []) == nil)
    }

    @Test func extraNamesComeAfterVocabularyWithoutDuplicates() {
        // Order only matters for what fits (`fitting`); here everything fits, and
        // the sentence groups people and topics regardless of where they came from.
        #expect(WhisperPrompt.build(extraNames: ["Sarah Müller", "skyfield", "Tom Baker"], vocabulary: ["Skyfield", "KPI"]) ==
                "Sarah Müller and Tom Baker talk about Skyfield and KPI.")
        #expect(WhisperPrompt.build(extraNames: ["Sarah Connor"], vocabulary: []) == "Sarah Connor is in this meeting.")
    }

    @Test func truncatesLongListsFromTheEnd() {
        let terms = (1...300).map { "Term\($0)" }
        let prompt = WhisperPrompt.build(vocabulary: terms)!
        #expect(prompt.count <= WhisperPrompt.maxCharacters)
        #expect(prompt.hasPrefix("This meeting is about Term1, Term2, "))
        #expect(prompt.hasSuffix("."))
        let kept = WhisperPrompt.fitting(terms)
        #expect(kept.count < terms.count)
        #expect(kept == Array(terms.prefix(kept.count)))
    }

    @Test func shortListsFitWhole() {
        let terms = ["Skyfield", "Carnot", "KPI"]
        #expect(WhisperPrompt.fitting(terms) == terms)
    }

    @Test func buildTermsMatchesWhatThePromptWasBuiltFrom() {
        // Q-1: the terms are returned alongside the prompt instead of re-parsed from it.
        let terms = WhisperPrompt.buildTerms(extraNames: ["Sarah Müller"], vocabulary: ["Skyfield", "KPI"])
        #expect(terms == ["Skyfield", "KPI", "Sarah Müller"])
        #expect(WhisperPrompt.buildTerms(vocabulary: []) == [])
    }

    // MARK: Prompt echo and invented labels (Q-1)

    private let terms = ["Skyfield", "Carnot", "Ahsan", "KPI", "Sarah Müller"]
    private var words: Set<String> { WhisperPrompt.words(in: terms.joined(separator: ", ")) }

    @Test func detectsEchoedPrompt() {
        #expect(WhisperPrompt.isEcho("Skyfield, Carnot, Ahsan, KPI.", promptWords: words))
        #expect(WhisperPrompt.isEcho("Skyfield, Carnot, Ahsan, KPI, Sarah Müller.", promptWords: words))
        #expect(WhisperPrompt.isEcho("Skyfield Carnot.", promptWords: words))
    }

    @Test func keepsRealSpeechWithTerms() {
        #expect(!WhisperPrompt.isEcho("We moved the Skyfield rollout to Carnot.", promptWords: words))
        #expect(!WhisperPrompt.isEcho("Sarah?", promptWords: words))
        #expect(!WhisperPrompt.isEcho("Thanks, Ahsan.", promptWords: words))
    }

    @Test func noPromptMeansNoEchoFilter() {
        #expect(!WhisperPrompt.isEcho("Skyfield, Carnot.", promptWords: []))
    }

    @Test func liveParseDropsEcho() {
        let line = "[00:00:00.000 --> 00:00:20.000]   Skyfield, Carnot, Ahsan, KPI."
        #expect(Transcriber.parseSegment(line, speaker: "Them", promptWords: words) == nil)
        #expect(Transcriber.parseSegment(line, speaker: "Them") != nil)
        let real = "[00:00:00.000 --> 00:00:04.000]   We moved the Skyfield rollout to Carnot."
        #expect(Transcriber.parseSegment(real, speaker: "Them", promptWords: words)?.text == "We moved the Skyfield rollout to Carnot.")
    }

    @Test func finalParseDropsEcho() throws {
        let json = """
            {"result": {"language": "en"}, "transcription": [
              {"offsets": {"from": 0, "to": 4000}, "text": " We moved the Skyfield rollout to Carnot."},
              {"offsets": {"from": 4000, "to": 24000}, "text": " Skyfield, Carnot, Ahsan, KPI."},
              {"offsets": {"from": 24000, "to": 26000}, "text": " Skyfield, Carnot, Ahsan."}
            ]}
            """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("earl-vocab-\(UUID().uuidString).json")
        try json.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let parsed = try Transcriber.parse(url, speaker: "Them", promptWords: words)
        #expect(parsed.turns.map(\.text) == ["We moved the Skyfield rollout to Carnot."])
    }

    // MARK: Invented labels (Q-1)

    @Test func stripsAnInventedLabelAtTheStart() {
        #expect(WhisperPrompt.stripInventedLabels("Alex Weber: Ja, genau.", promptWords: words(from: "Alex Weber"))
                == "Ja, genau.")
        #expect(WhisperPrompt.stripInventedLabels("Weber: Ja, genau.", promptWords: words(from: "Alex Weber"))
                == "Ja, genau.")
    }

    @Test func stripsAnInventedLabelAfterASentenceEnd() {
        let text = "Ja. Alex Weber: Genau, das stimmt."
        #expect(WhisperPrompt.stripInventedLabels(text, promptWords: words(from: "Alex Weber")) == "Ja. Genau, das stimmt.")
    }

    @Test func stripsRepeatedInventedLabels() {
        let text = "Alex Weber: Ja. Alex Weber: Genau."
        #expect(WhisperPrompt.stripInventedLabels(text, promptWords: words(from: "Alex Weber")) == "Ja. Genau.")
    }

    @Test func keepsARealColonInSpeech() {
        let text = "So the plan: first we ship, then we tell them."
        #expect(WhisperPrompt.stripInventedLabels(text, promptWords: words(from: "Alex Weber")) == text)
    }

    @Test func keepsATime() {
        let text = "Let's meet at 10:30 tomorrow."
        #expect(WhisperPrompt.stripInventedLabels(text, promptWords: words(from: "Alex Weber")) == text)
    }

    @Test func onlyStripsWhenAPromptWordIsInvolved() {
        let text = "Chairperson: let's begin."
        #expect(WhisperPrompt.stripInventedLabels(text, promptWords: words(from: "Alex Weber")) == text)
    }

    private func words(from prompt: String) -> Set<String> { WhisperPrompt.words(in: prompt) }

    // MARK: Attendees (Q-1)

    private func person(_ name: String, _ email: String? = nil) -> Attendee {
        Attendee(name: name, email: email, isMe: false)
    }

    @Test func dropsGroupAddressesByName() {
        let attendees = [
            person("Distribution - ORG - Sales EU"), person("Shared Sales EU"), person("Team Freitagsrunde"),
            person("DL Finance"), person("Info - ORG - Finance"), person("Alex Weber"),
        ]
        #expect(WhisperPrompt.attendeeTerms(attendees, vocabulary: []) == ["Alex Weber"])
    }

    @Test func dropsGroupAddressesByEmail() {
        let attendees = [
            person("Finance team", "dl_finance@acme.com"), person("All hands", "all.hands@acme.com"),
            person("Shared inbox", "shared.inbox@acme.com"), person("Support", "team.support@acme.com"),
            person("Distribution", "distribution-list@acme.com"), person("Someone", "u_someone@acme.com"),
            person("Real Person", "real.person@acme.com"),
        ]
        // Every address shares the "acme.com" domain, group ones included, so
        // the company name is still added once alongside the one real person.
        #expect(WhisperPrompt.attendeeTerms(attendees, vocabulary: []) == ["Real Person", "Acme"])
    }

    @Test func keepsANameThatMerelyContainsADash() {
        // " -Extern" (no space after the dash) is a suffix to strip, not a
        // " - " group separator.
        #expect(!WhisperPrompt.isGroupAddress(person("Sam Kowalski -Extern")))
    }

    @Test func stripsExternalSuffixes() {
        #expect(WhisperPrompt.cleanAttendeeName(person("Sam Kowalski -Extern")) == "Sam Kowalski")
        #expect(WhisperPrompt.cleanAttendeeName(person("Jo Brandt (Extern)")) == "Jo Brandt")
        #expect(WhisperPrompt.cleanAttendeeName(person("Jo Brandt (extern)")) == "Jo Brandt")
        #expect(WhisperPrompt.cleanAttendeeName(person("Jo Brandt (External)")) == "Jo Brandt")
        #expect(WhisperPrompt.cleanAttendeeName(person("Jo Brandt [EXT]")) == "Jo Brandt")
        #expect(WhisperPrompt.cleanAttendeeName(person("Alex Weber")) == "Alex Weber")
    }

    @Test func dedupesCleanedNamesCaseInsensitively() {
        let attendees = [person("Sam Kowalski -Extern"), person("Sam Kowalski")]
        #expect(WhisperPrompt.attendeeTerms(attendees, vocabulary: []) == ["Sam Kowalski"])
    }

    // Q-3: the notes prompt's participant list uses this without the company
    // name `attendeeTerms` adds for Whisper.
    @Test func cleanedAttendeeNamesSkipsGroupsAndSuffixesButNoCompany() {
        let attendees = [
            person("Alex Weber", "alex@acme-labs.de"), person("Sam Kowalski -Extern"),
            person("Distribution - ORG - Sales EU"),
        ]
        #expect(WhisperPrompt.cleanedAttendeeNames(attendees) == ["Alex Weber", "Sam Kowalski"])
    }

    @Test func addsTheCommonestCompanyDomainOnce() {
        let attendees = [
            person("Alex Weber", "alex@acme-labs.de"), person("Jo Brandt", "jo@acme-labs.de"),
            person("Sam Kowalski", "sam@partner.com"),
        ]
        #expect(WhisperPrompt.attendeeTerms(attendees, vocabulary: []) == ["Alex Weber", "Jo Brandt", "Sam Kowalski", "Acme-labs"])
    }

    @Test func skipsWebmailDomains() {
        let attendees = [person("Alex Weber", "alex@gmail.com"), person("Jo Brandt", "jo@web.de")]
        #expect(WhisperPrompt.companyName(from: attendees, vocabulary: []) == nil)
    }

    @Test func skipsTheCompanyNameWhenTheVocabularyAlreadyHasIt() {
        let attendees = [person("Alex Weber", "alex@acme-labs.de")]
        #expect(WhisperPrompt.companyName(from: attendees, vocabulary: ["Acme Labs"]) == nil)
        #expect(WhisperPrompt.companyName(from: attendees, vocabulary: []) == "Acme-labs")
    }

    @Test func noDomainMeansNoCompanyName() {
        #expect(WhisperPrompt.companyName(from: [person("Alex Weber")], vocabulary: []) == nil)
        #expect(WhisperPrompt.companyName(from: [], vocabulary: []) == nil)
    }

    // MARK: Summarizer

    @Test func summarizerAddsVocabularyLine() {
        var s = Summarizer()
        s.vocabulary = ["Skyfield", "KPI"]
        #expect(s.vocabularyLine == "Correct spellings of names and terms: Skyfield, KPI.\n\n")
        s.vocabulary = []
        #expect(s.vocabularyLine == "")
    }

    @Test func transcriberHasNoPromptWithoutTerms() {
        var t = Transcriber()
        t.prompt = WhisperPrompt.build(vocabulary: [])
        #expect(t.prompt == nil)
    }
}
