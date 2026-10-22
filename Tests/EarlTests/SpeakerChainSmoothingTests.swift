import Testing
@testable import Earl

/// Q-2: whisper breaks a phrase at every ~1 s pause, and `SpeakerAssignment`
/// used to give each phrase its own majority voice, so one sentence split
/// across such a pause could come out as two voices. These test the post-pass
/// that links such phrases back into one "sentence chain" and gives every
/// turn in it the voice spoken longest.
struct SpeakerChainSmoothingTests {
    /// A phrase whose words are evenly spread across [start, end], so the
    /// exact word timings don't matter, only the phrase's own span and text.
    static func phrase(_ text: String, _ start: Double, _ end: Double) -> Phrase {
        let tokens = text.split(separator: " ").map(String.init)
        let step = (end - start) / Double(tokens.count)
        let words = tokens.enumerated().map { i, t in
            TimedWord(text: " " + t, start: start + Double(i) * step, end: start + Double(i + 1) * step)
        }
        return Phrase(turn: Turn(start: start, end: end, speaker: "Them", text: text), words: words)
    }

    /// One voice covering the whole [start, end] span, so `assign` never
    /// splits the phrase itself and gives it straight to that voice.
    static func segment(_ voice: Int, _ start: Double, _ end: Double) -> (start: Double, end: Double, speaker: Int) {
        (start, end, voice)
    }

    @Test func fourPhraseSentenceBecomesOneVoice() {
        // "So I wanted to present you or I teased at you also like a" / "few
        // weeks ago regarding the roadmap and now I wanted to present you a
        // little" / "bit more in detail and what was or" / "what is
        // currently aligned" — one person, split by whisper at every pause,
        // heard by diarization as alternating because the voices overlap
        // enough to confuse it. Voice 0 talks longer overall, so it wins.
        let phrases = [
            Self.phrase("So I wanted to present you or I teased at you also like a", 0, 5),
            Self.phrase("few weeks ago regarding the roadmap and now I wanted to present you a little", 5.5, 8.5),
            Self.phrase("bit more in detail and what was or", 9, 11),
            Self.phrase("what is currently aligned", 11.5, 12.5),
        ]
        let d = Diarization(segments: [Self.segment(0, 0, 5), Self.segment(1, 5.5, 8.5),
                                       Self.segment(0, 9, 11), Self.segment(1, 11.5, 12.5)], speakers: [])
        let out = SpeakerAssignment.assign(phrases, to: d)
        #expect(out.count == 4)
        #expect(out.allSatisfy { $0.speaker == 0 })
    }

    @Test func realInterruptionStaysTwoVoices() {
        // "…and then we" / "Sorry, can I ask something?": the second phrase
        // starts a new sentence (capital S), so it's never linked.
        let phrases = [Self.phrase("and then we", 0, 2), Self.phrase("Sorry, can I ask something?", 2.4, 4)]
        let d = Diarization(segments: [Self.segment(0, 0, 2), Self.segment(1, 2.4, 4)], speakers: [])
        let out = SpeakerAssignment.assign(phrases, to: d)
        #expect(out.map(\.speaker) == [0, 1])
    }

    @Test func questionAndAnswerStayTwoVoices() {
        // The question ends with "?", so its answer is never linked back to it.
        let phrases = [Self.phrase("What do you think?", 0, 2), Self.phrase("I think it's fine.", 2.3, 4)]
        let d = Diarization(segments: [Self.segment(0, 0, 2), Self.segment(1, 2.3, 4)], speakers: [])
        let out = SpeakerAssignment.assign(phrases, to: d)
        #expect(out.map(\.speaker) == [0, 1])
    }

    @Test func neverLinksAcrossAGapOfASecondOrMore() {
        // Same continuation shape (no ending punctuation, lowercase next),
        // but the pause is a full second: never smoothed.
        let phrases = [Self.phrase("so I wanted to say", 0, 2), Self.phrase("something about the budget", 3, 5)]
        let d = Diarization(segments: [Self.segment(0, 0, 2), Self.segment(1, 3, 5)], speakers: [])
        let out = SpeakerAssignment.assign(phrases, to: d)
        #expect(out.map(\.speaker) == [0, 1])
    }

    @Test func nilVoicesAreLeftAlone() {
        // Exercises `smoothChains` directly (it's public exactly so this can
        // be tested on its own): the middle turn has no voice nearby, so it
        // keeps `nil` even though it sits inside the chain, while the two
        // real voices on either side still get smoothed to whichever talked
        // longer.
        let assigned: [(turn: Turn, speaker: Int?)] = [
            (Turn(start: 0, end: 5, speaker: "Them", text: "so I wanted to say"), 0),
            (Turn(start: 5.4, end: 5.8, speaker: "Them", text: "something in between"), nil),
            (Turn(start: 6.2, end: 7.2, speaker: "Them", text: "about the roadmap for next quarter"), 1),
        ]
        let out = SpeakerAssignment.smoothChains(assigned)
        #expect(out.map(\.speaker) == [0, nil, 0])
    }

    @Test func tiesGoToTheFirstTurnsVoice() {
        let phrases = [Self.phrase("so we talked about it", 0, 4), Self.phrase("and agreed on the plan", 4.5, 8.5)]
        let d = Diarization(segments: [Self.segment(0, 0, 4), Self.segment(1, 4.5, 8.5)], speakers: [])
        let out = SpeakerAssignment.assign(phrases, to: d)
        #expect(out.map(\.speaker) == [0, 0])
    }

    @Test func withinPhraseSplitsMidSentenceAreSmoothed() {
        // Seen on a real meeting: the diarizer flipped voices every few words
        // through one person's opening sentence, inside a single phrase.
        let list: [(String, Double, Double)] = [("So", 0, 1), ("I", 1, 2), ("wanted", 2, 3), ("to", 3, 4),
                                                 ("present", 4, 5.5), ("you", 5.6, 7.5), ("the", 7.5, 9), ("roadmap", 9, 12)]
        let words = list.map { TimedWord(text: " " + $0.0, start: $0.1, end: $0.2) }
        let phrase = Phrase(turn: Turn(start: 0, end: 12, speaker: "Them", text: "So I wanted to present you the roadmap"),
                            words: words)
        let d = Diarization(segments: [Self.segment(0, 0, 5.5), Self.segment(1, 5.5, 7.5), Self.segment(0, 7.5, 12)],
                            speakers: [])
        let out = SpeakerAssignment.assign([phrase], to: d)
        #expect(Set(out.map(\.speaker)) == [0])
    }

    @Test func withinPhraseSplitAtANewSentenceStays() {
        let list: [(String, Double, Double)] = [("That's", 0, 1), ("the", 1, 2), ("plan.", 2, 3),
                                                 ("Sounds", 3.2, 4.5), ("good", 4.5, 6)]
        let words = list.map { TimedWord(text: " " + $0.0, start: $0.1, end: $0.2) }
        let phrase = Phrase(turn: Turn(start: 0, end: 6, speaker: "Them", text: "That's the plan. Sounds good"), words: words)
        let d = Diarization(segments: [Self.segment(0, 0, 3), Self.segment(1, 3, 6)], speakers: [])
        let out = SpeakerAssignment.assign([phrase], to: d)
        #expect(out.map(\.speaker) == [0, 1])
    }
}
