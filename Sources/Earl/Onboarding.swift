import AppKit
import SwiftUI

// D-2: the first-run window. It takes a colleague from first launch to ready,
// one calm screen per step, in Apple's own style (system materials, SF Pro,
// SF Symbols); only Earl's face and his body lines are his. Earl watches the
// permissions and downloads himself and moves on when they flip.

extension Prefs.Key {
    /// Set when the user reaches "You're All Set": the window no longer opens by itself.
    static let onboardingFinished = "onboardingFinished"
    /// Screen audio was asked for, so the next launch is the restart: reopen the window there.
    static let screenAudioAsked = "screenAudioAsked"
    /// Earl quit in the middle of a download: start it again when the window reopens.
    static let onboardingResumeDownload = "onboardingResumeDownload"
}

enum OnboardingScreen: Hashable {
    case welcome
    case step(SetupStep)
    case done
}

/// Which screen shows, from SetupGuide's list. Pure, so it can be tested without the window.
struct OnboardingFlow: Equatable {
    var screen: OnboardingScreen

    /// From welcome or a finished step to the next missing step, or done.
    /// An unfinished step stays; done stays done. `modelsDeferred`: the
    /// listening tools are downloading in the background, or were put off
    /// with "Not Now" after a failure, so the permissions come first and the
    /// models step comes last (still never done while they're missing).
    mutating func advance(_ s: SetupState, modelsDeferred: Bool = false) {
        let left = SetupGuide.steps(s)
        let ahead = modelsDeferred ? left.filter { $0 != .models } : left
        let last: OnboardingScreen = left.contains(.models) ? .step(.models) : .done
        switch screen {
        case .done: return
        case .step(let step) where ahead.contains(step): return
        case .step(.models) where ahead.isEmpty && left.contains(.models): return // nothing else to do: wait here
        case .welcome, .step: screen = ahead.first.map { .step($0) } ?? last
        }
    }

    /// Where the window opens. Welcome only on a true first run (nothing
    /// downloaded, the microphone never asked); after the restart, or when
    /// the user comes back, the next missing step; done when nothing is left.
    static func resume(_ s: SetupState, finishedBefore: Bool) -> OnboardingFlow {
        guard let next = SetupGuide.next(s) else { return OnboardingFlow(screen: .done) }
        if !finishedBefore && next == .models && s.microphone == .notAsked { return OnboardingFlow(screen: .welcome) }
        return OnboardingFlow(screen: .step(next))
    }

    /// The page dots once the models are put off: their dot moves to the end, before done.
    static func modelsLast(_ pages: [OnboardingScreen]) -> [OnboardingScreen] {
        guard let i = pages.firstIndex(of: .step(.models)) else { return pages }
        var pages = pages
        pages.remove(at: i)
        pages.insert(.step(.models), at: pages.last == .done ? pages.count - 1 : pages.count)
        return pages
    }

    /// The screens ahead, for the page dots: asking for screen audio always
    /// needs the restart after it.
    static func pages(_ s: SetupState, from start: OnboardingScreen) -> [OnboardingScreen] {
        var pages: [OnboardingScreen] = start == .welcome ? [.welcome] : []
        for step in SetupGuide.steps(s) {
            pages.append(.step(step))
            if step == .screenAudio { pages.append(.step(.relaunch)) }
        }
        return pages + [.done]
    }
}

/// D-3: restarting for screen audio while the tools download would throw the
/// download away (it starts again from zero). So the button waits for it, and
/// Earl restarts by himself when it's done. Pure, so it can be tested.
struct RelaunchPlan: Equatable {
    /// "Restart After Download" was pressed.
    private(set) var waiting = false

    /// The restart button: true to restart now; during a download (or a
    /// recording, or a meeting being processed) wait for it.
    mutating func press(downloading: Bool, busy: Bool = false) -> Bool {
        guard downloading || busy else { return true }
        waiting = true
        return false
    }

    /// Restart by itself: asked to, the download done, and no call being
    /// recorded or meeting being processed (a restart would end them).
    func shouldRelaunch(downloading: Bool, busy: Bool) -> Bool { waiting && !downloading && !busy }

    /// A failed download keeps its reason on screen: no restart by itself,
    /// the button is plain "Restart Earl" again.
    mutating func downloadEnded(failed: Bool) { if failed { waiting = false } }

    mutating func cancel() { waiting = false }

