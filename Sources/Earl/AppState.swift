import AppKit
import Foundation
import UserNotifications

enum SidebarItem: Hashable {
    case meeting(String)
    case engine
    case todos // R3-2
    /// S-2: a series page by `MeetingSeries` key; the brief when its next event is coming.
    case series(String)
    case ask // S-3: questions across all meetings
}

/// A meeting being transcribed and/or summarized, with live output for the UI.
struct Job: Identifiable {
    enum Kind { case full, summaryOnly }
    enum Step { case queued, transcribing, summarizing }

    let id: String // meeting id
    var kind: Kind
    var step: Step = .queued
    var startedAt: Date?
    var status = "Waiting…"

    // Transcription
    var model = ""
    var track: String?
    var trackIndex = 0
    var trackCount = 2
    var trackProgress: Double = 0
    var language: String?
    var liveTurns: [Turn] = []

    // Summary
    var passLabel = ""
    var thinkingChars = 0
    var liveText = ""
    var tokens = 0
    var tokensPerSecond: Double = 0

    /// Overall progress through transcription, 0...1.
    var transcriptionProgress: Double {
        (Double(trackIndex) + trackProgress) / Double(max(1, trackCount))
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var meetings: [Meeting] = []
    @Published var selection: SidebarItem?
    /// R3-2: every checkbox line across meetings, derived on reload().
    @Published private(set) var actionItems: [ActionItem] = []

    @Published private(set) var recordingID: String? { didSet { updateActivity() } }
    @Published private(set) var recordingStartedAt: Date?
    @Published private(set) var isStarting = false
    /// Ticks every second while recording, to drive the elapsed-time display.
    @Published private(set) var now = Date()

    /// Processing queue; the first non-queued job is the one running.
    @Published private(set) var jobs: [Job] = [] { didSet { updateActivity() } }
    /// Meetings whose notes Earl finished and you haven't seen arrive yet; the
    /// front page settles in once for each.
    private(set) var freshNotes: Set<String> = []
    /// Counts finished notes, so Earl can nod in the sidebar.
    @Published private(set) var notesFinished = 0

    let engine = Engine()
    let shortcut = GlobalShortcut() // R1-1
    let callDetector = CallDetector() // R1-2
    let calendar = CalendarService() // R2-1
    let liveStage = LiveStage() // R2-5
    let armed = ArmedRecorder() // R2-6
    let offerPanel = OfferPanel() // R2-6
    let reminders = RemindersSync() // R3-2

    private var recorder: Recorder?
    private var timer: Timer?
    private var worker: Task<Void, Never>?
    private var currentTask: Task<Void, Never>?
    private var activity: NSObjectProtocol?

    var isRecording: Bool { recordingID != nil }
    /// The one definition of busy: a recording, a start, or a meeting being processed.
    /// A restart (setup) and an update install both wait for this to end.
    var isBusy: Bool { isRecording || isStarting || !jobs.isEmpty }
    var store: MeetingStore { MeetingStore(root: Prefs.storageURL) }
    var activeJob: Job? { jobs.first { $0.step != .queued } }

    var elapsedText: String {
        guard let start = recordingStartedAt else { return "" }
        return Meeting.timestamp(max(0, now.timeIntervalSince(start)))
    }

    init() {
        Prefs.register()
        reload()
        guard !DemoMode.isActive else { return } // U-0: no services, no processing
        // D-3: a built-in notes server left by a crash goes; a running one waits for meetings in progress.
        Task {
            await BuiltInServer.shared.clearOrphan()
            await BuiltInServer.shared.setAppBusy { [weak self] in !(self?.jobs.isEmpty ?? true) }
        }
        resumeInterrupted()
        if Prefs.textOnly { applyTextOnly() } // P-1: audio left by a quit mid-processing
        // R1-1: registered here so the shortcut works before any window opens.
        shortcut.onPress = { [weak self] in self?.shortcutPressed() }
        shortcut.start()
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        Task { await engine.refresh(meetings: meetings) }
        // R1-2: offer to record calls, and to stop when they end.
        callDetector.start(record: { [weak self] in self?.startRecording() },
                           stop: { [weak self] in self?.stopRecording() })
        setUpNextMeeting() // R2-6: armed recordings and the floating offer panel
        BriefNudger.shared.start(state: self) // S-2: the nudge before a series meeting
        // D-4: updates wait for meetings, the notes server's leases and downloads.
        Updates.shared.isBusy = { [weak self] in
            guard let self else { return false }
            return !Updates.mayInstallNow(busy: self.isBusy, serving: BuiltInServer.isServing,
                                          downloading: !self.engine.downloads.isEmpty)
        }
        Updates.shared.start()
    }

    func reload() {
        meetings = store.loadAll()
        BriefCache.entries.removeAll() // S-2
        let superseded = SeriesTodos.superseded(in: meetings) // a task carried over a series counts once
        actionItems = meetings.flatMap { ActionItems.parse($0.summary, meetingID: $0.id) } // R3-2
            .filter { !superseded.contains($0.id) }
    }

    func meeting(_ id: String) -> Meeting? {
        meetings.first { $0.id == id }
    }

    func job(_ id: String) -> Job? {
        jobs.first { $0.id == id }
    }

    func isBusy(_ id: String) -> Bool { job(id) != nil }

    /// True once per meeting whose notes just arrived.
    func takeFreshNotes(_ id: String) -> Bool { freshNotes.remove(id) != nil }

    func refreshEngine() async {
        guard !DemoMode.isActive else { return } // U-0: the demo sets the engine's state
        await engine.refresh(meetings: meetings)
    }

    // MARK: - Recording

    func startRecording() {
        guard recorder == nil, !isStarting else { return }
        MeetingPlayer.stopAll() // R3-1: playback would leak into the capture.
        isStarting = true
        // D-3: on 16 GB or less, an idle built-in notes writer gives its memory back.
        if BuiltInServer.stopsForRecording(memory: ProcessInfo.processInfo.physicalMemory) {
            Task { await BuiltInServer.shared.stopUnlessBusy() }
        }
        Task {
            defer { isStarting = false }
            var created: Meeting?
            do {
                guard await Recorder.requestMicrophoneAccess() else {
                    AppDelegate.openOnboarding?() // D-2: the setup window shows where the switch is
                    throw PipelineError.message("Finish getting ready first.")
                }
                let meeting = try store.create(startedAt: Date(), microphone: Recorder.microphoneName)
                created = meeting
                let rec = Recorder(outputDir: meeting.folder, live: liveStage.prepare()) // R2-5
                rec.onError = { [weak self] error in
                    Task { @MainActor in self?.recordingFailed(error) }
                }
                try await rec.start()
                liveStage.start() // R2-5

                recorder = rec
                recordingID = meeting.id
                recordingStartedAt = meeting.info.startedAt
                startTimer()
                // R2-4: speakers or headphones decides whether echo removal runs.
                if let output = OutputDevice.current() {
                    update(meeting.id) {
                        $0.outputDevice = output.name
                        $0.usedSpeakers = output.isSpeakers
                    }
                }
                // R1-2: remember which call this recording belongs to.
                if let call = callDetector.recordingDidStart() {
                    update(meeting.id) {
                        $0.callApp = call.name
                        $0.callAppBundleID = call.bundleID
                    }
                }
                // R2-6: an armed event claims a recording started near it; R2-1 otherwise.
                if !claimArmedRecording(meeting.id) { autoLinkCalendarEvent(meeting.id) }
                reload()
                selection = .meeting(meeting.id)
            } catch {
                liveStage.end() // R2-5
                if let created { try? FileManager.default.removeItem(at: created.folder) }
                showError("Couldn't start recording", error)
            }
            engine.refreshLocal(meetings: meetings)
        }
    }

    /// D-3: a fresh look for the notes writer, which the Summaries card shows too.
    private func resolveNotesBackend() async -> NotesBackend {
        let backend = await NotesEngine.resolve()
        engine.adopt(backend)
        return backend
    }

    func stopRecording() {
        Task { await finishRecording(thenProcess: true) }
    }

    func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    /// Current input levels for the meters (0...1).
    var levels: (them: Float, me: Float) { recorder?.levels ?? demoLevels ?? (0, 0) }
    var lastSound: (them: Date?, me: Date?) { recorder?.lastSound ?? (demoLevels != nil ? (Date(), Date()) : (nil, nil)) }
    /// U-0: fixed meter levels for a demo recording.
    var demoLevels: (them: Float, me: Float)?

    /// Stops a running recording before quitting; processing resumes on next launch.
    func quit() {
        Task {
            if isRecording { await finishRecording(thenProcess: false) }
            NSApp.terminate(nil)
        }
    }

    private func finishRecording(thenProcess: Bool) async {
        guard let rec = recorder, let id = recordingID else { return }
        recorder = nil
        stopTimer()
        await rec.stop()
        liveStage.end(saveIn: Prefs.storageURL.appendingPathComponent(id)) // R2-5
        let startedAt = recordingStartedAt ?? Date()
        recordingID = nil
        recordingStartedAt = nil
        callDetector.recordingDidStop() // R1-2

        update(id) {
            $0.duration = Date().timeIntervalSince(startedAt)
            $0.status = .transcribing
        }
        if thenProcess { enqueue(id, kind: .full) }
    }

    private func recordingFailed(_ error: Error) {
        guard let id = recordingID else { return }
        recorder = nil
        stopTimer()
        liveStage.end(saveIn: Prefs.storageURL.appendingPathComponent(id)) // R2-5
        let startedAt = recordingStartedAt ?? Date()
        recordingID = nil
        recordingStartedAt = nil
        callDetector.recordingDidStop() // R1-2
        update(id) {
            $0.duration = Date().timeIntervalSince(startedAt)
            $0.status = .transcribing
        }
        notify("Recording stopped unexpectedly", error.localizedDescription)
        enqueue(id, kind: .full)
    }

    private func startTimer() {
        now = Date()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.now = Date() }
        }
        // .common so it keeps ticking while menus are open.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Processing queue

