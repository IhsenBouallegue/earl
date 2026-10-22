import Accelerate
import AVFoundation
import CoreAudio
import Foundation

/// R2-4: removes the call's echo from the mic track before Whisper hears it.
///
/// On laptop speakers the mic picks up the call a little later and quieter.
/// Per 10 ms frame and per band, the call audio (system track) predicts how
/// much echo the mic should hear; frames the echo explains are muted in a
/// temporary copy of the mic track, frames with more than the echo (you, or
/// you over the call) are left alone. Works on band energies, not waveforms,
/// so the speaker's and room's filtering only has to be estimated per band.
enum EchoFilter {
    static let sampleRate = 16000.0
    /// 10 ms hop, 32 ms window.
    static let hop = 160
    static let windowLength = 512
    static let frameSeconds = 0.01
    static let bandCount = 24
    /// Lags searched, in frames: a little negative in case the two tracks
    /// start slightly misaligned, up to 400 ms of speaker, room and buffer delay.
    static let lags = -5...40

    enum Label: UInt8 {
        /// Only mic noise.
        case silence
        /// The mic hears only the call.
        case echo
        /// The mic hears you and no call.
        case you
        /// You and the call at once (double talk).
        case both
    }

    struct Analysis {
        var labels: [Label]
        /// Frames muted in the cleaned mic track.
        var mute: [Bool]
        /// Frames where the gate is sure it heard you: more than the echo, and
        /// the mic's envelope doesn't follow the call's.
        var heardYou: [Bool]
        var delayMs: Double
        /// Mean band correlation between the mic and the delayed call at the best lag.
        var correlation: Float
        /// False when the mic doesn't follow the call (headphones, muted speakers):
        /// nothing is muted then.
        var detected: Bool

        var removedSeconds: Double { Double(mute.lazy.filter { $0 }.count) * EchoFilter.frameSeconds }

        /// Where the gate heard you, in seconds.
        func youSpans() -> [ClosedRange<Double>] {
            var spans: [ClosedRange<Double>] = []
            var start: Int?
            for i in 0...heardYou.count {
                let on = i < heardYou.count && heardYou[i]
                if on, start == nil { start = i }
                if !on, let s = start {
                    spans.append(Double(s) * frameSeconds...Double(i) * frameSeconds)
                    start = nil
                }
            }
            return spans
        }
    }

    struct Result {
        /// The cleaned mic track, in the temporary folder. The caller deletes it.
        var cleaned: URL
        var removedSeconds: Double
        /// Where the gate heard you; the text fallback leaves segments there alone.
        var youSpans: [ClosedRange<Double>]
        var delayMs: Double
    }

    // MARK: - Files

    /// Writes a copy of `mic` with the echo-only stretches silenced. Returns nil
    /// when there's no echo to remove (or the files aren't 16 kHz mono); the
    /// original mic track is never changed.
    static func clean(mic: URL, system: URL) throws -> Result? {
        try cleanAndAnalyze(mic: mic, system: system).result
    }

    /// `clean`, also returning the analysis (nil if the files couldn't be analyzed).
    static func cleanAndAnalyze(mic: URL, system: URL) throws -> (result: Result?, analysis: Analysis?) {
        let micFile = try AVAudioFile(forReading: mic)
        let sysFile = try AVAudioFile(forReading: system)
        for f in [micFile, sysFile] where f.processingFormat.sampleRate != sampleRate || f.processingFormat.channelCount != 1 {
            return (nil, nil)
        }
        let micFeatures = try features(of: micFile)
        let sysFeatures = try features(of: sysFile)
        let analysis = analyze(mic: micFeatures, system: sysFeatures)
        guard analysis.detected, analysis.removedSeconds > 0 else { return (nil, analysis) }

        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("earl-mic-clean-\(UUID().uuidString).wav")
        try write(micFile, gains: frameGains(analysis.mute), to: out)
        return (Result(cleaned: out, removedSeconds: analysis.removedSeconds,
                       youSpans: analysis.youSpans(), delayMs: analysis.delayMs), analysis)
    }

