import CoreML
import FluidAudio
import Foundation
@testable import Earl

// R2-5, option B of the live stage (not shipped): rolling WeSpeaker voice
// prints matched to online clusters. Kept here so LiveSpeakersEvalTests can
// reproduce the comparison that picked streaming Sortformer instead.

/// Voices found so far, from a stream of voice prints. A print close to a
/// known voice joins it; anything else starts a candidate, which becomes a
/// face once it has been heard a few times. Faces that converge are merged,
/// and faces that barely talked are dropped.
struct OnlineClusters {
    struct Config {
        /// Cosine similarity at which a print belongs to a voice.
        var match: Float = 0.5
        /// Cosine similarity at which two voices are one.
        var merge: Float = 0.65
        /// Prints needed before a candidate gets a face (at a 0.5 s hop).
        var confirmCount = 3
        /// Candidates not heard for this long are forgotten.
        var candidateExpiry: Double = 8
        /// A face that talked less than `minTalk` seconds is removed after this long.
        var pruneAfter: Double = 30
        var minTalk: Double = 3
        /// The running mean weighs new prints at least this much, so a voice can drift.
        var maxCount = 40
    }

    struct Cluster {
        /// Stable key for the tracker; never reused.
        let key: Int
        /// The voice's number on the stage (0-based), set when it gets a face.
        var face: Int?
        var centroid: [Float]
        var count: Int
        var talk: Double = 0
        var created: Double
        var confirmedAt: Double?
        var lastSeen: Double
    }

    var config = Config()
    private(set) var clusters: [Cluster] = []
    private var nextKey = 0
    private var nextFace = 0

    init(config: Config = Config()) { self.config = config }

    /// Voices with a face, in the order they got it.
    var faces: [Cluster] { clusters.filter { $0.face != nil }.sorted { $0.face! < $1.face! } }

    func cluster(_ key: Int) -> Cluster? { clusters.first { $0.key == key } }

    /// Adds a voice print heard at `time` (seconds) and returns the key of its voice.
    @discardableResult
    mutating func observe(_ embedding: [Float], at time: Double) -> Int {
        let e = Self.normalized(embedding)
        // Faces win ties with candidates, so a known voice isn't split off.
        let scored = clusters.indices.map { ($0, Self.dot(e, clusters[$0].centroid)) }
        let bestFace = scored.filter { clusters[$0.0].face != nil }.max { $0.1 < $1.1 }
        let best = scored.max { $0.1 < $1.1 }
        let pick: (Int, Float)? = if let bestFace, bestFace.1 >= config.match { bestFace } else { best }
        guard let (i, similarity) = pick, similarity >= config.match else {
            clusters.append(Cluster(key: nextKey, centroid: e, count: 1, created: time, lastSeen: time))
            nextKey += 1
            return nextKey - 1
        }
        var c = clusters[i]
        c.count += 1
        let w = 1 / Float(min(c.count, config.maxCount))
        c.centroid = Self.normalized(zip(c.centroid, e).map { $0 + ($1 - $0) * w })
        c.lastSeen = time
        if c.face == nil, c.count >= config.confirmCount {
            c.face = nextFace
            c.confirmedAt = time
            nextFace += 1
        }
        clusters[i] = c
        return c.key
    }

    mutating func addTalk(_ key: Int, seconds: Double) {
        guard let i = clusters.firstIndex(where: { $0.key == key }) else { return }
        clusters[i].talk += seconds
    }

    /// The face closest to `embedding`, if at least `minimum` similar.
    func nearestFace(_ embedding: [Float], minimum: Float) -> Int? {
        let e = Self.normalized(embedding)
        let best = clusters.filter { $0.face != nil }.map { ($0.key, Self.dot(e, $0.centroid)) }.max { $0.1 < $1.1 }
        guard let best, best.1 >= minimum else { return nil }
        return best.0
    }