    func retranscribe(_ id: String) { enqueue(id, kind: .full) }
    func resummarize(_ id: String) { enqueue(id, kind: .summaryOnly) }

    /// K-1: rewrite the notes in another shape, and remember it for the series.
    func rewriteNotes(_ id: String, as kind: MeetingKind) {
        guard !isBusy(id) else { return }
        update(id) {
            $0.notesKind = kind.rawValue
            $0.notesKindByUser = true
        }
        resummarize(id)
    }

    /// Retries whatever step failed.
    func retry(_ id: String) {
        guard let m = meeting(id), !m.isUnreadable else { return }
        // A transcript without a summary means only the summary step failed.
        enqueue(id, kind: !m.turns.isEmpty && (m.summary.isEmpty || !m.hasAudio) ? .summaryOnly : .full)
    }

    func cancel(_ id: String) {
        guard let job = job(id) else { return }
        if job.step == .queued {
            jobs.removeAll { $0.id == id }
            update(id) { $0.status = .failed; $0.error = "Processing was cancelled." }
        } else {
            currentTask?.cancel()
        }
    }

    private func enqueue(_ id: String, kind: Job.Kind) {
        guard !isBusy(id), meeting(id)?.isUnreadable != true else { return }
        jobs.append(Job(id: id, kind: kind))
        guard worker == nil else { return }
        worker = Task {
            while let next = jobs.first(where: { $0.step == .queued }) {
                let task = Task { await process(next.id, kind: next.kind) }
                currentTask = task
                await task.value
                if let m = meeting(next.id), m.info.status != .failed, !m.summary.isEmpty {
                    freshNotes.insert(next.id)
                    notesFinished += 1
                }
                jobs.removeAll { $0.id == next.id }
            }
            currentTask = nil
            worker = nil
            engine.refreshLocal(meetings: meetings)
        }
    }

