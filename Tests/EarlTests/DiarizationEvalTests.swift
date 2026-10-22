import Foundation
import Testing
@testable import Earl

/// R2-2 evaluation on synthetic meetings (T-1): the call track of a
/// `SyntheticMeeting` goes through the real pipeline (whisper, diarization and
/// turn assignment, as the app runs it for "Them") and `SyntheticScore` grades
/// it. Skipped unless `EARL_EVAL_MODELS` points at a folder for the speaker
/// model (downloaded there if missing). Run it with tools/eval-diarization.sh.
///
/// - `clean` (always, when enabled): the `clean` preset, seed 1, with targets.
/// - `presetMatrix`: every preset in `EARL_EVAL_PRESETS` × seed in `EARL_EVAL_SEEDS`,
///   measured and described, no targets.
/// - `oneHour` (`EARL_EVAL_LONG`): timing on an hour of audio.
///
/// `EARL_EVAL_CACHE` keeps the meetings and whisper's output in a folder, so
/// later runs only redo the diarization: that's how the knobs below are tuned.
@Suite(.serialized) // one at a time, so the timings aren't shared
struct DiarizationEvalTests {
    static let env = ProcessInfo.processInfo.environment
    static let modelsDir = env["EARL_EVAL_MODELS"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    static let whisperModel = env["EARL_EVAL_WHISPER_MODEL"] ?? Prefs.defaultWhisperModel
    static let cacheDir = env["EARL_EVAL_CACHE"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    static let minutes = env["EARL_EVAL_MINUTES"].flatMap(Double.init) ?? 5
    static let presets = (env["EARL_EVAL_PRESETS"] ?? "").split(separator: ",")
        .compactMap { SyntheticMeeting.Preset(rawValue: String($0)) }
    static let seeds = (env["EARL_EVAL_SEEDS"] ?? "1").split(separator: ",").compactMap { UInt64(String($0)) }

    static func diarizer() async throws -> Diarizer {
        var diarizer = Diarizer(modelsDir: modelsDir!)
        // Knobs for tuning the clustering.
        if let x = env["EARL_EVAL_THRESHOLD"].flatMap(Double.init) { diarizer.config.clustering.threshold = x }
        if let x = env["EARL_EVAL_FA"].flatMap(Double.init) { diarizer.config.clustering.warmStartFa = x }
        if let x = env["EARL_EVAL_FB"].flatMap(Double.init) { diarizer.config.clustering.warmStartFb = x }
        if let x = env["EARL_EVAL_NUM"].flatMap(Int.init) { diarizer.config.clustering.numSpeakers = x }
        if let x = env["EARL_EVAL_REEMBED"].flatMap(Double.init) {
            diarizer.config.zeroVoteReembed = .init(enabled: x > 0, minDurationSeconds: x)
        }
        if let x = env["EARL_EVAL_MINSEG"].flatMap(Double.init) { diarizer.config.embedding.minSegmentDurationSeconds = x }
        if let x = env["EARL_EVAL_STEP"].flatMap(Double.init) { diarizer.config.segmentation.stepRatio = x }
        if let x = env["EARL_EVAL_MINGAP"].flatMap(Double.init) { diarizer.config.postProcessing.minGapDurationSeconds = x }
        if let x = env["EARL_EVAL_MINON"].flatMap(Double.init) { diarizer.config.segmentation.minDurationOn = x }
        if let x = env["EARL_EVAL_MINOFF"].flatMap(Double.init) { diarizer.config.segmentation.minDurationOff = x }
        if env["EARL_EVAL_OVERLAP"] != nil { diarizer.config.embedding.excludeOverlap = false }
        if env["EARL_EVAL_OVERLAP_SEGMENTS"] != nil { diarizer.config.postProcessing.exclusiveSegments = false }
        if env["EARL_EVAL_UNCONSTRAINED"] != nil { diarizer.config.clustering.constrainedAssignment = false }
        // Small-voice consolidation: "0" turns it off, "1" on with the defaults.
        if let x = env["EARL_EVAL_CONSOLIDATE"] {
            diarizer.consolidation = x == "0" ? nil : diarizer.consolidation ?? .init()
        }
        if diarizer.consolidation != nil {
            if let x = env["EARL_EVAL_SMALL"].flatMap(Double.init) { diarizer.consolidation!.smallSeconds = x }
            if let x = env["EARL_EVAL_SMALLSIM"].flatMap(Double.init) { diarizer.consolidation!.minSimilarity = x }
            if let x = env["EARL_EVAL_FOLD"].flatMap(Double.init) { diarizer.consolidation!.foldSeconds = x > 0 ? x : nil }
        }
        if !diarizer.isInstalled {
            let started = Date()
            try await diarizer.download { _ in }
            print("[eval] downloaded speaker model in \(fmt(Date().timeIntervalSince(started))) s, \(diarizer.installedBytes) bytes")
        }
        return diarizer
    }

    static func fmt(_ x: Double) -> String { String(format: "%.1f", x) }
    static func pct(_ a: Int, _ b: Int) -> String { String(format: "%.1f %%", 100 * Double(a) / Double(max(1, b))) }

    static func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("earl-eval-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Swift Testing may run the test on the main thread, where
    /// `Process.waitUntilExit` never sees the process end.
    static func offMain(_ body: @escaping @Sendable () async throws -> Void) async throws {
        try await Task.detached(operation: body).value
    }

    // MARK: - One meeting

    /// The meeting, from the cache when it's there.
    static func meeting(_ preset: SyntheticMeeting.Preset, seed: UInt64, minutes: Double, in scratch: URL) throws
        -> SyntheticMeeting {
        let name = "\(preset.rawValue)-seed\(seed)-\(fmt(minutes))min"
        let folder = (cacheDir ?? scratch).appendingPathComponent(name, isDirectory: true)
        let truthURL = folder.appendingPathComponent("truth.json")
        if FileManager.default.fileExists(atPath: truthURL.path),
           FileManager.default.fileExists(atPath: folder.appendingPathComponent("system-16k.wav").path) {
            return SyntheticMeeting(folder: folder, truth: try SyntheticTruth.load(truthURL))
        }
        let started = Date()
        let made = try SyntheticMeeting.make(preset: preset, seed: seed, minutes: minutes, in: folder)
        print("[eval] generated \(name) in \(fmt(Date().timeIntervalSince(started))) s")
        return made
    }

    struct Result {
        var preset: String
        var seed: UInt64
        var audioSeconds: Double
        var trueSpeakers: Int
        var turns: [Turn]
        var speakersFound: Int
        /// Talk time of each found voice, as saved in speakers.json.
        var speakerSeconds: [Double]
        var report: SyntheticScore.Report
        /// Whisper and diarization side by side, as the app runs them; nil when whisper's output came from the cache.
        var totalSeconds: Double?
        var diarizationSeconds: Double

        /// Distinct true voices that some found voice stands for.
        var coveredSpeakers: Int { Set(report.mapping.filter { $0.key != "Them/none" }.values).count }
        /// Found voices beyond one per covered true voice (a voice split in two, or noise).
        var extraSpeakers: Int { speakersFound - coveredSpeakers }
        /// True voices with no found voice of their own (merged into another).
        var mergedSpeakers: Int { trueSpeakers - coveredSpeakers }
    }

    /// Runs the call track of `meeting` through whisper and diarization and
    /// scores the "Them" words. With a cache, whisper's output is kept next to
    /// the meeting and reused, and only the diarization and assignment rerun.
    static func evaluate(_ meeting: SyntheticMeeting, diarizer: Diarizer) async throws -> Result {
        let language = ["german", "backchannel"].contains(meeting.truth.preset) ? "de" : "en"
        let cachedJSON = cacheDir == nil ? nil
            : meeting.folder.appendingPathComponent("whisper-system-\(URL(fileURLWithPath: whisperModel).lastPathComponent).json")
        var turns: [Turn]
        var speakers: [Speaker]
        var total: Double?
        var diarization: Double
        if let cachedJSON, FileManager.default.fileExists(atPath: cachedJSON.path) {
            // The same steps as Transcriber.transcribe for a diarized track.
            let words = try Transcriber.parsePhrases(cachedJSON, speaker: "Them")
            let started = Date()
            let result = try await diarizer.run(audio: meeting.system)
            diarization = Date().timeIntervalSince(started)
            var segments: [Turn] = []
            for (turn, voice) in SpeakerAssignment.assign(words.phrases, to: result) {
                var turn = turn
                turn.speakerID = voice.map { "system#\($0)" }
                segments.append(turn)
            }
            var voices: [String: (track: String, embedding: [Float], seconds: Double)] = [:]
            for v in result.speakers { voices["system#\(v.index)"] = ("Them", v.embedding, v.seconds) }
            (turns, speakers) = SpeakerAssignment.number(Transcriber.buildTurns(from: segments), voices: voices)
        } else {
            // Only the call track: the app diarizes "Them" and not the mic.
            let work = try tempDir()
            defer { try? FileManager.default.removeItem(at: work) }
            try FileManager.default.copyItem(at: meeting.system, to: work.appendingPathComponent("system-16k.wav"))
            var transcriber = Transcriber()
            transcriber.modelPath = whisperModel
            transcriber.language = language
            transcriber.prompt = nil
            transcriber.diarizer = diarizer
            transcriber.diarizeMic = false
            let started = Date()
            let output = try await transcriber.transcribe(folder: work) { _ in }
            total = Date().timeIntervalSince(started)
            diarization = output.diarizationSeconds ?? 0
            (turns, speakers) = (output.turns, output.speakers)
            if let cachedJSON {
                try? FileManager.default.copyItem(at: work.appendingPathComponent("whisper-system.json"), to: cachedJSON)
            }
        }

        var truth = meeting.truth
        truth.utterances = truth.utterances.filter { $0.track == "Them" }
        truth.overlaps = SyntheticTruth.overlaps(of: truth.utterances)
        let segments = turns.map {
            SyntheticScore.Segment(start: $0.start, end: $0.end, track: $0.speaker, speaker: $0.speakerID ?? "none",
                                   text: $0.text)
        }
        let report = SyntheticScore.score(truth: truth, segments: segments)
        return Result(preset: meeting.truth.preset, seed: meeting.truth.seed, audioSeconds: truth.duration,
                      trueSpeakers: truth.speakers.filter { $0.track == "Them" }.count, turns: turns,
                      speakersFound: speakers.count, speakerSeconds: speakers.map(\.seconds), report: report, totalSeconds: total,
                      diarizationSeconds: diarization)
    }

    static func describe(_ r: Result, truth: SyntheticTruth) -> String {
        let rep = r.report
        func who(_ id: String) -> String {
            truth.speaker(id).map { "\(id) \($0.voice)\($0.gainDb <= -12 ? " (far)" : "")" } ?? id
        }
        var lines = [
            "[eval] \(r.preset) seed \(r.seed): \(fmt(r.audioSeconds)) s audio, speakers found \(r.speakersFound) of \(r.trueSpeakers)"
                + " (merged \(r.mergedSpeakers), extra \(r.extraSpeakers)); total "
                + (r.totalSeconds.map { fmt($0) + " s" } ?? "n/a (whisper cached)")
                + ", diarization \(fmt(r.diarizationSeconds)) s; talk time "
                + r.speakerSeconds.map { String(format: "%.0f", $0) }.joined(separator: "/") + " s",
            "[eval]   right speaker \(pct(rep.correctSpeakerWords, rep.matchedWords)) of \(rep.matchedWords) words; "
                + "lost \(pct(rep.lostWords, rep.truthWords)): crosstalk \(rep.lostInCrosstalk)/\(rep.wordsInCrosstalk), "
                + "overlaps \(rep.lostInOverlap)/\(rep.wordsInOverlap), elsewhere \(rep.lostElsewhere)/\(rep.wordsElsewhere)",
            "[eval]   interjections \(rep.interjections): right \(rep.interjectionsRightSpeaker), "
                + "wrong \(rep.interjectionsWrongSpeaker), lost \(rep.interjectionsLost)",
        ]
        for (id, labels) in rep.confusion.sorted(by: { $0.key < $1.key }) {
            let total = labels.values.reduce(0, +)
            let parts = labels.sorted { $0.value > $1.value }.map { label, n in
                "\(label.replacingOccurrences(of: "Them/", with: ""))→\(rep.mapping[label] ?? "?") \(n)"
            }
            lines.append("[eval]   \(who(id)): \(total) words: " + parts.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Tests

    @Test(.enabled(if: modelsDir != nil, "Set EARL_EVAL_MODELS to run the diarization evaluation"))
    func clean() async throws {
        try await Self.offMain {
            let scratch = try Self.tempDir()
            defer { try? FileManager.default.removeItem(at: scratch) }
            let meeting = try Self.meeting(.clean, seed: 1, minutes: Self.minutes, in: scratch)
            let result = try await Self.evaluate(meeting, diarizer: try await Self.diarizer())
            if Self.env["EARL_EVAL_TRANSCRIPT"] != nil {
                for t in result.turns { print("[turn] \(Self.fmt(t.start)) \(t.speakerID ?? "-"): \(t.text)") }
            }
            print(Self.describe(result, truth: meeting.truth))
            // Unlike the old hand-written script, T-1's clean voices come out
            // over-split (4-6 voices for 3 on seeds 1-9), so the target is that
            // no voice is merged into another, not an exact count.
            #expect(result.mergedSpeakers == 0)
            #expect(result.speakersFound <= 5)
            #expect(result.report.speakerAccuracy >= 0.9)
        }
    }

    /// The matrix: prints each run, then one line per preset in a Markdown table.
    @Test(.enabled(if: modelsDir != nil && !presets.isEmpty, "Set EARL_EVAL_PRESETS to evaluate presets"))
    func presetMatrix() async throws {
        try await Self.offMain {
            let scratch = try Self.tempDir()
            defer { try? FileManager.default.removeItem(at: scratch) }
            let diarizer = try await Self.diarizer()
            var results: [Result] = []
            for preset in Self.presets {
                for seed in Self.seeds {
                    let meeting = try Self.meeting(preset, seed: seed, minutes: Self.minutes, in: scratch)
                    let result = try await Self.evaluate(meeting, diarizer: diarizer)
                    print(Self.describe(result, truth: meeting.truth))
                    results.append(result)
                }
            }
            print(Self.table(results))
        }
    }

    static func table(_ results: [Result]) -> String {
        var rows = [
            "| preset | speakers found / true | right speaker | lost in crosstalk | lost in overlaps | lost elsewhere "
                + "| interjections right / wrong / lost | merged / extra voices | diarization s | total s |",
            "|---|---|---|---|---|---|---|---|---|---|",
        ]
        for preset in results.map(\.preset).reduce(into: [String](), { if !$0.contains($1) { $0.append($1) } }) {
            let rs = results.filter { $0.preset == preset }
            func sum(_ k: KeyPath<SyntheticScore.Report, Int>) -> Int { rs.reduce(0) { $0 + $1.report[keyPath: k] } }
            let totals = rs.compactMap(\.totalSeconds)
            rows.append([
                preset,
                rs.map { "\($0.speakersFound)/\($0.trueSpeakers)" }.joined(separator: ", "),
                pct(sum(\.correctSpeakerWords), sum(\.matchedWords)),
                "\(pct(sum(\.lostInCrosstalk), sum(\.wordsInCrosstalk))) of \(sum(\.wordsInCrosstalk))",
                "\(pct(sum(\.lostInOverlap), sum(\.wordsInOverlap))) of \(sum(\.wordsInOverlap))",
                "\(pct(sum(\.lostElsewhere), sum(\.wordsElsewhere))) of \(sum(\.wordsElsewhere))",
                "\(sum(\.interjectionsRightSpeaker)) / \(sum(\.interjectionsWrongSpeaker)) / \(sum(\.interjectionsLost))",
                "\(rs.reduce(0) { $0 + $1.mergedSpeakers }) / \(rs.reduce(0) { $0 + $1.extraSpeakers })",
                fmt(rs.reduce(0) { $0 + $1.diarizationSeconds } / Double(rs.count)),
                totals.isEmpty ? "n/a" : fmt(totals.reduce(0, +) / Double(totals.count)),
            ].joined(separator: " | ").wrappedInPipes)
        }
        rows.append("(sums over \(Set(results.map(\.seed)).count) seed(s); seconds are means per meeting)")
        return rows.joined(separator: "\n")
    }

    /// Timing on an hour of audio: diarization alone, whisper alone, and both at
    /// once, to decide whether running them side by side pays off.
    @Test(.enabled(if: modelsDir != nil && env["EARL_EVAL_LONG"] != nil, "Set EARL_EVAL_LONG to time an hour of audio"))
    func oneHour() async throws {
        try await Self.offMain { try await Self.runOneHour() }
    }

    static func runOneHour() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let meeting = try Self.meeting(.clean, seed: 1, minutes: 60, in: dir)
        let url = meeting.system
        let minutes = meeting.truth.duration / 60
        let diarizer = try await Self.diarizer()

        var started = Date()
        let result = try await diarizer.run(audio: url)
        let diarize = Date().timeIntervalSince(started)
        print("[eval] \(Self.fmt(minutes)) min: diarization \(Self.fmt(diarize)) s, \(result.speakers.count) speakers")

        let whisperArgs = ["-m", Self.whisperModel, "-f", url.path, "-l", "en", "-oj", "-of",
                           dir.appendingPathComponent("w").path, "-np", "-ml", "1", "-sow",
                           "-t", "\(min(8, max(2, ProcessInfo.processInfo.activeProcessorCount / 2)))",
                           "--vad", "-vm", Prefs.vadModel]
        started = Date()
        try await ProcessRunner.run(Prefs.defaultWhisperPath, whisperArgs)
        let whisper = Date().timeIntervalSince(started)
        print("[eval] \(Self.fmt(minutes)) min: whisper \(Self.fmt(whisper)) s")

        started = Date()
        async let w: Void = ProcessRunner.run(Prefs.defaultWhisperPath, whisperArgs)
        async let d = diarizer.run(audio: url)
        _ = try await (w, d)
        let both = Date().timeIntervalSince(started)
        print("[eval] \(Self.fmt(minutes)) min: side by side \(Self.fmt(both)) s vs one after the other \(Self.fmt(whisper + diarize)) s")
    }
}

private extension String {
    var wrappedInPipes: String { "| " + self + " |" }
}
