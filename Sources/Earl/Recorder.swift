import AppKit
import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Writes one audio track to a WAV file. Pads with silence so the file stays
/// aligned with wall-clock time, even when the stream starts late or has gaps.
final class TrackWriter {
    let url: URL
    private var file: AVAudioFile?
    private var framesWritten: AVAudioFramePosition = 0
    private var firstPTS: CMTime?
    private var initialOffset: Double = 0
    private let recordingStart: DispatchTime
    private var loggedError = false
    private(set) var buffersReceived = 0
    /// R2-5: the live stage's tap. Gets a copy of each buffer after it's written.
    let tap: LiveTap?
    /// When a buffer arrived, in uptime nanoseconds (replaceable in tests).
    var arrivalTime: () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }

    /// Latest input level, 0...1, written on the audio queue and read by the UI.
    private let levelLock = NSLock()
    private var _level: Float = 0
    private var _lastSound: Date?
    var level: Float { levelLock.withLock { _level } }
    /// When this track last carried audible sound.
    var lastSound: Date? { levelLock.withLock { _lastSound } }

    init(url: URL, recordingStart: DispatchTime, tap: LiveTap? = nil) {
        self.url = url
        self.recordingStart = recordingStart
        self.tap = tap
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        guard let desc = sampleBuffer.formatDescription,
              var asbd = desc.audioStreamBasicDescription,
              let format = AVAudioFormat(streamDescription: &asbd) else { return }
        let frames = AVAudioFrameCount(sampleBuffer.numSamples)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        guard status == noErr else { return }
        append(buffer, at: sampleBuffer.presentationTimeStamp)
    }

    /// Writes one buffer captured at `pts` (split out so tests can feed buffers).
    func append(_ buffer: AVAudioPCMBuffer, at pts: CMTime) {
        let format = buffer.format
        let frames = buffer.frameLength
        buffersReceived += 1
        measure(buffer)
        defer { tap?.push(buffer) } // R2-5: after writing, and never waits on analysis

        do {
            if file == nil {
                file = try AVAudioFile(forWriting: url, settings: format.settings,
                                       commonFormat: format.commonFormat, interleaved: format.isInterleaved)
                // Each track uses its own clock for gaps; the track's start is
                // aligned to the recording start by wall-clock arrival time.
                firstPTS = pts
                initialOffset = Double(arrivalTime() - recordingStart.uptimeNanoseconds) / 1e9
            }
            guard let file, let firstPTS else { return }

            let sinceFirst = CMTimeGetSeconds(CMTimeSubtract(pts, firstPTS))
            let expected = AVAudioFramePosition((initialOffset + sinceFirst) * format.sampleRate)
            let gap = expected - framesWritten
            if gap > AVAudioFramePosition(format.sampleRate * 0.05) {
                try writeSilence(frames: gap, format: format, to: file)
            }
            try file.write(from: buffer)
            framesWritten += AVAudioFramePosition(frames)
        } catch {
            if !loggedError {
                NSLog("Earl: failed writing \(url.lastPathComponent): \(error)")
                loggedError = true
            }
        }
    }

    private func measure(_ buffer: AVAudioPCMBuffer) {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += samples[i] * samples[i] }
        let rms = (sum / Float(buffer.frameLength)).squareRoot()
        let db = 20 * log10(max(rms, 1e-7))
        // Map -60 dB...0 dB to 0...1.
        let level = min(1, max(0, (db + 60) / 60))
        levelLock.withLock {
            _level = level
            if db > -50 { _lastSound = Date() }
        }
    }

    private func writeSilence(frames: AVAudioFramePosition, format: AVAudioFormat, to file: AVAudioFile) throws {
        var remaining = frames
        let chunk = AVAudioFrameCount(format.sampleRate)
        guard let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { return }
        for b in UnsafeMutableAudioBufferListPointer(silence.mutableAudioBufferList) {
            if let data = b.mData { memset(data, 0, Int(b.mDataByteSize)) }
        }
        while remaining > 0 {
            let n = AVAudioFrameCount(min(AVAudioFramePosition(chunk), remaining))
            silence.frameLength = n
            try file.write(from: silence)
            framesWritten += AVAudioFramePosition(n)
            remaining -= AVAudioFramePosition(n)
        }
    }

    func close() {
        file = nil // AVAudioFile finalizes the WAV header on deinit
        levelLock.withLock { _level = 0 }
    }
}

/// Records system audio ("Them") and the microphone ("Me") into two separate
/// WAV files using ScreenCaptureKit. No virtual audio driver needed.
final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate {
    private let queue = DispatchQueue(label: "earl.audio")
    private var stream: SCStream?
    private let system: TrackWriter
    private let mic: TrackWriter

    /// Called on a background queue if capture stops unexpectedly.
    var onError: ((Error) -> Void)?

    init(outputDir: URL, live: LiveEngine? = nil) {
        let start = DispatchTime.now()
        system = TrackWriter(url: outputDir.appendingPathComponent("system.wav"), recordingStart: start,
                             tap: live?.systemTap) // R2-5
        mic = TrackWriter(url: outputDir.appendingPathComponent("mic.wav"), recordingStart: start, tap: live?.micTap)
    }

    static func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    func start() async throws {
        if !CGPreflightScreenCaptureAccess() {
            // D-2: not from inside a recording; the setup window asks for it and restarts Earl.
            // Asking puts Earl in System Settings' list, so the switch is there to turn on.
            CGRequestScreenCaptureAccess()
            await MainActor.run { AppDelegate.openOnboarding?() }
            throw PipelineError.message("Finish getting ready first.")
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw PipelineError.message("No display found to attach audio capture to.")
        }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.captureMicrophone = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000
        config.channelCount = 1
        // We only want audio; keep the video side as cheap as possible.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
        queue.sync {
            system.close()
            mic.close()
        }
    }

    /// Current input levels (0...1) for the level meters.
    var levels: (them: Float, me: Float) { (system.level, mic.level) }
    var lastSound: (them: Date?, me: Date?) { (system.lastSound, mic.lastSound) }

    static var microphoneName: String? {
        AVCaptureDevice.default(for: .audio)?.localizedName
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        switch type {
        case .audio: system.append(sampleBuffer)
        case .microphone: mic.append(sampleBuffer)
        default: break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async {
            self.system.close()
            self.mic.close()
        }
        onError?(error)
    }
}
