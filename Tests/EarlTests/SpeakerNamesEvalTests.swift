import AVFoundation
import Foundation
import Testing
@testable import Earl

/// R2-3 evaluation: realistic synthetic meetings (T-1), in which people address
/// each other by name, run through whisper and diarization, then through the
/// name guesser on the local LLM. Reports precision (named speakers that are
/// right) and coverage (speakers named), with and without an attendee list,
/// and the voice-print similarities behind `SpeakerEdit.carryOverThreshold`.
///
///     EARL_EVAL_NAMES=1 EARL_EVAL_MODELS=<speaker models> ./test.sh --filter SpeakerNamesEvalTests
///
/// Optional: `EARL_EVAL_NAMES_SEEDS` (default 1,2,3), `EARL_EVAL_NAMES_MINUTES`
/// (default 5), `EARL_EVAL_NAMES_CACHE` (a folder that keeps the transcripts
/// between runs, for trying prompts), `EARL_EVAL_NAMES_REUSE` (also reuse the
/// model's answers from the cache), `EARL_EVAL_NAMES_DUMP` (a folder to write
/// the prompts to), `EARL_EVAL_LLM_URL`, `EARL_EVAL_LLM_MODEL`,
/// `EARL_EVAL_NAMES_REASONING=on` (let the model think first, as before R2-7).
@Suite(.serialized)
struct SpeakerNamesEvalTests {
    static let env = ProcessInfo.processInfo.environment
    static let enabled = env["EARL_EVAL_NAMES"] != nil && DiarizationEvalTests.modelsDir != nil
    static let seeds = (env["EARL_EVAL_NAMES_SEEDS"] ?? "1,2,3").split(separator: ",").compactMap { UInt64($0) }
    static let minutes = Double(env["EARL_EVAL_NAMES_MINUTES"] ?? "") ?? 5

    struct Case {
        var seed: UInt64
        var meeting: Meeting
        var truth: SyntheticTruth
        /// Found speaker ID → true name, by the words it covers.
        var names: [String: String]
    }

    struct Tally {
        var named = 0, correct = 0, eligible = 0
        mutating func add(_ other: Tally) { named += other.named; correct += other.correct; eligible += other.eligible }
        var line: String {
            "precision \(DiarizationEvalTests.pct(correct, named)), coverage \(DiarizationEvalTests.pct(named, eligible))"
        }
    }

    @Test(.enabled(if: enabled, "Set EARL_EVAL_NAMES and EARL_EVAL_MODELS to evaluate the name guesser"))
    func guessNames() async throws {
        try await DiarizationEvalTests.offMain { try await Self.run() }
    }

