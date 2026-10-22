import Foundation

enum PipelineError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let m): return m
        }
    }
}

/// Appends lines to a log file from several tasks at once.
final class LogFile: @unchecked Sendable {
    private let handle: FileHandle?
    private let lock = NSLock()

    init(_ url: URL?) {
        guard let url else { handle = nil; return }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
    }

    func write(_ line: String) {
        lock.withLock { try? handle?.write(contentsOf: Data((line + "\n").utf8)) }
    }

    deinit { try? handle?.close() }
}

enum ProcessRunner {
    /// Runs an executable to completion, handing each line of stdout and stderr
    /// to `onLine` as it arrives. Cancelling the task terminates the process.
    static func run(_ executable: String, _ args: [String], log: URL? = nil,
                    onLine: (@Sendable (_ line: String, _ isError: Bool) async -> Void)? = nil) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let logFile = LogFile(log)
        let name = URL(fileURLWithPath: executable).lastPathComponent
        // Wait for the exit through terminationHandler: waitUntilExit() on a
        // concurrency thread sometimes never returns once the process has ended.
        let exited = AsyncStream<Void> { done in
            process.terminationHandler = { _ in done.finish() }
        }

        try await withTaskCancellationHandler {
            try process.run()
            logFile.write("$ \(name) \(args.joined(separator: " "))")
            await withTaskGroup(of: Void.self) { group in
                for (pipe, isError) in [(out, false), (err, true)] {
                    group.addTask {
                        for await line in lines(of: pipe.fileHandleForReading) {
                            logFile.write(line)
                            await onLine?(line, isError)
                        }
                    }
                }
            }
            for await _ in exited {}
            try Task.checkCancellation()
            guard process.terminationStatus == 0 else {
                let hint = log.map { " See \($0.lastPathComponent) in the meeting folder." } ?? ""
                throw PipelineError.message("\(name) failed (exit code \(process.terminationStatus)).\(hint)")
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    /// The lines of a pipe. Reads on a dispatch thread: `FileHandle.bytes`
    /// blocks a Swift concurrency thread per pipe, and when those run out the
    /// other pipe isn't drained and the process stalls on a full pipe.
    private static func lines(of handle: FileHandle) -> AsyncStream<String> {
        AsyncStream { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var buffer = Data()
                func emit(upTo end: Data.Index) {
                    let line = String(decoding: buffer[buffer.startIndex..<end], as: UTF8.self)
                    if !line.isEmpty { continuation.yield(line) }
                }
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    buffer.append(chunk)
                    while let end = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                        emit(upTo: end)
                        buffer.removeSubrange(buffer.startIndex...end)
                    }
                }
                emit(upTo: buffer.endIndex)
                continuation.finish()
            }
        }
    }
}

/// Transcribes a meeting folder's two audio tracks with whisper.cpp and merges
/// them into speaker turns.
struct Transcriber {
    var whisperPath = Prefs.whisperPath
    var modelPath = Prefs.whisperModel
    var vadModelPath = Prefs.vadModel
    var language = Prefs.language
    /// Whisper's initial prompt: the vocabulary, as a natural sentence
    /// (R1-3, Q-1). `nil` means no `--prompt`.
    var prompt: String? = WhisperPrompt.build()
    /// Q-1: the terms `prompt` was built from, kept alongside it instead of
    /// re-parsed from the sentence. Used for `MeetingInfo.vocabularyTerms`
    /// and, tokenised, for echo detection and label stripping.
    var promptTerms: [String] = WhisperPrompt.buildTerms()
    /// R2-2: tells voices apart on the call audio (and the mic, if asked). `nil` means off.
    var diarizer: Diarizer? = Prefs.separateSpeakers ? Diarizer() : nil
    var diarizeMic = Prefs.separateMicSpeakers
    /// R2-4: whether the call played on speakers. false (headphones) skips the echo gate.
    var usedSpeakers: Bool?

    enum Event {
        /// Started a track ("Them" or "Me"), index is 0-based.
        case track(speaker: String, index: Int, count: Int)
        case progress(Double)
        case language(String)
        case segment(Turn)
        /// Started telling the voices apart on a track (R2-2).
        case diarizing(speaker: String)
        /// Removing the call's echo from the mic track (R2-4).
        case removingEcho
    }