    /// Merges voices that converged, forgets stale candidates and drops faces
    /// that hardly talked. Returns keys that were merged away, with the key they joined.
    @discardableResult
    mutating func maintain(at time: Double) -> [(from: Int, into: Int)] {
        var merged: [(from: Int, into: Int)] = []
        var changed = true
        while changed {
            changed = false
            outer: for a in clusters.indices {
                for b in clusters.indices where b > a {
                    guard Self.dot(clusters[a].centroid, clusters[b].centroid) >= config.merge else { continue }
                    // Keep the older face (or the one with a face at all).
                    let aRank = clusters[a].face ?? Int.max, bRank = clusters[b].face ?? Int.max
                    let (keep, drop) = aRank <= bRank ? (a, b) : (b, a)
                    var k = clusters[keep]
                    let d = clusters[drop]
                    let total = Float(k.count + d.count)
                    k.centroid = Self.normalized(zip(k.centroid, d.centroid).map {
                        ($0 * Float(k.count) + $1 * Float(d.count)) / total
                    })
                    k.count += d.count
                    k.talk += d.talk
                    k.lastSeen = max(k.lastSeen, d.lastSeen)
                    if k.face == nil, k.count >= config.confirmCount {
                        k.face = nextFace
                        k.confirmedAt = time
                        nextFace += 1
                    }
                    clusters[keep] = k
                    merged.append((d.key, k.key))
                    clusters.remove(at: drop)
                    changed = true
                    break outer
                }
            }
        }
        clusters.removeAll { c in
            if c.face == nil { return time - c.lastSeen > config.candidateExpiry }
            return time - (c.confirmedAt ?? c.created) > config.pruneAfter && c.talk < config.minTalk
        }
        return merged
    }

    static func normalized(_ v: [Float]) -> [Float] {
        let norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return norm > 0 ? v.map { $0 / norm } : v
    }

    static func dot(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return -1 }
        var s: Float = 0
        for i in a.indices { s += a[i] * b[i] }
        return s
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float { dot(normalized(a), normalized(b)) }
}

/// Turns a stretch of 16 kHz audio into a voice print.
protocol SpeakerEmbedding: AnyObject {
    /// `samples` is at most 10 s; `speech` has one flag per 10 ms frame of it,
    /// saying which frames to pool.
    func embed(_ samples: [Float], speech: [Bool]) throws -> [Float]
}

/// R2-2's WeSpeaker model, run directly: FBank features on the CPU, the
/// embedding network on the Neural Engine, with a mask over the frames to pool.
/// Loaded straight from the installed files so nothing is ever downloaded here.
final class WeSpeakerEmbedder: SpeakerEmbedding {
    private let fbank: MLModel
    private let network: MLModel
    /// pyannote's x-vector centering and LDA, the space its PLDA compares voices in.
    private let plda: MLModel
    private let rhoInput: MLMultiArray
    var usePLDA = false
    private let audio: MLMultiArray
    private let weights: MLMultiArray
    private let windowSamples: Int
    private let weightFrames: Int

    init(repoDir: URL) throws {
        let cpu = MLModelConfiguration()
        cpu.computeUnits = .cpuOnly
        fbank = try MLModel(contentsOf: repoDir.appendingPathComponent(ModelNames.OfflineDiarizer.fbankFile), configuration: cpu)
        let all = MLModelConfiguration()
        all.computeUnits = .all
        network = try MLModel(contentsOf: repoDir.appendingPathComponent(ModelNames.OfflineDiarizer.embeddingFile),
                              configuration: all)
        plda = try MLModel(contentsOf: repoDir.appendingPathComponent(ModelNames.OfflineDiarizer.pldaRhoFile), configuration: cpu)
        guard let rhoShape = plda.modelDescription.inputDescriptionsByName["embeddings"]?.multiArrayConstraint?.shape
        else { throw PipelineError.message("The speaker model has unexpected inputs.") }
        rhoInput = try MLMultiArray(shape: rhoShape, dataType: .float32)
        guard let audioShape = fbank.modelDescription.inputDescriptionsByName["audio"]?.multiArrayConstraint?.shape,
              let weightShape = network.modelDescription.inputDescriptionsByName["weights"]?.multiArrayConstraint?.shape
        else { throw PipelineError.message("The speaker model has unexpected inputs.") }
        audio = try MLMultiArray(shape: audioShape, dataType: .float32)
        weights = try MLMultiArray(shape: weightShape, dataType: .float32)
        windowSamples = audio.count
        weightFrames = weights.count
    }