    static func run() async throws {
        var summarizer = Summarizer()
        summarizer.baseURL = env["EARL_EVAL_LLM_URL"] ?? Prefs.defaultLLMURL
        summarizer.model = env["EARL_EVAL_LLM_MODEL"] ?? Prefs.defaultLLMModel
        summarizer.vocabulary = []
        var guesser = SpeakerNameGuesser(summarizer: summarizer)
        // R2-7: thinking is off by default; EARL_EVAL_NAMES_REASONING=on measures it on.
        guesser.reasoning = env["EARL_EVAL_NAMES_REASONING"] == "on"
        print("[names] \(summarizer.model), reasoning \(guesser.reasoning ? "on" : "off")")

        let cache = env["EARL_EVAL_NAMES_CACHE"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        let root = cache ?? FileManager.default.temporaryDirectory.appendingPathComponent("earl-names-\(UUID().uuidString)")
        defer { if cache == nil { try? FileManager.default.removeItem(at: root) } }

        // Totals for the spec's guard rules alone, and with corroboration (what Earl uses).
        var totals: [String: Tally] = [:]
        var same: [Float] = [], different: [Float] = []
        for seed in seeds {
            let c = try await load(seed: seed, in: root)
            let userName = c.truth.speakers.first { $0.track == "Me" }?.name
            let attendees = c.truth.speakers.map { Attendee(name: $0.name, email: nil, isMe: $0.track == "Me") }
            print("[names] seed \(seed): \(c.meeting.speakers.count) voices found for \(c.truth.speakers.count - 1) remote people; "
                  + c.names.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
            for (label, list) in [("with attendees", attendees), ("without attendees", [])] {
                let tag = list.isEmpty ? "without" : "with"
                if let dump = env["EARL_EVAL_NAMES_DUMP"] { // the prompt, for trying variants by hand
                    let prompt = SpeakerNameGuesser.prompt(
                        meeting: c.meeting, candidates: SpeakerNameGuesser.candidates(in: c.meeting),
                        attendees: list, userName: userName, limit: 1_000_000)
                    try prompt.write(toFile: "\(dump)/prompt-\(seed)-\(tag).txt", atomically: true, encoding: .utf8)
                }
                // With EARL_EVAL_NAMES_REUSE, the model's answers are kept next
                // to the cached transcripts, to try the rules without the LLM.
                let saved = c.meeting.folder.appendingPathComponent("answer-\(tag).txt")
                let started = Date()
                let answer: String
                if env["EARL_EVAL_NAMES_REUSE"] != nil, let text = try? String(contentsOf: saved, encoding: .utf8) {
                    answer = text
                } else {
                    answer = try await guesser.ask(meeting: c.meeting, attendees: list, userName: userName)
                    if cache != nil { try answer.write(to: saved, atomically: true, encoding: .utf8) }
                }
                let took = DiarizationEvalTests.fmt(Date().timeIntervalSince(started))
                for corroborate in [false, true] {
                    let guesses = SpeakerNameGuesser.interpret(answer, meeting: c.meeting, attendees: list,
                                                               userName: userName, corroborate: corroborate)
                    let tally = score(guesses, c)
                    let rules = corroborate ? "corroborated" : "guard only"
                    totals["\(label), \(rules)", default: Tally()].add(tally)
                    print("[names] seed \(seed) \(label), \(rules): \(tally.line)" + (corroborate ? "" : ", \(took) s"))
                    for (id, g) in guesses.sorted(by: { $0.key < $1.key }) {
                        let right = c.names[id].map { Self.matches(g.name, $0) } ?? false
                        print("[names]   \(id) → \(g.name) \(right ? "right" : "WRONG, is \(c.names[id] ?? "?")") · \(g.evidence)")
                    }
                }
            }
            let sims = try await voicePrints(c)
            same += sims.same
            different += sims.different
        }
        for (key, tally) in totals.sorted(by: { $0.key < $1.key }) { print("[names] all seeds \(key): \(tally.line)") }
        print("""
            [names] voice prints, same person across the two halves: min \(fmt(same.min())) mean \(fmt(mean(same)))
            [names] voice prints, different people: max \(fmt(different.max())) mean \(fmt(mean(different)))
            """)
        #expect(same.allSatisfy { $0 >= SpeakerEdit.carryOverThreshold })
        #expect(different.allSatisfy { $0 < SpeakerEdit.carryOverThreshold })
    }

    static func fmt(_ x: Float?) -> String { x.map { String(format: "%.2f", $0) } ?? "–" }
    static func mean(_ x: [Float]) -> Float? { x.isEmpty ? nil : x.reduce(0, +) / Float(x.count) }

    static func matches(_ guess: String, _ truth: String) -> Bool {
        guess.split(separator: " ").first.map { $0.lowercased() == truth.lowercased() } ?? false
    }

    static func score(_ guesses: [String: SpeakerNameGuesser.Guess], _ c: Case) -> Tally {
        let candidates = SpeakerNameGuesser.candidates(in: c.meeting)
        var t = Tally()
        t.eligible = candidates.filter { c.names[$0.id] != nil }.count
        t.named = guesses.count
        t.correct = guesses.filter { id, g in c.names[id].map { matches(g.name, $0) } ?? false }.count
        return t
    }

    /// Generates and transcribes a meeting, or reads it back from the cache.
    static func load(seed: UInt64, in root: URL) async throws -> Case {
        let dir = root.appendingPathComponent("realistic-\(seed)-\(Int(minutes))min")
        let store = MeetingStore(root: root)
        let transcript = dir.appendingPathComponent("transcript.json")
        if !FileManager.default.fileExists(atPath: transcript.path) {
            try? FileManager.default.removeItem(at: dir)
            try SyntheticMeeting.make(preset: .realistic, seed: seed, minutes: minutes, in: dir)
            // Only the call track, diarized like the app does it.
            let work = try DiarizationEvalTests.tempDir()
            defer { try? FileManager.default.removeItem(at: work) }
            try FileManager.default.copyItem(at: dir.appendingPathComponent("system-16k.wav"),
                                             to: work.appendingPathComponent("system-16k.wav"))
            var transcriber = Transcriber()
            transcriber.prompt = nil
            transcriber.diarizer = try await DiarizationEvalTests.diarizer()
            transcriber.diarizeMic = false
            let started = Date()
            let output = try await transcriber.transcribe(folder: work) { _ in }
            print("[names] seed \(seed): transcribed in \(DiarizationEvalTests.fmt(Date().timeIntervalSince(started))) s")
            try store.saveTranscript(output.turns, in: dir)
            try store.saveSpeakers(output.speakers, in: dir)
        }
        let truth = try SyntheticTruth.load(dir.appendingPathComponent("truth.json"))
        let turns = try JSONDecoder().decode([Turn].self, from: Data(contentsOf: transcript))
        let speakers = store.loadSpeakers(in: dir)
        let meeting = Meeting(id: "eval", folder: dir, info: MeetingInfo(
            title: "Eval", titleIsDefault: true, startedAt: Date(), duration: truth.duration, status: .done),
            turns: turns, summary: "", files: [], speakers: speakers)

        var themTruth = truth
        themTruth.utterances = truth.utterances.filter { $0.track == "Them" }
        themTruth.overlaps = SyntheticTruth.overlaps(of: themTruth.utterances)
        let segments = turns.map {
            SyntheticScore.Segment(start: $0.start, end: $0.end, track: $0.speaker, speaker: $0.speakerID ?? "none", text: $0.text)
        }
        let mapping = SyntheticScore.score(truth: themTruth, segments: segments).mapping
        var names: [String: String] = [:]
        for s in speakers { if let v = mapping["\(s.track)/\(s.id)"], let name = truth.speaker(v)?.name { names[s.id] = name } }
        return Case(seed: seed, meeting: meeting, truth: truth, names: names)
    }

    /// Voice prints, for the carry-over threshold. Transcribe Again on the same
    /// audio gives identical prints, so this is harsher: the first and second
    /// half of the call audio diarized separately (the same person saying
    /// different things), and different people.
    static func voicePrints(_ c: Case) async throws -> (same: [Float], different: [Float]) {
        let audio = c.meeting.folder.appendingPathComponent("system-16k.wav")
        guard FileManager.default.fileExists(atPath: audio.path) else { return ([], []) }
        let file = try AVAudioFile(forReading: audio, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        let half = samples.count / 2
        let offset = Double(half) / 16000
        var halves: [URL] = []
        for (k, part) in [samples[..<half], samples[half...]].enumerated() {
            let url = c.meeting.folder.appendingPathComponent("half\(k).wav")
            try SynthDSP.writeWAV(Array(part), to: url)
            halves.append(url)
        }
        defer { for url in halves { try? FileManager.default.removeItem(at: url) } }
        let diarizer = try await DiarizationEvalTests.diarizer()
        let runs = [try await diarizer.run(audio: halves[0]), try await diarizer.run(audio: halves[1])]
        let remote = c.truth.utterances.filter { $0.track == "Them" }
        // Diarization voice → true speaker, by overlap.
        func owner(_ d: Diarization, _ index: Int, shift: Double) -> String? {
            var cover: [String: Double] = [:]
            for seg in d.segments where seg.speaker == index {
                for u in remote {
                    let o = min(seg.end + shift, u.end) - max(seg.start + shift, u.start)
                    if o > 0 { cover[u.speaker, default: 0] += o }
                }
            }
            return cover.max { $0.value < $1.value }?.key
        }
        var same: [Float] = [], different: [Float] = []
        let x = runs[0].speakers.map { (owner(runs[0], $0.index, shift: 0), $0.embedding) }
        let y = runs[1].speakers.map { (owner(runs[1], $0.index, shift: offset), $0.embedding) }
        for (ox, ex) in x {
            for (oy, ey) in y where ox != nil && oy != nil && !ex.isEmpty && !ey.isEmpty {
                let s = SpeakerEdit.cosine(ex, ey)
                if ox == oy { same.append(s) } else { different.append(s) }
            }
        }
        print("[names] seed \(c.seed) voice prints across halves: same \(same.map { fmt($0) }), different max \(fmt(different.max()))")
        return (same, different)
    }
}