    private static func features(of file: AVAudioFile) throws -> Features {
        file.framePosition = 0
        let analyzer = BandAnalyzer()
        let chunk: AVAudioFrameCount = 16000 * 10
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else {
            throw PipelineError.message("Couldn't read \(file.url.lastPathComponent).")
        }
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: chunk)
            guard buffer.frameLength > 0, let data = buffer.floatChannelData?[0] else { break }
            analyzer.feed(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
        }
        return analyzer.finish()
    }

    /// Streams `file` through the per-frame gains into a new WAV of the same format.
    private static func write(_ file: AVAudioFile, gains: (Int) -> Float, to url: URL) throws {
        file.framePosition = 0
        let output = try AVAudioFile(forWriting: url, settings: file.fileFormat.settings,
                                     commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk: AVAudioFrameCount = 16000 * 10
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else { return }
        var position = 0
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: chunk)
            guard buffer.frameLength > 0, let data = buffer.floatChannelData?[0] else { break }
            for i in 0..<Int(buffer.frameLength) { data[i] *= gains(position + i) }
            position += Int(buffer.frameLength)
            try output.write(from: buffer)
        }
    }

    /// Per-sample gain from the per-frame mute mask: a 10 ms linear fade
    /// between frame centers, so muting never clicks.
    static func frameGains(_ mute: [Bool]) -> (Int) -> Float {
        let half = windowLength / 2
        return { sample in
            guard !mute.isEmpty else { return 1 }
            let pos = Double(sample - half) / Double(hop)
            let f = Int(pos.rounded(.down))
            func g(_ i: Int) -> Float { mute[min(max(i, 0), mute.count - 1)] ? 0 : 1 }
            let t = Float(pos - Double(f))
            return g(f) + (g(f + 1) - g(f)) * t
        }
    }

    // MARK: - Analysis

    /// Band energies per frame, band-major: `bands[b][frame]`.
    struct Features {
        var bands: [[Float]]
        var count: Int { bands.first?.count ?? 0 }
    }

    static func features(of samples: [Float]) -> Features {
        let analyzer = BandAnalyzer()
        samples.withUnsafeBufferPointer { analyzer.feed($0) }
        return analyzer.finish()
    }

    static func analyze(mic: [Float], system: [Float]) -> Analysis {
        analyze(mic: features(of: mic), system: features(of: system))
    }

    // Tuning. Energies are powers; ratios below are power ratios.
    /// The echo is predicted this much louder than estimated before a frame
    /// counts as more than echo (6 dB of margin for the estimate's error).
    static let echoMargin: Float = 4
    /// What's left after the echo must be this share of the mic's energy to be you.
    static let youShare: Float = 0.35
    /// Reverb tail of the predicted echo: 60 dB of decay in this many seconds.
    static let tailSeconds = 0.6
    /// Mean band correlation at the best lag above which the mic hears the call.
    static let detectThreshold: Float = 0.15
    /// Local correlation above which the mic follows the call (see `heardYou`).
    static let followThreshold: Float = 0.5

    static func analyze(mic: Features, system: Features) -> Analysis {
        let n = mic.count
        let nb = bandCount
        guard n > 0 else {
            return Analysis(labels: [], mute: [], heardYou: [], delayMs: 0, correlation: 0, detected: false)
        }
        // The system track sized to the mic's frames.
        let sys: [[Float]] = system.bands.map { b in
            b.count >= n ? Array(b[0..<n]) : b + [Float](repeating: 0, count: n - b.count)
        }
        let micNoise = noiseFloor(mic.bands)

        // 1. Delay: where the mic's band envelopes follow the call's best.
        let (lagPerFrame, correlation, globalLag) = estimateLags(mic: mic.bands, system: sys)
        let detected = correlation >= detectThreshold

        // 2. The echo the mic should hear, before its per-band gain: the delayed
        //    call energy with a decaying tail for the room's reverb.
        let decay = Float(pow(10, -6 * frameSeconds / tailSeconds))
        var predicted = [[Float]](repeating: [Float](repeating: 0, count: n), count: nb)
        for b in 0..<nb {
            let s = sys[b]
            var tail: Float = 0
            predicted[b].withUnsafeMutableBufferPointer { e in
                for t in 0..<n {
                    let u = t - lagPerFrame[t]
                    // Neighbouring frames too: the lag is only known to a frame.
                    var v: Float = 0
                    for k in (u - 1)...(u + 1) where k >= 0 && k < n { v = max(v, s[k]) }
                    tail = max(v, tail * decay)
                    e[t] = tail
                }
            }
        }

        // 3. Per-band echo gain: a low percentile of mic over predicted energy
        //    where the call is loud (mostly echo alone, since people rarely talk
        //    over each other for long), then refined on the frames judged echo.
        var gain = [Float](repeating: 0, count: nb)
        for b in 0..<nb {
            let p = predicted[b], m = mic.bands[b], z = micNoise[b]
            let loud = percentile(p.filter { $0 > 0 }, 0.7)
            var ratios: [Float] = []
            for t in 0..<n where p[t] > loud && p[t] > 0 {
                ratios.append(max(0, m[t] - z[t]) / p[t])
            }
            // No echo found: the ratios are your voice over the call, not a path.
            gain[b] = detected ? percentile(ratios, 0.3) : 0
        }
        let initialGain = gain
        var frames = classify(mic: mic.bands, noise: micNoise, predicted: predicted, gain: gain)
        for _ in 0..<2 {
            for b in 0..<nb {
                let p = predicted[b], m = mic.bands[b], z = micNoise[b]
                var ratios: [Float] = []
                for t in 0..<n where frames.labels[t] == .echo && m[t] > 3 * z[t] && p[t] > 0 {
                    ratios.append((m[t] - z[t]) / p[t])
                }
                guard ratios.count > 50 else { continue }
                gain[b] = min(percentile(ratios, 0.75), initialGain[b] * 4)
            }
            frames = classify(mic: mic.bands, noise: micNoise, predicted: predicted, gain: gain)
        }
        let labels = frames.labels

        // 4. Frame decisions: keep you (with some room around your words),
        //    mute the rest of where echo is present.
        let echoPresent = frames.echoPresent
        var keep = labels.map { $0 == .you || $0 == .both }
        keep = medianFilter(keep, radius: 2)                       // drop blips of 20 ms or less
        keep = closeGaps(keep, maxGap: 30)                         // between your words
        keep = dilate(keep, before: 30, after: 30)                 // onsets and trailing sounds
        var mute = (0..<n).map { detected && echoPresent[$0] && !keep[$0] }
        mute = closeGaps(mute, maxGap: 10).enumerated().map { $1 && !keep[$0] }

        // 5. Frames the gate is sure are you, for the text fallback: your
        //    voice over the call doesn't rise and fall with the call; echo the
        //    gate mistook for you (a louder speaker, distortion) does.
        let follows = localCorrelation(mic: mic.bands, system: sys, lag: lagPerFrame, radius: 25)
        let heardYou = (0..<n).map { (labels[$0] == .you || labels[$0] == .both) && follows[$0] < followThreshold }

        return Analysis(labels: labels, mute: mute, heardYou: heardYou,
                        delayMs: Double(globalLag) * frameSeconds * 1000, correlation: correlation, detected: detected)
    }

    /// Mean band correlation of log energies between the mic and the delayed
    /// call over ±`radius` frames, per frame.
    static func localCorrelation(mic: [[Float]], system: [[Float]], lag: [Int], radius: Int) -> [Float] {
        let n = mic.first?.count ?? 0
        var total = [Double](repeating: 0, count: n)
        // Prefix sums of x, y, x², y², xy, reused per band.
        var px = [Double](repeating: 0, count: n + 1), py = px, pxx = px, pyy = px, pxy = px
        for b in 0..<mic.count {
            let x = vForce.log10(vDSP.add(max(percentile(mic[b], 0.05), 1e-12), mic[b]))
            let sysFloor = max(percentile(system[b], 0.05), 1e-12)
            var aligned = [Float](repeating: 0, count: n)
            for t in 0..<n {
                let u = t - lag[t]
                if u >= 0 && u < n { aligned[t] = system[b][u] }
            }
            let y = vForce.log10(vDSP.add(sysFloor, aligned))
            px.withUnsafeMutableBufferPointer { px in
            py.withUnsafeMutableBufferPointer { py in
            pxx.withUnsafeMutableBufferPointer { pxx in
            pyy.withUnsafeMutableBufferPointer { pyy in
            pxy.withUnsafeMutableBufferPointer { pxy in
            total.withUnsafeMutableBufferPointer { total in
                for t in 0..<n {
                    let a = Double(x[t]), c = Double(y[t])
                    px[t + 1] = px[t] + a; py[t + 1] = py[t] + c
                    pxx[t + 1] = pxx[t] + a * a; pyy[t + 1] = pyy[t] + c * c; pxy[t + 1] = pxy[t] + a * c
                }
                for t in 0..<n {
                    let lo = max(0, t - radius), hi = min(n, t + radius + 1)
                    let w = Double(hi - lo)
                    let sx = px[hi] - px[lo], sy = py[hi] - py[lo]
                    let vx = w * (pxx[hi] - pxx[lo]) - sx * sx, vy = w * (pyy[hi] - pyy[lo]) - sy * sy
                    let cov = w * (pxy[hi] - pxy[lo]) - sx * sy
                    if vx > 1e-9, vy > 1e-9 { total[t] += cov / (vx * vy).squareRoot() }
                }
            }}}}}}
        }
        return total.map { Float($0 / Double(max(mic.count, 1))) }
    }

    /// Labels each frame from the mic energy left over after the predicted
    /// echo (with margin) and the noise floor; also whether echo is audible.
    static func classify(mic: [[Float]], noise: [[Float]], predicted: [[Float]], gain: [Float])
        -> (labels: [Label], echoPresent: [Bool]) {
        let n = mic.first?.count ?? 0
        let zeros = [Float](repeating: 0, count: n)
        var pm = zeros, pn = zeros, pe = zeros, residual = zeros
        for b in 0..<mic.count {
            let e = vDSP.multiply(gain[b], predicted[b])
            vDSP.add(pm, mic[b], result: &pm)
            vDSP.add(pn, noise[b], result: &pn)
            vDSP.add(pe, e, result: &pe)
            // max(0, m - margin·e - 2·z)
            let left = vDSP.subtract(mic[b], vDSP.add(multiplication: (e, echoMargin), multiplication: (noise[b], 2)))
            vDSP.add(residual, vDSP.threshold(left, to: 0, with: .clampToThreshold), result: &residual)
        }
        var labels = [Label](repeating: .silence, count: n)
        var present = [Bool](repeating: false, count: n)
        for t in 0..<n {
            let echo = pe[t] > 0.5 * pn[t]
            present[t] = echo
            if residual[t] > youShare * pm[t] && residual[t] > 3 * pn[t] {
                labels[t] = echo && pe[t] > 0.05 * pm[t] ? .both : .you
            } else if echo && pm[t] > 2 * pn[t] {
                labels[t] = .echo
            }
        }
        return (labels, present)
    }

    /// Best lag per frame (from minute-long windows, falling back to the
    /// whole call), the mean band correlation at the global best lag, and that lag.
    static func estimateLags(mic: [[Float]], system: [[Float]]) -> (perFrame: [Int], correlation: Float, lag: Int) {
        let n = mic.first?.count ?? 0
        // Log energies, centred per band, correlated only where the call is audible.
        func logs(_ x: [[Float]]) -> [[Float]] {
            x.map { band in
                let floor = max(percentile(band, 0.1), (band.max() ?? 0) * 1e-9, 1e-12)
                let l = vForce.log10(vDSP.threshold(band, to: floor, with: .clampToThreshold))
                return vDSP.add(-vDSP.mean(l), l)
            }
        }
        let micLog = logs(mic), sysLog = logs(system)
        let micSquared = micLog.map { vDSP.multiply($0, $0) }
        var broadband = [Float](repeating: 0, count: n)
        for band in system { vDSP.add(broadband, band, result: &broadband) }
        let sysFloor = max(percentile(broadband, 0.1), (broadband.max() ?? 0) * 1e-6, 1e-12)
        let active = broadband.map { $0 > sysFloor * 10 ? Float(1) : 0 }
        let masked = sysLog.map { vDSP.multiply(active, $0) }             // m·y
        let maskedSquared = zip(masked, sysLog).map { vDSP.multiply($0, $1) } // m·y²

        // Sums for a Pearson correlation per 30 s block, lag and band, in one
        // pass; windows and the whole call add blocks up. System frame u pairs
        // with mic frame u + lag.
        struct Sums { var xy = 0.0, x = 0.0, xx = 0.0, y = 0.0, yy = 0.0, w = 0.0 }
        let block = 3000
        let blockCount = (n + block - 1) / block
        let lagList = Array(lags)
        var sums = [Sums](repeating: Sums(), count: blockCount * lagList.count * mic.count)
        func dot(_ a: [Float], _ ao: Int, _ b: [Float], _ bo: Int, _ count: Int) -> Double {
            var r: Float = 0
            a.withUnsafeBufferPointer { pa in
                b.withUnsafeBufferPointer { pb in vDSP_dotpr(pa.baseAddress! + ao, 1, pb.baseAddress! + bo, 1, &r, vDSP_Length(count)) }
            }
            return Double(r)
        }
        func sum(_ a: [Float], _ o: Int, _ count: Int) -> Double {
            var r: Float = 0
            a.withUnsafeBufferPointer { vDSP_sve($0.baseAddress! + o, 1, &r, vDSP_Length(count)) }
            return Double(r)
        }
        for k in 0..<blockCount {
            for (li, lag) in lagList.enumerated() {
                let u0 = max(k * block, -lag), u1 = min(min(n, (k + 1) * block), n - lag)
                guard u1 > u0 else { continue }
                let count = u1 - u0
                let w = sum(active, u0, count)
                guard w > 0 else { continue }
                for b in 0..<mic.count {
                    sums[(k * lagList.count + li) * mic.count + b] = Sums(
                        xy: dot(micLog[b], u0 + lag, masked[b], u0, count),
                        x: dot(micLog[b], u0 + lag, active, u0, count),
                        xx: dot(micSquared[b], u0 + lag, active, u0, count),
                        y: sum(masked[b], u0, count), yy: sum(maskedSquared[b], u0, count), w: w)
                }
            }
        }
        func curve(_ blocks: Range<Int>) -> (lag: Int, corr: Float, weight: Double) {
            var best = (lag: 0, corr: -Float.infinity)
            var weight = 0.0
            for (li, lag) in lagList.enumerated() {
                var total = 0.0
                var w = 0.0
                for b in 0..<mic.count {
                    var s = Sums()
                    for k in blocks {
                        let t = sums[(k * lagList.count + li) * mic.count + b]
                        s.xy += t.xy; s.x += t.x; s.xx += t.xx; s.y += t.y; s.yy += t.yy; s.w += t.w
                    }
                    w = s.w
                    let den = ((s.w * s.xx - s.x * s.x) * (s.w * s.yy - s.y * s.y)).squareRoot()
                    if den > 0 { total += (s.w * s.xy - s.x * s.y) / den }
                }
                weight = max(weight, w)
                guard w > 100 else { continue }
                let corr = Float(total / Double(mic.count))
                if corr > best.corr { best = (lag, corr) }
            }
            return (best.lag, best.corr.isFinite ? best.corr : 0, weight)
        }

        let global = curve(0..<blockCount)
        var perFrame = [Int](repeating: global.lag, count: n)
        // Minute-long windows, half overlapping: the delay can drift a little
        // over a call (buffer gaps, device changes).
        if blockCount >= 4 {
            var centers: [(center: Int, lag: Int)] = []
            for k in 0..<(blockCount - 1) {
                let c = curve(k..<(k + 2))
                let trusted = c.weight > 1000 && c.corr >= max(detectThreshold, global.corr * 0.6)
                centers.append(((k + 1) * block, trusted ? c.lag : global.lag))
            }
            // Median of three neighbours so one odd window doesn't jump.
            let smoothed = centers.indices.map { i -> Int in
                let near = centers[max(0, i - 1)...min(centers.count - 1, i + 1)].map(\.lag).sorted()
                return near[near.count / 2]
            }
            var ci = 0
            for t in 0..<n {
                while ci + 1 < centers.count, abs(centers[ci + 1].center - t) < abs(centers[ci].center - t) { ci += 1 }
                perFrame[t] = smoothed[ci]
            }
        }
        return (perFrame, global.corr, global.lag)
    }

    /// Mic noise floor per band and frame: a low percentile over 30 s blocks,
    /// then the lowest of the neighbouring blocks, so a long stretch of speech
    /// or echo never passes for the floor.
    static func noiseFloor(_ bands: [[Float]]) -> [[Float]] {
        let block = 3000
        return bands.map { band in
            let n = band.count
            guard n > 0 else { return [] }
            let blocks = stride(from: 0, to: n, by: block).map { percentile(Array(band[$0..<min(n, $0 + block)]), 0.05) }
            let floors = blocks.indices.map { i in
                max(blocks[max(0, i - 2)...min(blocks.count - 1, i + 2)].min() ?? 0, 1e-12)
            }
            return (0..<n).map { floors[$0 / block] }
        }
    }

    // MARK: - Helpers

    /// From an even sample of at most 20 000 values: close enough, and an
    /// hour-long track isn't sorted two dozen times.
    static func percentile(_ x: [Float], _ p: Double) -> Float {
        guard !x.isEmpty else { return 0 }
        let step = max(1, x.count / 20000)
        let sorted = (step == 1 ? x : stride(from: 0, to: x.count, by: step).map { x[$0] }).sorted()
        return sorted[min(sorted.count - 1, max(0, Int(Double(sorted.count - 1) * p)))]
    }

    static func medianFilter(_ x: [Bool], radius: Int) -> [Bool] {
        guard !x.isEmpty else { return x }
        var ones = 0
        var out = [Bool](repeating: false, count: x.count)
        // Running count over the window [i - radius, i + radius].
        for i in 0..<min(radius, x.count) where x[i] { ones += 1 }
        for i in 0..<x.count {
            if i + radius < x.count, x[i + radius] { ones += 1 }
            if i - radius - 1 >= 0, x[i - radius - 1] { ones -= 1 }
            let size = min(x.count - 1, i + radius) - max(0, i - radius) + 1
            out[i] = ones * 2 > size
        }
        return out
    }

    /// Fills runs of false no longer than `maxGap` between two trues.
    static func closeGaps(_ x: [Bool], maxGap: Int) -> [Bool] {
        var out = x
        var lastTrue: Int?
        for i in x.indices where x[i] {
            if let l = lastTrue, i - l - 1 <= maxGap, i - l > 1 {
                for j in (l + 1)..<i { out[j] = true }
            }
            lastTrue = i
        }
        return out
    }

    static func dilate(_ x: [Bool], before: Int, after: Int) -> [Bool] {
        var out = x
        for i in x.indices where x[i] {
            for j in max(0, i - before)...min(x.count - 1, i + after) { out[j] = true }
        }
        return out
    }
}

