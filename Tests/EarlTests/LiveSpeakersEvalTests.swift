import FluidAudio
import Foundation
import Testing
@testable import Earl

/// R2-5 evaluation: T-1 meetings played through the live trackers in 100 ms
/// chunks, as the stage gets them, scored against `truth.json`.
///
///     EARL_LIVE_EVAL=1 EARL_EVAL_MODELS=<dir with speaker-diarization/> \
///       [EARL_LIVE_SORTFORMER=<cache dir>] [EARL_LIVE_MEETINGS=<dir of preset-seed folders>] \
///       ./test.sh --filter LiveSpeakersEvalTests
///
/// Option A is the app's tracker with FluidAudio's streaming Sortformer,
/// downloaded into EARL_LIVE_SORTFORMER. Option B (rolling WeSpeaker prints,
/// Support/LiveOptionB.swift) is kept for the comparison.
@Suite(.serialized)
struct LiveSpeakersEvalTests {
    static let env = ProcessInfo.processInfo.environment
    static let enabled = env["EARL_LIVE_EVAL"] == "1" && env["EARL_EVAL_MODELS"] != nil
    static let chunk = 1600 // 100 ms at 16 kHz

    /// One step of a run: the voice the tracker holds as talking.
    struct Step { var time: Double; var face: Int? }

    struct Run {
        var steps: [Step] = []
        /// Face -> when it appeared.
        var faces: [Int: Double] = [:]
        var seconds: Double = 0
    }

    // MARK: Meetings

