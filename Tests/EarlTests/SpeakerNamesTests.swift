import Foundation
import Testing
@testable import Earl

struct SpeakerNamesTests {
    static func speaker(_ id: String, _ track: String = "Them", name: String? = nil, source: Speaker.NameSource? = nil,
                        embedding: [Float] = [1, 0], seconds: Double = 10) -> Speaker {
        Speaker(id: id, track: track, name: name, nameSource: source, embedding: embedding, seconds: seconds)
    }

    static func turn(_ start: Double, _ end: Double, _ id: String?, _ text: String, track: String = "Them") -> Turn {
        Turn(start: start, end: end, speaker: track, text: text, speakerID: id)
    }

    static func meeting(_ turns: [Turn], _ speakers: [Speaker]) -> Meeting {
        Meeting(id: "m", folder: URL(fileURLWithPath: "/tmp/m"),
                info: MeetingInfo(title: "M", titleIsDefault: true, startedAt: Date(), duration: 0, status: .done),
                turns: turns, summary: "", files: [], speakers: speakers)
    }

    static let attendees = [
        Attendee(name: "Sarah Chen", email: nil, isMe: false),
        Attendee(name: "Tom Baker", email: nil, isMe: false),
        Attendee(name: "Alex Kim", email: nil, isMe: true),
    ]

    /// Tom asks Sarah, Sarah answers, Tom thanks her.
    static let conversation = meeting([
        turn(0, 3, "S1", "Sarah, can you give us an update on the release?"),
        turn(3, 8, "S2", "Sure. The release candidate is ready."),
        turn(8, 10, "S1", "Thanks Sarah. Alex, anything from you?"),
        turn(10, 12, nil, "Nothing from me.", track: "Me"),
        turn(12, 14, "S3", "Over to you Tom for the budget."),
        turn(14, 18, "S1", "Thanks. The budget is on track."),
    ], [speaker("S1"), speaker("S2"), speaker("S3")])

    // MARK: Parsing

    @Test func parsesPlainJSON() {
        let out = SpeakerNameGuesser.parse(#"{"S1": {"name": "Tom", "evidence": "x"}, "S2": null}"#,
                                           validIDs: ["S1", "S2"])
        #expect(out == ["S1": .init(name: "Tom", evidence: "x")])
    }

    @Test func parsesFencesThinkTagsAndJunk() {
        let answer = """
            <think>S1 is probably Tom {"S1": "Wrong"} because…</think>
            Here you go:
            ```json
            {"Speaker 2": {"name": "Sarah.", "evidence": "Tom says 'Sarah, can you…' just before"},
             "s1": "Tom", "S9": {"name": "Ghost"}, "S3": {"name": ""}, "junk": 4}
            ```
            Hope that helps!
            """
        let out = SpeakerNameGuesser.parse(answer, validIDs: ["S1", "S2", "S3"])
        #expect(out["S1"]?.name == "Tom")
        #expect(out["S2"]?.name == "Sarah")
        #expect(out["S2"]?.evidence.hasPrefix("Tom says") == true)
        #expect(out["S3"] == nil)
        #expect(out["S9"] == nil)
    }

    @Test func unclosedThinkingAndGarbageGiveNothing() {
        #expect(SpeakerNameGuesser.parse("<think>{\"S1\": \"Tom\"}", validIDs: ["S1"]).isEmpty)
        #expect(SpeakerNameGuesser.parse("I can't tell.", validIDs: ["S1"]).isEmpty)
        #expect(SpeakerNameGuesser.parse("{not json}", validIDs: ["S1"]).isEmpty)
    }