/// Band energies of 32 ms Hann-windowed frames every 10 ms, fed in chunks.
final class BandAnalyzer {
    private let n = EchoFilter.windowLength
    private let hop = EchoFilter.hop
    private let setup: FFTSetup
    private let window: [Float]
    /// First FFT bin of each band, plus one past the last.
    private let edges: [Int]
    private var pending: [Float] = []
    private var bands: [[Float]]
    private var real: [Float], imag: [Float], windowed: [Float], power: [Float]

    init() {
        setup = vDSP_create_fftsetup(9, FFTRadix(kFFTRadix2))!
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: n, isHalfWindow: false)
        // Mel-spaced bands from 100 Hz to 8 kHz, at least one bin each.
        func mel(_ f: Double) -> Double { 2595 * log10(1 + f / 700) }
        func hz(_ m: Double) -> Double { 700 * (pow(10, m / 2595) - 1) }
        let binHz = EchoFilter.sampleRate / Double(n)
        var e: [Int] = []
        for i in 0...EchoFilter.bandCount {
            let f = hz(mel(100) + (mel(8000) - mel(100)) * Double(i) / Double(EchoFilter.bandCount))
            var bin = Int((f / binHz).rounded())
            if let last = e.last { bin = max(bin, last + 1) }
            e.append(min(bin, n / 2 + 1))
        }
        edges = e
        bands = [[Float]](repeating: [], count: EchoFilter.bandCount)
        real = [Float](repeating: 0, count: n / 2)
        imag = [Float](repeating: 0, count: n / 2)
        windowed = [Float](repeating: 0, count: n)
        power = [Float](repeating: 0, count: n / 2 + 1)
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    func feed(_ samples: UnsafeBufferPointer<Float>) {
        pending.append(contentsOf: samples)
        var start = 0
        while start + n <= pending.count {
            frame(at: start)
            start += hop
        }
        pending.removeFirst(start)
    }