    struct Output {
        var turns: [Turn]
        var language: String?
        // R2-2
        var speakers: [Speaker] = []
        var speakerModel: String?
        var diarizationSeconds: Double?
        var speakerNote: String?
        // R2-4: nil when the echo gate didn't run.
        var echoRemovedSeconds: Double?
    }

    private static let tracks = [("system", "Them"), ("mic", "Me")]

    func transcribe(folder: URL, onEvent: @escaping @MainActor (Event) -> Void) async throws -> Output {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: whisperPath) else {
            throw PipelineError.message("Earl's transcriber is missing (\(whisperPath)). Install Earl again from the latest download.")
        }
        guard fm.fileExists(atPath: modelPath) else {
            throw PipelineError.message("Whisper model not found at \(modelPath). Choose or download one under the hood.")
        }
        let log = folder.appendingPathComponent("whisper.log")
        // Q-1: from the terms, not the sentence — "talk", "about" etc. aren't
        // vocabulary and shouldn't count towards an echo or an invented label.
        let promptWords = WhisperPrompt.words(in: promptTerms.joined(separator: ", "))

        // Whisper wants 16 kHz mono 16-bit; that's also ~6x smaller than the raw capture.
        for (track, _) in Self.tracks {
            let raw = folder.appendingPathComponent("\(track).wav")
            let pcm = folder.appendingPathComponent("\(track)-16k.wav")
            if fm.fileExists(atPath: raw.path) {
                try await ProcessRunner.run("/usr/bin/afconvert",
                                            ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", raw.path, pcm.path], log: log)
                try? fm.removeItem(at: raw)
            }
        }

        let present = Self.tracks.filter { fm.fileExists(atPath: folder.appendingPathComponent("\($0.0)-16k.wav").path) }
        guard !present.isEmpty else {
            throw PipelineError.message("No audio found for this meeting.")
        }

        // R2-4: without headphones the mic hears the call too. Transcribe a
        // copy of the mic with the echo muted; mic-16k.wav stays as recorded
        // for playback.
        let echo = try await removeEcho(folder: folder, log: log, onEvent: onEvent)
        defer { if let cleaned = echo?.result?.cleaned { try? fm.removeItem(at: cleaned) } }

        var segments: [Turn] = []
        var detectedLanguage: String?
        var voices: [String: (track: String, embedding: [Float], seconds: Double)] = [:]
        var diarizationSeconds: Double?
        var speakerNote: String?
        for (index, (track, speaker)) in present.enumerated() {
            await onEvent(.track(speaker: speaker, index: index, count: present.count))
            let pcm = speaker == "Me" ? echo?.result?.cleaned ?? folder.appendingPathComponent("\(track)-16k.wav")
                : folder.appendingPathComponent("\(track)-16k.wav")
            let outBase = folder.appendingPathComponent("whisper-\(track)")
            var wanted = speaker == "Them" || diarizeMic ? diarizer : nil
            // V-1: a call track of pure silence was never captured; say so
            // instead of "No speech detected" from the speaker model.
            if speaker == "Them", SilentTrack.isSilent(pcm) == true {
                LogFile(log).write("Call audio is silent: nothing was captured from the call.")
                speakerNote = SilentTrack.note
                wanted = nil
            }
            if let d = wanted, !d.isInstalled {
                LogFile(log).write("Speaker model not downloaded; voices on \(speaker) not separated.")
                speakerNote = "Not separated: the speaker model isn't downloaded."
                wanted = nil
            }
            let diarizer = wanted
            // Q-1: word-level timing isn't just for diarization any more —
            // without it, an undiarized "Me" segment can run for minutes (VAD
            // hands whisper the whole quiet-free stretch) and `buildTurns`
            // stamps all of it at the start, cutting the other side's
            // sentences in half.
            let wordLevel = diarizer != nil || speaker == "Me"
            var args = ["-m", modelPath, "-f", pcm.path, "-l", language, "-oj", "-of", outBase.path, "-np", "-pp",
                        "-t", "\(min(8, max(2, ProcessInfo.processInfo.activeProcessorCount / 2)))"]
            if fm.fileExists(atPath: vadModelPath) {
                // Voice activity detection skips silence, which stops Whisper from
                // hallucinating text during quiet stretches.
                args += ["--vad", "-vm", vadModelPath]
            }
            // Q-1: keeps the vocabulary in effect for the whole recording
            // without leaving room for Whisper's own text to condition on
            // itself (see `WhisperPrompt.maxContext`). Applied on both
            // tracks, and even with no prompt: -mc 0 then just turns off
            // whisper.cpp's per-segment self-conditioning.
            args += ["--carry-initial-prompt", "-mc", "\(WhisperPrompt.maxContext(for: prompt))"]
            if let prompt {
                // Biases Whisper towards the vocabulary's spellings (R1-3).
                args += ["--prompt", prompt]
            }
            if wordLevel {
                // One segment per word: its times are the only word timings that
                // survive --vad (the -ojf token times are in VAD-trimmed time).
                // They let segments that span two voices be split, and let a long
                // undiarized track be regrouped into phrases (Q-1).
                args += ["-ml", "1", "-sow"]
            }
            // Diarization runs on the Neural Engine alongside whisper on the GPU;
            // on an hour of audio that took 136 s instead of 200 s one after the other.
            async let diarized: (result: Result<Diarization, Error>, seconds: Double)? = {
                guard let diarizer else { return nil }
                let started = Date()
                do {
                    return (.success(try await diarizer.run(audio: pcm)), Date().timeIntervalSince(started))
                } catch {
                    return (.failure(error), Date().timeIntervalSince(started))
                }
            }()

            try await ProcessRunner.run(whisperPath, args, log: log) { line, isError in
                if isError {
                    if let p = Self.parseProgress(line) { await onEvent(.progress(p)) }
                    if let lang = Self.parseLanguage(line) { await onEvent(.language(lang)) }
                } else if let seg = Self.parseSegment(line, speaker: speaker, promptWords: promptWords) {
                    await onEvent(.segment(seg))
                }
            }
            let json = outBase.appendingPathExtension("json")
            let parsed: (turns: [Turn], language: String?)
            if diarizer != nil {
                let words = try Self.parsePhrases(json, speaker: speaker, promptWords: promptWords)
                parsed = (words.phrases.map(\.turn), words.language)
                await onEvent(.diarizing(speaker: speaker))
                let (outcome, seconds) = await diarized!
                do {
                    let result = try outcome.get()
                    diarizationSeconds = (diarizationSeconds ?? 0) + seconds
                    var trackTurns: [Turn] = []
                    for (turn, voice) in SpeakerAssignment.assign(words.phrases, to: result) {
                        var turn = turn
                        turn.speakerID = voice.map { "\(track)#\($0)" }
                        trackTurns.append(turn)
                    }
                    segments += TranscriptCleanup.clean(trackTurns) // Q-1
                    for v in result.speakers {
                        voices["\(track)#\(v.index)"] = (speaker, v.embedding, v.seconds)
                    }
                } catch {
                    try Task.checkCancellation()
                    // Carry on with one "Them"; the meeting still completes.
                    LogFile(log).write("Telling voices apart failed: \(error.localizedDescription)")
                    speakerNote = "Couldn't tell voices apart: \(error.localizedDescription)"
                    segments += TranscriptCleanup.clean(parsed.turns) // Q-1
                }
            } else if wordLevel {
                let words = try Self.parsePhrases(json, speaker: speaker, promptWords: promptWords)
                parsed = (words.phrases.map(\.turn), words.language)
                segments += TranscriptCleanup.clean(parsed.turns) // Q-1
            } else {
                parsed = try Self.parse(json, speaker: speaker, promptWords: promptWords)
                segments += TranscriptCleanup.clean(parsed.turns) // Q-1
            }
            // Prefer the language of the call audio; the mic track may be mostly silence.
            if detectedLanguage == nil, !parsed.turns.isEmpty { detectedLanguage = parsed.language }
            if let lang = parsed.language { await onEvent(.language(lang)) }
        }

        let lang = language == "auto" ? detectedLanguage : language
        let turns = Self.buildTurns(from: segments, youSpans: echo?.result?.youSpans)
        let numbered = SpeakerAssignment.number(turns, voices: voices)
        return Output(turns: numbered.turns, language: lang, speakers: numbered.speakers,
                      speakerModel: diarizationSeconds == nil ? nil : Diarizer.modelName,
                      diarizationSeconds: diarizationSeconds, speakerNote: speakerNote,
                      echoRemovedSeconds: echo.map { $0.result?.removedSeconds ?? 0 })
    }