    static func button(downloading: Bool, waiting: Bool) -> String {
        downloading || waiting ? OnboardingCopy.relaunchAfterDownload : OnboardingCopy.relaunch.primary
    }

    /// Only a quit in the middle of a download picks it up again at the next launch.
    static func resumeOnQuit(downloading: Bool) -> Bool { downloading }
}

/// D-3: one download at a time. A step's download asked for while another
/// step's runs waits for it, then starts by itself. Pure, so it can be tested.
enum DownloadQueue {
    enum Action: Equatable { case start, queue, ignore }

    static func request(_ step: SetupStep, running: SetupStep?) -> Action {
        guard let running else { return .start }
        return running == step ? .ignore : .queue
    }

    /// What starts when `ended`'s download stops.
    static func next(queued: SetupStep?, ended: SetupStep) -> SetupStep? {
        queued == ended ? nil : queued
    }
}

/// One step's download, as the first-run window runs it: the size, the work
/// (reporting bytes done; returns why it failed, or nil), and how to stop it.
struct StepDownload {
    /// What `start` returns when the download went away without its file
    /// (cancelled elsewhere, e.g. in Under the Hood): not a failure, not done.
    static let vanished = "\u{0}vanished"
    var bytes: Int64
    var start: @MainActor (_ progress: @escaping @MainActor (Int64) -> Void) async -> String?
    var cancel: @MainActor () -> Void
}

// MARK: - Window state

/// The window's state: the screen, the setup it watches, and the download.
@MainActor
final class OnboardingModel: ObservableObject {
    /// What fills the five slots. A step can look different by state:
    /// microphone turned down once, or blocked by an administrator.
    enum Page: Hashable {
        case welcome, models, downloading, checking, microphone, microphoneOff, admin, screenAudio, relaunch, notes, done
    }

    enum Download: Equatable {
        case idle
        case running(done: Int64, total: Int64, minutesLeft: Int?)
        /// This window's download stopped.
        case failed(String)
        /// A file chosen here didn't work.
        case importFailed(String)

        var failed: Bool {
            switch self {
            case .failed, .importFailed: true
            case .idle, .running: false
            }
        }
    }

    @Published private(set) var flow: OnboardingFlow
    @Published private(set) var state: SetupState
    @Published private(set) var pages: [OnboardingScreen]
    /// The running or last download, and the step it belongs to.
    @Published private(set) var download: Download = .idle
    @Published private(set) var downloadStep: SetupStep?
    /// Restarting for screen audio waits for a running download.
    @Published private(set) var relaunchPlan = RelaunchPlan()
    /// The download done, the restart waits for a recording or a meeting being processed.
    @Published private(set) var relaunchHeld = false
    /// A step's download waiting for the running one (the notes model after the listening tools).
    @Published private(set) var queuedStep: SetupStep?
    /// A call is being recorded or a meeting processed: a restart now would end it.
    /// EarlApp points this at AppState.
    static var appBusy: @MainActor () -> Bool = { false }
    private var relaunchLoop: Task<Void, Never>?
    /// Bytes still to download for the listening tools.
    @Published private(set) var neededBytes: Int64
    /// A file chosen by hand is being checked.
    var importing: Bool { importJob != nil }
    /// The green check that settles for a moment when a step is done.
    @Published private(set) var ticking = false
    @Published private(set) var copiedNote = false
    /// "Show Me Where Earl Lives" was clicked on the done screen.
    @Published private(set) var whereShown = false

    private weak var engine: Engine?
    @Published private var job: Task<Void, Never>?
    private var stopJob: (@MainActor () -> Void)?
    nonisolated(unsafe) private var quitObserver: NSObjectProtocol?

    deinit {
        if let quitObserver { NotificationCenter.default.removeObserver(quitObserver) }
    }
    @Published private var importJob: Task<Void, Never>?
    /// The models step was put off (downloading in the background, or "Not
    /// Now" after a failure): the permissions come first, the models last.
    @Published private(set) var modelsLater = false
    /// Moving to the next screen (after the check, or the download's first beat).
    private var moving = false

    /// Sizes of the two speaker models (FluidAudio's own downloads).
    private static let speakerBytes: Int64 = 22_000_000
    private static let liveSpeakerBytes: Int64 = 106_000_000
    private static let turbo = WhisperModelOption.all[0]

