import Accelerate
import AVFoundation
import Foundation
@testable import Earl

/// Small, seeded DSP helpers for building synthetic test meetings (T-1).
/// Everything works on mono 16 kHz Float samples, the format Whisper and the
/// diarization code see. Heavy loops go through vDSP because tests build in
/// debug mode, where plain Swift loops over millions of samples are slow.
enum SynthDSP {
    static let sampleRate = 16000
    static let fs = Double(sampleRate)

    static func samples(_ seconds: Double) -> Int { Int((seconds * fs).rounded()) }
    static func seconds(_ samples: Int) -> Double { Double(samples) / fs }
    static func linear(_ db: Double) -> Float { Float(pow(10, db / 20)) }
    static func decibels(_ linear: Float) -> Double { 20 * log10(max(Double(linear), 1e-12)) }

    // MARK: - Levels

    static func rms(_ x: [Float], _ range: Range<Int>? = nil) -> Float {
        let r = (range ?? 0..<x.count).clamped(to: 0..<x.count)
        guard !r.isEmpty else { return 0 }
        return x.withUnsafeBufferPointer { vDSP.rootMeanSquare(UnsafeBufferPointer(rebasing: $0[r])) }
    }

    /// RMS over several ranges together, e.g. only where someone speaks.
    static func rms(_ x: [Float], over ranges: [Range<Int>]) -> Float {
        var sum = 0.0, count = 0
        for r in ranges {
            let c = r.clamped(to: 0..<x.count)
            guard !c.isEmpty else { continue }
            let v = Double(rms(x, c))
            sum += v * v * Double(c.count)
            count += c.count
        }
        return count == 0 ? 0 : Float((sum / Double(count)).squareRoot())
    }

    static func peak(_ x: [Float]) -> Float { x.isEmpty ? 0 : vDSP.maximumMagnitude(x) }

    static func scaled(_ x: [Float], by g: Float) -> [Float] { vDSP.multiply(g, x) }

    static func applyGain(_ x: inout [Float], db: Double) { x = vDSP.multiply(linear(db), x) }

    /// Adds `src * gain` into `dst` starting at `offset`, clipped to `dst`'s length.
    static func add(_ src: [Float], into dst: inout [Float], at offset: Int, gain: Float = 1) {
        let start = max(0, offset), skip = start - offset
        let n = min(src.count - skip, dst.count - start)
        guard n > 0 else { return }
        src.withUnsafeBufferPointer { s in
            dst.withUnsafeMutableBufferPointer { d in
                var g = gain
                vDSP_vsma(s.baseAddress! + skip, 1, &g, d.baseAddress! + start, 1, d.baseAddress! + start, 1, vDSP_Length(n))
            }
        }
    }

    static func sum(_ a: [Float], _ b: [Float]) -> [Float] {
        var out = a.count >= b.count ? a : b
        add(a.count >= b.count ? b : a, into: &out, at: 0)
        return out
    }

    /// Delays by `n` samples (negative advances), keeping the length.
    static func shifted(_ x: [Float], by n: Int) -> [Float] {
        var out = [Float](repeating: 0, count: x.count)
        add(x, into: &out, at: n)
        return out
    }

    /// Plays `x` `factor` times faster, like a tape: pitch and tempo both
    /// rise by `factor`. Linear interpolation, low-passed first when speeding
    /// up so nothing folds back above Nyquist.
    static func resampled(_ x: [Float], by factor: Double) -> [Float] {
        guard factor > 0, factor != 1, x.count > 1 else { return x }
        let src = factor > 1 ? filter(filter(x, .lowpass, 7600 / factor), .lowpass, 7600 / factor) : x
        let n = Int(Double(src.count - 1) / factor)
        return (0..<n).map { i in
            let t = Double(i) * factor
            let k = Int(t), f = Float(t - Double(k))
            return k + 1 < src.count ? src[k] * (1 - f) + src[k + 1] * f : src[k]
        }
    }