    /// Runs R2-4's echo gate when both tracks exist and the call wasn't on
    /// headphones. nil when it didn't run; a nil result when it found no echo.
    private func removeEcho(folder: URL, log: URL,
                            onEvent: @escaping @MainActor (Event) -> Void) async throws -> (result: EchoFilter.Result?, analysis: EchoFilter.Analysis)? {
        let mic = folder.appendingPathComponent("mic-16k.wav"), system = folder.appendingPathComponent("system-16k.wav")
        guard usedSpeakers != false, FileManager.default.fileExists(atPath: mic.path),
              FileManager.default.fileExists(atPath: system.path) else { return nil }
        await onEvent(.removingEcho)
        let started = Date()
        do {
            let (result, analysis) = try await Task.detached(priority: .userInitiated) {
                try EchoFilter.cleanAndAnalyze(mic: mic, system: system)
            }.value
            try Task.checkCancellation()
            guard let analysis else { return nil }
            LogFile(log).write(String(format: "Echo gate: %@, delay %.0f ms, correlation %.2f, muted %.0f s of mic audio in %.1f s.",
                                      analysis.detected ? "echo found" : "no echo", analysis.delayMs, analysis.correlation,
                                      result?.removedSeconds ?? 0, Date().timeIntervalSince(started)))
            return (result, analysis)
        } catch {
            try Task.checkCancellation()
            // Carry on with the original mic; the text filter still catches the worst.
            LogFile(log).write("Echo gate failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Parsing live output

    private static let segmentRegex = try! NSRegularExpression(
        pattern: #"^\[(\d+):(\d+):(\d+\.\d+) --> (\d+):(\d+):(\d+\.\d+)\]\s*(.*)$"#)

    static func parseSegment(_ line: String, speaker: String, promptWords: Set<String> = []) -> Turn? {
        let ns = line as NSString
        guard let m = segmentRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        func num(_ i: Int) -> Double { Double(ns.substring(with: m.range(at: i))) ?? 0 }
        let text = ns.substring(with: m.range(at: 7)).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !isNoise(text, promptWords: promptWords) else { return nil }
        return Turn(start: num(1) * 3600 + num(2) * 60 + num(3), end: num(4) * 3600 + num(5) * 60 + num(6),
                    speaker: speaker, text: text)
    }

    static func parseProgress(_ line: String) -> Double? {
        guard let r = line.range(of: "progress =") else { return nil }
        let digits = line[r.upperBound...].filter(\.isNumber)
        return Double(digits).map { min(1, $0 / 100) }
    }

    static func parseLanguage(_ line: String) -> String? {
        guard let r = line.range(of: "auto-detected language: ") else { return nil }
        return line[r.upperBound...].split(separator: " ").first.map(String.init)
    }

    // MARK: - Final output

    private struct WhisperOutput: Decodable {
        struct Segment: Decodable {
            struct Offsets: Decodable { let from: Int; let to: Int }
            let offsets: Offsets
            let text: String
        }
        struct Result: Decodable { let language: String? }
        let result: Result?
        let transcription: [Segment]
    }

    static func parse(_ url: URL, speaker: String, promptWords: Set<String> = []) throws -> (turns: [Turn], language: String?) {
        // whisper.cpp can split multi-byte characters across tokens; repair
        // invalid UTF-8 before decoding.
        let raw = try Data(contentsOf: url)
        let data = Data(String(decoding: raw, as: UTF8.self).utf8)
        let output = try JSONDecoder().decode(WhisperOutput.self, from: data)
        let turns: [Turn] = output.transcription.compactMap { seg in
            let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !isNoise(text, promptWords: promptWords) else { return nil }
            // Q-1: an invented "Alex Weber:" at the start of a sentence, not real speech.
            let stripped = WhisperPrompt.stripInventedLabels(text, promptWords: promptWords)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !stripped.isEmpty else { return nil }
            return Turn(start: Double(seg.offsets.from) / 1000, end: Double(seg.offsets.to) / 1000,
                        speaker: speaker, text: stripped)
        }
        return (turns, output.result?.language)
    }

    /// Reads word-per-segment output (`-ml 1 -sow`) and groups the words back
    /// into phrases: a new one starts after a pause of a second, at the end of a
    /// sentence, or past 200 characters.
    static func parsePhrases(_ url: URL, speaker: String, promptWords: Set<String> = []) throws
        -> (phrases: [Phrase], language: String?) {
        let raw = try Data(contentsOf: url)
        let data = Data(String(decoding: raw, as: UTF8.self).utf8)
        let output = try JSONDecoder().decode(WhisperOutput.self, from: data)
        var timed: [TimedWord] = []
        for seg in output.transcription {
            let trimmed = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !isNoise(trimmed) else { continue }
            timed.append(TimedWord(text: seg.text, start: Double(seg.offsets.from) / 1000, end: Double(seg.offsets.to) / 1000))
        }
        var groups: [[TimedWord]] = []
        for word in StretchedWords.fix(timed) { // V-1: words that swallowed a pause VAD cut out
            if let last = groups.last?.last, word.start - last.end < 1, let end = last.text.last, !".?!".contains(end),
               groups[groups.count - 1].reduce(0, { $0 + $1.text.count }) < 200 {
                groups[groups.count - 1].append(word)
            } else {
                groups.append([word])
            }
        }
        let phrases: [Phrase] = groups.compactMap { words in
            let text = words.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !isNoise(text, promptWords: promptWords) else { return nil }
            // Q-1: an invented "Alex Weber:" at the start of a phrase, not real speech.
            let stripped = WhisperPrompt.stripInventedLabels(text, promptWords: promptWords)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !stripped.isEmpty else { return nil }
            // Drop the label's words too: SpeakerAssignment.split rebuilds the
            // text from them when a phrase spans two voices. Phrases break at
            // every sentence end, so a label can only lead the phrase.
            var kept = words
            if stripped != text.trimmingCharacters(in: .whitespacesAndNewlines),
               let colon = kept.prefix(3).firstIndex(where: { $0.text.trimmingCharacters(in: .whitespaces).hasSuffix(":") }) {
                kept.removeFirst(colon + 1)
            }
            guard !kept.isEmpty else { return nil }
            return Phrase(turn: Turn(start: kept[0].start, end: kept[kept.count - 1].end, speaker: speaker, text: stripped),
                          words: kept)
        }
        return (phrases, output.result?.language)
    }

    /// Live output on a diarized track comes one word at a time; join words
    /// into the previous line until a sentence ends or the speaker pauses.
    /// Whole segments (more than one word) are shown as they come.
    static func appendLive(_ turn: Turn, to turns: inout [Turn]) {
        if !turn.text.contains(" "), var last = turns.last, last.speaker == turn.speaker, turn.start - last.end < 1,
           let end = last.text.last, !".?!".contains(end), last.text.count < 200 {
            last.text += (turn.text.first?.isPunctuation == true ? "" : " ") + turn.text
            last.end = max(last.end, turn.end)
            turns[turns.count - 1] = last
        } else {
            turns.append(turn)
        }
    }

    /// Whisper marks non-speech as e.g. "[BLANK_AUDIO]", "(music)" or "*laughs*".
    /// On noise it can also repeat its initial prompt (R1-3).
    private static func isNoise(_ text: String, promptWords: Set<String> = []) -> Bool {
        let pairs: [(Character, Character)] = [("[", "]"), ("(", ")"), ("*", "*")]
        return pairs.contains { text.first == $0.0 && text.last == $0.1 }
            || WhisperPrompt.isEcho(text, promptWords: promptWords)
    }

    /// `youSpans`: where R2-4's echo gate heard you on the mic; nil when it didn't run.
    static func buildTurns(from segments: [Turn], youSpans: [ClosedRange<Double>]? = nil) -> [Turn] {
        // Without headphones the mic also picks up the other people. Drop "Me"
        // segments that repeat what "Them" said at the same time (R2-4).
        let deduped = EchoFilter.dropEchoedSegments(segments, youSpans: youSpans)

        var turns: [Turn] = []
        for seg in deduped.sorted(by: { $0.start < $1.start }) {
            if var last = turns.last, last.speaker == seg.speaker, last.speakerID == seg.speakerID,
               seg.start - last.end < 4, last.text.count + seg.text.count < 1200 {
                last.text += " " + seg.text
                last.end = max(last.end, seg.end)
                turns[turns.count - 1] = last
            } else {
                turns.append(seg)
            }
        }
        return turns
    }
}
