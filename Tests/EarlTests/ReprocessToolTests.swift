import Foundation
import Testing
@testable import Earl

/// Q-1: replays Earl's real processing on a copy of a meeting folder, driven
/// by `tools/reprocess.sh <folder> [--no-notes]`, so before/after
/// transcript-hygiene changes can be compared on real (but never committed)
/// meetings. Calls the same `Transcriber`, `SpeakerNameGuesser` and
/// `Summarizer` that `AppState.process` does, without an `AppState` (which
/// would touch the real ~/Meetings and ask for calendar access).
///
/// Refuses anything that isn't under `$TMPDIR` or `/tmp`, and anything under
/// `~/Meetings`, as a second line of defence behind the shell script.
struct ReprocessTool {
    static let env = ProcessInfo.processInfo.environment
    static let folder = env["EARL_REPROCESS"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    static let noNotes = env["EARL_REPROCESS_NO_NOTES"] == "1"

    /// K-1: EARL_REPROCESS_KINDS=<library>: the kind each meeting would get
    /// without the model, read only. Ids and numbers, never titles.
    @Test(.enabled(if: env["EARL_REPROCESS_KINDS"] != nil)) func kinds() throws {
        let root = URL(fileURLWithPath: try #require(Self.env["EARL_REPROCESS_KINDS"]), isDirectory: true)
        let library = MeetingStore(root: root).loadAll().filter { !$0.turns.isEmpty }
        for m in library.sorted(by: { $0.info.startedAt < $1.info.startedAt }) {
            let talk = MeetingKind.talk(in: m)
            let kind = MeetingKind.decide(m, in: library).map(\.rawValue) ?? "ask the model"
            print(String(format: "[kinds] %@ %3.0f min · %3d invited · you %3.0f %% · top %3.0f %% · %@", m.id,
                         m.info.duration / 60, m.info.attendees?.count ?? 0, talk.mine * 100, (talk.top ?? 0) * 100, kind))
        }
    }

    /// K-1: EARL_REPROCESS_GUESS=<library copy>: what the notes model says
    /// about each meeting the rules leave to it.
    @Test(.enabled(if: env["EARL_REPROCESS_GUESS"] != nil)) func guessKinds() async throws {
        let root = URL(fileURLWithPath: try #require(Self.env["EARL_REPROCESS_GUESS"]), isDirectory: true)
        try Self.assertSafe(root)
        let library = MeetingStore(root: root).loadAll().filter { !$0.turns.isEmpty }
        let model = Self.model ?? Prefs.llmModel
        for m in library.sorted(by: { $0.info.startedAt < $1.info.startedAt }) where MeetingKind.decide(m, in: library) == nil {
            let started = Date()
            var s = Summarizer()
            s.model = model
            let answer = (try? await s.answer(system: KindGuess.system,
                                              prompt: KindGuess.prompt(transcript: m.transcriptText, title: m.info.calendarTitle ?? m.info.title,
                                                                       userName: Self.userName, facts: KindGuess.facts(m)),
                                              maxTokens: 400, reasoning: false)) ?? "(failed)"
            print(String(format: "[guess] %@ → %@ (%@) in %.0f s", m.id, KindGuess.parse(answer)?.rawValue ?? "unclear",
                         String(answer.prefix(30)).replacingOccurrences(of: "\n", with: " "), Date().timeIntervalSince(started)))
        }
    }

    @Test(.enabled(if: folder != nil)) func run() async throws {
        try await DiarizationEvalTests.offMain { try await Self.process() }
    }

    static func process() async throws {
        let folder = try #require(Self.folder)
        try assertSafe(folder)

        let fm = FileManager.default
        let infoURL = folder.appendingPathComponent("meeting.json")
        guard fm.fileExists(atPath: infoURL.path) else {
            Issue.record("No meeting.json in \(folder.path); point EARL_REPROCESS at a copy of a meeting folder.")
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var info = try decoder.decode(MeetingInfo.self, from: Data(contentsOf: infoURL))

        // EARL_REPROCESS_NAMES_ONLY=1: rerun just the name guess on the
        // transcript a previous replay wrote, through the same combined path
        // (address first, then the model) `AppState.guessSpeakerNames` uses,
        // and show the model's raw answer.
        if env["EARL_REPROCESS_NAMES_ONLY"] == "1" {
            let store = MeetingStore(root: folder.deletingLastPathComponent())
            var meeting = try #require(store.load(folder))
            meeting.speakers = meeting.speakers.map { var s = $0; s.name = nil; return s }
            var guesser = SpeakerNameGuesser()
            if let model = Self.model { guesser.summarizer.model = model }
            let result = await SpeakerNameGuesser.combinedGuess(meeting: meeting, attendees: info.attendees ?? [],
                                                                 userName: Self.userName, guesser: guesser)
            print("[reprocess] addressed: " + SpeakerNameGuesser.addressedLogLine(result.addressed))
            if !result.remaining.isEmpty {
                let prompt = SpeakerNameGuesser.prompt(meeting: meeting, candidates: result.remaining,
                                                       attendees: info.attendees ?? [], userName: Self.userName, limit: 60000)
                try prompt.write(to: folder.appendingPathComponent("names-prompt.txt"), atomically: true, encoding: .utf8)
            }
            if let answer = result.modelAnswer { print("[reprocess] raw answer: \(answer)") }
            if let error = result.modelError { print("[reprocess] guessing names failed: \(error)") }
            print("[reprocess] name guesses: " + SpeakerNameGuesser.logLine(result.modelOutcomes))
            return
        }

        // EARL_REPROCESS_NOTES_ONLY=1: keep the transcript and names, rewrite
        // only the notes, the way "Summarize again" does.
        if env["EARL_REPROCESS_NOTES_ONLY"] == "1" {
            let store = MeetingStore(root: folder.deletingLastPathComponent())
            var meeting = try #require(store.load(folder))
            try await writeNotes(&meeting, info: &info, store: store, folder: folder)
            try store.save(info, in: folder)
            meeting.info = info
            store.saveMarkdown(meeting)
            return
        }

        // The same prompt Earl would build for this meeting (R2-1, Q-1).
        let attendeeTerms = WhisperPrompt.attendeeTerms(info.attendees ?? [])
        var transcriber = Transcriber()
        transcriber.prompt = WhisperPrompt.build(extraNames: attendeeTerms)
        transcriber.promptTerms = WhisperPrompt.buildTerms(extraNames: attendeeTerms)
        transcriber.usedSpeakers = info.usedSpeakers

        let started = Date()
        let output = try await transcriber.transcribe(folder: folder) { _ in }
        print(String(format: "[reprocess] transcribed in %.1f s, %d turns, %d words",
                     Date().timeIntervalSince(started), output.turns.count, NotesGate.wordCount(output.turns)))

        // A placeholder root: every MeetingStore call below names its own folder.
        let store = MeetingStore(root: folder.deletingLastPathComponent())
        try store.saveTranscript(output.turns, in: folder)
        var speakers = output.speakers
        try store.saveSpeakers(speakers, in: folder)

        info.language = output.language
        info.vocabularyTerms = transcriber.promptTerms
        info.speakerModel = output.speakerModel
        info.speakerCount = output.speakerModel == nil ? nil : output.speakers.count
        info.diarizationSeconds = output.diarizationSeconds
        info.speakerNote = output.speakerNote
        info.echoRemovedSeconds = output.echoRemovedSeconds

        var meeting = Meeting(id: folder.lastPathComponent, folder: folder, info: info, turns: output.turns,
                              summary: "", files: [], speakers: speakers)

        // Q-3's combined guesser (address first, then the model), called the
        // way AppState.guessSpeakerNames does.
        if Prefs.guessSpeakerNames, !SpeakerNameGuesser.candidates(in: meeting).isEmpty {
            var guesser = SpeakerNameGuesser()
            if let model = Self.model { guesser.summarizer.model = model }
            let result = await SpeakerNameGuesser.combinedGuess(meeting: meeting, attendees: info.attendees ?? [],
                                                                 userName: Self.userName, guesser: guesser)
            print("[reprocess] addressed: " + SpeakerNameGuesser.addressedLogLine(result.addressed))
            if let answer = result.modelAnswer { print("[reprocess] raw answer: \(answer)") }
            if let error = result.modelError { print("[reprocess] guessing names failed: \(error)") }
            print("[reprocess] name guesses: " + SpeakerNameGuesser.logLine(result.modelOutcomes))
            let (guesses, dropped) = result.final(speakers: speakers) // V-1
            speakers = SpeakerNameGuesser.apply(guesses, to: speakers)
            meeting.speakers = speakers
            do {
                try store.saveSpeakers(speakers, in: folder)
            } catch {
                print("[reprocess] saving speaker names failed: \(error.localizedDescription)")
            }
            print("[reprocess] guessed names: " + NameCollisions.logLine(kept: guesses, dropped: dropped))
        }

        if noNotes {
            print("[reprocess] --no-notes: skipping notes")
        } else if meeting.turns.isEmpty {
            print("[reprocess] no transcript: skipping notes")
        } else if !NotesGate.worthNotes(turns: meeting.turns, duration: info.duration) {
            print("[reprocess] too short for notes: \(NotesGate.wordCount(meeting.turns)) words, \(info.duration) s")
        } else {
            try await writeNotes(&meeting, info: &info, store: store, folder: folder)
        }

        try store.save(info, in: folder)
        meeting.info = info
        store.saveMarkdown(meeting)
        print("[reprocess] wrote transcript.md in \(folder.path)")
    }

    /// Notes as `AppState.process` writes them: language (R2-7), and S-1's
    /// series context from the library the copy came from, read only
    /// (EARL_REPROCESS_LIBRARY, default ~/Meetings).
    static func writeNotes(_ meeting: inout Meeting, info: inout MeetingInfo, store: MeetingStore, folder: URL) async throws {
        var summarizer = Summarizer()
        if let model = Self.model { summarizer.model = model }
        print("[reprocess] notes model: \(summarizer.model)")
        summarizer.vocabulary = WhisperPrompt.fitting(Prefs.vocabularyTerms)
        summarizer.prompt.language = NotesLanguage.resolve(setting: Prefs.notesLanguage, detected: info.language)
        summarizer.prompt.userName = Self.userName
        let libraryPath = env["EARL_REPROCESS_LIBRARY"] ?? FileManager.default.homeDirectoryForCurrentUser.path + "/Meetings"
        let library = MeetingStore(root: URL(fileURLWithPath: libraryPath, isDirectory: true)).loadAll()
            .filter { $0.id != meeting.id }
        meeting.info = info
        // K-1: the kind the way AppState resolves it (EARL_REPROCESS_KIND forces one).
        let forced = env["EARL_REPROCESS_KIND"].flatMap(MeetingKind.init(rawValue:))
        let model = summarizer.model
        let snapshot = meeting
        var resolved: (MeetingKind, String)
        if let forced {
            resolved = (forced, "forced")
        } else {
            resolved = await MeetingKind.resolve(snapshot, in: library + [snapshot]) {
                await KindGuess.ask(snapshot, userName: Self.userName, model: model)
            }
        }
        let talk = MeetingKind.talk(in: meeting)
        print(String(format: "[reprocess] kind: %@ (%@) · you said %.0f %%, top voice %.0f %%", resolved.0.rawValue,
                     resolved.1, talk.mine * 100, (talk.top ?? 0) * 100))
        info.notesKind = resolved.0.rawValue
        meeting.info = info
        let series = SeriesContext.prepare(for: meeting, in: library + [meeting], userName: Self.userName,
                                           kind: resolved.0)
        summarizer.prompt.seriesContext = series.text
        summarizer.prompt.kind = series.kind
        print("[reprocess] " + series.log)
        let started = Date()
        do {
            let result = try await summarizer.summarize(meeting.transcriptText, context: SummaryContext(info)) { _ in }
            try store.saveSummary(TodoFiles.keepingTicks(result.markdown, in: folder), in: folder)
            meeting.summary = result.markdown
            if info.titleIsDefault, let title = result.title {
                info.title = title
                info.titleIsDefault = false
            }
            info.headline = result.headline
            print(String(format: "[reprocess] wrote notes (%d chars) in %.0f s", result.markdown.count, Date().timeIntervalSince(started)))
        } catch {
            print("[reprocess] notes failed, continuing without them: \(error.localizedDescription)")
        }
    }

    /// The test process has its own defaults, not Earl's: pass the notes
    /// model and your name to match what the app would use.
    static var model: String? { env["EARL_REPROCESS_MODEL"].flatMap { $0.isEmpty ? nil : $0 } }
    static var userName: String? { env["EARL_REPROCESS_USER"].flatMap { $0.isEmpty ? nil : $0 } ?? Prefs.userName }

    static func assertSafe(_ folder: URL) throws {
        let path = folder.standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let meetingsRoot = home + "/Meetings"
        guard path != meetingsRoot, !path.hasPrefix(meetingsRoot + "/") else {
            throw PipelineError.message("Refusing to reprocess anything under ~/Meetings.")
        }
        let tmp = URL(fileURLWithPath: env["TMPDIR"] ?? "/tmp").standardizedFileURL.path
        let allowed = [tmp, "/tmp"]
        guard allowed.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else {
            throw PipelineError.message("reprocess.sh only runs on a copy under $TMPDIR or /tmp (got \(path)).")
        }
    }
}
