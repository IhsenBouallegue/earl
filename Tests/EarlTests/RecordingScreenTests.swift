import Foundation
import Testing
@testable import Earl

/// U-4: the recording screen's turn history and its copy.
struct RecordingScreenTests {
    /// Feeds `talker` every 0.1 s from `from` to `to`.
    private func talk(_ history: inout LiveTurnHistory, _ talker: Int?, from: Double, to: Double) {
        var t = from
        while t <= to + 1e-9 {
            history.update(talker: talker, at: t)
            t += 0.1
        }
    }

    @Test func shortPausesOfTheSameVoiceStayOneTurn() {
        var h = LiveTurnHistory()
        talk(&h, 0, from: 0, to: 5)
        talk(&h, nil, from: 5.1, to: 6.5) // a breath
        talk(&h, 0, from: 6.6, to: 10)
        #expect(h.turns.count == 1)
        #expect(abs(h.turns[0].seconds - 10) < 0.01)
        #expect(h.isOpen)
        talk(&h, nil, from: 10.1, to: 11)
        #expect(!h.isOpen)
    }

    @Test func aLongPauseStartsANewTurn() {
        var h = LiveTurnHistory()
        talk(&h, 0, from: 0, to: 3)
        talk(&h, nil, from: 3.1, to: 8)
        talk(&h, 0, from: 8.1, to: 10)
        #expect(h.turns.map(\.voice) == [0, 0])
    }

    @Test func turnsAlternateBetweenVoicesAndYou() {
        var h = LiveTurnHistory()
        talk(&h, 0, from: 0, to: 4)
        talk(&h, -1, from: 4.1, to: 6)
        talk(&h, 1, from: 6.1, to: 9)
        #expect(h.turns.map(\.voice) == [0, -1, 1])
        #expect(h.turns[1].isMe)
        #expect(Set(h.turns.map(\.id)).count == 3)
    }

    @Test func aBlipIsDroppedAndTheTurnAroundItHealed() {
        var h = LiveTurnHistory()
        talk(&h, 0, from: 0, to: 4)
        talk(&h, 1, from: 4.1, to: 4.3) // a cough on another voice
        #expect(h.shown.map(\.voice) == [0]) // not drawn while it's this short
        talk(&h, 0, from: 4.4, to: 8)
        #expect(h.turns.map(\.voice) == [0])
        #expect(abs(h.turns[0].seconds - 8) < 0.01)
    }

    @Test func historyStaysBoundedOverATwoHourCall() {
        var h = LiveTurnHistory()
        var t = 0.0
        var voice = 0
        while t < 2 * 3600 {
            h.update(talker: voice, at: t)
            t += 0.1
            if Int(t * 10) % 50 == 0 { voice = (voice + 1) % 3 } // a new speaker every 5 s
        }
        #expect(h.turns.count == h.limit)
        #expect(h.turns.last!.end > 2 * 3600 - 6)
        // The newest turns are the ones kept, in order.
        #expect(zip(h.turns, h.turns.dropFirst()).allSatisfy { $0.start < $1.start })
    }

    @Test func dotsGrowWithTheTurn() {
        #expect(LiveTurn.dots(for: 0) == 1)
        #expect(LiveTurn.dots(for: 3) == 1)
        #expect(LiveTurn.dots(for: 12) == 2)
        #expect(LiveTurn.dots(for: 42) == 6)
        #expect(LiveTurn.dots(for: 3600) == 12)
    }

    @Test func earlsRecordingLineChangesEveryFewMinutes() {
        #expect(EarlVoice.whileRecording(elapsed: 0).lead == EarlVoice.listening)
        #expect(EarlVoice.whileRecording(elapsed: 239).lead == EarlVoice.listening)
        #expect(EarlVoice.whileRecording(elapsed: 240).lead != EarlVoice.listening)
        #expect(EarlVoice.whileRecording(elapsed: 240 * Double(EarlVoice.recordingLines.count)).lead == EarlVoice.listening)
    }

    @Test func talkingCaption() {
        #expect(StageFormat.talking(nil) == "Listening")
        #expect(StageFormat.talking(LiveFace(voice: -1, label: "You", seconds: 3, isActive: true)) == "You're talking")
        #expect(StageFormat.talking(LiveFace(voice: 1, label: "Speaker 2", seconds: 3, isActive: true))
            == "Speaker 2 is talking")
    }

    @Test func silenceHintWaitsLongerForTheMic() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let now = start.addingTimeInterval(60)
        #expect(SilenceHint.text(nil, since: start, now: now, isThem: true) == "No call audio for 1 min")
        #expect(SilenceHint.text(nil, since: start, now: now, isThem: false, after: 120) == nil)
        #expect(SilenceHint.text(start, since: start, now: start.addingTimeInterval(180), isThem: false, after: 120)
            == "Mic quiet for 3 min")
    }
}