    /// Pads the tail with silence so the last samples get a frame too.
    func finish() -> EchoFilter.Features {
        if !pending.isEmpty {
            let tail = pending.count
            pending += [Float](repeating: 0, count: n)
            var start = 0
            while start < tail {
                frame(at: start)
                start += hop
            }
            pending = []
        }
        return EchoFilter.Features(bands: bands)
    }

    private func frame(at start: Int) {
        pending.withUnsafeBufferPointer { p in
            vDSP_vmul(p.baseAddress! + start, 1, window, 1, &windowed, 1, vDSP_Length(n))
        }
        real.withUnsafeMutableBufferPointer { r in
            imag.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                windowed.withUnsafeBufferPointer { w in
                    w.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, 9, FFTDirection(FFT_FORWARD))
                power[0] = r[0] * r[0]
                power[n / 2] = i[0] * i[0]
                for k in 1..<(n / 2) { power[k] = r[k] * r[k] + i[k] * i[k] }
            }
        }
        for b in 0..<EchoFilter.bandCount {
            var sum: Float = 0
            for k in edges[b]..<edges[b + 1] { sum += power[k] }
            bands[b].append(sum)
        }
    }
}

// MARK: - Copy

enum EchoHint {
    /// The recording view's footer.
    static func text(usedSpeakers: Bool?) -> String {
        usedSpeakers == true
            ? "You're on speakers. Earl removes the echo, but headphones give the cleanest transcript."
            : "Headphones give the cleanest transcript."
    }

