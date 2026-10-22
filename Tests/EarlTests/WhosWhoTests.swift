import Foundation
import Testing
@testable import Earl

// W-1: who the card asks about, Earl's words, names to suggest and what to play.
struct WhosWhoTests {
    static func speaker(_ id: String, _ track: String = "Them", name: String? = nil, source: Speaker.NameSource? = nil,
                        seconds: Double = 60) -> Speaker {
        Speaker(id: id, track: track, name: name, nameSource: source, embedding: [1, 0], seconds: seconds)
    }

    static func meeting(_ speakers: [Speaker], turns: [Turn]? = nil, attendees: [Attendee]? = nil,
                        status: MeetingStatus = .done, dismissed: Bool? = nil) -> Meeting {
        var info = MeetingInfo(title: "Weekly", titleIsDefault: false, startedAt: Date(), duration: 600, status: status)
        info.attendees = attendees
        info.whosWhoDismissed = dismissed
        let turns = turns ?? speakers.enumerated().map { i, s in
            Turn(start: Double(i * 10), end: Double(i * 10 + 5), speaker: s.track, text: "Hello.", speakerID: s.id)
        }
        return Meeting(id: "m", folder: URL(fileURLWithPath: "/tmp/m"), info: info, turns: turns, summary: "",
                       files: [], speakers: speakers)
    }

    // MARK: Who to ask about

    @Test func asksAboutGuessesAndLongUnnamedVoices() {
        let m = Self.meeting([
            Self.speaker("S1", "Me", seconds: 300), // you
            Self.speaker("S2", name: "Sarah", source: .guessed, seconds: 12), // a guess, however short
            Self.speaker("S3", seconds: 29), // too short
            Self.speaker("S4", seconds: 30),
            Self.speaker("S5", name: "Tom", source: .confirmed, seconds: 400),
            Self.speaker("S6", name: "Priya", source: .voice, seconds: 400),
        ])
        let asks = WhosWho.asks(for: m)
        #expect(asks.map(\.speakerID) == ["S4", "S2"]) // by talk time
        #expect(asks[1].kind == .guess("Sarah"))
        #expect(asks[0].kind == .unnamed)
    }

    @Test func atMostFourRowsLongestFirst() {
        let m = Self.meeting((1...6).map { Self.speaker("S\($0)", seconds: Double(30 + $0 * 10)) })
        #expect(WhosWho.asks(for: m).map(\.speakerID) == ["S6", "S5", "S4", "S3"])
    }

