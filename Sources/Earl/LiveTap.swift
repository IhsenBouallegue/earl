import AVFoundation
import Foundation

// R2-5: the live audio tap behind the speaker stage. The audio queue only
// copies samples into a small inbox; resampling and analysis happen on the
// stage's own queue, so recording never waits on them.

/// Hands audio from the capture queue to the analysis queue. `push` is the
/// only call made on the audio queue: a copy into a bounded inbox under a lock
/// that the other side holds just long enough to swap the inbox out. If
/// analysis falls behind, the oldest samples are dropped from the inbox, never
/// from the recording.
final class LiveTap: @unchecked Sendable {
    /// Beyond this much unread audio, analysis has stalled and old samples go.
    static let maxInboxSeconds = 2.0

    private let lock = NSLock()
    private var inbox: [Float] = []
    private var spare: [Float] = []
    private var rate: Double = 48000
    private var dropped = 0

    init() {
        inbox.reserveCapacity(Int(48000 * Self.maxInboxSeconds))
        spare.reserveCapacity(Int(48000 * Self.maxInboxSeconds))
    }

    /// Called on the audio queue with each captured buffer (first channel only).
    func push(_ buffer: AVAudioPCMBuffer) {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        let n = Int(buffer.frameLength)
        let sampleRate = buffer.format.sampleRate
        lock.lock()
        if sampleRate != rate {
            // A new format: what's left in the inbox was at the old rate.
            inbox.removeAll(keepingCapacity: true)
            rate = sampleRate
        }
        let limit = Int(rate * Self.maxInboxSeconds)
        let overflow = inbox.count + n - limit
        if overflow > 0 {
            let drop = min(overflow, inbox.count)
            inbox.removeFirst(drop)
            dropped += drop
        }
        inbox.append(contentsOf: UnsafeBufferPointer(start: samples, count: min(n, limit)))
        lock.unlock()
    }

    /// Takes everything pushed since the last call, at the capture rate.
    func drain() -> (samples: [Float], rate: Double, dropped: Int) {
        lock.lock()
        swap(&inbox, &spare)
        let rate = rate
        let dropped = dropped
        self.dropped = 0
        lock.unlock()
        let out = spare
        spare.removeAll(keepingCapacity: true)
        return (out, rate, dropped)
    }
}

/// The last few seconds of one track at 16 kHz mono, oldest first. Lock
/// protected, so a reader on another thread always sees whole appends.
final class AudioRing: @unchecked Sendable {
    let capacity: Int
    private var storage: [Float]
    private var head = 0 // next write position
    private var written = 0
    private let lock = NSLock()

    init(capacity: Int) {
        self.capacity = max(1, capacity)
        storage = [Float](repeating: 0, count: self.capacity)
    }

    convenience init(seconds: Double = 10, sampleRate: Double = LiveAudio.sampleRate) {
        self.init(capacity: Int(seconds * sampleRate))
    }

    /// Samples appended since the ring was made (including overwritten ones).
    var totalWritten: Int { lock.withLock { written } }

    func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        lock.withLock {
            // Only the newest `capacity` samples can survive.
            let source = samples.count > capacity ? Array(samples.suffix(capacity)) : samples
            var i = 0
            while i < source.count {
                let n = min(source.count - i, capacity - head)
                storage.replaceSubrange(head..<head + n, with: source[i..<i + n])
                head = (head + n) % capacity
                i += n
            }
            written += samples.count
        }
    }

    /// The newest `count` samples (fewer if the ring holds fewer), oldest first.
    func latest(_ count: Int) -> [Float] {
        lock.withLock {
            let n = min(count, capacity, written)
            guard n > 0 else { return [] }
            let start = (head - n + capacity) % capacity
            if start + n <= capacity { return Array(storage[start..<start + n]) }
            return Array(storage[start..<capacity]) + Array(storage[0..<(start + n - capacity)])
        }
    }
}

