import Foundation
import Testing
@testable import Earl

/// V-1: one name, one speaker, across confirmed names, voice memory, direct
/// address and the model.
struct NameCollisionsTests {
    typealias Guess = SpeakerNameGuesser.Guess
    static func speaker(_ id: String, name: String? = nil, source: Speaker.NameSource? = nil) -> Speaker {
        SpeakerNamesTests.speaker(id, name: name, source: source)
    }

    @Test func voiceBeatsAddress() {
        // The real case: voice memory named S2, then address named S1 the same.
        let speakers = [Self.speaker("S1"), Self.speaker("S2", name: "Daniel Falk", source: .voice)]
        let out = NameCollisions.resolve(speakers: speakers,
                                         guesses: [(.addressed, ["S1": Guess(name: "Daniel Falk", evidence: "q")])])
        #expect(out.kept.isEmpty)
        #expect(out.dropped["S1"]?.holder == "S2")
        #expect(NameCollisions.logLine(kept: out.kept, dropped: out.dropped)
            == "S1 = Daniel Falk (dropped: S2 has this name by voice)")
    }

    @Test func confirmedBeatsEveryGuess() {
        let speakers = [Self.speaker("S1", name: "Sarah Chen", source: .confirmed), Self.speaker("S2"), Self.speaker("S3")]
        let out = NameCollisions.resolve(speakers: speakers, guesses: [
            (.addressed, ["S2": Guess(name: "sarah chen", evidence: "")]),
            (.model, ["S3": Guess(name: "Sarah", evidence: "")]),
        ])
        #expect(out.kept.isEmpty)
        #expect(out.dropped["S2"]?.reason == "S1 has this name confirmed")
        #expect(out.dropped["S3"]?.reason == "S1 has this name confirmed")
    }

    @Test func addressBeatsModel() {
        let speakers = [Self.speaker("S1"), Self.speaker("S2")]
        let out = NameCollisions.resolve(speakers: speakers, guesses: [
            (.model, ["S1": Guess(name: "Tom", evidence: "")]),
            (.addressed, ["S2": Guess(name: "Tom Baker", evidence: "Thanks, Tom.")]),
        ])
        #expect(out.kept == ["S2": Guess(name: "Tom Baker", evidence: "Thanks, Tom.")])
        #expect(out.dropped["S1"]?.reason == "S2 has this name from who was addressed")
    }

    @Test func differentPeopleWithTheSameFirstNameBothStay() {
        let speakers = [Self.speaker("S1", name: "Tom Baker", source: .voice), Self.speaker("S2")]
        let out = NameCollisions.resolve(speakers: speakers,
                                         guesses: [(.addressed, ["S2": Guess(name: "Tom Ford", evidence: "")])])
        #expect(out.kept["S2"]?.name == "Tom Ford")
        #expect(out.dropped.isEmpty)
    }

    @Test func diacriticsAndCaseDontMakeADifferentPerson() {
        #expect(NameCollisions.samePerson("René Müller", "rene muller"))
        #expect(NameCollisions.samePerson("Daniel", "Daniel Falk"))
        #expect(!NameCollisions.samePerson("Tom Baker", "Tom Ford"))
        #expect(!NameCollisions.samePerson("Anna", "Hanna"))
    }

    @Test func namedSpeakersAreNeverRenamedAndUncontestedGuessesStay() {
        let speakers = [Self.speaker("S1", name: "Sarah", source: .voice), Self.speaker("S2"), Self.speaker("S3")]
        let out = NameCollisions.resolve(speakers: speakers, guesses: [
            (.addressed, ["S1": Guess(name: "Megan", evidence: ""), "S2": Guess(name: "Tom", evidence: "")]),
            (.model, ["S3": Guess(name: "Priya", evidence: "")]),
        ])
        #expect(out.kept.keys.sorted() == ["S2", "S3"])
        #expect(NameCollisions.logLine(kept: out.kept, dropped: out.dropped) == "S2 = Tom, S3 = Priya")
        #expect(NameCollisions.logLine(kept: [:], dropped: [:]) == "none")
    }

    @Test func logOrdersSpeakersByNumber() {
        let kept = ["S10": Guess(name: "B", evidence: ""), "S2": Guess(name: "A", evidence: "")]
        #expect(NameCollisions.logLine(kept: kept, dropped: [:]) == "S2 = A, S10 = B")
    }

    @Test func combinedGuessSendsACollidingAddressedSpeakerToTheModel() async {
        // S2 is Daniel by voice; S1 is addressed as Daniel too. S1 must not
        // get the name, and stays a candidate for the model.
        let turns = [
            SpeakerNamesTests.turn(0, 3, "S3", "Okay, Daniel, wie sieht es bei dir aus?"),
            SpeakerNamesTests.turn(3, 6, "S1", "Bei mir ist alles gut."),
            SpeakerNamesTests.turn(6, 9, "S2", "Bei mir auch."),
        ]
        let speakers = [Self.speaker("S1"), Self.speaker("S2", name: "Daniel Falk", source: .voice), Self.speaker("S3")]
        let meeting = SpeakerNamesTests.meeting(turns, speakers)
        let attendees = [Attendee(name: "Daniel Falk", email: nil, isMe: false)]
        var guesser = SpeakerNameGuesser()
        guesser.summarizer.baseURL = "http://127.0.0.1:1" // fails fast; no model here
        let result = await SpeakerNameGuesser.combinedGuess(meeting: meeting, attendees: attendees, userName: nil,
                                                             guesser: guesser)
        #expect(result.addressed["S1"] == nil)
        #expect(result.addressedDropped["S1"]?.holder == "S2")
        #expect(result.remaining.map(\.id).contains("S1"))
        let final = result.final(speakers: speakers)
        #expect(final.guesses.isEmpty)
        #expect(NameCollisions.logLine(kept: final.guesses, dropped: final.dropped)
            == "S1 = Daniel Falk (dropped: S2 has this name by voice)")
    }
}
