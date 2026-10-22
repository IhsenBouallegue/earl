import AVFoundation
import Foundation
import Testing
@testable import Earl

struct AudioPlayerTests {
    // MARK: Seconds to frames

    @Test func secondsToFrames() {
        #expect(PlaybackMath.frame(at: 0, sampleRate: 16000, length: 160_000) == 0)
        #expect(PlaybackMath.frame(at: 2.5, sampleRate: 16000, length: 160_000) == 40_000)
        #expect(PlaybackMath.frame(at: 1.00003, sampleRate: 16000, length: 160_000) == 16_000)
    }

    @Test func framesAreClampedToTheFile() {
        #expect(PlaybackMath.frame(at: -3, sampleRate: 16000, length: 160_000) == 0)
        #expect(PlaybackMath.frame(at: 60, sampleRate: 16000, length: 160_000) == 160_000)
        #expect(PlaybackMath.frame(at: .nan, sampleRate: 16000, length: 160_000) == 0)
        #expect(PlaybackMath.frame(at: 1, sampleRate: 0, length: 160_000) == 0)
    }

    @Test func turnsStartOneSecondEarly() {
        #expect(PlaybackMath.startTime(forTurnAt: 12.4) == 11.4)
        #expect(PlaybackMath.startTime(forTurnAt: 0.3) == 0)
    }

    // MARK: Position and rate

    @Test func positionAddsTheSeekOffset() {
        #expect(PlaybackMath.position(offset: 30, sampleTime: 16000, sampleRate: 16000) == 31)
        // Before the scheduled start the node reports negative times.
        #expect(PlaybackMath.position(offset: 30, sampleTime: -800, sampleRate: 16000) == 30)
    }

    @Test func playerClockIsMediaTimeAtAnyRate() {
        // At 2× the node renders 32000 frames in one wall second: two seconds of meeting.
        #expect(PlaybackMath.position(offset: 0, sampleTime: 32000, sampleRate: 16000, rate: 2) == 2)
    }

    @Test func latencyIsScaledByRate() {
        // 0.1 s of output latency hides 0.1 s of meeting at 1×, 0.2 s at 2×.
        let at1 = PlaybackMath.position(offset: 10, sampleTime: 16000, sampleRate: 16000, latency: 0.1, rate: 1)
        let at2 = PlaybackMath.position(offset: 10, sampleTime: 16000, sampleRate: 16000, latency: 0.1, rate: 2)
        #expect(abs(at1 - 10.9) < 1e-9)
        #expect(abs(at2 - 10.8) < 1e-9)
        // Never earlier than where playback started.
        #expect(PlaybackMath.position(offset: 10, sampleTime: 800, sampleRate: 16000, latency: 0.1, rate: 2) == 10)
    }

    @Test func rateLabels() {
        #expect(PlaybackMath.rates.map(PlaybackMath.rateLabel) == ["1×", "1.25×", "1.5×", "2×"])
    }

    // MARK: Current turn

    @Test func currentTurnLookup() {
        let starts: [Double] = [0.5, 4, 4, 9.2, 20]
        #expect(PlaybackMath.turnIndex(starts: starts, at: 0) == nil)
        #expect(PlaybackMath.turnIndex(starts: starts, at: 0.5) == 0)
        #expect(PlaybackMath.turnIndex(starts: starts, at: 3.99) == 0)
        #expect(PlaybackMath.turnIndex(starts: starts, at: 4) == 2) // the later of two turns starting together
        #expect(PlaybackMath.turnIndex(starts: starts, at: 9.19) == 2)
        #expect(PlaybackMath.turnIndex(starts: starts, at: 9.2) == 3)
        #expect(PlaybackMath.turnIndex(starts: starts, at: 500) == 4)
        #expect(PlaybackMath.turnIndex(starts: [], at: 3) == nil)
    }

    @Test func currentTurnLookupMatchesLinearScan() {
        let starts = (0..<200).map { Double($0) * 1.7 + Double($0 % 3) * 0.1 }.sorted()
        for time in stride(from: -1.0, through: 350, by: 0.37) {
            let expected = starts.lastIndex { $0 <= time }
            #expect(PlaybackMath.turnIndex(starts: starts, at: time) == expected)
        }
    }

    // MARK: Loading

    @MainActor
    @Test func loadsBothTracksAndSeeksWhilePaused() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("earl-player-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try writeSilence(folder.appendingPathComponent("system-16k.wav"), seconds: 3)
        try writeSilence(folder.appendingPathComponent("mic-16k.wav"), seconds: 5)

        let turns = [Turn(start: 0.5, end: 2, speaker: "Them", text: "Hi"),
                     Turn(start: 2.5, end: 4, speaker: "Me", text: "Hello")]
        let meeting = Meeting(id: folder.lastPathComponent, folder: folder, info: MeetingInfo(
            title: "T", titleIsDefault: true, startedAt: Date(), duration: 5, status: .done),
            turns: turns, summary: "",
            files: [MeetingFile(name: "system-16k.wav", bytes: 1), MeetingFile(name: "mic-16k.wav", bytes: 1)])
        #expect(MeetingPlayer.canPlay(meeting))

        let player = MeetingPlayer()
        player.load(meeting: meeting)
        #expect(player.isLoaded)
        #expect(abs(player.duration - 5) < 0.01) // the longer track
        #expect(player.currentTurnID == nil)

        player.seek(to: 3)
        #expect(player.currentTime == 3)
        #expect(player.currentTurnID == turns[1].id)
        player.skip(by: -10)
        #expect(player.currentTime == 0)
        player.seek(to: 99)
        #expect(player.currentTime == player.duration)

        MeetingPlayer.stopAll()
        #expect(!player.isLoaded)
    }

    @Test func noPlayableAudioWithoutThe16kFiles() {
        let meeting = Meeting(id: "x", folder: URL(fileURLWithPath: "/tmp/x"), info: MeetingInfo(
            title: "T", titleIsDefault: true, startedAt: Date(), duration: 5, status: .done),
            turns: [], summary: "", files: [MeetingFile(name: "system.wav", bytes: 1),
                                            MeetingFile(name: "transcript.json", bytes: 1)])
        #expect(!MeetingPlayer.canPlay(meeting))
    }

    private func writeSilence(_ url: URL, seconds: Double) throws {
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000,
                                       AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                                       AVLinearPCMIsFloatKey: false]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let frames = AVAudioFrameCount(seconds * 16000)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames))
        buffer.frameLength = frames
        try file.write(from: buffer)
    }
}
