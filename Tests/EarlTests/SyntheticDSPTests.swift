import Foundation
import Testing
@testable import Earl

/// Fast checks of the synthetic-meeting building blocks (T-1). The full
/// generator runs in `SyntheticMeetingTests` with EARL_SYNTH=1.
struct SyntheticDSPTests {
    private func tone(_ seconds: Double, freq: Double = 440, amp: Float = 0.5) -> [Float] {
        SynthDSP.scaled(SynthDSP.sine(SynthDSP.samples(seconds), freq: freq), by: amp)
    }

    /// Buzzy, speech-like bursts: a 150 Hz harmonic stack switched on and off.
    private func speechLike(_ seconds: Double) -> [Float] {
        let n = SynthDSP.samples(seconds)
        var x = [Float](repeating: 0, count: n)
        for h in 1...12 {
            SynthDSP.add(SynthDSP.sine(n, freq: 150 * Double(h), phase: Double(h)), into: &x, at: 0, gain: 0.3 / Float(h))
        }
        let burst = SynthDSP.samples(0.3)
        for i in 0..<n where (i / burst) % 2 == 1 { x[i] = 0 }
        return x
    }

    @Test func gainIsAppliedInDecibels() {
        var x = tone(1)
        let before = SynthDSP.rms(x)
        SynthDSP.applyGain(&x, db: -6)
        #expect(abs(SynthDSP.decibels(SynthDSP.rms(x) / before) + 6) < 0.01)
    }

    @Test func addPlacesAndClipsAtOffset() {
        var dst = [Float](repeating: 0, count: 5)
        SynthDSP.add([1, 1, 1], into: &dst, at: 3, gain: 2)
        #expect(dst == [0, 0, 0, 2, 2])
        SynthDSP.add([1, 1, 1], into: &dst, at: -2, gain: 1)
        #expect(dst == [1, 0, 0, 2, 2])
    }

    @Test func wavRoundTripKeepsSamples() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("earl-synth-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let x = tone(0.5)
        try SynthDSP.writeWAV(x, to: url)
        let y = try SynthDSP.readAudio(url)
        #expect(y.count == x.count)
        #expect(zip(x, y).allSatisfy { abs($0 - $1) < 1.0 / 16000 })
    }

    @Test func delayEstimateFindsAKnownShift() {
        let x = speechLike(4)
        #expect(SynthDSP.estimateDelay(reference: x, delayed: SynthDSP.shifted(x, by: 123), maxLag: 800) == 123)
        #expect(SynthDSP.estimateDelay(reference: x, delayed: SynthDSP.shifted(x, by: -40), maxLag: 800) == -40)
    }

    @Test func codecRoundTripKeepsLengthAndTiming() throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("earl-synth-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        let x = speechLike(4)
        let result = try SynthDSP.codecRoundTrip(x, bitrate: 24000, workDir: work)
        #expect(result.audio.count == x.count)
        #expect(result.codec == "opus")
        // After the correction there's no delay left to find.
        #expect(abs(SynthDSP.estimateDelay(reference: x, delayed: result.audio, maxLag: 800)) <= 1)
        // And it's still the same signal, not silence.
        #expect(SynthDSP.decibels(SynthDSP.rms(result.audio) / SynthDSP.rms(x)) > -3)
    }

    @Test func seedMakesNoiseAndLossDeterministic() {
        var a = SeededRNG(seed: 7), b = SeededRNG(seed: 7), c = SeededRNG(seed: 8)
        let pa = SynthDSP.pink(4000, rng: &a), pb = SynthDSP.pink(4000, rng: &b), pc = SynthDSP.pink(4000, rng: &c)
        #expect(pa == pb)
        #expect(pa != pc)
        let x = tone(10)
        let la = SynthDSP.packetLoss(x, rate: 0.03, rng: &a), lb = SynthDSP.packetLoss(x, rate: 0.03, rng: &b)
        #expect(la.audio == lb.audio)
        #expect(la.dropped == lb.dropped)
        let ka = SynthDSP.keyboard(16000 * 20, bursts: 3, rng: &a).audio
        let kb = SynthDSP.keyboard(16000 * 20, bursts: 3, rng: &b).audio
        #expect(ka == kb)
    }

    @Test func packetLossDropsAboutTheRateAndKeepsLength() {
        var rng = SeededRNG(seed: 3)
        let x = tone(60)
        let loss = SynthDSP.packetLoss(x, rate: 0.02, rng: &rng)
        #expect(loss.audio.count == x.count)
        // 3000 frames at 2 %: 60 expected.
        #expect((30...95).contains(loss.dropped.count))
        #expect(loss.audio != x)
    }

