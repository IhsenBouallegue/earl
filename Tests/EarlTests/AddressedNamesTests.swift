import Foundation
import Testing
@testable import Earl

/// Q-3: names from who was addressed, no LLM. Uses `SpeakerNamesTests`'
/// `turn`/`speaker`/`meeting` helpers (same module, same test target).
struct AddressedNamesTests {
    func attendee(_ name: String, isMe: Bool = false) -> Attendee { Attendee(name: name, email: nil, isMe: isMe) }

    // MARK: Vocative shapes

    @Test func sentenceStartVocativeNamesTheNextSpeaker() {
        // "Isa, you were raising your hand." starts a new sentence and is
        // answered by the next turn: S3 is Isa = Isabelle Kramer.
        let turns = [
            SpeakerNamesTests.turn(0, 5, "S1", "This is where we are located. Isa, you were raising your hand."),
            SpeakerNamesTests.turn(5, 8, "S3", "Yeah, I'm not sure if it fits here."),
        ]
        let out = AddressedNames.guesses(turns: turns, candidates: ["S1", "S3"], attendees: [attendee("Isabelle Kramer")],
                                         userName: nil)
        #expect(out["S3"]?.name == "Isabelle Kramer")
        #expect(out["S3"]?.evidence == "Isa, you were raising your hand.")
    }

    @Test func commaVocativeNamesTheNextSpeaker() {
        // German: "Kam was bei dir, Matt?" follows a comma and is answered
        // right after: S1 is Matt = Matthias Vogel.
        let turns = [
            SpeakerNamesTests.turn(0, 4, "S4", "Kam was bei dir, Matt?"),
            SpeakerNamesTests.turn(4, 8, "S1", "Also ich habe es auch noch nicht."),
        ]
        let out = AddressedNames.guesses(turns: turns, candidates: ["S1", "S4"], attendees: [attendee("Matthias Vogel")],
                                         userName: nil)
        #expect(out["S1"]?.name == "Matthias Vogel")
        #expect(out["S1"]?.evidence == "Kam was bei dir, Matt?")
    }

    @Test func leadingWordVocativeNamesThePreviousSpeaker() {
        // "Aber Matthias, dann können wir weiter." addresses the person who
        // just spoke, right at the start of the reply.
        let turns = [
            SpeakerNamesTests.turn(0, 3, "S1", "Wir müssen das klären."),
            SpeakerNamesTests.turn(3, 6, "S2", "Aber Matthias, dann können wir weiter."),
        ]
        let out = AddressedNames.guesses(turns: turns, candidates: ["S1", "S2"], attendees: [attendee("Matthias Vogel")],
                                         userName: nil)
        #expect(out["S1"]?.name == "Matthias Vogel")
        #expect(out["S1"]?.evidence == "Aber Matthias, dann können wir weiter.")
    }

    @Test func thanksVocativeNamesThePreviousSpeaker() {
        let turns = [
            SpeakerNamesTests.turn(0, 3, "S1", "The release candidate is ready."),
            SpeakerNamesTests.turn(3, 6, "S2", "Thank you, Lance."),
        ]
        let out = AddressedNames.guesses(turns: turns, candidates: ["S1", "S2"], attendees: [attendee("Lance Ortiz")],
                                         userName: nil)
        #expect(out["S1"]?.name == "Lance Ortiz")
    }

    @Test func selfIntroductionNamesTheSpeaker() {
        let turns = [SpeakerNamesTests.turn(0, 3, "S4", "Hallo zusammen, ich bin Matthias aus dem Vertrieb.")]
        let out = AddressedNames.guesses(turns: turns, candidates: ["S4"], attendees: [attendee("Matthias Vogel")],
                                         userName: nil)
        #expect(out["S4"]?.name == "Matthias Vogel")
    }

    // MARK: No attendees

    @Test func repeatedAddressWithNoAttendeesIsAccepted() {
        let turns = [
            SpeakerNamesTests.turn(0, 3, "S1", "Priya, can you check this?"),
            SpeakerNamesTests.turn(3, 6, "S2", "Sure, one moment."),
            SpeakerNamesTests.turn(6, 9, "S1", "Priya, did you find it?"),
            SpeakerNamesTests.turn(9, 12, "S2", "Yes, found it."),
        ]
        let out = AddressedNames.guesses(turns: turns, candidates: ["S1", "S2"], attendees: [], userName: nil)
        #expect(out["S2"]?.name == "Priya")
    }

    @Test func aSingleAddressWithNoAttendeesIsIgnored() {
        let turns = [
            SpeakerNamesTests.turn(0, 3, "S1", "Priya, can you check this?"),
            SpeakerNamesTests.turn(3, 6, "S2", "Sure, one moment."),
        ]
        let out = AddressedNames.guesses(turns: turns, candidates: ["S1", "S2"], attendees: [], userName: nil)
        #expect(out.isEmpty)
    }

    // MARK: Guards

    @Test func mentionInPassingCastsNoVote() {
        let turns = [
            SpeakerNamesTests.turn(0, 3, "S1", "As Tom said earlier, we should proceed."),
            SpeakerNamesTests.turn(3, 6, "S2", "Sure, let's do that."),
        ]
        let out = AddressedNames.guesses(turns: turns, candidates: ["S1", "S2"], attendees: [attendee("Tom Baker")],
                                         userName: nil)
        #expect(out.isEmpty)
    }

    @Test func addressingYouGivesNobodyTheName() {
        let turns = [
            SpeakerNamesTests.turn(0, 3, "S1", "Tom, can you help with this?"),
            SpeakerNamesTests.turn(3, 6, nil, "Sure thing.", track: "Me"),
        ]
        let out = AddressedNames.guesses(turns: turns, candidates: ["S1"], attendees: [attendee("Tom Baker")], userName: nil)
        #expect(out.isEmpty)
    }

    @Test func twoSpeakersAddressedWithTheSameNameGetNeither() {
        let turns = [
            SpeakerNamesTests.turn(0, 5, "S3", "Hey everyone, thanks for joining today, let's get started with the "
                + "agenda right now. Tom, can you kick things off for us?"),
            SpeakerNamesTests.turn(5, 8, "S1", "Sure, happy to start."),
            SpeakerNamesTests.turn(8, 13, "S4", "Great, thanks for that update, now let's move to the next topic on "
                + "our list here today. Tom, are you ready with your part?"),
            SpeakerNamesTests.turn(13, 16, "S2", "Yes, I'm ready."),
        ]
        let out = AddressedNames.guesses(turns: turns, candidates: ["S1", "S2"], attendees: [attendee("Tom Baker")],
                                         userName: nil)
        #expect(out["S1"] == nil)
        #expect(out["S2"] == nil)
    }

    @Test func yourOwnNameNeverGoesToAnyone() {
        let turns = [
            SpeakerNamesTests.turn(0, 3, "S1", "Ahsan, can you check this?"),
            SpeakerNamesTests.turn(3, 6, "S2", "Sure, I'll check."),
        ]
        let out = AddressedNames.guesses(turns: turns, candidates: ["S1", "S2"], attendees: [], userName: "Ahsan")
        #expect(out.isEmpty)
    }

    @Test func noTurnsOrCandidatesGiveNothing() {
        #expect(AddressedNames.guesses(turns: [], candidates: ["S1"], attendees: [], userName: nil).isEmpty)
        let turns = [SpeakerNamesTests.turn(0, 3, "S1", "Tom, can you help?")]
        #expect(AddressedNames.guesses(turns: turns, candidates: [], attendees: [attendee("Tom Baker")], userName: nil).isEmpty)
    }
}