    /// The Details tab's echo line; nil when the gate didn't run.
    static func removedText(_ seconds: Double?) -> String? {
        guard let seconds else { return nil }
        return seconds < 1 ? "None found on the mic" : "Removed from \(Format.duration(seconds)) of mic audio"
    }
}

// MARK: - Output device

/// The default output device at recording start, and whether the mic can hear it.
struct OutputDevice: Equatable {
    var name: String
    /// True for speakers, false for headphones, nil when the kind of device
    /// doesn't tell (a USB interface, a virtual device, an unknown Bluetooth
    /// name). Only false skips the echo gate; it checks for echo itself.
    var isSpeakers: Bool?

    static func current() -> OutputDevice? {
        var device = AudioObjectID(kAudioObjectUnknown)
        guard get(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, &device),
              device != kAudioObjectUnknown else { return nil }
        var cfName: Unmanaged<CFString>?
        guard get(device, kAudioObjectPropertyName, &cfName), let name = cfName?.takeRetainedValue() as String? else { return nil }
        var transport: UInt32 = 0
        _ = get(device, kAudioDevicePropertyTransportType, &transport)
        var source: UInt32 = 0
        _ = get(device, kAudioDevicePropertyDataSource, &source, scope: kAudioDevicePropertyScopeOutput)
        return OutputDevice(name: name, isSpeakers: isSpeakers(name: name, transport: transport, dataSource: source))
    }

