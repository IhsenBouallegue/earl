import CoreAudio
import Foundation
import Testing
@testable import Earl

/// R2-4: the echo gate's frame classifier on small synthetic signals, the text
/// fallback, and the output device rules. Fast; the Whisper evaluation is
/// EchoEvalTests.
struct EchoFilterTests {
    static let seconds = 30.0
    static var n: Int { SynthDSP.samples(seconds) }

    /// Speech-like noise: talk spurts of 1-3 s with 4-6 syllables a second,
    /// separated by pauses, shaped by a band-pass around `center` Hz.
    static func voice(seed: UInt64, center: Double, level: Float = 0.1) -> (audio: [Float], talking: [Range<Int>]) {
        var rng = SeededRNG(seed: seed)
        var x = [Float](repeating: 0, count: n)
        var talking: [Range<Int>] = []
        var t = rng.uniform(0.3, 1.0)
        while t < seconds - 1 {
            let length = rng.uniform(1, 3), rate = rng.uniform(4, 6)
            let start = SynthDSP.samples(t), end = min(n, SynthDSP.samples(t + length))
            for i in start..<end {
                let s = Double(i - start) / SynthDSP.fs
                let syllable = Float(abs(sin(Double.pi * rate * s)))
                x[i] = (rng.float() * 2 - 1) * syllable
            }
            talking.append(start..<end)
            t += length + rng.uniform(0.6, 1.8)
        }
        let shaped = SynthDSP.filter(SynthDSP.filter(x, .bandpass, center, q: 0.5), .lowpass, 4000)
        return (SynthDSP.scaled(shaped, by: level / max(SynthDSP.rms(shaped, over: talking), 1e-9)), talking)
    }

    /// The call as the mic hears it from laptop speakers: delayed, quieter,
    /// duller and with some room.
    static func echo(of x: [Float], delayMs: Double = 80, gainDb: Double = -20) -> [Float] {
        let room = SynthDSP.reverb(SynthDSP.filter(x, .lowpass, 5000), rt60: 0.3, wet: 0.3)
        return SynthDSP.scaled(SynthDSP.shifted(room, by: SynthDSP.samples(delayMs / 1000)), by: SynthDSP.linear(gainDb))
    }

    static func noise(seed: UInt64, level: Float = 0.0005) -> [Float] {
        var rng = SeededRNG(seed: seed)
        return SynthDSP.scaled(SynthDSP.pink(n, rng: &rng), by: level)
    }

    /// Share of frames inside `ranges` (in samples) for which `test` holds.
    static func share(_ ranges: [Range<Int>], _ count: Int, _ test: (Int) -> Bool) -> Double {
        let frames = Set(ranges.flatMap { r in
            (r.lowerBound / EchoFilter.hop)..<min(count, r.upperBound / EchoFilter.hop)
        })
        guard !frames.isEmpty else { return 0 }
        return Double(frames.filter(test).count) / Double(frames.count)
    }

    // MARK: - Classifier

    @Test func pureEchoIsMuted() {
        let call = Self.voice(seed: 1, center: 900)
        let mic = SynthDSP.sum(Self.echo(of: call.audio), Self.noise(seed: 2))
        let a = EchoFilter.analyze(mic: mic, system: call.audio)
        #expect(a.detected)
        #expect(abs(a.delayMs - 80) <= 20, "delay \(a.delayMs) ms")
        // Where the call talks (shifted by the delay), the mic is echo, and muted.
        let heard = call.talking.map { ($0.lowerBound + 1280)..<($0.upperBound + 1280) }
        #expect(Self.share(heard, a.labels.count) { a.labels[$0] == .echo } > 0.8)
        #expect(Self.share(heard, a.mute.count) { a.mute[$0] } > 0.9)
        #expect(!a.labels.contains(.you) || Double(a.labels.filter { $0 == .you }.count) / Double(a.labels.count) < 0.01)
    }

    @Test func anotherVoiceWithoutEchoIsLeftAlone() {
        let call = Self.voice(seed: 1, center: 900)
        let you = Self.voice(seed: 3, center: 1400)
        let mic = SynthDSP.sum(you.audio, Self.noise(seed: 2))
        let a = EchoFilter.analyze(mic: mic, system: call.audio)
        #expect(!a.detected, "correlation \(a.correlation)")
        #expect(!a.mute.contains(true))
        #expect(Self.share(you.talking, a.labels.count) { a.labels[$0] == .you } > 0.8)
        #expect(!a.labels.contains(.echo))
    }

