import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import Earl

/// R2-5: the live stage's tap, resampling, echo check, faces from voice slots
/// and accessories. The model itself is exercised by LiveSpeakersEvalTests.
struct LiveStageTests {
    // MARK: Ring buffer and tap

    @Test func ringKeepsTheNewestSamplesInOrder() {
        let ring = AudioRing(capacity: 10)
        #expect(ring.latest(4).isEmpty)
        ring.append((1...7).map(Float.init))
        #expect(ring.latest(5) == [3, 4, 5, 6, 7])
        #expect(ring.latest(50) == (1...7).map(Float.init))
        ring.append((8...15).map(Float.init)) // wraps around
        #expect(ring.latest(10) == (6...15).map(Float.init))
        #expect(ring.latest(3) == [13, 14, 15])
        ring.append((100...130).map(Float.init)) // more than the capacity at once
        #expect(ring.latest(10) == (121...130).map(Float.init))
        #expect(ring.totalWritten == 46)
    }

    private func buffer(_ samples: [Float], rate: Double = 48000) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        b.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { b.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        return b
    }

    @Test func tapHandsOverEverythingAndDropsOnlyWhenAnalysisStalls() {
        let tap = LiveTap()
        tap.push(buffer([1, 2, 3]))
        tap.push(buffer([4, 5]))
        var out = tap.drain()
        #expect(out.samples == [1, 2, 3, 4, 5])
        #expect(out.rate == 48000)
        #expect(out.dropped == 0)
        #expect(tap.drain().samples.isEmpty)

        // Nobody drains for 3 s: only the newest 2 s are kept.
        let second = [Float](repeating: 0.1, count: 48000)
        for _ in 0..<3 { tap.push(buffer(second)) }
        out = tap.drain()
        #expect(out.samples.count == 96000)
        #expect(out.dropped == 48000)
    }

    @Test func resamplerStreamsTo16kHz() {
        // 1 s of a 440 Hz tone at 48 kHz, in 10 ms buffers like the capture.
        let rate = 48000.0
        let tone = (0..<48000).map { Float(0.5 * sin(2 * .pi * 440 * Double($0) / rate)) }
        let resampler = Resampler()
        var out: [Float] = []
        for start in stride(from: 0, to: tone.count, by: 480) {
            out += resampler.convert(Array(tone[start..<start + 480]), rate: rate)
        }
        #expect(abs(out.count - 16000) <= 64)
        // Same pitch: zero crossings of 440 Hz over the steady part.
        let steady = Array(out[800..<min(out.count, 15200)])
        let crossings = zip(steady, steady.dropFirst()).filter { ($0 < 0) != ($1 < 0) }.count
        let expected = 2 * 440 * Double(steady.count) / 16000
        #expect(abs(Double(crossings) - expected) < 6)
        let rms = (steady.reduce(0) { $0 + $1 * $1 } / Float(steady.count)).squareRoot()
        #expect(abs(rms - Float(0.5 / 2.0.squareRoot())) < 0.02)
        // 16 kHz passes through untouched.
        #expect(Resampler().convert([0.1, 0.2], rate: 16000) == [0.1, 0.2])
    }

    @Test func frameLevelsAreDecibelsPer10ms() {
        let loud = [Float](repeating: 0.1, count: 320) + [Float](repeating: 0, count: 100)
        let levels = LiveAudio.frameLevels(loud[...])
        #expect(levels.count == 2)
        #expect(abs(levels[0] - -20) < 0.01)
    }

    // MARK: Recording integrity