    // MARK: - Filters

    enum FilterKind { case lowpass, highpass, bandpass }

    /// RBJ cookbook biquad, run through vDSP.
    static func filter(_ x: [Float], _ kind: FilterKind, _ freq: Double, q: Double = 0.707) -> [Float] {
        let w = 2 * Double.pi * freq / fs, cw = cos(w), alpha = sin(w) / (2 * q)
        var b: [Double]
        switch kind {
        case .lowpass: b = [(1 - cw) / 2, 1 - cw, (1 - cw) / 2]
        case .highpass: b = [(1 + cw) / 2, -(1 + cw), (1 + cw) / 2]
        case .bandpass: b = [alpha, 0, -alpha]
        }
        let a0 = 1 + alpha, a = [-2 * cw / a0, (1 - alpha) / a0]
        b = b.map { $0 / a0 }
        guard var bq = vDSP.Biquad(coefficients: b + a, channelCount: 1, sectionCount: 1, ofType: Float.self) else { return x }
        return bq.apply(input: x)
    }

    /// First-order low-pass (a leaky integrator), as a one-section biquad.
    static func onePole(_ x: [Float], pole: Double, gain: Double) -> [Float] {
        guard var bq = vDSP.Biquad(coefficients: [gain, 0, 0, -pole, 0], channelCount: 1, sectionCount: 1,
                                   ofType: Float.self) else { return x }
        return bq.apply(input: x)
    }

    /// Feedback comb y[n] = x[n] + g·y[n−d], computed a block of `d` samples at
    /// a time so each step is one vDSP call.
    static func comb(_ x: [Float], delay d: Int, gain g: Float) -> [Float] {
        var y = x
        feedback(&y, delay: d, gain: g)
        return y
    }

    private static func feedback(_ y: inout [Float], delay d: Int, gain g: Float) {
        guard d > 0 else { return }
        var n = d
        y.withUnsafeMutableBufferPointer { p in
            var gg = g
            while n < p.count {
                let len = min(d, p.count - n)
                vDSP_vsma(p.baseAddress! + n - d, 1, &gg, p.baseAddress! + n, 1, p.baseAddress! + n, 1, vDSP_Length(len))
                n += d
            }
        }
    }

    /// Schroeder all-pass y[n] = −g·x[n] + x[n−d] + g·y[n−d].
    static func allpass(_ x: [Float], delay d: Int, gain g: Float) -> [Float] {
        var y = vDSP.multiply(-g, x)
        add(x, into: &y, at: d)
        feedback(&y, delay: d, gain: g)
        return y
    }

    /// A small Schroeder reverb: four combs in parallel, then two all-passes.
    /// `rt60` is the decay time in seconds, `wet` the reverberant share.
    static func reverb(_ x: [Float], rt60: Double, wet: Float) -> [Float] {
        let combMs = [29.7, 37.1, 41.1, 43.7]
        var tail = [Float](repeating: 0, count: x.count)
        for ms in combMs {
            let d = samples(ms / 1000)
            let g = Float(pow(10, -3 * Double(d) / (rt60 * fs)))
            add(comb(x, delay: d, gain: g), into: &tail, at: 0, gain: 0.25)
        }
        tail = allpass(tail, delay: samples(0.005), gain: 0.7)
        tail = allpass(tail, delay: samples(0.0017), gain: 0.7)
        // Match the tail's level to the input so `wet` means what it says.
        let t = rms(tail), s = rms(x)
        let norm: Float = t > 0 ? s / t : 0
        var out = vDSP.multiply(1 - wet, x)
        add(tail, into: &out, at: 0, gain: wet * norm)
        return out
    }