    @Test func yourVoiceOverTheEchoIsKept() {
        let call = Self.voice(seed: 1, center: 900)
        let you = Self.voice(seed: 4, center: 1400)
        let mic = SynthDSP.sum(SynthDSP.sum(Self.echo(of: call.audio), you.audio), Self.noise(seed: 2))
        let a = EchoFilter.analyze(mic: mic, system: call.audio)
        #expect(a.detected)
        // Every frame of yours is kept, including where you talk over the call.
        #expect(Self.share(you.talking, a.mute.count) { a.mute[$0] } == 0)
        #expect(Self.share(you.talking, a.labels.count) { a.labels[$0] == .you || a.labels[$0] == .both } > 0.8)
        #expect(Self.share(you.talking, a.heardYou.count) { a.heardYou[$0] } > 0.7)
        // Where only the call talks, the echo goes.
        let callOnly = call.talking.map { ($0.lowerBound + 1280)..<($0.upperBound + 1280) }
            .filter { r in !you.talking.contains { $0.overlaps((r.lowerBound - 8000)..<(r.upperBound + 8000)) } }
        if !callOnly.isEmpty {
            #expect(Self.share(callOnly, a.mute.count) { a.mute[$0] } > 0.8)
        }
    }

    @Test func echoMistakenForYouDoesntCountAsHeard() {
        // A louder echo path than the gain estimate learned stays correlated with the call.
        let call = Self.voice(seed: 1, center: 900)
        let mic = SynthDSP.sum(Self.echo(of: call.audio), Self.noise(seed: 2))
        let features = EchoFilter.features(of: mic), system = EchoFilter.features(of: call.audio)
        let lag = [Int](repeating: 8, count: features.count)
        let follows = EchoFilter.localCorrelation(mic: features.bands, system: system.bands, lag: lag, radius: 25)
        let heard = call.talking.map { ($0.lowerBound + 1280)..<($0.upperBound + 1280) }
        #expect(Self.share(heard, follows.count) { follows[$0] >= EchoFilter.followThreshold } > 0.8)
    }

    @Test func cleanWritesAMutedCopyAndKeepsTheOriginal() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("earl-echo-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let call = Self.voice(seed: 1, center: 900)
        let you = Self.voice(seed: 4, center: 1400)
        let micURL = folder.appendingPathComponent("mic-16k.wav"), sysURL = folder.appendingPathComponent("system-16k.wav")
        try SynthDSP.writeWAV(SynthDSP.sum(SynthDSP.sum(Self.echo(of: call.audio), you.audio), Self.noise(seed: 2)), to: micURL)
        try SynthDSP.writeWAV(call.audio, to: sysURL)
        let before = try Data(contentsOf: micURL)

        let result = try #require(try EchoFilter.clean(mic: micURL, system: sysURL))
        defer { try? FileManager.default.removeItem(at: result.cleaned) }
        #expect(try Data(contentsOf: micURL) == before)
        let original = try SynthDSP.readAudio(micURL), cleaned = try SynthDSP.readAudio(result.cleaned)
        #expect(cleaned.count == original.count)
        #expect(result.removedSeconds > 1)
        #expect(!result.youSpans.isEmpty)
        // Your talk spurts come through unchanged (up to 16-bit rounding).
        for r in you.talking {
            let diff = zip(original[r], cleaned[r]).map { abs($0 - $1) }.max() ?? 0
            #expect(diff < 0.001)
        }
    }

    @Test func fadesBetweenMutedAndKeptFrames() {
        let gains = EchoFilter.frameGains([false, false, true, true, false])
        let center = { (f: Int) in f * EchoFilter.hop + EchoFilter.windowLength / 2 }
        #expect(gains(center(1)) == 1)
        #expect(gains(center(2)) == 0)
        #expect(abs(gains(center(1) + EchoFilter.hop / 2) - 0.5) < 0.01)
        #expect(gains(center(3)) == 0)
        #expect(gains(center(4)) == 1)
    }

    @Test func morphologyHelpers() {
        #expect(EchoFilter.closeGaps([true, false, false, true], maxGap: 2) == [true, true, true, true])
        #expect(EchoFilter.closeGaps([true, false, false, false, true], maxGap: 2) == [true, false, false, false, true])
        #expect(EchoFilter.dilate([false, false, true, false, false], before: 1, after: 2) == [false, true, true, true, true])
        #expect(EchoFilter.medianFilter([false, true, false, false, false], radius: 1) == [false, false, false, false, false])
        #expect(EchoFilter.medianFilter([true, true, false, true, true], radius: 1) == [true, true, true, true, true])
    }

    // MARK: - Text fallback

    @Test func editDistanceFindsTheClosestRun() {
        let w = EchoFilter.words
        #expect(EchoFilter.substringEditDistance(w("ship it on friday"), in: w("so we ship it on friday then")) == 0)
        #expect(EchoFilter.substringEditDistance(w("ship it friday"), in: w("so we ship it on friday then")) == 1)
        #expect(EchoFilter.substringEditDistance(w("hello"), in: w("goodbye")) == 1)
    }