    // Q-3: strings meaning "no guess" that aren't a JSON null.
    @Test func stringNullAndItsVariantsAreNoGuess() {
        for word in ["null", "Null", "NULL", "none", "None", "unknown", "n/a", "N/A", "-"] {
            let out = SpeakerNameGuesser.parse(#"{"S1": {"name": "\#(word)", "evidence": "x"}}"#, validIDs: ["S1"])
            #expect(out["S1"] == nil, "\(word)")
        }
        // A real name that merely contains one of those words isn't affected.
        let out = SpeakerNameGuesser.parse(#"{"S1": {"name": "Nolan", "evidence": "x"}}"#, validIDs: ["S1"])
        #expect(out["S1"]?.name == "Nolan")
    }

    // MARK: Guard rules

    @Test func mockedAnswerNamesTheRightSpeakersAndRejectsInventions() {
        let answer = """
            {"S1": {"name": "Tom", "evidence": "S3 says 'over to you Tom'"},
             "S2": {"name": "Sarah", "evidence": "Asked 'Sarah, can you…', S2 answers"},
             "S3": {"name": "Jennifer", "evidence": "sounds like a Jennifer"}}
            """
        let out = SpeakerNameGuesser.interpret(answer, meeting: Self.conversation, attendees: Self.attendees,
                                               userName: "Alex")
        #expect(out["S1"]?.name == "Tom")
        #expect(out["S2"]?.name == "Sarah")
        #expect(out["S3"] == nil) // not an attendee, not in the transcript
        let named = SpeakerNameGuesser.apply(out, to: Self.conversation.speakers)
        #expect(named.first { $0.id == "S2" }?.nameSource == .guessed)
        #expect(named.first { $0.id == "S2" }?.isGuess == true)
    }

    @Test func nameInTranscriptIsAcceptedWithoutAttendees() {
        let guesses = ["S2": SpeakerNameGuesser.Guess(name: "Sarah", evidence: ""),
                       "S3": SpeakerNameGuesser.Guess(name: "sarah", evidence: "")]
        let out = SpeakerNameGuesser.accept(["S2": guesses["S2"]!], speakers: Self.conversation.speakers,
                                            attendees: [], userName: nil,
                                            transcript: Self.conversation.turns.map(\.text).joined(separator: "\n"))
        #expect(out["S2"]?.name == "Sarah")
        // Verbatim means the same case: "will" in a sentence isn't Will.
        let lower = SpeakerNameGuesser.accept(["S1": .init(name: "Will", evidence: "")],
                                              speakers: Self.conversation.speakers, attendees: [], userName: nil,
                                              transcript: "I will send it tomorrow.")
        #expect(lower.isEmpty)
        // Unless whisper wrote the whole line in lowercase, as it does on muffled call audio.
        let muffled = SpeakerNameGuesser.accept(["S1": .init(name: "Megan", evidence: "")],
                                                speakers: Self.conversation.speakers, attendees: [], userName: nil,
                                                transcript: "Good point.\nthanks megan would you update the guide")
        #expect(muffled["S1"]?.name == "Megan")
        let mixed = SpeakerNameGuesser.accept(["S1": .init(name: "Megan", evidence: "")],
                                              speakers: Self.conversation.speakers, attendees: [], userName: nil,
                                              transcript: "Thanks megan, would you update the guide?")
        #expect(mixed.isEmpty)
    }

    @Test func attendeeFullNameKeepsCalendarSpelling() {
        let out = SpeakerNameGuesser.accept(["S1": .init(name: "tom baker", evidence: "")],
                                            speakers: Self.conversation.speakers, attendees: Self.attendees,
                                            userName: nil, transcript: "")
        #expect(out["S1"]?.name == "Tom Baker")
    }

    @Test func neverYourOwnName() {
        let speakers = Self.conversation.speakers
        for name in ["Alex", "alex", "Alex Kim"] {
            let out = SpeakerNameGuesser.accept(["S1": .init(name: name, evidence: "")], speakers: speakers,
                                                attendees: Self.attendees, userName: nil, transcript: "Alex, hi")
            #expect(out.isEmpty, "\(name)")
        }
        let viaPrefs = SpeakerNameGuesser.accept(["S1": .init(name: "Robin", evidence: "")], speakers: speakers,
                                                 attendees: [], userName: "Robin", transcript: "Thanks Robin")
        #expect(viaPrefs.isEmpty)
    }

    // MARK: NameMatch in accept/support (Q-2)

    @Test func acceptMapsShortFormsAndMisspellingsToTheAttendee() {
        let attendees = [Attendee(name: "Isabelle Kramer", email: nil, isMe: false)]
        let isa = SpeakerNameGuesser.accept(["S1": .init(name: "Isa", evidence: "")],
                                            speakers: Self.conversation.speakers, attendees: attendees,
                                            userName: nil, transcript: "Thanks Isa")
        #expect(isa["S1"]?.name == "Isabelle Kramer")

        let matthias = [Attendee(name: "Matthias Vogel", email: nil, isMe: false)]
        let mathias = SpeakerNameGuesser.accept(["S1": .init(name: "Mathias", evidence: "")],
                                               speakers: Self.conversation.speakers, attendees: matthias,
                                               userName: nil, transcript: "Thanks Mathias")
        #expect(mathias["S1"]?.name == "Matthias Vogel")
    }

    @Test func acceptKeepsAmbiguousFuzzyMatchAsSaid() {
        // "Isa" is a short form of both attendees' first names, so neither is
        // picked; the guess is kept as the model said it.
        let attendees = [Attendee(name: "Isabelle Kramer", email: nil, isMe: false),
                         Attendee(name: "Isadora Ross", email: nil, isMe: false)]
        let out = SpeakerNameGuesser.accept(["S1": .init(name: "Isa", evidence: "")],
                                            speakers: Self.conversation.speakers, attendees: attendees,
                                            userName: nil, transcript: "Thanks Isa")
        #expect(out["S1"]?.name == "Isa")
    }

    @Test func neverYourOwnNameByFuzzyMatch() {
        // "Asan" must not name another speaker Ahsan just because it's close.
        let out = SpeakerNameGuesser.accept(["S1": .init(name: "Asan", evidence: "")],
                                            speakers: Self.conversation.speakers, attendees: [],
                                            userName: "Ahsan", transcript: "Thanks Asan")
        #expect(out.isEmpty)
    }

    @Test func neverTheSameNameTwice() {
        let speakers = [Self.speaker("S1"), Self.speaker("S2"), Self.speaker("S3", name: "Megan", source: .confirmed)]
        let transcript = "Thanks Sarah. Megan, go ahead."
        let twice = SpeakerNameGuesser.accept(["S1": .init(name: "Sarah", evidence: ""), "S2": .init(name: "Sarah", evidence: "")],
                                              speakers: speakers, attendees: [], userName: nil, transcript: transcript)
        #expect(twice.isEmpty)
        let taken = SpeakerNameGuesser.accept(["S1": .init(name: "Megan", evidence: "")],
                                              speakers: speakers, attendees: [], userName: nil, transcript: transcript)
        #expect(taken.isEmpty)
        // An already named speaker is never renamed by a guess.
        let named = SpeakerNameGuesser.accept(["S3": .init(name: "Sarah", evidence: "")],
                                              speakers: speakers, attendees: [], userName: nil, transcript: transcript)
        #expect(named.isEmpty)
    }

    @Test func placeholdersAreNotNames() {
        for name in ["Speaker 2", "Unknown", "Them", "null", "none", "n/a", "-"] {
            let out = SpeakerNameGuesser.accept(["S1": .init(name: name, evidence: "")],
                                                speakers: Self.conversation.speakers, attendees: [], userName: nil,
                                                transcript: "Speaker 2 Unknown Them null none n/a -")
            #expect(out.isEmpty, "\(name)")
        }
    }

    // MARK: Corroboration

    @Test func supportCountsNamesNextToTheSpeaker() {
        let turns = Self.conversation.turns
        #expect(SpeakerNameGuesser.support(for: "S2", name: "Sarah", turns: turns) == 2) // asked before, thanked after
        #expect(SpeakerNameGuesser.support(for: "S1", name: "Tom", turns: turns) == 1)   // "over to you Tom", then S1
        #expect(SpeakerNameGuesser.support(for: "S1", name: "Sarah", turns: turns) == 0) // S1 says it, isn't her
        let intro = [Self.turn(0, 2, "S4", "Hi all, this is Priya from finance.")]
        #expect(SpeakerNameGuesser.support(for: "S4", name: "Priya", turns: intro) == 1)
    }

    // Q-3: widened from the last 10 words to the last 25, so a name well
    // before the end of a long turn still counts.
    @Test func supportCountsANameFurtherBackInALongTurn() {
        let turns = [
            Self.turn(0, 5, "S5", "And now I think, René, you're going to have some additional information "
                + "on the six chapters here. Right."),
            Self.turn(5, 8, "S2", "Thank you for that."),
        ]
        #expect(SpeakerNameGuesser.support(for: "S2", name: "René", turns: turns) == 1)
        // Still nothing beyond 25 words.
        let farther = [
            Self.turn(0, 5, "S5", "René, " + String(repeating: "word ", count: 24) + "and that's it."),
            Self.turn(5, 8, "S2", "Thank you for that."),
        ]
        #expect(SpeakerNameGuesser.support(for: "S2", name: "René", turns: farther) == 0)
    }

    @Test func supportToleratesShortFormsAndMisspellings() {
        let mathias = [Self.turn(0, 3, "S1", "Mathias, can you take this?"), Self.turn(3, 8, "S2", "Sure thing.")]
        #expect(SpeakerNameGuesser.support(for: "S2", name: "Matthias", turns: mathias) == 1)
        let isa = [Self.turn(0, 3, "S1", "Isa, over to you."), Self.turn(3, 8, "S2", "Thanks.")]
        #expect(SpeakerNameGuesser.support(for: "S2", name: "Isabelle", turns: isa) == 1)
    }

    @Test func supportRecognizesGermanIntroductions() {
        let ichBin = [Self.turn(0, 2, "S4", "Hallo zusammen, ich bin Matthias aus dem Vertrieb.")]
        #expect(SpeakerNameGuesser.support(for: "S4", name: "Matthias", turns: ichBin) == 1)
        let hierSpricht = [Self.turn(0, 2, "S5", "Hier spricht Jana vom Marketing.")]
        #expect(SpeakerNameGuesser.support(for: "S5", name: "Jana", turns: hierSpricht) == 1)
        let meinName = [Self.turn(0, 2, "S6", "Mein Name ist Markus.")]
        #expect(SpeakerNameGuesser.support(for: "S6", name: "Markus", turns: meinName) == 1)
        let ichHeisse = [Self.turn(0, 2, "S7", "Ich heiße Isa.")] // short form still recognised
        #expect(SpeakerNameGuesser.support(for: "S7", name: "Isabelle", turns: ichHeisse) == 1)
    }

    // MARK: The log line

    @Test func logLineShowsRawGuessesAndDropReasons() {
        let turns = [
            Self.turn(0, 2, "S9", "Isa, go ahead."),
            Self.turn(2, 5, "S1", "Thanks, sounds good."),
            Self.turn(6, 8, "S2", "Let's move to budget."),
        ]
        let speakers = [Self.speaker("S1"), Self.speaker("S2"), Self.speaker("S3")]
        let meeting = Self.meeting(turns, speakers)
        let attendees = [Attendee(name: "Isabelle Kramer", email: nil, isMe: false)]
        let answer = """
            {"S1": {"name": "Isa", "evidence": "asked to go ahead"},
             "S2": {"name": "Mathias", "evidence": "guess"}, "S3": null}
            """
        let explained = SpeakerNameGuesser.explain(answer, meeting: meeting, attendees: attendees, userName: nil)
        #expect(SpeakerNameGuesser.logLine(explained)
            == "S1 = Isa (kept: Isabelle Kramer), S2 = Mathias (dropped: not an attendee and not said in the transcript), "
            + "S3 = null")
    }

    @Test func addressedLogLineFormatsNameAndEvidence() {
        #expect(SpeakerNameGuesser.addressedLogLine([:]) == "none")
        let addressed = ["S3": SpeakerNameGuesser.Guess(name: "Isabelle Kramer", evidence: "Isa, you were raising your hand."),
                         "S1": SpeakerNameGuesser.Guess(name: "Matthias Vogel", evidence: "Kam was bei dir, Matt?")]
        #expect(SpeakerNameGuesser.addressedLogLine(addressed)
            == #"S1 = Matthias Vogel ("Kam was bei dir, Matt?"), S3 = Isabelle Kramer ("Isa, you were raising your hand.")"#)
    }

    // MARK: Combining (Q-3)

    @Test func combinedGuessSkipsTheModelWhenAddressAlreadyNamedEveryone() async {
        // Both voices introduce themselves, so `AddressedNames` names both
        // and the model is never asked.
        let turns = [
            Self.turn(0, 3, "S1", "Hi, this is Tom from finance."),
            Self.turn(3, 6, "S2", "Hi, this is Sarah from sales."),
        ]
        let speakers = [Self.speaker("S1"), Self.speaker("S2")]
        let meeting = Self.meeting(turns, speakers)
        let attendees = [Attendee(name: "Tom Baker", email: nil, isMe: false),
                         Attendee(name: "Sarah Chen", email: nil, isMe: false)]
        // A guesser whose model would throw if it were ever asked.
        var guesser = SpeakerNameGuesser()
        guesser.summarizer.baseURL = "http://127.0.0.1:1"
        let result = await SpeakerNameGuesser.combinedGuess(meeting: meeting, attendees: attendees, userName: nil,
                                                             guesser: guesser)
        #expect(result.addressed["S1"]?.name == "Tom Baker")
        #expect(result.addressed["S2"]?.name == "Sarah Chen")
        #expect(result.remaining.isEmpty)
        #expect(result.modelAnswer == nil)
        #expect(result.modelError == nil)
        #expect(result.modelOutcomes.isEmpty)
    }

    @Test func guessesByEliminationOrRoleAreDropped() {
        // The model names all three; only S1 and S2 are backed by the transcript.
        let answer = """
            {"S1": {"name": "Tom", "evidence": ""}, "S2": {"name": "Sarah", "evidence": ""},
             "S3": {"name": "Priya", "evidence": "the only attendee left"}}
            """
        let attendees = Self.attendees + [Attendee(name: "Priya", email: nil, isMe: false)]
        let out = SpeakerNameGuesser.interpret(answer, meeting: Self.conversation, attendees: attendees, userName: "Alex")
        #expect(out.keys.sorted() == ["S1", "S2"])
        let loose = SpeakerNameGuesser.interpret(answer, meeting: Self.conversation, attendees: attendees,
                                                 userName: "Alex", corroborate: false)
        #expect(loose.keys.sorted() == ["S1", "S2", "S3"])
    }

    @Test func nameBackedMoreForAnotherSpeakerIsDropped() {
        // "Sarah" is said next to S3 once, but twice next to S2.
        let turns = Self.conversation.turns + [Self.turn(20, 22, "S1", "Sarah, one more thing?"),
                                               Self.turn(22, 24, "S3", "Yes?")]
        let meeting = Self.meeting(turns, Self.conversation.speakers)
        let out = SpeakerNameGuesser.corroborated(["S3": .init(name: "Sarah", evidence: "")], turns: meeting.turns,
                                                  candidates: ["S1", "S2", "S3"])
        #expect(out.isEmpty)
    }

    @Test func candidatesSkipNamedAndYou() {
        let speakers = [Self.speaker("S1"), Self.speaker("S2", name: "Tom", source: .confirmed),
                        Self.speaker("S3", "Me", seconds: 100), Self.speaker("S4", "Me", seconds: 5)]
        let ids = SpeakerNameGuesser.candidates(in: Self.meeting([], speakers)).map(\.id)
        #expect(ids == ["S1", "S4"])
    }

    @Test func promptLabelsCandidatesAndYou() {
        let prompt = SpeakerNameGuesser.prompt(meeting: Self.conversation, candidates: Self.conversation.speakers,
                                               attendees: Self.attendees, userName: nil, limit: 100_000)
        #expect(prompt.contains("S2: Sure. The release candidate is ready."))
        #expect(prompt.contains("Me: Nothing from me."))
        #expect(prompt.contains("\"Me\" is the user, Alex Kim."))
        #expect(prompt.contains("Invited to the meeting: Sarah Chen, Tom Baker."))
    }

    // Q-3: evidence quoted before the name, in the guidance and the example.
    @Test func promptAsksForEvidenceBeforeTheName() throws {
        let prompt = SpeakerNameGuesser.prompt(meeting: Self.conversation, candidates: Self.conversation.speakers,
                                               attendees: Self.attendees, userName: nil, limit: 100_000)
        #expect(prompt.contains(#"{"evidence": "…", "name": "…"}"#))
        #expect(prompt.contains("short form or a misspelling"))
        #expect(prompt.contains("never evidence of who they are"))
        let evidence = try #require(prompt.range(of: "\"evidence\""))
        let name = try #require(prompt.range(of: "\"name\""))
        #expect(evidence.upperBound < name.lowerBound)
    }

    // Q-3: the JSON schema sent to the server, one required key per
    // candidate, evidence first.
    @Test func schemaHasOneKeyPerCandidateEvidenceFirst() throws {
        let schema = SpeakerNameGuesser.schema(for: ["S1", "S2"])
        #expect(schema.name == "speaker_names")
        let properties = try #require(schema.schema["properties"] as? [String: Any])
        #expect(Set(properties.keys) == ["S1", "S2"])
        #expect(schema.schema["required"] as? [String] == ["S1", "S2"])
        let s1 = try #require(properties["S1"] as? [String: Any])
        let variants = try #require(s1["anyOf"] as? [[String: Any]])
        #expect(variants.count == 2)
        #expect(variants[0]["type"] as? String == "null")
        let guessSchema = try #require(variants[1]["properties"] as? [String: Any])
        #expect(guessSchema.keys.sorted() == ["evidence", "name"])
        #expect((guessSchema["evidence"] as? [String: Any])?["maxLength"] as? Int == 160)
        #expect((guessSchema["name"] as? [String: Any])?["maxLength"] as? Int == 40)
        #expect(variants[1]["required"] as? [String] == ["evidence", "name"])
    }

    // MARK: Compacting

    @Test func compactKeepsMentionsTheirNeighboursAndEdges() {
        var lines: [(start: Double, text: String)] = []
        for i in 0..<200 { lines.append((Double(i * 10), "S\(i % 3 + 1): filler line number \(i) about the budget")) }
        lines[100] = (1000, "S1: Priya, can you take that one?")
        lines[101] = (1010, "S2: Sure, I'll do it.")
        let out = SpeakerNameGuesser.compact(lines, names: [], limit: 2500, edgeSeconds: 60)
        #expect(out.count <= 2500 + 20)
        #expect(out.contains("Priya, can you take that one?"))
        #expect(out.contains("S2: Sure, I'll do it."))
        #expect(out.contains("filler line number 99 "))
        #expect(out.contains("filler line number 0 "))
        #expect(out.contains("…"))
        let all = SpeakerNameGuesser.compact(lines, names: [], limit: 1_000_000)
        #expect(!all.contains("…"))
    }

    @Test func findsAddressedNames() {
        let names = SpeakerNameGuesser.addressedNames(in: "Thanks Megan, that helps. Okay, Tom, can you do it? Good point, Lisa.")
        #expect(names == ["Megan", "Tom", "Lisa"])
    }

    // MARK: Editing

    @Test func renameConfirmAndClear() {
        var s = [Self.speaker("S1"), Self.speaker("S2")]
        s = SpeakerEdit.rename(s, id: "S2", to: "  Sarah ", source: .guessed, evidence: "why")
        #expect(s[1].name == "Sarah" && s[1].nameSource == .guessed && s[1].evidence == "why")
        s = SpeakerEdit.rename(s, id: "S2", to: "Sarah", source: .confirmed)
        #expect(s[1].nameSource == .confirmed && s[1].evidence == nil && !s[1].isGuess)
        s = SpeakerEdit.rename(s, id: "S2", to: nil, source: nil)
        #expect(s[1].name == nil && s[1].nameSource == nil)
        #expect(s[0].name == nil)
    }

    @Test func mergeAddsTimeAveragesVoicesAndJoinsTurns() {
        let speakers = [Self.speaker("S1", embedding: [1, 0], seconds: 30),
                        Self.speaker("S2", name: "Tom", source: .confirmed, embedding: [0, 1], seconds: 10),
                        Self.speaker("S3", embedding: [0, 0], seconds: 5)]
        let turns = [Self.turn(0, 2, "S1", "Hello."), Self.turn(2.5, 4, "S2", "Hi there."),
                     Self.turn(4.5, 6, "S1", "How are you?"), Self.turn(6.5, 8, "S3", "Fine."),
                     Self.turn(20, 22, "S2", "Later on.")]
        let (t, s) = SpeakerEdit.merge(turns: turns, speakers: speakers, from: "S1", into: "S2")
        #expect(s.map(\.id) == ["S2", "S3"])
        let tom = s[0]
        #expect(tom.seconds == 40)
        #expect(tom.name == "Tom")
        #expect(abs(tom.embedding[0] - 0.75) < 1e-6 && abs(tom.embedding[1] - 0.25) < 1e-6)
        #expect(t.map(\.speakerID) == ["S2", "S3", "S2"])
        #expect(t[0].text == "Hello. Hi there. How are you?")
        #expect(t[0].start == 0 && t[0].end == 6)
        #expect(t[2].text == "Later on.") // too far apart to join
    }

    @Test func mergeIntoUnnamedTakesTheOtherName() {
        let speakers = [Self.speaker("S1"), Self.speaker("S2", name: "Sarah", source: .guessed)]
        let (_, s) = SpeakerEdit.merge(turns: [], speakers: speakers, from: "S2", into: "S1")
        #expect(s.count == 1 && s[0].id == "S1" && s[0].name == "Sarah" && s[0].nameSource == .guessed)
    }

    @Test func mergeWithItselfOrUnknownChangesNothing() {
        let speakers = [Self.speaker("S1"), Self.speaker("S2")]
        let turns = [Self.turn(0, 1, "S1", "a")]
        #expect(SpeakerEdit.merge(turns: turns, speakers: speakers, from: "S1", into: "S1").speakers == speakers)
        #expect(SpeakerEdit.merge(turns: turns, speakers: speakers, from: "S9", into: "S1").speakers == speakers)
    }

    @Test func mergedNamesShowOnEveryTurn() {
        let speakers = [Self.speaker("S1", name: "Sarah", source: .confirmed), Self.speaker("S2")]
        let turns = [Self.turn(0, 1, "S1", "a"), Self.turn(10, 11, "S2", "b")]
        let (t, s) = SpeakerEdit.merge(turns: turns, speakers: speakers, from: "S2", into: "S1")
        let m = Self.meeting(t, s)
        #expect(m.turns.map { m.displayName(for: $0) } == ["Sarah", "Sarah"])
        let m2 = Self.meeting(turns, speakers)
        #expect(m2.turns.map { m2.displayName(for: $0) } == ["Sarah", "Speaker 2"])
        #expect(m2.markdown.contains("Sarah:** a"))
    }

    // MARK: Carrying names over

    @Test func carriesConfirmedNamesToSimilarVoices() {
        let old = [Self.speaker("S1", name: "Sarah", source: .confirmed, embedding: [1, 0, 0]),
                   Self.speaker("S2", name: "Tom", source: .guessed, embedding: [0, 1, 0]),
                   Self.speaker("S3", name: "Megan", source: .confirmed, embedding: [0, 0, 1]),
                   Self.speaker("S4", "Me", name: "Priya", source: .confirmed, embedding: [0.7, 0.7, 0])]
        let new = [Self.speaker("S1", embedding: [0.1, 0.99, 0]),     // Tom's voice: guessed, not carried
                   Self.speaker("S2", embedding: [0.98, 0.05, 0.1]),   // Sarah
                   Self.speaker("S3", embedding: [0.6, 0.6, 0.53]),    // in between: below the threshold
                   Self.speaker("S4", "Me", embedding: [0.7, 0.72, 0])] // Priya, on her own track
        let out = SpeakerEdit.carryOver(from: old, to: new)
        #expect(out.map(\.name) == [nil, "Sarah", nil, "Priya"])
        #expect(out[1].nameSource == .confirmed)
    }

    @Test func carryOverIsOneToOne() {
        let old = [Self.speaker("S1", name: "Sarah", source: .confirmed, embedding: [1, 0])]
        let new = [Self.speaker("S1", embedding: [0.9, 0.1]), Self.speaker("S2", embedding: [1, 0.01])]
        let out = SpeakerEdit.carryOver(from: old, to: new)
        #expect(out.map(\.name) == [nil, "Sarah"])
    }

    @Test func cosine() {
        #expect(SpeakerEdit.cosine([1, 0], [1, 0]) == 1)
        #expect(SpeakerEdit.cosine([1, 0], [0, 1]) == 0)
        #expect(SpeakerEdit.cosine([], []) == 0)
        #expect(SpeakerEdit.cosine([1], [1, 2]) == 0)
    }

    // MARK: Saved data

    @Test func speakersAndFlagRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("earl-names-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingStore(root: dir)
        var s = Self.speaker("S1", name: "Sarah", source: .guessed)
        s.evidence = "Tom says 'thanks Sarah'"
        try store.saveSpeakers([s], in: dir)
        #expect(store.loadSpeakers(in: dir) == [s])

        // Old meeting.json files, without the R2-3 flag, still load.
        let old = #"{"title":"A","titleIsDefault":true,"startedAt":"2026-01-01T10:00:00Z","duration":60,"status":"done"}"#
        try old.write(to: dir.appendingPathComponent("meeting.json"), atomically: true, encoding: .utf8)
        var meeting = try #require(store.load(dir))
        #expect(meeting.info.namesChangedSinceSummary == nil)
        meeting.info.namesChangedSinceSummary = true
        try store.save(meeting.info, in: dir)
        #expect(store.load(dir)?.info.namesChangedSinceSummary == true)
    }

    @Test func badgeMarksGuesses() {
        let speakers = [Self.speaker("S1", name: "Sarah", source: .guessed), Self.speaker("S2", name: "Tom", source: .confirmed)]
        var guessed = speakers
        guessed[0].evidence = "Tom says 'thanks Sarah'"
        let a = Speaker.badge(for: Self.turn(0, 1, "S1", ""), in: guessed)
        #expect(a.name == "Sarah?" && a.help?.contains("thanks Sarah") == true)
        let b = Speaker.badge(for: Self.turn(0, 1, "S2", ""), in: speakers)
        #expect(b.name == "Tom" && b.help == nil)
        // Exports and the summarizer use the plain name.
        #expect(Self.meeting([Self.turn(0, 1, "S1", "hi")], speakers).transcriptText.contains("Sarah: hi"))
    }
}