    /// RMS compressor on 5 ms blocks with attack/release smoothing; the gain is
    /// interpolated per sample so it doesn't click. Levels are in dBFS.
    static func compress(_ x: [Float], thresholdDb: Double, ratio: Double,
                         attack: Double = 0.01, release: Double = 0.15, makeupDb: Double = 0) -> [Float] {
        let block = samples(0.005)
        let blocks = (x.count + block - 1) / block
        guard blocks > 0 else { return x }
        let aCoef = exp(-0.005 / attack), rCoef = exp(-0.005 / release)
        var gains = [Float](repeating: 1, count: blocks + 1)
        var env = 0.0
        for i in 0..<blocks {
            let r = i * block..<min(x.count, (i + 1) * block)
            let level = Double(rms(x, r))
            let c = level > env ? aCoef : rCoef
            env = c * env + (1 - c) * level
            let db = decibels(Float(env))
            let over = max(0, db - thresholdDb)
            gains[i + 1] = linear(-over * (1 - 1 / ratio) + makeupDb)
        }
        gains[0] = gains[1]
        // Ramp from each block's gain to the next.
        var ramp = [Float](repeating: 0, count: blocks * block)
        for i in 0..<blocks {
            ramp.withUnsafeMutableBufferPointer { p in
                var start = gains[i], step = (gains[i + 1] - gains[i]) / Float(block)
                vDSP_vramp(&start, &step, p.baseAddress! + i * block, 1, vDSP_Length(block))
            }
        }
        return vDSP.multiply(x, Array(ramp[0..<x.count]))
    }

    /// A peak limiter's gain curve for signals that must stay in step: per
    /// 1 ms block, just enough to keep the loudest of them under `ceiling`,
    /// held over neighbouring blocks and released over about 50 ms.
    static func limiterGain(for signals: [[Float]], ceiling: Float) -> [Float] {
        let n = signals.map(\.count).max() ?? 0
        let block = samples(0.001)
        let blocks = (n + block - 1) / block
        guard blocks > 0 else { return [] }
        var need = [Float](repeating: 1, count: blocks)
        for x in signals {
            x.withUnsafeBufferPointer { p in
                for b in 0..<blocks where b * block < p.count {
                    let r = b * block..<min(p.count, (b + 1) * block)
                    let pk = vDSP.maximumMagnitude(UnsafeBufferPointer(rebasing: p[r]))
                    if pk > ceiling { need[b] = min(need[b], ceiling / pk) }
                }
            }
        }
        // Reach the needed gain one block early and let go slowly.
        var gains = need
        for b in 0..<blocks - 1 { gains[b] = min(gains[b], need[b + 1]) }
        let release = Float(exp(-1.0 / 50))
        for b in 1..<max(1, blocks) where gains[b] > gains[b - 1] {
            gains[b] = min(gains[b], 1 - (1 - gains[b - 1]) * release)
        }
        var out = [Float](repeating: 1, count: blocks * block)
        out.withUnsafeMutableBufferPointer { p in
            for b in 0..<blocks {
                var start = b == 0 ? gains[0] : gains[b - 1], step = (gains[b] - start) / Float(block)
                vDSP_vramp(&start, &step, p.baseAddress! + b * block, 1, vDSP_Length(block))
            }
        }
        // The ramp arrives at each block's gain at its end; clamp so no sample
        // exceeds what its own block needs.
        for b in 0..<blocks where need[b] < 1 {
            for i in (b * block)..<((b + 1) * block) { out[i] = min(out[i], need[b]) }
        }
        return Array(out.prefix(n))
    }

    // MARK: - Noise and events

    /// Seeded white noise in −1…1.
    static func white(_ n: Int, rng: inout SeededRNG) -> [Float] {
        (0..<n).map { _ in rng.float() * 2 - 1 }
    }

    /// Pink noise: white noise through parallel one-pole filters (an economy
    /// version of Paul Kellet's filter), normalized to RMS 1.
    static func pink(_ n: Int, rng: inout SeededRNG) -> [Float] {
        let w = white(n, rng: &rng)
        var out = vDSP.multiply(0.1848, w)
        for (pole, gain) in [(0.99765, 0.0990460), (0.96300, 0.2965164), (0.57000, 1.0526913)] {
            add(onePole(w, pole: pole, gain: gain), into: &out, at: 0)
        }
        return normalizedRMS(out)
    }