    @Test func fuzzyEchoWithoutTheGate() {
        let them = [Turn(start: 10, end: 14, speaker: "Them", text: "We should ship the release on Friday, not Monday.")]
        // Whisper worded the echo a little differently.
        let echo = Turn(start: 10.1, end: 14.1, speaker: "Me", text: "We should ship the release Friday not Monday")
        let mine = Turn(start: 10.5, end: 13, speaker: "Me", text: "I think Monday is better for the team")
        let short = Turn(start: 20, end: 21, speaker: "Me", text: "Sure.")
        let kept = EchoFilter.dropEchoedSegments(them + [echo, mine, short], youSpans: nil)
        #expect(kept.map(\.text) == [them[0].text, mine.text, short.text])
        // A lone "Sure." from the call at the same time is echo.
        let sure = [Turn(start: 20, end: 20.8, speaker: "Them", text: "Sure.")]
        #expect(EchoFilter.dropEchoedSegments(sure + [short], youSpans: nil).map(\.speaker) == ["Them"])
    }

    @Test func afterTheGateOnlyUnheardVerbatimRepeatsGo() {
        let them = [Turn(start: 100, end: 102, speaker: "Them", text: "Claire, what do you think?"),
                    Turn(start: 110, end: 111, speaker: "Them", text: "Sure.")]
        // You, echoing their phrasing, where the gate heard you.
        let yours = Turn(start: 101.5, end: 103.5, speaker: "Me", text: "Frank, what do you think?")
        // Your own "Sure." over theirs, heard by the gate.
        let yourSure = Turn(start: 110.2, end: 111, speaker: "Me", text: "Sure.")
        // An echo the gate let through without hearing you.
        let leak = Turn(start: 100.1, end: 102.1, speaker: "Me", text: "Claire, what do you think?")
        let heard: [ClosedRange<Double>] = [102.0...103.2, 110.3...110.8]
        let kept = EchoFilter.dropEchoedSegments(them + [yours, yourSure, leak], youSpans: heard)
        #expect(kept.contains(yours))
        #expect(kept.contains(yourSure))
        #expect(!kept.contains(leak))
    }

    @Test func buildTurnsPassesTheSpansThrough() {
        let segments = [
            Turn(start: 0, end: 2, speaker: "Them", text: "Sure."),
            Turn(start: 0.1, end: 2, speaker: "Me", text: "Sure."),
        ]
        #expect(Transcriber.buildTurns(from: segments).map(\.speaker) == ["Them"])
        #expect(Transcriber.buildTurns(from: segments, youSpans: [0.2...1.5]).map(\.speaker) == ["Them", "Me"])
    }

    // MARK: - Output device and copy

    @Test func outputDeviceKinds() {
        let fourCC = { (s: String) in s.utf8.reduce(UInt32(0)) { $0 << 8 | UInt32($1) } }
        let builtIn = kAudioDeviceTransportTypeBuiltIn, bluetooth = kAudioDeviceTransportTypeBluetooth
        #expect(OutputDevice.isSpeakers(name: "MacBook Pro Speakers", transport: builtIn, dataSource: fourCC("ispk")) == true)
        #expect(OutputDevice.isSpeakers(name: "External Headphones", transport: builtIn, dataSource: fourCC("hdpn")) == false)
        #expect(OutputDevice.isSpeakers(name: "Built-in Output", transport: builtIn, dataSource: fourCC("hdpn")) == false)
        #expect(OutputDevice.isSpeakers(name: "Ahsan's AirPods Pro", transport: bluetooth, dataSource: 0) == false)
        #expect(OutputDevice.isSpeakers(name: "WH-1000XM5", transport: bluetooth, dataSource: 0) == false)
        #expect(OutputDevice.isSpeakers(name: "Beats Pill", transport: bluetooth, dataSource: 0) == true)
        #expect(OutputDevice.isSpeakers(name: "JBL Flip 6", transport: bluetooth, dataSource: 0) == true)
        #expect(OutputDevice.isSpeakers(name: "LG UltraFine", transport: kAudioDeviceTransportTypeDisplayPort, dataSource: 0) == true)
        // Can't tell: the gate runs and checks for echo itself.
        #expect(OutputDevice.isSpeakers(name: "Scarlett 2i2 USB", transport: kAudioDeviceTransportTypeUSB, dataSource: 0) == nil)
        #expect(OutputDevice.isSpeakers(name: "Mystery 42", transport: bluetooth, dataSource: 0) == nil)
    }

    @Test func copy() {
        #expect(EchoHint.text(usedSpeakers: true).hasPrefix("You're on speakers."))
        #expect(EchoHint.text(usedSpeakers: nil) == "Headphones give the cleanest transcript.")
        #expect(EchoHint.removedText(nil) == nil)
        #expect(EchoHint.removedText(0) == "None found on the mic")
        #expect(EchoHint.removedText(180) == "Removed from 3 min of mic audio")
    }

    @Test func oldMeetingInfoStillLoads() throws {
        let json = #"{"title":"T","titleIsDefault":true,"startedAt":0,"duration":1,"status":"done"}"#
        let info = try JSONDecoder().decode(MeetingInfo.self, from: Data(json.utf8))
        #expect(info.usedSpeakers == nil && info.outputDevice == nil && info.echoRemovedSeconds == nil)
    }
}