    /// `hasMeetings`: someone who already has meetings has used Earl before, so no welcome.
    init(engine: Engine, hasMeetings: Bool = false) {
        self.engine = engine
        engine.refreshLocal()
        let s = engine.setupState
        let finished = UserDefaults.standard.bool(forKey: Prefs.Key.onboardingFinished) || hasMeetings
        let flow = OnboardingFlow.resume(s, finishedBefore: finished)
        self.flow = flow
        state = s
        pages = OnboardingFlow.pages(s, from: flow.screen)
        neededBytes = Self.missingBytes()
        // A quit in the middle of a download: the reopened window starts it again.
        quitObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, RelaunchPlan.resumeOnQuit(downloading: self.downloading) else { return }
                UserDefaults.standard.set(true, forKey: Prefs.Key.onboardingResumeDownload)
            }
        }
    }

    /// U-0: a fixed screen for snapshots; nothing is watched or downloaded.
    init(demo state: SetupState, screen: OnboardingScreen, pages: [OnboardingScreen], download: Download = .idle,
         downloadStep: SetupStep? = .models, neededBytes: Int64 = 1_730_000_000, copiedNote: Bool = false,
         whereShown: Bool = false, demoDownloading: Bool = false, relaunchWaiting: Bool = false,
         queuedStep: SetupStep? = nil) {
        self.state = state
        flow = OnboardingFlow(screen: screen)
        self.pages = pages
        self.download = download
        self.downloadStep = downloadStep
        demoBusy = demoDownloading
        self.neededBytes = neededBytes
        self.copiedNote = copiedNote
        self.whereShown = whereShown
        if relaunchWaiting { _ = relaunchPlan.press(downloading: true) }
        self.queuedStep = queuedStep
    }

    /// U-0: a still picture of a download running in the background.
    private var demoBusy = false

    /// A download is running (this step's or one in the background).
    var downloading: Bool { job != nil || demoBusy }

    /// The step on screen.
    var currentStep: SetupStep? {
        if case .step(let step) = flow.screen { return step }
        return nil
    }

    /// The download as the screen on show sees it: its own step's, else nothing.
    var stepDownload: Download { downloadStep != nil && downloadStep == currentStep ? download : .idle }

    var page: Page {
        let running: Bool = if case .running = stepDownload { true } else { false }
        switch flow.screen {
        case .welcome: return .welcome
        case .done: return .done
        case .step(.models):
            if running { return .downloading }
            return importing ? .checking : .models
        case .step(.microphone):
            if SetupGuide.blockedByAdmin(state) { return .admin }
            return state.microphone == .denied ? .microphoneOff : .microphone
        case .step(.screenAudio): return .screenAudio
        case .step(.relaunch): return .relaunch
        case .step(.notes):
            if running { return .downloading }
            return importing ? .checking : .notes
        }
    }

    var pageIndex: Int { pages.firstIndex(of: flow.screen) ?? 0 }

    /// The listening tools wait for the permissions: downloading in the background, or put off.
    private var modelsDeferred: Bool { modelsLater || (job != nil && downloadStep == .models) }

    /// After a failure, "Not Now" moves on to the permissions; when none are
    /// left it closes the window (the menu bar keeps "Finish getting ready").
    var notNowCloses: Bool {
        var next = flow
        next.advance(state, modelsDeferred: true)
        return next == flow
    }

    // MARK: Watching

    /// Earl looks every second (twice a second while downloading) and moves on by himself.
    func watch() async {
        // Earl restarted for screen audio in the middle of the download: pick it up again.
        if UserDefaults.standard.bool(forKey: Prefs.Key.onboardingResumeDownload) {
            UserDefaults.standard.removeObject(forKey: Prefs.Key.onboardingResumeDownload)
            refresh()
            let left = SetupGuide.steps(state)
            if left.contains(.models) { startDownload(.models) } else if left.contains(.notes) { startDownload(.notes) }
        }
        while !Task.isCancelled {
            // D-3: on the notes step, look again for LM Studio or Ollama (localhost, a second at most).
            if currentStep == .notes { await engine?.refreshNotesBackend() }
            refresh()
            try? await Task.sleep(for: .milliseconds(job == nil ? 1000 : 500))
        }
    }

    private func refresh() {
        guard let engine else { return }
        engine.refreshLocal()
        state = engine.setupState
        neededBytes = Self.missingBytes()
        guard case .step(let step) = flow.screen, !moving else { return }
        var next = flow
        next.advance(state, modelsDeferred: modelsDeferred)
        guard next != flow else { return }
        moving = true
        if SetupGuide.steps(state).contains(step) {
            // Put off, not done (the download goes on in the background): a beat
            // on the progress so it's seen to start, then on, without the check.
            Task {
                try? await Task.sleep(for: .milliseconds(1500))
                moving = false
                var again = flow
                again.advance(state, modelsDeferred: modelsDeferred)
                guard again != flow else { return } // it failed meanwhile: the reason stays on screen
                if step == .models { modelsLater = true }
                move(to: again)
            }
            return
        }
        // The step is done: a green check for a moment, then the next screen.
        ticking = true
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            ticking = false
            moving = false
            move(to: next)
        }
    }

    private func move(to next: OnboardingFlow) {
        flow = next
        if !pages.contains(next.screen) { pages = OnboardingFlow.pages(state, from: next.screen) }
        if modelsLater { pages = OnboardingFlow.modelsLast(pages) }
        if next.screen == .done { UserDefaults.standard.set(true, forKey: Prefs.Key.onboardingFinished) }
    }

    // MARK: Actions

    func primary() {
        switch page {
        case .welcome: move(to: advanced())
        case .notes:
            startDownload(.notes) // D-3: the built-in note writer for this Mac's memory
        case .models: startDownload(.models)
        case .downloading, .checking: break
        case .microphone: Task { await engine?.requestMicrophone(); refresh() }
        case .microphoneOff: Engine.openPrivacySettings("Privacy_Microphone")
        case .admin:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(OnboardingCopy.itNote, forType: .string)
            copiedNote = true
        case .screenAudio: engine?.requestScreenAudio(); refresh()
        case .relaunch:
            // A restart now would throw the download away: wait for it, then restart by itself.
            if relaunchPlan.press(downloading: downloading, busy: Self.appBusy()) { engine?.relaunch() } else { relaunchWhenFree() }
        case .done: UserDefaults.standard.set(true, forKey: Prefs.Key.onboardingFinished)
        }
    }

    func secondary() {
        switch page {
        case .models where stepDownload.failed:
            // Not Now: the step stays missing; the permissions first, the models screen again at the end.
            modelsLater = true
            move(to: advanced())
        case .models: chooseFiles()
        case .downloading: cancelDownload()
        case .relaunch: Engine.openPrivacySettings("Privacy_ScreenCapture")
        case .done: withAnimation(.easeOut(duration: 0.2)) { whereShown = true }
        case .notes:
            UserDefaults.standard.set(false, forKey: Prefs.Key.summariesEnabled) // transcripts only
            if queuedStep == .notes { queuedStep = nil }
            move(to: advanced())
        default: break
        }
    }

    /// The small link under the body ("Use a File I Have…" after a failure).
    func action() { chooseFiles() }

    private func advanced() -> OnboardingFlow {
        var next = flow
        if case .step = next.screen { next.screen = .welcome } // a step skipped by hand: as from the start
        next.advance(state, modelsDeferred: modelsDeferred)
        if next.screen == flow.screen {
            // Skipped by hand and it's the last step: the models screen when they're still missing, else done.
            let modelsMissing = SetupGuide.steps(state).contains(.models)
            next.screen = modelsMissing ? .step(.models) : .done
        }
        return next
    }

    // MARK: Listening tools

    /// What's missing: the transcription model at the chosen path (the
    /// recommended one if that's gone), silence detection and both speaker models.
    private static func missingBytes() -> Int64 {
        let fm = FileManager.default
        var bytes: Int64 = 0
        if !fm.fileExists(atPath: Prefs.whisperModel) && !fm.fileExists(atPath: turbo.path) { bytes += turbo.bytes }
        if !fm.fileExists(atPath: Prefs.vadModel) { bytes += WhisperModelOption.vad.bytes }
        if !Diarizer().isInstalled { bytes += speakerBytes }
        if !LiveSpeakerModel.isInstalled { bytes += liveSpeakerBytes }
        return bytes
    }

    /// Starts the step's download (the one on screen by default), with the
    /// same progress, cancel and failure on its screen for every step.
    func startDownload(_ step: SetupStep? = nil) {
        guard let step = step ?? currentStep, importJob == nil else { return }
        switch DownloadQueue.request(step, running: job == nil ? nil : downloadStep) {
        case .start: break
        case .queue: queuedStep = step; return // "Starts after the listening tools."
        case .ignore: return
        }
        if queuedStep == step { queuedStep = nil }
        let work: StepDownload?
        switch step {
        case .models:
            guard state.transcriberPresent else {
                downloadStep = .models
                download = .failed(OnboardingCopy.transcriberMissing)
                return
            }
            work = modelsDownload()
        case .notes: work = notesModelDownload()
        default: work = nil
        }
        guard let work else { return }
        run(step, work)
    }

    private func run(_ step: SetupStep, _ work: StepDownload) {
        let total = max(1, work.bytes)
        let start = Date()
        downloadStep = step
        stopJob = work.cancel
        download = .running(done: 0, total: total, minutesLeft: nil)
        job = Task {
            let failure = await work.start { [weak self] done in
                guard let self, !Task.isCancelled else { return }
                let elapsed = Date().timeIntervalSince(start)
                var minutes: Int?
                if elapsed > 4, done > 0 {
                    let rate = Double(done) / elapsed
                    minutes = Int((Double(total - done) / rate / 60).rounded(.up))
                }
                self.download = .running(done: min(done, total), total: total, minutesLeft: minutes)
            }
            guard !Task.isCancelled else { return } // cancelled: cancelDownload has reset everything
            if failure == StepDownload.vanished { // cancelled elsewhere: as if Cancel was pressed here
                job = nil
                stopJob = nil
                cancelDownload()
                return
            }
            job = nil
            stopJob = nil
            download = failure.map { .failed($0) } ?? .idle
            relaunchPlan.downloadEnded(failed: failure != nil)
            if failure == nil { refresh() }
            downloadEnded(step)
        }
    }

    /// The next queued download starts; else, if "Restart After Download"
    /// was pressed, the restart (now nothing is lost).
    private func downloadEnded(_ step: SetupStep) {
        if let next = DownloadQueue.next(queued: queuedStep, ended: step) {
            queuedStep = nil
            startDownload(next)
        }
        relaunchWhenFree()
    }

    /// Restarts once the downloads are done and no call is being recorded or
    /// meeting processed; looks again every few seconds while one is.
    private func relaunchWhenFree() {
        guard relaunchLoop == nil else { return }
        relaunchLoop = Task {
            defer { relaunchLoop = nil; relaunchHeld = false }
            while relaunchPlan.waiting && !downloading {
                if relaunchPlan.shouldRelaunch(downloading: downloading, busy: Self.appBusy()) {
                    engine?.relaunch()
                    return
                }
                relaunchHeld = true
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    /// The listening tools: the transcription files side by side, then the speaker models.
    private func modelsDownload() -> StepDownload? {
        guard let engine else { return nil }
        engine.downloadError = nil
        let fm = FileManager.default
        if !fm.fileExists(atPath: Prefs.whisperModel) {
            // The chosen model is gone: use the recommended one.
            UserDefaults.standard.set(Self.turbo.path, forKey: Prefs.Key.whisperModel)
        }
        let files = [Self.turbo, WhisperModelOption.vad].filter { option in
            !fm.fileExists(atPath: option == Self.turbo ? Prefs.whisperModel : option.path)
        }
        let speakers = SpeakerModel.shared, live = LiveSpeakerModelState.shared
        let needSpeakers = !Diarizer().isInstalled, needLive = !LiveSpeakerModel.isInstalled

        return StepDownload(bytes: neededBytes, start: { report in
            files.forEach(engine.download)
            // First the transcription files, side by side.
            while !Task.isCancelled, files.contains(where: { engine.downloads[$0.file] != nil }) {
                report(files.reduce(0) { $0 + Int64(Double($1.bytes) * (engine.downloads[$1.file] ?? 1)) })
                try? await Task.sleep(for: .milliseconds(500))
            }
            guard !Task.isCancelled else { return nil }
            if let error = files.lazy.compactMap({ engine.downloadFailures[$0.file] }).first { return error }
            let first = files.reduce(Int64(0)) { $0 + $1.bytes }
            // Then the speaker models.
            if needSpeakers { speakers.download() }
            if needLive { live.download() }
            while !Task.isCancelled, speakers.progress != nil || live.progress != nil {
                let s = needSpeakers ? Int64(Double(Self.speakerBytes) * (speakers.progress ?? 1)) : 0
                let l = needLive ? Int64(Double(Self.liveSpeakerBytes) * (live.progress ?? 1)) : 0
                report(first + s + l)
                try? await Task.sleep(for: .milliseconds(500))
            }
            guard !Task.isCancelled else { return nil }
            // Only the downloads started here: an old error from Settings isn't this run's.
            return (needSpeakers ? speakers.error : nil) ?? (needLive ? live.error : nil)
        }, cancel: {
            engine.cancelDownload(Self.turbo)
            engine.cancelDownload(.vad)
            speakers.cancel()
            live.cancel()
        })
    }

    /// D-3: the built-in note writer sized to this Mac, checked against its SHA-256.
    private func notesModelDownload() -> StepDownload? {
        guard let engine else { return nil }
        let model = BuiltInModel.forMemory(ProcessInfo.processInfo.physicalMemory)
        engine.downloadError = nil
        return StepDownload(bytes: model.bytes, start: { report in
            engine.download(model)
            while !Task.isCancelled, let progress = engine.downloads[model.file] {
                report(Int64(Double(model.bytes) * progress))
                try? await Task.sleep(for: .milliseconds(500))
            }
            guard !Task.isCancelled else { return nil }
            if let error = engine.downloadFailure(model) { return error } // only this file's failure
            guard model.fileURL != nil else { return StepDownload.vanished }
            await engine.refreshNotesBackend() // ready at once, not on the next look
            return nil
        }, cancel: {
            engine.cancelDownload(model)
        })
    }

    func cancelDownload() {
        job?.cancel()
        job = nil
        stopJob?()
        stopJob = nil
        download = .idle
        relaunchPlan.cancel()
        if let step = downloadStep { downloadEnded(step) }
    }

    /// "Use a File I Have…": files a colleague passed on, matched by checksum.
    /// Only this window's own imports report here (not an old error from Settings).
    private func chooseFiles() {
        guard let engine, job == nil, importJob == nil else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose the files a colleague gave you."
        panel.prompt = "Use"
        guard panel.runModal() == .OK else { return }
        download = .idle
        downloadStep = currentStep == .notes ? .notes : .models // D-3: the note writer's file, on its own screen
        let urls = panel.urls
        importJob = Task {
            var failure: String?
            for url in urls {
                await engine.importModel(from: url).value
                if failure == nil, let error = engine.downloadError { failure = error }
            }
            if let failure { download = .importFailed(failure) }
            importJob = nil
            if currentStep == .notes { await engine.refreshNotesBackend() }
            refresh()
        }
    }
}

// MARK: - Window

/// The window's content. It looks at the setup every second while open.
struct OnboardingWindow: View {
    @StateObject private var model: OnboardingModel
    @Environment(\.dismissWindow) private var dismissWindow

    init(engine: Engine, hasMeetings: Bool) {
        _model = StateObject(wrappedValue: OnboardingModel.forWindow(engine, hasMeetings: hasMeetings))
    }

    var body: some View {
        OnboardingView(model: model) {
            dismissWindow(id: Onboarding.windowID)
            AppDelegate.openMeetings?()
        }
        .task { await model.watch() }
        .onExitCommand { dismissWindow(id: Onboarding.windowID) }
        // In the Dock and app switcher while open, like the Meetings window.
        .onAppear { NSApp.setActivationPolicy(.regular) }
        .onDisappear {
            let meetingsOpen = NSApp.windows.contains { $0.isVisible && $0.identifier?.rawValue.hasPrefix("meetings") == true }
            if !meetingsOpen { NSApp.setActivationPolicy(.accessory) }
        }
    }
}

extension OnboardingModel {
    /// A download keeps going when the window is closed; reopening shows it again.
    private static var running: OnboardingModel?

    static func forWindow(_ engine: Engine, hasMeetings: Bool) -> OnboardingModel {
        if let running, running.job != nil || running.relaunchPlan.waiting { return running }
        let model = OnboardingModel(engine: engine, hasMeetings: hasMeetings)
        running = model
        return model
    }
}

enum Onboarding {
    static let windowID = "onboarding"

    /// At launch: open while something is missing and the user never finished,
    /// and always right after the restart for screen audio (also when it was
    /// finished before and Record sent the user back). Only for the real app.
    @MainActor
    static func shouldOpenAtLaunch(_ engine: Engine) -> Bool {
        guard Bundle.main.bundleIdentifier != nil, !DemoMode.isActive else { return false }
        let d = UserDefaults.standard
        let restarted = d.bool(forKey: Prefs.Key.screenAudioAsked)
        d.removeObject(forKey: Prefs.Key.screenAudioAsked)
        if restarted { return true } // "I'll reopen this window right after."
        guard !d.bool(forKey: Prefs.Key.onboardingFinished) else { return false }
        engine.refreshLocal()
        return SetupGuide.next(engine.setupState) != nil
    }
}