    /// Brown (red) noise: leaky-integrated white noise, normalized to RMS 1.
    static func brown(_ n: Int, rng: inout SeededRNG) -> [Float] {
        normalizedRMS(filter(onePole(white(n, rng: &rng), pole: 0.995, gain: 0.05), .highpass, 20))
    }

    static func normalizedRMS(_ x: [Float]) -> [Float] {
        let r = rms(x)
        return r > 0 ? vDSP.multiply(1 / r, x) : x
    }

    static func sine(_ n: Int, freq: Double, phase: Double = 0) -> [Float] {
        var ramp = [Float](repeating: 0, count: n)
        var start = Float(phase), step = Float(2 * Double.pi * freq / fs)
        vDSP_vramp(&start, &step, &ramp, 1, vDSP_Length(n))
        // Wrap the phase so single precision doesn't lose accuracy on long tracks.
        ramp = ramp.map { $0.truncatingRemainder(dividingBy: 2 * .pi) }
        return vForce.sin(ramp)
    }

    /// A fan: brown rumble plus a slowly wobbling blade tone and its harmonic.
    /// RMS about 1.
    static func fanHum(_ n: Int, rng: inout SeededRNG) -> [Float] {
        var out = vDSP.multiply(0.8, filter(brown(n, rng: &rng), .lowpass, 400))
        let wobble = vDSP.add(1, vDSP.multiply(0.2, sine(n, freq: 0.3)))
        add(vDSP.multiply(sine(n, freq: 118), wobble), into: &out, at: 0, gain: 0.5)
        add(sine(n, freq: 236, phase: 1), into: &out, at: 0, gain: 0.2)
        return normalizedRMS(out)
    }

    /// Typing: short band-passed noise bursts with a fast decay, in bursts of
    /// 5–20 keys at 5–9 keys per second. Returns the track (peak about 1) and
    /// the typing stretches in seconds.
    static func keyboard(_ n: Int, bursts: Int, rng: inout SeededRNG) -> (audio: [Float], spans: [(Double, Double)]) {
        var out = [Float](repeating: 0, count: n)
        var spans: [(Double, Double)] = []
        let clickLen = samples(0.012)
        let decay = (0..<clickLen).map { Float(exp(-Double($0) / Double(samples(0.002)))) }
        let total = seconds(n)
        for b in 0..<bursts {
            // Spread bursts over the meeting, one per equal slice.
            let slice = total / Double(bursts)
            var t = Double(b) * slice + rng.uniform(0.1, 0.6) * slice
            let begin = t
            for _ in 0..<rng.int(5...20) {
                var click = vDSP.multiply(white(clickLen, rng: &rng), decay)
                click = filter(click, .bandpass, rng.uniform(1800, 4200), q: 1.2)
                add(normalizedPeak(click), into: &out, at: samples(t), gain: Float(rng.uniform(0.5, 1)))
                t += 1 / rng.uniform(5, 9)
            }
            spans.append((begin, t))
        }
        return (out, spans)
    }

    static func normalizedPeak(_ x: [Float]) -> [Float] {
        let p = peak(x)
        return p > 0 ? vDSP.multiply(1 / p, x) : x
    }

    // MARK: - Network