    @Test func hiddenAfterNotNowWhileBusyOrUnfinished() {
        let speakers = [Self.speaker("S1", seconds: 90), Self.speaker("S2", seconds: 90)]
        #expect(WhosWho.asks(for: Self.meeting(speakers, dismissed: true)).isEmpty)
        #expect(WhosWho.asks(for: Self.meeting(speakers), busy: true).isEmpty)
        #expect(WhosWho.asks(for: Self.meeting(speakers, status: .summarizing)).isEmpty)
        #expect(WhosWho.asks(for: Self.meeting(speakers, dismissed: false)).count == 2)
        // A voice with no turns left (merged away) isn't asked about.
        #expect(WhosWho.asks(for: Self.meeting(speakers, turns: [Turn(start: 0, end: 5, speaker: "Them", text: "Hi",
                                                                      speakerID: "S1")])).map(\.speakerID) == ["S1"])
    }

    @Test func hiddenForGoodOnceEveryoneHasAName() {
        let m = Self.meeting([Self.speaker("S1", name: "Tom", source: .confirmed),
                              Self.speaker("S2", name: "Sarah", source: .voice)])
        #expect(WhosWho.asks(for: m).isEmpty)
        #expect(WhosWho.notificationBody(for: m) == "Weekly")
    }

    // MARK: Earl's words

    @Test func earlsLines() {
        let guess = WhosWho.Ask(speakerID: "S2", kind: .guess("Sarah"), seconds: 40)
        let unnamed = WhosWho.Ask(speakerID: "S3", kind: .unnamed, seconds: 40)
        #expect(WhosWho.lead(for: [guess]) == "Is this Sarah?")
        #expect(WhosWho.lead(for: [unnamed]) == "I didn't catch one voice.")
        #expect(WhosWho.lead(for: [unnamed, unnamed, unnamed]) == "I didn't catch three voices.")
        #expect(WhosWho.lead(for: [unnamed, guess]) == "Two voices I'm not sure of.")
        let m = Self.meeting([Self.speaker("S1", seconds: 90), Self.speaker("S2", seconds: 90)])
        #expect(WhosWho.notificationBody(for: m) == "Weekly\nEarl has a question about two voices.")
    }

    @Test func talkTime() {
        #expect(WhosWho.talkTime(43) == "43 s")
        #expect(WhosWho.talkTime(240) == "4 min")
        #expect(WhosWho.talkTime(89) == "1 min")
    }

    // MARK: Suggestions

    static let invited = [Attendee(name: "Alex Morgan", email: nil, isMe: true),
                          Attendee(name: "Zoe Hart", email: nil, isMe: false),
                          Attendee(name: "Ben Ito", email: nil, isMe: false),
                          Attendee(name: "Carla Diaz", email: nil, isMe: false),
                          Attendee(name: "Tom Becker", email: nil, isMe: false),
                          Attendee(name: "Dana Fox", email: nil, isMe: false),
                          Attendee(name: "Eve Lund", email: nil, isMe: false)]

    @Test func suggestionsSaidNearTheVoiceThenSeriesThenAlphabetical() {
        let turns = [
            Turn(start: 0, end: 5, speaker: "Me", text: "What do you think, Zoe?"),
            Turn(start: 6, end: 12, speaker: "Them", text: "I like it.", speakerID: "S2"),
            Turn(start: 13, end: 20, speaker: "Them", text: "Me too.", speakerID: "S3"),
        ]
        let m = Self.meeting([Self.speaker("S2"), Self.speaker("S3"),
                              Self.speaker("S4", name: "Tom", source: .confirmed)], turns: turns, attendees: Self.invited)
        var older = Self.meeting([Self.speaker("S1", name: "Eve Lund", source: .confirmed),
                                  Self.speaker("S2", name: "Dana Fox", source: .voice),
                                  Self.speaker("S3", name: "Ben Ito", source: .guessed)]) // a guess doesn't count
        older.info.startedAt = Date(timeIntervalSinceNow: -86400)
        let names = WhosWho.suggestions(for: "S2", in: m, earlier: [older], userName: "Alex")
        // Zoe was addressed right before S2; Eve and Dana were named in the
        // series; then Ben, Carla alphabetically. Tom has a voice already, and
        // you're never suggested. Four at most.
        #expect(names == ["Zoe Hart", "Dana Fox", "Eve Lund", "Ben Ito"])
        #expect(WhosWho.suggestions(for: "S2", in: m, earlier: [older], userName: "Alex", limit: 10)
            == ["Zoe Hart", "Dana Fox", "Eve Lund", "Ben Ito", "Carla Diaz"])
    }

    @Test func suggestionsSkipNamesAnyVoiceHasEvenAsAGuess() {
        let m = Self.meeting([Self.speaker("S1", name: "Zoe", source: .guessed), Self.speaker("S2")],
                             attendees: Array(Self.invited.prefix(3)))
        #expect(WhosWho.suggestions(for: "S2", in: m, earlier: [], userName: nil) == ["Ben Ito"])
    }

    @Test func suggestionsFromTheSeriesWithoutAnInvite() {
        let m = Self.meeting([Self.speaker("S1"), Self.speaker("S2")])
        let newer = Self.meeting([Self.speaker("S1", name: "Nina", source: .confirmed)])
        let older = Self.meeting([Self.speaker("S1", name: "Sam", source: .confirmed),
                                  Self.speaker("S2", name: "Nina", source: .confirmed)])
        #expect(WhosWho.suggestions(for: "S1", in: m, earlier: [newer, older], userName: nil) == ["Nina", "Sam"])
    }

    @Test func confirmingAGuessUsesTheInvitedName() {
        #expect(WhosWho.confirmedName(for: "Zoe", attendees: Self.invited) == "Zoe Hart")
        #expect(WhosWho.confirmedName(for: "Quinn", attendees: Self.invited) == "Quinn")
    }

    // MARK: What to play

    @Test func longestCleanTurnCappedAtEightSeconds() {
        let turns = [
            Turn(start: 0, end: 20, speaker: "Them", text: "Long, but talked over.", speakerID: "S2"),
            Turn(start: 10, end: 12, speaker: "Me", text: "Mm."),
            Turn(start: 30, end: 36, speaker: "Them", text: "Short and clean.", speakerID: "S2"),
            Turn(start: 40, end: 52, speaker: "Them", text: "Long and clean.", speakerID: "S2"),
            Turn(start: 60, end: 90, speaker: "Them", text: "Someone else.", speakerID: "S3"),
        ]
        let clip = WhosWho.clip(for: "S2", in: turns)
        #expect(clip?.turn.start == 40)
        #expect(clip?.seconds == 8)
        let short = WhosWho.clip(for: "S2", in: Array(turns.prefix(3)))
        #expect(short?.turn.start == 30)
        #expect(short?.seconds == 6)
    }

    @Test func clipFallsBackToTheLongestTurn() {
        let turns = [Turn(start: 0, end: 6, speaker: "Them", text: "A", speakerID: "S2"),
                     Turn(start: 5, end: 7, speaker: "Them", text: "B", speakerID: "S3"),
                     Turn(start: 8, end: 11, speaker: "Them", text: "C", speakerID: "S2"),
                     Turn(start: 10, end: 12, speaker: "Me", text: "D")]
        #expect(WhosWho.clip(for: "S2", in: turns)?.turn.start == 0)
        #expect(WhosWho.clip(for: "S9", in: turns) == nil)
    }
}