    @Test func reverbAddsATailAndKeepsLength() {
        var x = [Float](repeating: 0, count: 16000)
        x[100] = 1
        let y = SynthDSP.reverb(x, rt60: 0.5, wet: 0.5)
        #expect(y.count == x.count)
        #expect(SynthDSP.rms(y, 1600..<4800) > 0.0005)
        #expect(SynthDSP.rms(x, 1600..<4800) == 0)
    }

    @Test func compressorNarrowsTheLevelGap() {
        let loud = tone(1, amp: 0.5), quiet = tone(1, amp: 0.02)
        let y = SynthDSP.compress(loud + quiet, thresholdDb: -26, ratio: 3)
        let gapBefore = SynthDSP.decibels(SynthDSP.rms(loud) / SynthDSP.rms(quiet))
        let gapAfter = SynthDSP.decibels(SynthDSP.rms(y, 4000..<16000) / SynthDSP.rms(y, 20000..<32000))
        #expect(gapAfter < gapBefore - 6)
        #expect(y.count == 32000)
    }

    @Test func limiterCatchesPeaksAndLeavesTheRest() {
        var x = tone(2, amp: 0.3)
        x[16000] = 2
        let y = SynthDSP.scaled(x, by: 1)
        let g = SynthDSP.limiterGain(for: [x, y], ceiling: 0.9)
        #expect(g.count == x.count)
        #expect(zip(x, g).allSatisfy { abs($0 * $1) <= 0.9001 })
        #expect(g[4000] > 0.9999 && g[30000] > 0.9999)
    }

    @Test func noiseIsNormalizedAndFiltersShapeIt() {
        var rng = SeededRNG(seed: 1)
        let pink = SynthDSP.pink(64000, rng: &rng)
        #expect(abs(SynthDSP.rms(pink) - 1) < 0.01)
        // Pink noise has more energy low than high.
        let low = SynthDSP.rms(SynthDSP.filter(pink, .lowpass, 500))
        let high = SynthDSP.rms(SynthDSP.filter(pink, .highpass, 4000))
        #expect(low > high)
    }

    @Test func trimSilenceCutsToTheVoice() {
        let x = [Float](repeating: 0, count: 8000) + tone(0.5) + [Float](repeating: 0, count: 4000)
        let y = SynthDSP.trimSilence(x, margin: 0.01)
        #expect(abs(y.count - SynthDSP.samples(0.52)) <= SynthDSP.samples(0.006))
    }

    @Test func overlapsAreFoundAndMerged() {
        let u: [SyntheticTruth.Utterance] = [
            .init(speaker: "A", track: "Them", start: 0, end: 5, text: "a", kind: .turn),
            .init(speaker: "B", track: "Them", start: 4, end: 8, text: "b", kind: .turn),
            .init(speaker: "C", track: "Them", start: 6, end: 6.5, text: "c", kind: .interjection),
            .init(speaker: "A", track: "Them", start: 9, end: 10, text: "a", kind: .turn),
        ]
        let o = SyntheticTruth.overlaps(of: u)
        #expect(o.count == 2)
        #expect(o[0].start == 4 && o[0].end == 5 && o[0].speakers == ["A", "B"])
        #expect(o[1].start == 6 && o[1].end == 6.5 && o[1].speakers == ["B", "C"])
    }

    @Test func scriptIsSeededAndAddressesPeopleByName() {
        let names = ["Sarah", "Tom", "Megan", "Alex"]
        var a = SeededRNG(seed: 5), b = SeededRNG(seed: 5), c = SeededRNG(seed: 6)
        let la = SyntheticScript.build(pool: SyntheticScript.english, names: names, seconds: 300, rng: &a)
        let lb = SyntheticScript.build(pool: SyntheticScript.english, names: names, seconds: 300, rng: &b)
        let lc = SyntheticScript.build(pool: SyntheticScript.english, names: names, seconds: 300, rng: &c)
        #expect(la.map(\.text) == lb.map(\.text))
        #expect(la.map(\.text) != lc.map(\.text))
        #expect(!la.contains { $0.text.contains("{") })
        // Nobody talks twice in a row, and every name is used.
        #expect(zip(la, la.dropFirst()).allSatisfy { $0.speaker != $1.speaker })
        #expect(names.allSatisfy { n in la.contains { $0.text.contains(n) } })
        // Roughly five minutes of words at about 2.6 words a second.
        let words = la.reduce(0) { $0 + $1.text.split(separator: " ").count }
        #expect((500...900).contains(words))
    }
}
