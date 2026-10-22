import FluidAudio
import Foundation
import Testing
@testable import Earl

/// V-1: Parakeet TDT v3 (FluidAudio, Neural Engine) against Whisper as Earl
/// runs it, on T-1 synthetic meetings and on copies of real ones. Heavy:
/// only runs when asked.
///
/// - `EARL_EVAL_ASR=1` with `EARL_EVAL_MODELS` (speaker model folder) and
///   `EARL_EVAL_PARAKEET` (Parakeet folder, downloaded there if missing):
///   every preset in `EARL_EVAL_PRESETS` (default clean,realistic,german,mixed)
///   × `EARL_EVAL_SEEDS`, both engines in `EARL_EVAL_ASR_ENGINES`
///   (default whisper,parakeet), scored by `SyntheticScore`.
/// - `EARL_EVAL_ASR_FOLDER=<copy>[:<copy>…]` (meeting folder copies under
///   `$TMPDIR`): runs Parakeet and Whisper, each with the same diarization,
///   and writes `transcript-parakeet.json` and `transcript-whisper.json`
///   there. No names, no notes. `EARL_EVAL_ASR_NO_VOICES=1`: Parakeet only,
///   no diarization, for a quick look at the language.
/// - `EARL_EVAL_STRETCH`: see `stretchedWords`.
@Suite(.serialized)
struct ASREngineEvalTests {
    static let env = ProcessInfo.processInfo.environment
    static let enabled = env["EARL_EVAL_ASR"] == "1"
    static let folder = env["EARL_EVAL_ASR_FOLDER"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    static let parakeetDir = env["EARL_EVAL_PARAKEET"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    static let presets = (env["EARL_EVAL_PRESETS"] ?? "clean,realistic,german,mixed").split(separator: ",")
        .compactMap { SyntheticMeeting.Preset(rawValue: String($0)) }
    static let seeds = (env["EARL_EVAL_SEEDS"] ?? "1").split(separator: ",").compactMap { UInt64(String($0)) }
    static let engines = (env["EARL_EVAL_ASR_ENGINES"] ?? "whisper,parakeet").split(separator: ",").map(String.init)
    static let minutes = env["EARL_EVAL_MINUTES"].flatMap(Double.init) ?? 5

    @Test(.enabled(if: enabled)) func syntheticMatrix() async throws {
        try await DiarizationEvalTests.offMain { try await Self.runMatrix() }
    }

    @Test(.enabled(if: folder != nil)) func realMeeting() async throws {
        try await DiarizationEvalTests.offMain { try await Self.runReal() }
    }

    /// `EARL_EVAL_STRETCH=<folder>:<folder>…`: folders holding whisper's
    /// word-level JSON (`whisper-system.json`/`whisper-mic.json`, or
    /// `w-system.json`/`w-mic.json`); rebuilds the turns with and without
    /// `StretchedWords.fix`, scoring them when a `truth.json` is there.
    @Test(.enabled(if: env["EARL_EVAL_STRETCH"] != nil)) func stretchedWords() async throws {
        try await DiarizationEvalTests.offMain { try await Self.runStretch() }
    }

    static func runStretch() async throws {
        let diarizer = try await DiarizationEvalTests.diarizer()
        for path in (env["EARL_EVAL_STRETCH"] ?? "").split(separator: ":") {
            let folder = URL(fileURLWithPath: String(path), isDirectory: true)
            try ReprocessTool.assertSafe(folder)
            func json(_ track: String) -> URL? {
                ["whisper-\(track).json", "w-\(track).json"].map { folder.appendingPathComponent($0) }
                    .first { FileManager.default.fileExists(atPath: $0.path) }
            }
            let diarization = try await diarizer.run(audio: folder.appendingPathComponent("system-16k.wav"))
            let truthURL = folder.appendingPathComponent("truth.json")
            let truth = FileManager.default.fileExists(atPath: truthURL.path) ? try SyntheticTruth.load(truthURL) : nil
            for fixed in [false, true] {
                var segments: [Turn] = []
                for (track, speaker) in [("system", "Them"), ("mic", "Me")] {
                    guard let url = json(track) else { continue }
                    let raw = try rawWords(url)
                    let phrases = ParakeetEngine.phrases(fixed ? StretchedWords.fix(raw) : raw, speaker: speaker)
                    if speaker == "Them" {
                        segments += TranscriptCleanup.clean(SpeakerAssignment.assign(phrases, to: diarization).map { turn, voice in
                            var turn = turn
                            turn.speakerID = voice.map { "system#\($0)" }
                            return turn
                        })
                    } else {
                        segments += TranscriptCleanup.clean(phrases.map(\.turn))
                    }
                }
                var voices: [String: (track: String, embedding: [Float], seconds: Double)] = [:]
                for v in diarization.speakers { voices["system#\(v.index)"] = ("Them", v.embedding, v.seconds) }
                let turns = SpeakerAssignment.number(Transcriber.buildTurns(from: segments), voices: voices).turns
                var line = String(format: "[stretch] %@ %@: %d turns, %d over 90 s (%.0f s), %d under 3 words",
                                  folder.lastPathComponent, fixed ? "fixed" : "raw", turns.count,
                                  turns.filter { $0.end - $0.start > 90 }.count,
                                  turns.filter { $0.end - $0.start > 90 }.reduce(0) { $0 + $1.end - $1.start },
                                  turns.filter { $0.text.split(separator: " ").count < 3 }.count)
                if let truth {
                    let report = SyntheticScore.score(truth: truth, segments: turns.map {
                        SyntheticScore.Segment(start: $0.start, end: $0.end, track: $0.speaker,
                                               speaker: $0.speakerID ?? $0.speaker, text: $0.text)
                    })
                    line += String(format: "; lost %.1f %%, right speaker %.1f %%", report.lostShare * 100,
                                   report.speakerAccuracy * 100)
                }
                print(line)
            }
        }
    }

    /// Whisper's one-word segments as they are, noise and all.
    static func rawWords(_ url: URL) throws -> [TimedWord] {
        struct Output: Decodable {
            struct Segment: Decodable {
                struct Offsets: Decodable { let from: Int; let to: Int }
                let offsets: Offsets
                let text: String
            }
            let transcription: [Segment]
        }
        let data = Data(String(decoding: try Data(contentsOf: url), as: UTF8.self).utf8)
        return try JSONDecoder().decode(Output.self, from: data).transcription
            .filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty && !$0.text.contains("[") }
            .map { TimedWord(text: $0.text, start: Double($0.offsets.from) / 1000, end: Double($0.offsets.to) / 1000) }
    }

    // MARK: - Synthetic

    struct Row {
        var name: String
        var report: SyntheticScore.Report
        var englishLost: (lost: Int, total: Int)?
        var seconds: Double
        var audioSeconds: Double
    }

    static func runMatrix() async throws {
        let diarizer = try await DiarizationEvalTests.diarizer()
        let scratch = try DiarizationEvalTests.tempDir()
        defer { try? FileManager.default.removeItem(at: scratch) }
        var parakeet: ParakeetEngine?
        if engines.contains("parakeet") {
            let started = Date()
            parakeet = try await ParakeetEngine.load(from: try #require(parakeetDir))
            print(String(format: "[asr] parakeet loaded in %.1f s", Date().timeIntervalSince(started)))
        }
        var rows: [Row] = []
        for preset in presets {
            for seed in seeds {
                let meeting = try DiarizationEvalTests.meeting(preset, seed: seed, minutes: minutes, in: scratch)
                for engine in engines {
                    let started = Date()
                    let turns: [Turn]
                    if engine == "parakeet", let parakeet {
                        turns = try await ParakeetEngine.transcribe(meeting: meeting.folder, engine: parakeet, diarizer: diarizer)
                    } else {
                        turns = try await whisper(meeting, diarizer: diarizer, scratch: scratch)
                    }
                    let seconds = Date().timeIntervalSince(started)
                    let segments = turns.map {
                        SyntheticScore.Segment(start: $0.start, end: $0.end, track: $0.speaker,
                                               speaker: $0.speakerID ?? $0.speaker, text: $0.text)
                    }
                    let report = SyntheticScore.score(truth: meeting.truth, segments: segments)
                    var english: (Int, Int)?
                    if let e = meeting.truth.speakers.first(where: { $0.voice == "Daniel" }), preset == .mixed {
                        var only = meeting.truth
                        only.utterances = only.utterances.filter { $0.speaker == e.id }
                        only.overlaps = SyntheticTruth.overlaps(of: only.utterances)
                        let r = SyntheticScore.score(truth: only, segments: segments)
                        english = (r.lostWords, r.truthWords)
                    }
                    let name = "\(preset.rawValue)-\(seed) \(engine)"
                    rows.append(Row(name: name, report: report, englishLost: english, seconds: seconds,
                                    audioSeconds: meeting.truth.duration))
                    print("[asr] \(name): \(String(format: "%.1f", seconds)) s\n\(report)")
                    if env["EARL_EVAL_ASR_DUMP"] == "1" {
                        let text = turns.map { "[\(Int($0.start))] \($0.speakerID ?? $0.speaker): \($0.text)" }
                            .joined(separator: "\n")
                        try? text.write(to: meeting.folder.appendingPathComponent("asr-\(engine).txt"), atomically: true,
                                        encoding: .utf8)
                    }
                }
            }
        }
        print("| Run | Words lost | In overlaps | Elsewhere | Right speaker | English words lost | Time (both tracks + voices) |")
        print("|---|---|---|---|---|---|---|")
        for r in rows {
            let english = r.englishLost.map { String(format: "%.1f %% of %d", 100 * Double($0.lost) / Double(max(1, $0.total)), $0.total) } ?? "–"
            print(String(format: "| %@ | %.1f %% | %.1f %% | %.1f %% | %.1f %% | %@ | %.1f s for %.0f s |", r.name,
                         r.report.lostShare * 100, r.report.lostInOverlapShare * 100, r.report.lostElsewhereShare * 100,
                         r.report.speakerAccuracy * 100, english, r.seconds, r.audioSeconds))
        }
    }

    /// Whisper as `AppState.process` runs it: auto language, the names as
    /// the prompt, the call track diarized, the mic word-level.
    static func whisper(_ meeting: SyntheticMeeting, diarizer: Earl.Diarizer, scratch: URL) async throws -> [Turn] {
        let work = scratch.appendingPathComponent("whisper-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        for name in ["system-16k.wav", "mic-16k.wav"] {
            try FileManager.default.copyItem(at: meeting.folder.appendingPathComponent(name),
                                             to: work.appendingPathComponent(name))
        }
        var transcriber = Transcriber()
        transcriber.modelPath = DiarizationEvalTests.whisperModel
        transcriber.language = "auto"
        let names = meeting.truth.speakers.map(\.name)
        transcriber.prompt = WhisperPrompt.build(extraNames: names)
        transcriber.promptTerms = WhisperPrompt.buildTerms(extraNames: names)
        transcriber.diarizer = diarizer
        transcriber.diarizeMic = false
        transcriber.usedSpeakers = false
        return try await transcriber.transcribe(folder: work) { _ in }.turns
    }

    // MARK: - Real meeting copies

    static func runReal() async throws {
        let folders = try #require(Self.folder).path.split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        for folder in folders { try await runReal(folder) }
    }

    static func runReal(_ folder: URL) async throws {
        try ReprocessTool.assertSafe(folder)
        // EARL_EVAL_ASR_NO_VOICES=1: words only, for a quick look at language.
        let diarizer = env["EARL_EVAL_ASR_NO_VOICES"] == "1" ? nil : try await DiarizationEvalTests.diarizer()
        let engine = try await ParakeetEngine.load(from: try #require(parakeetDir))
        let started = Date()
        let turns = try await ParakeetEngine.transcribe(meeting: folder, engine: engine, diarizer: diarizer)
        print(String(format: "[asr] parakeet + voices on %@: %.1f s, %d turns, %d words", folder.lastPathComponent,
                     Date().timeIntervalSince(started), turns.count, NotesGate.wordCount(turns)))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        try encoder.encode(turns).write(to: folder.appendingPathComponent("transcript-parakeet.json"))
        guard engines.contains("whisper"), let diarizer else { return }

        // Whisper as `AppState.process` runs it on this meeting (the prompt
        // from its attendees, as ReprocessTool builds it), without names or notes.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let info = try decoder.decode(MeetingInfo.self, from: Data(contentsOf: folder.appendingPathComponent("meeting.json")))
        let terms = WhisperPrompt.attendeeTerms(info.attendees ?? [])
        var transcriber = Transcriber()
        transcriber.prompt = WhisperPrompt.build(extraNames: terms)
        transcriber.promptTerms = WhisperPrompt.buildTerms(extraNames: terms)
        transcriber.usedSpeakers = info.usedSpeakers
        transcriber.diarizer = diarizer
        let whisperStarted = Date()
        let output = try await transcriber.transcribe(folder: folder) { _ in }
        print(String(format: "[asr] whisper + voices on %@: %.1f s, %d turns, %d words", folder.lastPathComponent,
                     Date().timeIntervalSince(whisperStarted), output.turns.count, NotesGate.wordCount(output.turns)))
        try encoder.encode(output.turns).write(to: folder.appendingPathComponent("transcript-whisper.json"))
    }
}

/// Parakeet TDT v3 through FluidAudio, producing the same phrases Whisper's
/// word-level output does, so diarization and cleanup run unchanged.
struct ParakeetEngine {
    let manager: AsrManager

    static func load(from dir: URL) async throws -> ParakeetEngine {
        let models = try await AsrModels.downloadAndLoad(to: dir.appendingPathComponent(Repo.parakeetV3.folderName),
                                                         version: .v3)
        return ParakeetEngine(manager: AsrManager(config: .default, models: models))
    }

    func words(_ audio: URL) async throws -> [TimedWord] {
        var state = TdtDecoderState.make(decoderLayers: 2)
        let result = try await manager.transcribe(audio, decoderState: &state)
        return buildWordTimings(from: result.tokenTimings ?? []).map {
            TimedWord(text: " " + $0.word, start: $0.startTime, end: $0.endTime)
        }
    }

    /// Groups words the way `Transcriber.parsePhrases` does: a new phrase
    /// after a pause of a second, a sentence end, or 200 characters.
    static func phrases(_ words: [TimedWord], speaker: String) -> [Phrase] {
        var groups: [[TimedWord]] = []
        for word in words {
            if let last = groups.last?.last, word.start - last.end < 1, let end = last.text.last, !".?!".contains(end),
               groups[groups.count - 1].reduce(0, { $0 + $1.text.count }) < 200 {
                groups[groups.count - 1].append(word)
            } else {
                groups.append([word])
            }
        }
        return groups.map { words in
            let text = words.map(\.text).joined().trimmingCharacters(in: .whitespaces)
            return Phrase(turn: Turn(start: words[0].start, end: words[words.count - 1].end, speaker: speaker, text: text),
                          words: words)
        }
    }

    /// Both tracks of a meeting folder, the call track diarized, as
    /// `Transcriber.transcribe` does with Whisper.
    static func transcribe(meeting folder: URL, engine: ParakeetEngine, diarizer: Earl.Diarizer?) async throws -> [Turn] {
        var segments: [Turn] = []
        var voices: [String: (track: String, embedding: [Float], seconds: Double)] = [:]
        for (track, speaker) in [("system", "Them"), ("mic", "Me")] {
            let audio = folder.appendingPathComponent("\(track)-16k.wav")
            guard FileManager.default.fileExists(atPath: audio.path) else { continue }
            async let diarized: Earl.Diarization? = speaker == "Them" ? try await diarizer?.run(audio: audio) : nil
            let phrases = phrases(try await engine.words(audio), speaker: speaker)
            if let result = try await diarized {
                var trackTurns: [Turn] = []
                for (turn, voice) in SpeakerAssignment.assign(phrases, to: result) {
                    var turn = turn
                    turn.speakerID = voice.map { "\(track)#\($0)" }
                    trackTurns.append(turn)
                }
                segments += TranscriptCleanup.clean(trackTurns)
                for v in result.speakers { voices["\(track)#\(v.index)"] = (speaker, v.embedding, v.seconds) }
            } else {
                segments += TranscriptCleanup.clean(phrases.map(\.turn))
            }
        }
        return SpeakerAssignment.number(Transcriber.buildTurns(from: segments), voices: voices).turns
    }
}