    static func meetings() throws -> [(name: String, folder: URL)] {
        let presets = (env["EARL_LIVE_PRESETS"] ?? "clean,realistic,hard").split(separator: ",").map(String.init)
        let seeds: [UInt64] = [1, 2]
        let root = env["EARL_LIVE_MEETINGS"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("earl-live-eval")
        var out: [(String, URL)] = []
        for p in presets {
            for s in seeds {
                let folder = root.appendingPathComponent("\(p)-\(s)")
                if !FileManager.default.fileExists(atPath: folder.appendingPathComponent("truth.json").path) {
                    try SyntheticMeeting.make(preset: SyntheticMeeting.Preset(rawValue: p)!, seed: s, in: folder)
                }
                out.append(("\(p)-\(s)", folder))
            }
        }
        return out
    }

    // MARK: Option B

    static func runB(_ audio: [Float], embedder: SpeakerEmbedding, config: OnlineClusters.Config) -> Run {
        let tracker = OptionBTracker(embedder: embedder, config: config)
        var run = Run()
        var i = 0
        let started = Date()
        while i < audio.count {
            let end = min(audio.count, i + chunk)
            tracker.process(Array(audio[i..<end]))
            i = end
            for c in tracker.clusters.faces where run.faces[c.face!] == nil { run.faces[c.face!] = c.confirmedAt ?? tracker.time }
            run.steps.append(Step(time: Double(end) / 16000, face: tracker.mouthVoice))
        }
        run.seconds = Date().timeIntervalSince(started)
        return run
    }

    static func config() -> OnlineClusters.Config {
        var c = OnlineClusters.Config()
        if let x = env["EARL_LIVE_MATCH"].flatMap(Float.init) { c.match = x }
        if let x = env["EARL_LIVE_MERGE"].flatMap(Float.init) { c.merge = x }
        if let x = env["EARL_LIVE_CONFIRM"].flatMap(Int.init) { c.confirmCount = x }
        return c
    }

    // MARK: Option A

    /// Runs the app's tracker with the streaming model, as the stage does.
    static func runA(_ audio: [Float], models: SortformerModels, config: SortformerConfig) -> Run {
        let tracker = LiveSpeakerTracker(diarizer: SortformerStream(models: models, config: config))
        var run = Run()
        var i = 0
        let started = Date()
        while i < audio.count {
            let end = min(audio.count, i + chunk)
            tracker.process(system: Array(audio[i..<end]), mic: [])
            i = end
            for f in tracker.faces.faces where run.faces[f.index] == nil { run.faces[f.index] = f.confirmedAt }
            run.steps.append(Step(time: Double(end) / 16000, face: tracker.mouthVoice))
        }
        run.seconds = Date().timeIntervalSince(started)
        return run
    }

    // MARK: Scoring

    struct Score: CustomStringConvertible {
        var name = ""
        var speakers = 0
        var faces = 0
        var accuracy = 0.0
        var singleSteps = 0
        var firstFace: [String: (wall: Double?, talk: Double?)] = [:]
        var spurious = 0
        var merged: [String] = []
        var medianSwitch: Double?
        var realTime = 0.0

        var description: String {
            let appear = firstFace.keys.sorted().map { id -> String in
                let f = firstFace[id]!
                guard let talk = f.talk else { return "\(id) never" }
                return String(format: "%@ %.1f s talk (%.0f s in)", id, talk, f.wall ?? 0)
            }.joined(separator: ", ")
            return String(format: "%@: %d voices, %d faces (%d spurious, merged: %@); active face right %.1f %% of %d single-talk steps; median identity switch %@; %.3f s per s of audio\n    own face after: %@",
                          name, speakers, faces, spurious, merged.isEmpty ? "none" : merged.joined(separator: " "),
                          accuracy * 100, singleSteps, medianSwitch.map { String(format: "%.1f s", $0) } ?? "–", realTime, appear)
        }
    }

    static func score(_ run: Run, truth: SyntheticTruth, name: String) -> Score {
        let them = truth.utterances.filter { $0.track == "Them" }
        func single(_ t: Double) -> String? {
            let on = them.filter { $0.start <= t && t < $0.end }
            return on.count == 1 ? on[0].speaker : nil
        }
        // Each face stands for the true speaker it's most often active for.
        var votes: [Int: [String: Int]] = [:]
        var truthAt: [String?] = []
        for s in run.steps {
            let t = single(s.time - 0.05)
            truthAt.append(t)
            if let t, let f = s.face { votes[f, default: [:]][t, default: 0] += 1 }
        }
        let mapping = votes.mapValues { $0.max { $0.value < $1.value }!.key }
        var score = Score(name: name)
        score.speakers = Set(them.map(\.speaker)).count
        score.faces = run.faces.count
        let singles = run.steps.indices.filter { truthAt[$0] != nil }
        score.singleSteps = singles.count
        score.accuracy = Double(singles.filter { i in run.steps[i].face.flatMap { mapping[$0] } == truthAt[i] }.count)
            / Double(max(1, singles.count))
        // A speaker's own face: the earliest face mapped to them. Faces beyond one
        // per speaker are spurious; speakers without one were merged into someone.
        var owners: [String: [Int]] = [:]
        for (f, s) in mapping where run.faces[f] != nil { owners[s, default: []].append(f) }
        score.spurious = run.faces.count - owners.count
        for id in Set(them.map(\.speaker)).sorted() {
            let first = them.filter { $0.speaker == id }.map(\.start).min() ?? 0
            guard let face = owners[id]?.min(by: { run.faces[$0]! < run.faces[$1]! }), let at = run.faces[face] else {
                score.firstFace[id] = (nil, nil)
                score.merged.append(id)
                continue
            }
            let talk = them.filter { $0.speaker == id }.reduce(0.0) { $0 + max(0, min($1.end, at) - $1.start) }
            score.firstFace[id] = (at - first, talk)
        }
        // Identity switch: from the start of a turn by a new speaker, how long
        // until the active face is theirs (when they have one).
        var switches: [Double] = []
        let turns = them.filter { $0.kind == .turn }.sorted { $0.start < $1.start }
        for (prev, turn) in zip(turns, turns.dropFirst()) where prev.speaker != turn.speaker {
            guard owners[turn.speaker] != nil else { continue }
            let hit = run.steps.first { $0.time >= turn.start && $0.time <= turn.end && $0.face.flatMap { mapping[$0] } == turn.speaker }
            if let hit, run.faces[hit.face!]! <= turn.start { switches.append(hit.time - turn.start) }
        }
        switches.sort()
        score.medianSwitch = switches.isEmpty ? nil : switches[switches.count / 2]
        score.realTime = run.seconds / (run.steps.last?.time ?? 1)
        return score
    }

    // MARK: Tests

    @Test(.enabled(if: enabled, "Set EARL_LIVE_EVAL=1 and EARL_EVAL_MODELS to run the live stage evaluation"))
    func optionB() throws {
        let repo = URL(fileURLWithPath: Self.env["EARL_EVAL_MODELS"]!).appendingPathComponent("speaker-diarization")
        let started = Date()
        let embedder = try WeSpeakerEmbedder(repoDir: repo)
        embedder.usePLDA = Self.env["EARL_LIVE_PLDA"] != nil
        print("[live] B: model loaded in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
        for m in try Self.meetings() {
            let audio = try SynthDSP.readAudio(m.folder.appendingPathComponent("system-16k.wav"))
            let truth = try SyntheticTruth.load(m.folder.appendingPathComponent("truth.json"))
            let run = Self.runB(audio, embedder: embedder, config: Self.config())
            print("[live] B " + Self.score(run, truth: truth, name: m.name).description)
        }
    }

    /// How alike prints of the same and of different voices are, to set thresholds.
    @Test(.enabled(if: enabled && env["EARL_LIVE_SIMS"] != nil))
    func similarities() throws {
        let repo = URL(fileURLWithPath: Self.env["EARL_EVAL_MODELS"]!).appendingPathComponent("speaker-diarization")
        let embedder = try WeSpeakerEmbedder(repoDir: repo)
        embedder.usePLDA = Self.env["EARL_LIVE_PLDA"] != nil
        let window = Double(Self.env["EARL_LIVE_WINDOW"] ?? "") ?? 1.5
        for m in try Self.meetings() {
            let audio = try SynthDSP.readAudio(m.folder.appendingPathComponent("system-16k.wav"))
            let truth = try SyntheticTruth.load(m.folder.appendingPathComponent("truth.json"))
            var prints: [(String, [Float])] = []
            for u in truth.utterances where u.track == "Them" && u.kind == .turn && u.end - u.start >= window + 0.2 {
                let a = Int((u.start + 0.2) * 16000), n = Int(window * 16000)
                guard a + n <= audio.count else { continue }
                prints.append((u.speaker, try embedder.embed(Array(audio[a..<a + n]), speech: .init(repeating: true, count: n / 160))))
            }
            if Self.env["EARL_LIVE_CENTER"] != nil, let dims = prints.first?.1.count {
                var mean = [Float](repeating: 0, count: dims)
                for p in prints { for k in 0..<dims { mean[k] += p.1[k] / Float(prints.count) } }
                prints = prints.map { ($0.0, zip($0.1, mean).map { $0 - $1 }) }
            }
            var same: [Float] = [], diff: [Float] = []
            for i in prints.indices {
                for j in prints.indices where j > i {
                    let s = OnlineClusters.cosine(prints[i].1, prints[j].1)
                    if prints[i].0 == prints[j].0 { same.append(s) } else { diff.append(s) }
                }
            }
            same.sort(); diff.sort()
            func q(_ a: [Float], _ p: Double) -> String { a.isEmpty ? "-" : String(format: "%.2f", a[Int(Double(a.count - 1) * p)]) }
            print("[live] sims \(m.name): same p10 \(q(same, 0.1)) p50 \(q(same, 0.5)) p90 \(q(same, 0.9)); different p50 \(q(diff, 0.5)) p90 \(q(diff, 0.9)) p99 \(q(diff, 0.99))")
        }
    }

    @Test(.enabled(if: enabled && env["EARL_LIVE_SORTFORMER"] != nil, "Set EARL_LIVE_SORTFORMER to evaluate Sortformer"))
    func optionA() async throws {
        let cache = URL(fileURLWithPath: Self.env["EARL_LIVE_SORTFORMER"]!)
        var config = SortformerConfig.fastV2_1
        if Self.env["EARL_LIVE_PALETTIZED"] != nil { config.precision = .palettized }
        let started = Date()
        let models = try await SortformerModels.loadFromHuggingFace(config: config, cacheDirectory: cache)
        print("[live] A: model loaded in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
        for m in try Self.meetings() {
            let audio = try SynthDSP.readAudio(m.folder.appendingPathComponent("system-16k.wav"))
            let truth = try SyntheticTruth.load(m.folder.appendingPathComponent("truth.json"))
            let run = Self.runA(audio, models: models, config: config)
            print("[live] A " + Self.score(run, truth: truth, name: m.name).description)
        }
    }
}