    static func isSpeakers(name: String, transport: UInt32, dataSource: UInt32) -> Bool? {
        let lower = name.lowercased()
        let headphones = ["headphone", "headset", "airpods", "earpods", "beats", "buds", "earbuds", "wh-", "wf-",
                          "quietcomfort", "qc35", "qc45", "jabra", "plantronics", "poly ", "shokz", "aftershokz"]
        let speakers = ["speaker", "speak ", "pill", "soundlink", "homepod", "sonos", "boom", "jbl", "bose home", "soundbar"]
        // Speaker words first: "Beats Pill" and "Jabra Speak" are speakers.
        if speakers.contains(where: lower.contains) { return true }
        if headphones.contains(where: lower.contains) { return false }
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn:
            // Built-in output switches data source when something is plugged into the jack.
            if dataSource == fourCC("hdpn") { return false }
            return true
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeAirPlay:
            return true
        default:
            return nil
        }
    }

    private static func fourCC(_ s: String) -> UInt32 {
        s.utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }

    private static func get<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout T,
                               scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(object, &address) else { return false }
        var size = UInt32(MemoryLayout<T>.size)
        return withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0) == noErr
        }
    }
}

// MARK: - Text fallback

extension EchoFilter {
    /// The last safety net: drops "Me" segments that repeat what "Them" said
    /// at the same time. `youSpans` is where the signal step heard you (nil
    /// when it didn't run); segments there stay, so your own "sure" over the
    /// call isn't taken for its echo.
    static func dropEchoedSegments(_ segments: [Turn], youSpans: [ClosedRange<Double>]?) -> [Turn] {
        let them = segments.filter { $0.speaker == "Them" }.sorted { $0.start < $1.start }
        return segments.filter { seg in
            guard seg.speaker == "Me" else { return true }
            guard let spans = youSpans else { return !isEcho(seg, them: them) }
            // After the gate, what's left is mostly you. Only a segment where
            // the gate heard almost none of you, and that repeats the call word
            // for word, goes: people echo each other's phrasing ("Claire, what
            // do you think?" then "Frank, what do you think?").
            let heard = spans.reduce(0.0) { $0 + max(0, min(seg.end, $1.upperBound) - max(seg.start, $1.lowerBound)) }
            guard heard < 0.15 else { return true }
            return !isEcho(seg, them: them, maxDistance: 0)
        }
    }