    func embed(_ samples: [Float], speech: [Bool]) throws -> [Float] {
        let n = min(samples.count, windowSamples)
        let a = audio.dataPointer.assumingMemoryBound(to: Float.self)
        a.update(repeating: 0, count: windowSamples)
        samples.withUnsafeBufferPointer { a.update(from: $0.baseAddress!, count: n) }
        // The weights cover the whole window; frames past the audio stay 0.
        let w = weights.dataPointer.assumingMemoryBound(to: Float.self)
        let windowSeconds = Double(windowSamples) / LiveAudio.sampleRate
        for f in 0..<weightFrames {
            let t = (Double(f) + 0.5) * windowSeconds / Double(weightFrames)
            let frame = Int(t / LiveAudio.frameSeconds)
            w[f] = t * LiveAudio.sampleRate < Double(n) && frame < speech.count && speech[frame] ? 1 : 0
        }
        let features = try fbank.prediction(from: MLDictionaryFeatureProvider(dictionary: ["audio": audio]))
        guard let fbankOut = features.featureValue(for: "fbank_features")?.multiArrayValue else {
            throw PipelineError.message("The speaker model gave no features.")
        }
        let out = try network.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "fbank_features": fbankOut, "weights": weights,
        ]))
        guard let e = out.featureValue(for: "embedding")?.multiArrayValue else {
            throw PipelineError.message("The speaker model gave no voice print.")
        }
        let raw = (0..<e.count).map { e[$0].floatValue }
        return usePLDA ? try rho(raw) : raw
    }

    /// The print in PLDA space: raw WeSpeaker prints of different voices are
    /// nearly as alike as prints of the same voice (cosine ≈ 0.86 vs 0.90).
    func rho(_ raw: [Float]) throws -> [Float] {
        let dims = raw.count
        let p = rhoInput.dataPointer.assumingMemoryBound(to: Float.self)
        p.update(repeating: 0, count: rhoInput.count)
        raw.withUnsafeBufferPointer { p.update(from: $0.baseAddress!, count: min(dims, rhoInput.count)) }
        let out = try plda.prediction(from: MLDictionaryFeatureProvider(dictionary: ["embeddings": rhoInput]))
        guard let r = out.featureValue(for: "rho")?.multiArrayValue else {
            throw PipelineError.message("The speaker model gave no voice print.")
        }
        let width = r.shape.last?.intValue ?? r.count
        return (0..<width).map { r[$0].floatValue }
    }

}

/// Option B's tracker: a voice print of the last 1.5 s every 0.5 s of call
/// speech, matched to online clusters.
final class OptionBTracker {
    var config = OnlineClusters.Config()
    var window = 1.5, hop = 0.5, minSpeech = 0.5
    let embedder: SpeakerEmbedding
    private(set) var clusters: OnlineClusters
    private let ring = AudioRing(seconds: 10)
    private var speech: [Bool] = []
    private var remainder: [Float] = []
    private var floor: Float = -70
    private(set) var time = 0.0
    private var nextPrint = 1.5
    private(set) var activeKey: Int?

    init(embedder: SpeakerEmbedding, config: OnlineClusters.Config = .init()) {
        self.embedder = embedder
        self.config = config
        clusters = OnlineClusters(config: config)
    }

    var mouthVoice: Int? {
        let faces = clusters.faces
        if faces.count < 2 { return faces.first?.face ?? 0 }
        return activeKey.flatMap { clusters.cluster($0)?.face }
    }

    func process(_ samples: [Float]) {
        ring.append(samples)
        remainder += samples
        let whole = remainder.count / LiveAudio.frameSamples * LiveAudio.frameSamples
        for db in LiveAudio.frameLevels(remainder[..<whole]) {
            time += LiveAudio.frameSeconds
            floor = db < floor ? max(db, floor - 1) : floor + 0.01
            let s = db > max(floor + 10, -52)
            speech.append(s)
            if s, let activeKey { clusters.addTalk(activeKey, seconds: LiveAudio.frameSeconds) }
        }
        remainder.removeFirst(whole)
        if speech.count > 1000 { speech.removeFirst(speech.count - 600) }
        guard time >= nextPrint else { return }
        nextPrint = max(nextPrint + hop, time)
        let frames = Int(window / LiveAudio.frameSeconds)
        let recent = Array(speech.suffix(frames))
        guard recent.count == frames, Double(recent.filter { $0 }.count) >= minSpeech * Double(frames),
              let e = try? embedder.embed(ring.latest(frames * LiveAudio.frameSamples), speech: recent) else { return }
        let key = clusters.observe(e, at: time)
        if clusters.cluster(key)?.face != nil {
            activeKey = key
        } else if let near = clusters.nearestFace(e, minimum: config.match - 0.1) {
            activeKey = near
        }
        for (from, into) in clusters.maintain(at: time) where activeKey == from { activeKey = into }
        if let k = activeKey, clusters.cluster(k) == nil { activeKey = nil }
    }
}