    /// Drops 20 ms frames with probability `rate` and conceals each with the
    /// previous output frame, faded further for every frame in a burst, with
    /// short cross-fades at the edges. Returns the audio and the dropped frame
    /// start times.
    static func packetLoss(_ x: [Float], rate: Double, rng: inout SeededRNG) -> (audio: [Float], dropped: [Double]) {
        let frame = samples(0.02), fade = samples(0.0025)
        var out = x
        var dropped: [Double] = []
        var run = 0
        var i = frame
        while i + frame <= x.count {
            if rng.uniform(0, 1) < rate {
                run += 1
                dropped.append(seconds(i))
                let g = Float(pow(0.6, Double(run)))
                var concealed = vDSP.multiply(g, Array(out[(i - frame)..<i]))
                // Cross-fade into and out of the concealed frame.
                for k in 0..<fade {
                    let f = Float(k) / Float(fade)
                    concealed[k] = concealed[k] * f + x[i + k] * (1 - f)
                }
                out.replaceSubrange(i..<(i + frame), with: concealed)
                if i + frame + fade <= x.count {
                    for k in 0..<fade {
                        let f = Float(k) / Float(fade)
                        out[i + frame + k] = out[i + frame - 1] * (1 - f) + x[i + frame + k] * f
                    }
                }
            } else {
                run = 0
            }
            i += frame
        }
        return (out, dropped)
    }

    // MARK: - Alignment

    /// The lag (in samples, within ±`maxLag`) at which `delayed` best matches
    /// `reference`, measured on the loudest `window` seconds.
    static func estimateDelay(reference: [Float], delayed: [Float], maxLag: Int, window: Double = 3) -> Int {
        let w = min(samples(window), reference.count - 2 * maxLag)
        guard w > 0 else { return 0 }
        // Loudest window in 0.25 s steps.
        let step = samples(0.25)
        var best = maxLag, bestEnergy: Float = -1
        var s = maxLag
        while s + w + maxLag <= reference.count {
            let e = rms(reference, s..<(s + w))
            if e > bestEnergy { bestEnergy = e; best = s }
            s += step
        }
        var bestLag = 0, bestScore = -Float.infinity
        reference.withUnsafeBufferPointer { r in
            delayed.withUnsafeBufferPointer { d in
                for lag in -maxLag...maxLag {
                    let start = best + lag
                    guard start >= 0, start + w <= d.count else { continue }
                    var dot: Float = 0
                    vDSP_dotpr(r.baseAddress! + best, 1, d.baseAddress! + start, 1, &dot, vDSP_Length(w))
                    if dot > bestScore { bestScore = dot; bestLag = lag }
                }
            }
        }
        return bestLag
    }

    // MARK: - Codec

    struct CodecResult {
        var audio: [Float]
        /// "opus", or "aac" when afconvert can't encode Opus here.
        var codec: String
        /// The delay the codec added, which was removed from `audio`.
        var delayMs: Double
    }