    /// Whether a "Me" segment reads like the "Them" speech around it: the edit
    /// distance between its words and the closest run of words said on the
    /// call within 1.5 s, relative to its length, weighted by how much of the
    /// segment the call covers in time. Short segments must match exactly.
    /// `maxDistance` caps the edits allowed regardless of length.
    static func isEcho(_ seg: Turn, them: [Turn], maxDistance: Int = .max) -> Bool {
        let mine = words(seg.text)
        guard !mine.isEmpty else { return false }
        let near = them.filter { $0.start < seg.end + 1.5 && seg.start < $0.end + 1.5 }
        let theirs = near.flatMap { words($0.text) }
        guard !theirs.isEmpty else { return false }
        let distance = substringEditDistance(mine, in: theirs)
        guard distance <= maxDistance else { return false }
        // Time overlap with 0.5 s of slack for Whisper's timestamps.
        let duration = max(seg.end - seg.start, 0.1)
        let covered = near.reduce(0.0) { sum, t in
            sum + max(0, min(seg.end, t.end + 0.5) - max(seg.start, t.start - 0.5))
        }
        let overlap = min(1, covered / duration)
        if mine.count < 3 { return distance == 0 && overlap >= 0.5 }
        let similarity = (1 - Double(distance) / Double(mine.count)) * (0.5 + 0.5 * overlap)
        return similarity >= 0.6
    }

    /// Fewest word edits turning `a` into some contiguous run of `b`.
    static func substringEditDistance(_ a: [String], in b: [String]) -> Int {
        guard !a.isEmpty else { return 0 }
        guard !b.isEmpty else { return a.count }
        // Row i: cost of matching a[0..<i] ending at each position of b; the
        // run may start anywhere in b, so row 0 is free.
        var prev = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            var row = [Int](repeating: i, count: b.count + 1)
            for j in 1...b.count {
                row[j] = min(prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1), prev[j] + 1, row[j - 1] + 1)
            }
            prev = row
        }
        return prev.min() ?? a.count
    }

    static func words(_ s: String) -> [String] {
        s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }
}