enum LiveAudio {
    static let sampleRate: Double = 16000
    /// Level frames of 10 ms, for voice activity and the echo check.
    static let frameSamples = 160
    static let frameSeconds = 0.01

    /// dBFS of each whole 10 ms frame in `samples`; a partial frame at the end is ignored.
    static func frameLevels(_ samples: ArraySlice<Float>) -> [Float] {
        var out: [Float] = []
        out.reserveCapacity(samples.count / frameSamples)
        var i = samples.startIndex
        while i + frameSamples <= samples.endIndex {
            var sum: Float = 0
            for k in i..<i + frameSamples { sum += samples[k] * samples[k] }
            out.append(10 * log10(max(sum / Float(frameSamples), 1e-10)))
            i += frameSamples
        }
        return out
    }
}

/// Streams mono audio at any rate to 16 kHz with `AVAudioConverter`, keeping
/// the filter state between calls so chunks join without clicks.
final class Resampler {
    private var converter: AVAudioConverter?
    private var inputRate: Double = 0
    private let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: LiveAudio.sampleRate,
                                       channels: 1, interleaved: false)!

    func convert(_ samples: [Float], rate: Double) -> [Float] {
        guard !samples.isEmpty, rate > 0 else { return [] }
        if rate == LiveAudio.sampleRate { return samples }
        if converter == nil || rate != inputRate,
           let input = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false) {
            converter = AVAudioConverter(from: input, to: output)
            inputRate = rate
        }
        guard let converter,
              let inBuffer = AVAudioPCMBuffer(pcmFormat: converter.inputFormat, frameCapacity: AVAudioFrameCount(samples.count))
        else { return [] }
        inBuffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { inBuffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }

        let capacity = AVAudioFrameCount(Double(samples.count) * LiveAudio.sampleRate / rate) + 64
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return [] }
        var fed = false
        var error: NSError?
        converter.convert(to: outBuffer, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return inBuffer
        }
        guard error == nil, let data = outBuffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: data, count: Int(outBuffer.frameLength)))
    }
}

/// Tells whether the microphone is mostly hearing the call through the
/// speakers: its level envelope then follows the call audio's, a few tens of
/// milliseconds late. Your own voice doesn't follow the call's rhythm.
enum EchoCheck {
    /// How much history the check looks at: 300 ms, plus room for the delay.
    static let windowFrames = 30
    static let maxLagFrames = 15
    static var historyFrames: Int { windowFrames + maxLagFrames }

    /// `mic` and `system` are 10 ms frame levels in dBFS, oldest first, the
    /// newest frames aligned. Needs `historyFrames` of each.
    static func isEcho(mic: [Float], system: [Float], threshold: Float = 0.85) -> Bool {
        guard mic.count >= historyFrames, system.count >= historyFrames else { return false }
        let micWindow = Array(mic.suffix(windowFrames))
        // Nothing to confuse: the call is quiet, or the mic hears nothing.
        guard (system.suffix(historyFrames).max() ?? -100) > -50, (micWindow.max() ?? -100) > -60 else { return false }
        let sys = Array(system.suffix(historyFrames))
        var best: Float = -1
        for lag in 0...maxLagFrames {
            // The mic at frame t against the call at frame t - lag.
            let end = sys.count - lag
            best = max(best, correlation(micWindow, Array(sys[(end - windowFrames)..<end])))
        }
        return best >= threshold
    }

    /// Pearson correlation; 0 when either side is flat.
    static func correlation(_ a: [Float], _ b: [Float]) -> Float {
        let n = Float(min(a.count, b.count))
        guard n > 1 else { return 0 }
        let ma = a.reduce(0, +) / n, mb = b.reduce(0, +) / n
        var ab: Float = 0, aa: Float = 0, bb: Float = 0
        for (x, y) in zip(a, b) {
            ab += (x - ma) * (y - mb)
            aa += (x - ma) * (x - ma)
            bb += (y - mb) * (y - mb)
        }
        guard aa > 1e-3, bb > 1e-3 else { return 0 }
        return ab / (aa * bb).squareRoot()
    }
}