    /// Encodes with Opus (or AAC as a fallback) through afconvert and decodes
    /// back to 16 kHz. The codec's delay is measured and removed, and the
    /// length is kept, so times in the input still hold in the output.
    static func codecRoundTrip(_ x: [Float], bitrate: Int, workDir: URL) throws -> CodecResult {
        let fm = FileManager.default
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        let input = workDir.appendingPathComponent("codec-in.wav")
        let decoded = workDir.appendingPathComponent("codec-out.wav")
        try writeWAV(x, to: input, float: true)
        defer { for u in [input, decoded] { try? fm.removeItem(at: u) } }

        var codec = "opus"
        var encoded = workDir.appendingPathComponent("codec.caf")
        do {
            try run("/usr/bin/afconvert", ["-f", "caff", "-d", "opus", "-b", "\(bitrate)", input.path, encoded.path])
        } catch {
            codec = "aac"
            encoded = workDir.appendingPathComponent("codec.m4a")
            try run("/usr/bin/afconvert", ["-f", "m4af", "-d", "aac", "-b", "\(max(bitrate, 16000))", input.path, encoded.path])
        }
        defer { try? fm.removeItem(at: encoded) }
        try run("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEF32@16000", "-c", "1", encoded.path, decoded.path])
        var y = try readAudio(decoded)
        if y.count < x.count { y += [Float](repeating: 0, count: x.count - y.count) }
        let lag = estimateDelay(reference: x, delayed: y, maxLag: samples(0.1))
        y = Array(shifted(y, by: -lag).prefix(x.count))
        return CodecResult(audio: y, codec: codec, delayMs: seconds(lag) * 1000)
    }

    // MARK: - Files

    /// Mono 16 kHz WAV, 16-bit (clipped) or 32-bit float.
    static func writeWAV(_ x: [Float], to url: URL, float: Bool = false) throws {
        let bytesPerSample = float ? 4 : 2
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let dataBytes = x.count * bytesPerSample
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + dataBytes))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16)
        u16(float ? 3 : 1); u16(1); u32(UInt32(sampleRate)); u32(UInt32(sampleRate * bytesPerSample))
        u16(UInt16(bytesPerSample)); u16(UInt16(bytesPerSample * 8))
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(dataBytes))
        if float {
            x.withUnsafeBufferPointer { d.append(UnsafeBufferPointer(start: $0.baseAddress, count: $0.count)) }
        } else {
            let clipped = vDSP.clip(vDSP.multiply(32767, x), to: -32768...32767)
            let ints = vDSP.floatingPointToInteger(clipped, integerType: Int16.self, rounding: .towardNearestInteger)
            ints.withUnsafeBufferPointer { d.append(UnsafeBufferPointer(start: $0.baseAddress, count: $0.count)) }
        }
        try d.write(to: url)
    }

    /// Reads a mono 16 kHz file into Float samples.
    static func readAudio(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard format.sampleRate == fs, format.channelCount == 1 else {
            throw PipelineError.message("\(url.lastPathComponent) is not mono 16 kHz")
        }
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0 else { return [] }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return [] }
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }

    /// Cuts leading and trailing silence (below `thresholdDb` relative to the
    /// peak, in 5 ms blocks), keeping a small margin.
    static func trimSilence(_ x: [Float], thresholdDb: Double = -40, margin: Double = 0.01) -> [Float] {
        let block = samples(0.005)
        let limit = peak(x) * linear(thresholdDb)
        var first = -1, last = -1
        var i = 0
        while i < x.count {
            let r = i..<min(x.count, i + block)
            if x.withUnsafeBufferPointer({ vDSP.maximumMagnitude(UnsafeBufferPointer(rebasing: $0[r])) }) > limit {
                if first < 0 { first = i }
                last = r.upperBound
            }
            i += block
        }
        guard first >= 0 else { return [] }
        let m = samples(margin)
        return Array(x[max(0, first - m)..<min(x.count, last + m)])
    }

    @discardableResult
    static func run(_ executable: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard p.terminationStatus == 0 else {
            throw PipelineError.message("\(executable) failed (\(p.terminationStatus)): \(text.prefix(300))")
        }
        return text
    }
}

/// SplitMix64: tiny, fast and stable across Swift versions, unlike relying on
/// the standard library's `random(in:using:)` algorithms.
struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed ^ 0x5DEE_CE66_D1CE_4E5B }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in 0..<1.
    mutating func unit() -> Double { Double(next() >> 11) / Double(UInt64(1) << 53) }
    mutating func float() -> Float { Float(next() >> 40) / Float(1 << 24) }
    mutating func uniform(_ a: Double, _ b: Double) -> Double { a + (b - a) * unit() }
    mutating func int(_ r: ClosedRange<Int>) -> Int { r.lowerBound + Int(next() % UInt64(r.count)) }
    mutating func chance(_ p: Double) -> Bool { unit() < p }
    mutating func pick<T>(_ xs: [T]) -> T { xs[int(0...(xs.count - 1))] }

    mutating func shuffle<T>(_ xs: [T]) -> [T] {
        var a = xs
        guard a.count > 1 else { return a }
        for i in stride(from: a.count - 1, to: 0, by: -1) { a.swapAt(i, int(0...i)) }
        return a
    }
}
