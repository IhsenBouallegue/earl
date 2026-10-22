import Foundation
import Testing
@testable import Earl

struct SyntheticScoreTests {
    private func truth(echo: Bool = false) -> SyntheticTruth {
        let u: [SyntheticTruth.Utterance] = [
            .init(speaker: "A", track: "Them", start: 1, end: 6, text: "We ship the release on Monday morning.", kind: .turn),
            .init(speaker: "B", track: "Them", start: 3, end: 3.5, text: "Right.", kind: .interjection),
            .init(speaker: "B", track: "Them", start: 7, end: 12, text: "The migration processed 90% of the records.", kind: .turn),
            .init(speaker: "C", track: "Them", start: 9, end: 13, text: "Hang on, that would break billing.", kind: .crosstalk),
            .init(speaker: "D", track: "Me", start: 14, end: 16, text: "Thanks Tom, sounds good.", kind: .turn),
        ]
        return SyntheticTruth(
            preset: "test", seed: 1, duration: 17, speakers: [], utterances: u,
            overlaps: SyntheticTruth.overlaps(of: u),
            echo: echo ? [.init(start: 1.1, end: 13.2, delayMs: 100, gainDb: -18)] : [],
            degradations: .init())
    }

    @Test func perfectSeparatedTranscriptScoresFull() {
        let t = truth()
        let segs = t.utterances.map {
            SyntheticScore.Segment(start: $0.start, end: $0.end, track: $0.track, speaker: "S-" + $0.speaker, text: $0.text)
        }
        let r = SyntheticScore.score(truth: t, segments: segs)
        #expect(r.lostWords == 0)
        #expect(r.speakerAccuracy == 1)
        #expect(r.interjectionsRightSpeaker == 1)
        #expect(r.extraWords == 0)
        #expect(r.mapping["Them/S-C"] == "C")
    }

    @Test func withoutSeparationTheTrackMapsToOneSpeaker() {
        // Whisper hears the main lines, misses the interjection and most of the crosstalk.
        let segs = [
            SyntheticScore.Segment(start: 1, end: 6, track: "Them", speaker: "Them", text: "We ship the release on Monday morning."),
            SyntheticScore.Segment(start: 7, end: 12, track: "Them", speaker: "Them", text: "The migration processed 90 percent of the records."),
            SyntheticScore.Segment(start: 12, end: 13, track: "Them", speaker: "Them", text: "break billing"),
            SyntheticScore.Segment(start: 14, end: 16, track: "Me", speaker: "Me", text: "Thanks, Tom. Sounds good!"),
        ]
        let r = SyntheticScore.score(truth: truth(), segments: segs)
        #expect(r.truthWords == 7 + 1 + 8 + 6 + 4)
        #expect(r.interjectionsLost == 1)
        #expect(r.lostInCrosstalk + r.lostInOverlap + r.lostElsewhere == r.lostWords)
        #expect(r.lostWords == 1 + 4)
        #expect(r.lostInCrosstalk >= 3)
        // "Them" maps to B (8 words) over A (7); A's and C's words count as wrong.
        #expect(r.mapping["Them/Them"] == "B")
        #expect(r.correctSpeakerWords == 8 + 4)
    }

    @Test func longSegmentsSpanningSilenceStillAlign() {
        // With VAD, Whisper glues lines across long pauses into one segment.
        let segs = [
            SyntheticScore.Segment(start: 0.5, end: 13, track: "Them", speaker: "Them", text:
                "We ship the release on Monday morning. Right. The migration processed 90% of the records. "
                + "Hang on, that would break billing."),
            SyntheticScore.Segment(start: 14, end: 16, track: "Me", speaker: "Me", text: "Thanks Tom, sounds good."),
        ]
        let r = SyntheticScore.score(truth: truth(), segments: segs)
        #expect(r.lostWords == 0)
        #expect(r.interjectionsLost == 0)
        #expect(r.extraWords == 0)
    }

    @Test func echoWordsOnTheMicAreCounted() {
        let segs = [
            SyntheticScore.Segment(start: 1, end: 6, track: "Them", speaker: "Them", text: "We ship the release on Monday morning."),
            SyntheticScore.Segment(start: 1.1, end: 6.1, track: "Me", speaker: "Me", text: "the release on Monday"),
            SyntheticScore.Segment(start: 14, end: 16, track: "Me", speaker: "Me", text: "Thanks Tom, sounds good."),
        ]
        let r = SyntheticScore.score(truth: truth(echo: true), segments: segs)
        #expect(r.echoWordsAsMe == 4)
        #expect(r.extraWords == 0)
    }

    @Test func normalizesNumbersPunctuationAndFillers() {
        #expect(SyntheticScore.normalize("90% of 400, OK? Mm-hmm.") ==
            ["ninety", "percent", "of", "four", "hundred", "okay", "mhm"])
        #expect(SyntheticScore.normalize("Mm-hm") == SyntheticScore.normalize("mhm"))
        #expect(SyntheticScore.normalize("four thousand") == SyntheticScore.normalize("4000"))
        #expect(SyntheticScore.normalize("Two-factor") == ["two", "factor"])
    }

    @Test func lcsFindsTheLongestCommonRun() {
        let pairs = SyntheticScore.lcs(["a", "b", "c", "d"], ["x", "b", "d", "a"])
        #expect(pairs.count == 2)
        #expect(pairs.map(\.0) == [1, 3])
    }
}