    private func updateJob(_ id: String, _ change: (inout Job) -> Void) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[i])
    }

    private func process(_ id: String, kind: Job.Kind) async {
        guard var meeting = store.load(Prefs.storageURL.appendingPathComponent(id)), !meeting.isUnreadable else { return }
        updateJob(id) { $0.startedAt = Date() }
        do {
            if kind == .full {
                let modelPath = Prefs.whisperModel
                let modelName = WhisperModelOption.displayName(forPath: modelPath)
                updateJob(id) {
                    $0.step = .transcribing
                    $0.model = modelName
                    $0.status = "Preparing audio…"
                }
                update(id) { $0.status = .transcribing; $0.error = nil }

                let started = Date()
                var transcriber = Transcriber()
                // Q-1: attendeeTerms drops mailing lists and "-Extern" suffixes,
                // and adds the company name; buildTerms is kept alongside the
                // prompt instead of re-parsed from its sentence.
                let attendeeTerms = WhisperPrompt.attendeeTerms(meeting.info.attendees ?? []) // R2-1
                transcriber.prompt = WhisperPrompt.build(extraNames: attendeeTerms)
                transcriber.promptTerms = WhisperPrompt.buildTerms(extraNames: attendeeTerms)
                transcriber.usedSpeakers = meeting.info.usedSpeakers // R2-4
                let output = try await transcriber.transcribe(folder: meeting.folder) { [weak self] event in
                    self?.updateJob(id) { job in
                        switch event {
                        case .track(let speaker, let index, let count):
                            job.track = speaker
                            job.trackIndex = index
                            job.trackCount = count
                            job.trackProgress = 0
                            job.status = speaker == "Me" ? "Transcribing your microphone" : "Transcribing the call audio"
                        case .progress(let p):
                            job.trackProgress = p
                        case .language(let l):
                            job.language = l
                        case .segment(let turn):
                            Transcriber.appendLive(turn, to: &job.liveTurns) // R2-2: words arrive one by one
                        case .diarizing:
                            job.status = "Telling voices apart…" // R2-2
                        case .removingEcho:
                            job.status = "Removing echo…" // R2-4
                        }
                    }
                }
                // R2-3: keep confirmed names when transcribing again.
                var carried = SpeakerEdit.carryOver(from: meeting.speakers, to: output.speakers)
                // R3-3: voices you've named before, ahead of the guesser.
                let recognised = VoiceStore.shared.recognise(carried, attendees: meeting.info.attendees ?? [])
                carried = recognised.speakers
                if let line = recognised.log { LogFile(meeting.folder.appendingPathComponent("whisper.log")).write(line) }
                try store.saveTranscript(output.turns, in: meeting.folder)
                let speakers = LiveVoice.withAvatars(carried, turns: output.turns, in: meeting.folder) // R2-5
                try store.saveSpeakers(speakers, in: meeting.folder) // R2-2
                meeting.turns = output.turns
                meeting.speakers = speakers
                if !Prefs.keepAudio { store.deleteAudio(in: meeting.folder) }
                update(id) {
                    $0.language = output.language
                    $0.transcriptionModel = modelName
                    $0.transcriptionSeconds = Date().timeIntervalSince(started)
                    $0.vocabularyTerms = transcriber.promptTerms  // R1-3, Q-1: kept alongside the prompt
                    // R2-2
                    $0.speakerModel = output.speakerModel
                    $0.speakerCount = output.speakerModel == nil ? nil : output.speakers.count
                    $0.diarizationSeconds = output.diarizationSeconds
                    $0.speakerNote = output.speakerNote
                    $0.echoRemovedSeconds = output.echoRemovedSeconds // R2-4
                }

                // R2-3: a first guess at names, so the summary can use them.
                // D-3: a fresh look first, so names and notes use the same backend.
                if Prefs.guessSpeakerNames, !SpeakerNameGuesser.candidates(in: meeting).isEmpty,
                   await resolveNotesBackend() != .none {
                    updateJob(id) { $0.status = "Matching voices to names…" }
                    meeting.speakers = await guessSpeakerNames(meeting)
                    try Task.checkCancellation()
                    try store.saveSpeakers(meeting.speakers, in: meeting.folder)
                }
            }

            // Q-1: skip notes for a recording that's barely anything ("Yeah.");
            // .summaryOnly means the user asked for notes explicitly (retry),
            // so that always goes through.
            let worthNotes = kind == .summaryOnly || NotesGate.worthNotes(turns: meeting.turns, duration: meeting.info.duration)
            if Prefs.summariesEnabled && !meeting.turns.isEmpty && !worthNotes {
                LogFile(meeting.folder.appendingPathComponent("whisper.log"))
                    .write("Too short for notes: \(NotesGate.wordCount(meeting.turns)) words")
            }
            if Prefs.summariesEnabled && !meeting.turns.isEmpty && worthNotes {
                // D-3: LM Studio or Ollama may have started (or stopped) since Earl last looked.
                let backend = await resolveNotesBackend()
                // Nothing to write with: say so now instead of knocking on LM Studio's door.
                if backend == .none { throw PipelineError.message(NotesEngine.noWriter) }
                let model = NotesEngine.model(for: backend, fallback: Prefs.llmModel)
                updateJob(id) {
                    $0.step = .summarizing
                    $0.model = model
                    $0.status = NotesEngine.connecting(backend)
                    $0.liveText = ""
                }
                update(id) { $0.status = .summarizing; $0.error = nil }

                let started = Date()
                var summarizer = Summarizer()
                summarizer.reasoning = Prefs.notesThinking(model) // R2-7
                summarizer.prompt.language = NotesLanguage.resolve(setting: Prefs.notesLanguage,
                                                                   detected: self.meeting(id)?.info.language) // R2-7
                // S-1: earlier meetings of the series, and the meeting's kind.
                meeting.info = self.meeting(id)?.info ?? meeting.info // speakers found since loading
                let userName = Prefs.userName ?? meeting.info.attendees?.first(where: \.isMe)?.name
                // K-1: what kind of meeting it was; the model is asked only
                // when the numbers can't tell.
                let library = meetings
                let snapshot = meeting
                let resolved = await MeetingKind.resolve(meeting, in: library) { [weak self] in
                    self?.updateJob(id) { $0.status = "Working out what kind of meeting this was…" }
                    return await KindGuess.ask(snapshot, userName: userName, model: model)
                }
                update(id) { $0.notesKind = resolved.kind.rawValue }
                meeting.info.notesKind = resolved.kind.rawValue
                LogFile(meeting.folder.appendingPathComponent("whisper.log"))
                    .write("Kind: \(resolved.kind.rawValue) (\(resolved.reason))")
                let series = SeriesContext.prepare(for: meeting, in: meetings, userName: userName, kind: resolved.kind)
                summarizer.prompt.seriesContext = series.text
                summarizer.prompt.kind = series.kind
                LogFile(meeting.folder.appendingPathComponent("whisper.log")).write(series.log)
                let result = try await summarizer.summarize(
                    meeting.transcriptText, context: SummaryContext(meeting.info)) { [weak self] event in
                    self?.updateJob(id) { job in
                        switch event {
                        case .status(let s):
                            job.status = s
                        case .newPass(let label):
                            job.passLabel = label
                            job.status = label
                            job.liveText = ""
                            job.thinkingChars = 0
                        case .progress(let text, let thinkingChars, let tokens, let perSecond):
                            job.liveText = text
                            job.thinkingChars = thinkingChars
                            job.status = text.isEmpty && thinkingChars > 0 ? "Thinking…" : job.passLabel
                            job.tokens = tokens
                            job.tokensPerSecond = perSecond
                        }
                    }
                }
                // R3-2: keep ticks on items that are still there.
                try store.saveSummary(TodoFiles.keepingTicks(result.markdown, in: meeting.folder), in: meeting.folder)
                update(id) {
                    if $0.titleIsDefault, let title = result.title {
                        $0.title = title
                        $0.titleIsDefault = false
                    }
                    $0.headline = result.headline // U-2
                    $0.summaryModel = model
                    $0.summarySeconds = Date().timeIntervalSince(started)
                    $0.summaryTokensPerSecond = result.tokensPerSecond
                    $0.namesChangedSinceSummary = nil // R2-3
                    $0.summaryContext = result.context // R2-7
                    $0.summaryContextByEarl = result.context == nil ? nil : result.loadedByEarl
                }
                ModelSpeed.record(model: model, tokensPerSecond: result.tokensPerSecond, // R2-7
                                  seconds: Date().timeIntervalSince(started), meetingSeconds: meeting.info.duration)
            }

            update(id) { $0.status = .done; $0.error = nil }
            if let done = self.meeting(id) {
                store.saveMarkdown(done)
                notify("Meeting notes ready", WhosWho.notificationBody(for: done)) // W-1
            }
        } catch {
            let cancelled = error is CancellationError || Task.isCancelled
            update(id) {
                $0.status = .failed
                $0.error = cancelled ? "Processing was cancelled." : error.localizedDescription
            }
            if let m = self.meeting(id) { store.saveMarkdown(m) }
            if !cancelled { notify("Processing failed", error.localizedDescription) }
        }
    }

    /// Picks up meetings left mid-way when the app last quit.
    private func resumeInterrupted() {
        for m in meetings {
            switch m.info.status {
            case .recording:
                // Audio from a crashed recording may still be usable.
                update(m.id) {
                    $0.status = .failed
                    $0.error = "Earl quit while recording. Retry to transcribe what was captured."
                }
            case .transcribing:
                enqueue(m.id, kind: .full)
            case .summarizing:
                enqueue(m.id, kind: m.turns.isEmpty ? .full : .summaryOnly)
            case .done, .failed:
                break
            }
        }
    }

    // MARK: - Editing

    func rename(_ id: String, to title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, meeting(id)?.isUnreadable != true else { return }
        update(id) {
            $0.title = title
            $0.titleIsDefault = false
        }
        if let m = meeting(id) { store.saveMarkdown(m) }
    }

    func delete(_ id: String) {
        guard id != recordingID, !isBusy(id), let m = meeting(id) else { return }
        let alert = NSAlert()
        alert.messageText = "Delete “\(m.info.title)”?"
        alert.informativeText = "The meeting folder, including its audio, will be moved to the Trash."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        try? FileManager.default.trashItem(at: m.folder, resultingItemURL: nil)
        if selection == .meeting(id) { selection = nil }
        reload()
        engine.refreshLocal(meetings: meetings)
    }

    func deleteAudio(_ id: String) {
        guard id != recordingID, !isBusy(id), let m = meeting(id) else { return }
        let alert = NSAlert()
        alert.messageText = "Delete the audio of “\(m.info.title)”?"
        alert.informativeText = "The transcript and summary are kept, but you won't be able to transcribe this meeting again."
        alert.addButton(withTitle: "Delete Audio")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.deleteAudio(in: m.folder)
        reload()
        engine.refreshLocal(meetings: meetings)
    }

    func deleteAllAudio() {
        let candidates = meetings.filter { $0.hasAudio && $0.id != recordingID && !isBusy($0.id) && !$0.turns.isEmpty }
        guard !candidates.isEmpty else { return }
        let bytes = candidates.reduce(0) { $0 + $1.audioBytes }
        let alert = NSAlert()
        alert.messageText = "Delete audio from \(candidates.count) transcribed meetings?"
        alert.informativeText = "Frees \(Format.bytes(bytes)). Transcripts and summaries are kept."
        alert.addButton(withTitle: "Delete Audio")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        for m in candidates { store.deleteAudio(in: m.folder) }
        reload()
        engine.refreshLocal(meetings: meetings)
    }

    func reveal(_ id: String) {
        guard let m = meeting(id) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([m.folder])
    }

    func open(_ id: String, file: String) {
        guard let m = meeting(id) else { return }
        NSWorkspace.shared.open(m.folder.appendingPathComponent(file))
    }

    func copyMarkdown(_ id: String) {
        guard let m = meeting(id) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(m.markdown, forType: .string)
    }

    func openPrivacySettings(_ pane: String) { Engine.openPrivacySettings(pane) }

    // MARK: - Helpers

    /// Keeps macOS from App-Napping Earl while it records or processes. Without
    /// this, a menu bar app in the background gets throttled and summaries
    /// stream several times slower.
    private func updateActivity() {
        let needed = recordingID != nil || !jobs.isEmpty
        if needed, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled], reason: "Recording or processing a meeting")
        } else if !needed, let token = activity {
            ProcessInfo.processInfo.endActivity(token)
            activity = nil
        }
    }

    private func update(_ id: String, _ change: (inout MeetingInfo) -> Void) {
        let folder = Prefs.storageURL.appendingPathComponent(id)
        guard var meeting = store.load(folder), !meeting.isUnreadable else { return }
        change(&meeting.info)
        try? store.save(meeting.info, in: folder)
        reload()
    }

    private func notify(_ title: String, _ body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    private func showError(_ title: String, _ error: Error) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }
}

// MARK: - U-0 demo hooks

extension AppState {
    /// U-0: puts a meeting "on air" for UI snapshots, without a recorder.
    /// `elapsed` fixes the clock so every snapshot shows the same time.
    func demoRecording(_ id: String?, startedAt: Date = Date(), elapsed: TimeInterval = 0,
                       levels: (them: Float, me: Float)? = nil) {
        recordingID = id
        recordingStartedAt = id == nil ? nil : startedAt
        now = startedAt.addingTimeInterval(elapsed)
        demoLevels = id == nil ? nil : levels
    }

    /// U-0: shows processing jobs without running them.
    func demoJobs(_ jobs: [Job]) {
        self.jobs = jobs
    }
}