    /// Writes the same synthetic feed with and without the stage's tap; the
    /// WAV files must be identical.
    @Test func trackWriterOutputIsIdenticalWithTheTap() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("earl-tap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        func write(_ name: String, tap: LiveTap?) throws -> Data {
            let url = dir.appendingPathComponent(name)
            let start = DispatchTime.now()
            let writer = TrackWriter(url: url, recordingStart: start, tap: tap)
            writer.arrivalTime = { start.uptimeNanoseconds + 20_000_000 } // the first buffer lands 20 ms in
            var pts = 0
            for k in 0..<200 {
                let samples = (0..<1024).map { Float(sin(Double(k * 1024 + $0) * 0.01)) * 0.3 }
                writer.append(buffer(samples), at: CMTime(value: CMTimeValue(pts), timescale: 48000))
                // A 0.2 s dropout halfway, which gets padded with silence.
                pts += k == 100 ? 1024 + 9600 : 1024
                if let tap, k % 10 == 0 { _ = tap.drain() }
            }
            writer.close()
            return try Data(contentsOf: url)
        }

        let tap = LiveTap()
        let plain = try write("plain.wav", tap: nil)
        let tapped = try write("tapped.wav", tap: tap)
        #expect(plain.count > 200 * 1024 * 4)
        #expect(plain == tapped)
    }

    // MARK: Echo check

    /// A speech-like level envelope in dB: syllables and pauses.
    private func envelope(_ n: Int, seed: UInt64) -> [Float] {
        var rng = SeededRNG(seed: seed)
        var out: [Float] = []
        var level: Float = -30
        while out.count < n {
            level = Float.random(in: -40 ... -18, using: &rng)
            let length = Int.random(in: 4...14, using: &rng)
            out += [Float](repeating: level, count: length).map { $0 + Float.random(in: -1...1, using: &rng) }
            if Bool.random(using: &rng) { out += [Float](repeating: -70, count: Int.random(in: 2...8, using: &rng)) }
        }
        return Array(out.prefix(n))
    }

    @Test func echoOfTheCallIsRecognised() {
        let n = EchoCheck.historyFrames + 20
        let system = envelope(n, seed: 1)
        // The mic hears the call 60 ms later and 25 dB quieter, over room noise.
        var rng = SeededRNG(seed: 2)
        let echo = (0..<n).map { i in max(system[max(0, i - 6)] - 25, -75) + Float.random(in: -1...1, using: &rng) }
        #expect(EchoCheck.isEcho(mic: echo, system: system))

        // You talking over the call: your own rhythm.
        let you = envelope(n, seed: 3)
        #expect(!EchoCheck.isEcho(mic: you, system: system))
        // A silent call can't echo.
        #expect(!EchoCheck.isEcho(mic: you, system: [Float](repeating: -80, count: n)))
        // Not enough history yet.
        #expect(!EchoCheck.isEcho(mic: Array(echo.prefix(10)), system: Array(system.prefix(10))))
    }

    @Test func independentSpeechRarelyLooksLikeEcho() {
        var hits = 0
        for seed in 0..<200 as Range<UInt64> {
            let n = EchoCheck.historyFrames
            if EchoCheck.isEcho(mic: envelope(n, seed: seed * 2 + 10), system: envelope(n, seed: seed * 2 + 11)) { hits += 1 }
        }
        #expect(hits <= 10) // at most 5 % of 300 ms windows
    }

    // MARK: Faces from voice slots

    /// Frames of slot probabilities: `slot` talks, the others don't.
    private func frame(_ slot: Int?) -> [Float] { (0..<4).map { $0 == slot ? 0.9 : 0.05 } }

    private func talk(_ faces: inout LiveFaces, slot: Int?, from start: Double, seconds: Double) {
        for k in 0..<Int((seconds / 0.08).rounded()) { faces.add(frame(slot), at: start + Double(k) * 0.08, duration: 0.08) }
    }

    @Test func aVoiceGetsAFaceAfterTalkingASecondAndAHalf() {
        var faces = LiveFaces()
        talk(&faces, slot: 2, from: 0, seconds: 1.2)
        #expect(faces.faces.isEmpty)
        talk(&faces, slot: 2, from: 1.2, seconds: 0.4)
        #expect(faces.faces.map(\.index) == [0])
        #expect(faces.faces[0].slot == 2)
        talk(&faces, slot: 0, from: 2, seconds: 3)
        #expect(faces.faces.map(\.index) == [0, 1]) // numbered by arrival, not by slot
        #expect(abs(faces.faces[1].talk - 3.04) < 0.05)
        #expect(faces.faces[1].segments.count == 1)
        #expect(faces.faces[1].segments[0].start == 2)
        faces.setLatest(frame(0))
        #expect(faces.activeFace == 1)
        faces.setLatest(frame(nil)) // silence: the last voice keeps the floor
        #expect(faces.activeFace == 1)
        faces.setLatest(frame(2))
        #expect(faces.activeFace == 0)
    }

    @Test func facesThatBarelyTalkedArePruned() {
        var faces = LiveFaces()
        talk(&faces, slot: 0, from: 0, seconds: 10)
        talk(&faces, slot: 1, from: 10, seconds: 2) // a laugh, a cough
        faces.prune(at: 20)
        #expect(faces.faces.count == 2) // too early to tell
        faces.prune(at: 45)
        #expect(faces.faces.map(\.index) == [0])
        // The slot can come back as a real voice, with a new number.
        talk(&faces, slot: 1, from: 50, seconds: 4)
        #expect(faces.faces.map(\.index) == [0, 2])
    }

    @Test func segmentsJoinAcrossShortGaps() {
        var faces = LiveFaces()
        talk(&faces, slot: 0, from: 0, seconds: 2)
        talk(&faces, slot: nil, from: 2, seconds: 0.16)
        talk(&faces, slot: 0, from: 2.16, seconds: 1)
        talk(&faces, slot: nil, from: 3.16, seconds: 2)
        talk(&faces, slot: 0, from: 5.16, seconds: 1)
        #expect(faces.faces[0].segments.count == 2)
        #expect(abs(faces.faces[0].segments[0].end - 3.16) < 0.05)
    }

    // MARK: Tracker

    /// A fake streaming model: the voice is the pitch of each 80 ms frame.
    final class PitchDiarizer: LiveDiarizing {
        let frameSeconds = 0.08
        private var buffer: [Float] = []
        private var frames = 0

        func feed(_ samples: [Float]) throws -> LiveFrames {
            buffer += samples
            var out = LiveFrames(start: Double(frames) * frameSeconds)
            while buffer.count >= 1280 {
                let f = Array(buffer.prefix(1280))
                buffer.removeFirst(1280)
                frames += 1
                let loud = f.map { $0 * $0 }.reduce(0, +) / 1280 > 1e-4
                let crossings = zip(f, f.dropFirst()).filter { ($0 < 0) != ($1 < 0) }.count
                let hz = Double(crossings) / 2 / 0.08
                let slot: Int? = loud ? (hz < 300 ? 0 : 1) : nil
                out.finalized.append((0..<4).map { $0 == slot ? 0.95 : 0.02 })
            }
            out.latest = out.finalized.last
            return out
        }
    }

    private func tone(_ hz: Double, seconds: Double, amplitude: Double = 0.2) -> [Float] {
        (0..<Int(seconds * 16000)).map { Float(amplitude * sin(2 * .pi * hz * Double($0) / 16000)) }
    }

    private func feed(_ tracker: LiveSpeakerTracker, _ audio: [Float], mic: [Float]? = nil) {
        for start in stride(from: 0, to: audio.count, by: 1600) {
            let end = min(audio.count, start + 1600)
            tracker.process(system: Array(audio[start..<end]), mic: mic.map { Array($0[start..<end]) } ?? [])
        }
    }

    @Test func trackerSplitsThemWhenASecondVoiceTalks() {
        let tracker = LiveSpeakerTracker(diarizer: PitchDiarizer())
        feed(tracker, [Float](repeating: 0, count: 8000))
        #expect(tracker.remoteFaces().map(\.label) == ["Them"])
        #expect(!tracker.remoteTalking)

        feed(tracker, tone(200, seconds: 4))
        #expect(tracker.remoteFaces().map(\.label) == ["Them"])
        #expect(tracker.remoteTalking)
        #expect(tracker.mouthVoice == 0)

        feed(tracker, tone(450, seconds: 4))
        let faces = tracker.remoteFaces()
        #expect(faces.map(\.label) == ["Speaker 1", "Speaker 2"])
        #expect(faces.map(\.isActive) == [false, true])
        #expect(tracker.mouthVoice == 1)
        #expect(faces[0].seconds > 3.5)

        feed(tracker, tone(200, seconds: 1))
        #expect(tracker.mouthVoice == 0) // the identity follows quickly
        #expect(tracker.voices().map(\.avatar) == ["monocle", "glasses"])
        // Segments are on the call audio's clock.
        let first = tracker.voices()[0].segments[0]
        #expect(abs(first.start - 0.5) < 0.1)
    }

    @Test func aModelThatLoadsLateStillKeepsTheClock() {
        let tracker = LiveSpeakerTracker()
        feed(tracker, [Float](repeating: 0, count: 16000 * 3))
        tracker.diarizer = PitchDiarizer()
        feed(tracker, tone(200, seconds: 3))
        #expect(abs((tracker.voices().first?.segments.first?.start ?? 0) - 3) < 0.1)
    }

    @Test func withoutTheModelThereIsOneThem() {
        let tracker = LiveSpeakerTracker()
        feed(tracker, tone(200, seconds: 3) + tone(450, seconds: 3))
        let faces = tracker.remoteFaces()
        #expect(faces.count == 1)
        #expect(faces[0].label == "Them")
        #expect(faces[0].isActive)
        #expect(faces[0].seconds > 5)
        #expect(tracker.mouthVoice == 0)
        #expect(tracker.voices().isEmpty)
    }

    final class BrokenDiarizer: LiveDiarizing {
        let frameSeconds = 0.08
        func feed(_ samples: [Float]) throws -> LiveFrames { throw PipelineError.message("model fell over") }
    }

    @Test func aFailingModelFallsBackToThem() {
        let tracker = LiveSpeakerTracker(diarizer: BrokenDiarizer())
        feed(tracker, tone(200, seconds: 2))
        #expect(tracker.diarizer == nil)
        #expect(tracker.remoteFaces().map(\.label) == ["Them"])
        #expect(tracker.lastError != nil)
    }

    @Test func micEchoDoesNotCountAsYouTalking() {
        // Call audio with a speech-like rhythm; the mic hears it 50 ms later, quieter.
        var call: [Float] = []
        var rng = SeededRNG(seed: 9)
        while call.count < 16000 * 6 {
            let n = Int.random(in: 1600...4800, using: &rng)
            let amp = Double.random(in: 0.05...0.3, using: &rng)
            call += tone(Double.random(in: 150...300, using: &rng), seconds: Double(n) / 16000, amplitude: amp)
            call += [Float](repeating: 0, count: Int.random(in: 800...3200, using: &rng))
        }
        let echo = [Float](repeating: 0, count: 800) + call.dropLast(800).map { $0 * 0.08 }
        let tracker = LiveSpeakerTracker()
        feed(tracker, call, mic: echo)
        #expect(tracker.meTalk < 1)

        // Your own voice on the mic, with its own rhythm, counts.
        let you = LiveSpeakerTracker()
        feed(you, call, mic: tone(180, seconds: Double(call.count) / 16000, amplitude: 0.1))
        #expect(you.meTalk > 4)
    }

    // MARK: Faces

    @Test func accessoriesAreStableAndDistinct() {
        #expect(AvatarLook.accessory(forVoice: 0) == .monocle)
        let first = (0..<8).map { AvatarLook.voice($0) }
        #expect(Set(first.map(\.accessories[0])).count == 8)
        #expect((0..<8).map { AvatarLook.voice($0) } == first) // same voice, same face
        #expect(AvatarLook.voice(8).accessories.count == 2)
        #expect(!AvatarLook.me.accessories.contains(.monocle))
        // No face gets two accessories that fight for the same spot.
        let clashing: [Set<AvatarLook.Accessory>] = [[.monocle, .glasses], [.beanie, .headphones]]
        for i in 0..<64 {
            let set = Set(AvatarLook.voice(i).accessories)
            #expect(set.count == AvatarLook.voice(i).accessories.count)
            #expect(!clashing.contains { $0.isSubset(of: set) })
        }
        // Looks differ between the first voices.
        #expect(Set((0..<24).map { "\(AvatarLook.voice($0))" }).count == 24)
    }

    @Test func mouthFollowsLevelAndStepsWithReduceMotion() {
        #expect(StageMotion.mouthTarget(level: 0.2) == 0) // room noise
        #expect(StageMotion.mouthTarget(level: 0.9) == 1)
        #expect(StageMotion.mouthTarget(level: 0.6) > 0.3)
        let motion = StageMotion()
        _ = motion.tick(0)
        let dt = motion.tick(1.0 / 60)
        let smooth = motion.mouth(1, target: 0.7, dt: dt, reduceMotion: false)
        #expect(smooth > 0.2 && smooth < 0.7) // opens within a few frames
        let stepped = StageMotion().mouth(2, target: 0.4, dt: 0, reduceMotion: true)
        #expect(stepped == 0.5)
        #expect(StageFormat.talk(0.2) == "quiet so far")
        #expect(StageFormat.talk(42) == "42 s")
        #expect(StageFormat.talk(250) == "4 min")
    }

    // MARK: After recording

    private func turn(_ start: Double, _ end: Double, _ id: String?, me: Bool = false) -> Turn {
        Turn(start: start, end: end, speaker: me ? "Me" : "Them", text: "…", speakerID: id)
    }

    @Test func liveFacesLendTheirAccessoriesToOfflineSpeakers() throws {
        let speakers = [
            Speaker(id: "S1", track: "Me", embedding: [], seconds: 30),
            Speaker(id: "S2", track: "Them", embedding: [], seconds: 60),
            Speaker(id: "S3", track: "Them", embedding: [], seconds: 40),
            Speaker(id: "S4", track: "Them", embedding: [], seconds: 0.5),
        ]
        let turns = [turn(0, 10, "S2"), turn(10, 20, "S3"), turn(20, 25, "S2"), turn(25, 25.5, "S4"),
                     turn(0, 30, "S1", me: true)]
        let voices = [
            LiveVoice(index: 0, avatar: "monocle", seconds: 12,
                      segments: [LiveSegment(start: 0.4, end: 9.8), LiveSegment(start: 20.3, end: 24.9)]),
            LiveVoice(index: 1, avatar: "glasses", seconds: 9, segments: [LiveSegment(start: 10.2, end: 19.9)]),
            LiveVoice(index: 2, avatar: "moustache", seconds: 3, segments: [LiveSegment(start: 25.1, end: 25.4)]),
        ]
        let out = LiveVoice.assignAvatars(speakers, turns: turns, from: voices)
        // You keep your own look, and S4 overlaps under a second: no guess.
        #expect(out.map(\.avatar) == [nil, "monocle", "glasses", nil])

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("earl-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(LiveVoice.withAvatars(speakers, turns: turns, in: dir) == speakers) // no live faces saved
        LiveVoice.save(voices, in: dir)
        #expect(LiveVoice.load(in: dir) == voices)
        #expect(LiveVoice.withAvatars(speakers, turns: turns, in: dir) == out)
    }

    @Test func speakersWithoutAvatarsStillLoad() throws {
        let json = #"[{"id":"S1","track":"Them","embedding":[0.1],"seconds":3}]"#
        let speakers = try JSONDecoder().decode([Speaker].self, from: Data(json.utf8))
        #expect(speakers[0].avatar == nil)
    }
}
