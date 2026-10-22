import AVFoundation

// V-1: one real 8-minute call came out with an empty transcript and the
// note "Couldn't tell voices apart: No speech detected in audio". The call
// track was digital silence from start to end: the call's sound was never
// captured, which the note didn't say.
enum SilentTrack {
    /// Below this peak (about −80 dBFS) nothing was captured at all; even
    /// a quiet room or a muted call carries more noise than that.
    static let threshold: Float = 1e-4

    static let note = "The call audio was silent, so only your microphone was transcribed. "
        + "Check that Earl may record the call's sound."

    /// Whether every sample of the file stays under `threshold`. nil when
    /// the file can't be read.
    static func isSilent(_ url: URL) -> Bool? {
        guard let file = try? AVAudioFile(forReading: url),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1 << 16) else { return nil }
        while file.framePosition < file.length {
            do { try file.read(into: buffer) } catch { return nil }
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { break }
            for c in 0..<Int(buffer.format.channelCount) {
                let samples = UnsafeBufferPointer(start: channels[c], count: Int(buffer.frameLength))
                if samples.contains(where: { abs($0) >= threshold }) { return false }
            }
        }
        return true
    }
}
