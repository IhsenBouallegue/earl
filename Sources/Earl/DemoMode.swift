import AppKit
import FluidAudio
import SwiftUI

// U-0: renders every screen with made-up data to PNG files, so the UI can be
// looked at without the user's meetings or a screen recording permission.
// Run it through tools/snapshot-ui.sh, which starts the debug binary as
// "EarlDemo --demo <out-dir> [--dark] [--only <name>] [--icon <icns>]".
//
// Demo mode never touches real data: storage and Application Support live in
// a throwaway home under $TMPDIR, settings go to the binary's own defaults
// domain (EarlDemo, wiped before and after), the network is blocked, and none
// of the services (shortcut, call detector, calendar, notifications, LM
// Studio, recorder) start. Windows stay offscreen.

enum DemoMode {
    static let isActive = CommandLine.arguments.contains("--demo")

    /// The throwaway home: `Meetings` and `Library/Application Support/Earl`
    /// live under it, and paths inside it display as "~/…".
    static let home: URL? = {
        guard isActive else { return nil }
        // realpath, not resolvingSymlinksInPath: that drops "/private", and
        // folder listings put it back, which breaks the "~" display.
        let tmp = realpath(NSTemporaryDirectory(), nil).map { p in defer { free(p) }; return String(cString: p) }
        return URL(fileURLWithPath: tmp ?? NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("earl-demo-\(getpid())", isDirectory: true)
            .appendingPathComponent("home", isDirectory: true)
    }()

    /// The tab a meeting page opens on (MeetingDetail reads it on appear).
    @MainActor static var detailTab: MeetingDetail.Tab?
    /// U-3: a query the Meetings window opens with, its ⌘K search field showing.
    @MainActor static var searchQuery: String?
    /// S-3: the meeting page opens with Ask Earl's drawer showing.
    @MainActor static var askOpen = false

    static let screens = ["library-meeting", "meeting-transcript", "meeting-processing", "meeting-failed", "recording",
                          "todos", "engine", "engine-ollama", "engine-none", "empty", "menubar", "menubar-recording", "offer",
                          "components", // U-1
                          "search", // U-3
                          "brief", "series", // S-2
                          "meeting-daily", // S-1
                          "meeting-townhall", // K-1
                          "meeting-reading", // the page in one column, conversation hidden
                          "upnext", // the sidebar's next meeting in each phase
                          "ask", "ask-all", // S-3
                          // D-2: the first-run window, one name per screen and state
                          "onboarding-welcome", "onboarding-models", "onboarding-downloading", "onboarding-failed",
                          "onboarding-import-failed",
                          "onboarding-microphone", "onboarding-microphone-off", "onboarding-admin",
                          "onboarding-screenaudio", "onboarding-relaunch", "onboarding-done", "onboarding-done-where",
                          // D-3: the note writer, and restarting while the tools download
                          "onboarding-notes", "onboarding-notes-downloading", "onboarding-notes-queued",
                          "onboarding-notes-failed", "engine-builtin", "engine-builtin-downloading",
                          "onboarding-relaunch-downloading", "onboarding-relaunch-waiting"]

    struct Options {
        var out: URL
        var dark = false
        var only: String?
        var icon: String?
    }

    static func options() -> Options? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--demo"), i + 1 < args.count, !args[i + 1].hasPrefix("--") else { return nil }
        var options = Options(out: URL(fileURLWithPath: args[i + 1], isDirectory: true))
        options.dark = args.contains("--dark")
        if let j = args.firstIndex(of: "--only"), j + 1 < args.count { options.only = args[j + 1] }
        if let j = args.firstIndex(of: "--icon"), j + 1 < args.count { options.icon = args[j + 1] }
        return options
    }

    @MainActor
    static func run() -> Never {
        // The installed app has a bundle ID; the debug binary doesn't.
        guard Bundle.main.bundleIdentifier == nil else {
            fail("Demo mode only runs from the debug binary, through tools/snapshot-ui.sh.")
        }
        // The defaults domain is the process name. It must be a throwaway one,
        // never the app's, and never a plain `swift run` domain.
        let domain = ProcessInfo.processInfo.processName
        guard domain.hasSuffix("Demo") else {
            fail("Run demo mode through tools/snapshot-ui.sh, which gives it a throwaway settings domain.")
        }
        guard let options = options(), let home else {
            fail("Usage: EarlDemo --demo <out-dir> [--dark] [--only <name>] [--icon <icns>]")
        }
        if let only = options.only, !screens.contains(only) {
            fail("Unknown screen \(only). Screens: \(screens.joined(separator: ", "))")
        }

        let app = DemoApplication.shared
        _ = (app as? DemoApplication)?.forcePolicy(.accessory)
        let runner = DemoRunner(options: options, home: home, domain: domain)
        let delegate = DemoAppDelegate(runner: runner)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
        exit(0)
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("Earl demo: \(message)\n".utf8))
        exit(2)
    }
}

/// Keeps the demo out of the way: the meeting window's onAppear asks for a
/// Dock icon and focus, which a snapshot run must not take from the user.
final class DemoApplication: NSApplication {
    override func activate() {}
    override func setActivationPolicy(_ activationPolicy: NSApplication.ActivationPolicy) -> Bool { true }

    func forcePolicy(_ policy: NSApplication.ActivationPolicy) -> Bool {
        super.setActivationPolicy(policy)
    }
}

/// Never becomes key, so it can't take focus from the user.
private final class DemoWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class DemoAppDelegate: NSObject, NSApplicationDelegate {
    let runner: DemoRunner

    init(runner: DemoRunner) { self.runner = runner }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            let ok = await runner.run()
            exit(ok ? 0 : 1)
        }
    }
}

/// Fails every request: demo mode must not reach LM Studio or anything else.
private final class DemoNetworkBlock: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}

// MARK: - Runner

@MainActor
private final class DemoRunner {
    let options: DemoMode.Options
    let home: URL
    let domain: String
    private var state: AppState!
    private var data: DemoData!
    private var ids = DemoData.IDs()
    private var appearance: NSAppearance!

    init(options: DemoMode.Options, home: URL, domain: String) {
        self.options = options
        self.home = home
        self.domain = domain
    }

    func run() async -> Bool {
        defer { cleanUp() }
        do {
            try setUp()
            for name in DemoMode.screens where options.only == nil || options.only == name {
                try await render(name)
            }
            return true
        } catch {
            FileHandle.standardError.write(Data("Earl demo: \(error.localizedDescription)\n".utf8))
            return false
        }
    }

    // MARK: Setup

    private var meetingsDir: URL { home.appendingPathComponent("Meetings", isDirectory: true) }

    private func setUp() throws {
        URLProtocol.registerClass(DemoNetworkBlock.self)
        appearance = NSAppearance(named: options.dark ? .darkAqua : .aqua)
        NSApp.appearance = appearance
        if let icon = options.icon, let image = NSImage(contentsOfFile: icon) { NSApp.applicationIconImage = image }

        let fm = FileManager.default
        try? fm.removeItem(at: home.deletingLastPathComponent())
        try fm.createDirectory(at: meetingsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: Prefs.modelsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: options.out, withIntermediateDirectories: true)

        let d = UserDefaults.standard
        d.removePersistentDomain(forName: domain)
        d.set("~/Meetings", forKey: Prefs.Key.storagePath)
        d.set(DemoData.me.name, forKey: Prefs.Key.userName)
        d.set(true, forKey: Prefs.Key.rememberVoices)
        d.set(true, forKey: Prefs.Key.voicesConsentAsked)
        d.set(["google/gemma-4-e4b": [38.0, 71.0], "qwen/qwen3.8-27b": [11.0, 205.0]], forKey: Prefs.Key.modelSpeeds)

        // Everything below writes to the demo home; stop if the settings say otherwise.
        guard Prefs.storageURL.path == meetingsDir.path, Prefs.supportDir.path.hasPrefix(home.path) else {
            throw PipelineError.message("Demo storage isn't in the throwaway folder (\(Prefs.storageURL.path)); stopping.")
        }

        // Installed models, as sparse files of their real size.
        DemoData.sparseFile(URL(fileURLWithPath: Prefs.defaultWhisperModel), bytes: 1_624_555_275)
        DemoData.sparseFile(Prefs.modelsDir.appendingPathComponent("ggml-small.bin"), bytes: 487_601_967)
        DemoData.sparseFile(URL(fileURLWithPath: Prefs.vadModel), bytes: 885_098)
        // The speaker models, as Diarizer.isInstalled and LiveSpeakerModel.isInstalled look for them.
        let names = ModelNames.OfflineDiarizer.self
        let diarizerFiles = [names.segmentationFile, names.fbankFile, names.embeddingFile, names.pldaRhoFile]
            .map { "\($0)/coremldata.bin" } + [names.pldaParameters]
        for file in diarizerFiles {
            DemoData.sparseFile(Diarizer().repoDir.appendingPathComponent(file), bytes: 5_500_000)
        }
        DemoData.sparseFile(LiveSpeakerModel.modelURL.appendingPathComponent("coremldata.bin"), bytes: 106_000_000)
        try VoiceStore.write(DemoData.voices, to: Prefs.voicesURL)

        data = DemoData(store: MeetingStore(root: meetingsDir), now: Date())
        ids = try data.writeLibrary()

        state = AppState()
        state.shortcut.showDemo()
        state.calendar.showDemo(events: [data.events().next], calendars: [
            .init(id: "work", title: "Work", source: "Example Corp"),
            .init(id: "home", title: "Home", source: "iCloud"),
        ])
        state.engine.showDemo(
            whisperModels: ["ggml-large-v3-turbo.bin": 1_624_555_275, "ggml-small.bin": 487_601_967],
            server: Summarizer.ServerStatus(reachable: true, isLMStudio: true, models: [
                LLMModel(id: "google/gemma-4-e4b", type: "llm", quantization: "Q4_K_M", state: "loaded",
                         maxContextLength: 131_072, loadedContextLength: 32768),
                LLMModel(id: "qwen/qwen3.8-27b", type: "llm", quantization: "Q4_K_M", state: "not-loaded",
                         maxContextLength: 131_072),
            ]),
            meetings: state.meetings)
    }

    private func cleanUp() {
        UserDefaults.standard.removePersistentDomain(forName: domain)
        UserDefaults.standard.synchronize()
        try? FileManager.default.removeItem(at: home.deletingLastPathComponent())
    }

    // MARK: Screens

    private func render(_ name: String) async throws {
        state.selection = nil
        DemoMode.detailTab = nil
        DemoMode.searchQuery = nil
        DemoMode.askOpen = false // S-3
        switch name {
        case "library-meeting":
            state.selection = .meeting(ids.productSync)
            try await window(name)
        case "meeting-transcript":
            state.selection = .meeting(ids.productSync)
            DemoMode.detailTab = .transcript
            try await window(name)
        case "meeting-processing":
            let processing = try data.processing()
            state.reload()
            state.demoJobs([processing.job])
            state.selection = .meeting(processing.id)
            try await window(name)
            state.demoJobs([])
            try remove(processing.id)
        case "meeting-reading":
            UserDefaults.standard.set(false, forKey: "showsConversation")
            state.selection = .meeting(ids.productSync)
            try await window(name)
            UserDefaults.standard.removeObject(forKey: "showsConversation")
        case "upnext":
            guard let base = state.calendar.upcomingEvents.first else { break }
            let now = Date()
            func at(_ start: TimeInterval) -> CalendarCandidate {
                var e = base
                e.start = now.addingTimeInterval(start)
                e.end = e.start.addingTimeInterval(45 * 60)
                return e
            }
            try await panel(name, width: 280) {
                VStack(alignment: .leading, spacing: 12) {
                    SidebarUpNext(event: at(10 * 60), now: now, phase: .soon, briefCount: 2)
                    SidebarUpNext(event: at(4 * 60), now: now, phase: .soon)
                    SidebarUpNext(event: at(18 * 60), now: now, phase: .armed)
                    SidebarUpNext(event: at(-20 * 60), now: now, phase: .ongoing)
                    SidebarUpNext(event: at(-30 * 60), now: now, phase: .recording)
                }
                .padding(12)
                .frame(width: 256)
                .paperBackground(.sidebar)
            }
        case "meeting-failed":
            state.selection = .meeting(ids.failed)
            try await window(name)
        case "recording":
            try await whileRecording { try await self.window(name) }
        case "todos":
            state.selection = .todos
            try await window(name)
        case "engine", "engine-ollama", "engine-none", "engine-builtin", "engine-builtin-downloading":
            if name == "engine-ollama" {
                state.engine.showDemo(
                    whisperModels: state.engine.installedModels,
                    server: Summarizer.ServerStatus(reachable: true, isLMStudio: false, models: [
                        LLMModel(id: "qwen3:14b"), LLMModel(id: "llama3.2:3b"),
                    ]),
                    meetings: state.meetings, notesBackend: .ollama(model: "qwen3:14b"))
            } else if name == "engine-builtin" {
                // D-3: no LM Studio or Ollama, the built-in note writer downloaded and in use.
                let model = BuiltInModel.forMemory(ProcessInfo.processInfo.physicalMemory)
                state.engine.showDemo(whisperModels: state.engine.installedModels,
                                      server: Summarizer.ServerStatus(reachable: false, isLMStudio: false, models: []),
                                      meetings: state.meetings, notesBackend: .builtIn(model: model),
                                      builtIn: [model.file: model.bytes])
            } else if name == "engine-builtin-downloading" {
                let model = BuiltInModel.forMemory(ProcessInfo.processInfo.physicalMemory)
                state.engine.showDemo(whisperModels: state.engine.installedModels,
                                      server: Summarizer.ServerStatus(reachable: false, isLMStudio: false, models: []),
                                      meetings: state.meetings, notesBackend: .none)
                state.engine.showDemoDownload(file: model.file, progress: 0.42)
            } else if name == "engine-none" {
                state.engine.showDemo(whisperModels: state.engine.installedModels,
                                      server: Summarizer.ServerStatus(reachable: false, isLMStudio: false, models: []),
                                      meetings: state.meetings, notesBackend: .none)
            }
            try await panel(name, width: 784) {
                EngineView()
                    .frame(maxWidth: 720)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 28)
                    .paperBackground() // U-3: as in the window
            }
        case "empty":
            let empty = home.appendingPathComponent("Empty", isDirectory: true)
            try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
            UserDefaults.standard.set("~/Empty", forKey: Prefs.Key.storagePath)
            state.reload()
            try await window(name)
            UserDefaults.standard.set("~/Meetings", forKey: Prefs.Key.storagePath)
            state.reload()
        case "menubar":
            try await panel(name, width: MenuBarPanel.width) { MenuBarPanel() } // U-5: its own width
        case "menubar-recording":
            try await whileRecording { try await self.panel(name, width: MenuBarPanel.width) { MenuBarPanel() } }
        case "offer":
            // U-5: every kind of offer, the call one named after the next event.
            let teams = CallApps.all.first { $0.id == "teams" }
            let app = DetectedApp(key: "com.microsoft.teams2", name: "Microsoft Teams", bundleID: "com.microsoft.teams2",
                                  pid: -1, callApp: teams)
            let event = state.calendar.likelyEvent(for: app)
            try await panel(name, width: OfferPanelView.width + 48) {
                VStack(spacing: 16) {
                    OfferPanelView(item: .callOffer(app), event: event)
                    OfferPanelView(item: .stopOffer(app))
                    OfferPanelView(item: .confirmation(title: "Recording Pricing workshop", body: "Started as planned.",
                                                       recording: true))
                }
                .padding(24)
            }
        case "meeting-daily": // S-1: a daily with "Since last time"
            state.selection = .meeting(ids.standup)
            try await window(name)
        case "meeting-townhall": // K-1: notes shaped for a town hall
            state.selection = .meeting(ids.townHall)
            try await window(name)
        case "search": // U-3: ⌘K search, filtering the sidebar
            state.selection = .meeting(ids.productSync)
            DemoMode.searchQuery = "When does onboarding ship?" // S-3: a question, so Ask Earl leads
            try await window(name)
        case "ask": // S-3: the answer drawer on the meeting page
            state.selection = .meeting(ids.productSync)
            DemoMode.askOpen = true
            try await window(name)
        case "ask-all": // S-3: the Ask page with the questions across meetings
            state.selection = .ask
            try await window(name)
        case "brief": // S-2: the brief before the next event, a series with things open
            state.selection = .series(DemoData.pricingSeries)
            try await window(name)
        case "series": // S-2: a series with nothing coming
            state.selection = .series(DemoData.productSyncSeries)
            try await window(name)
        case "components": // U-1: the paper foundation on one page
            try await panel(name, width: 1240) { ComponentSheet(next: data.events().next, now: Date()) }
        case let name where name.hasPrefix("onboarding-"):
            try await onboarding(name)
        default:
            break
        }
    }

    /// D-2: one screen of the first-run window, for a colleague who has nothing set up yet.
    private func onboarding(_ name: String) async throws {
        var s = SetupState(transcriberPresent: true, whisperModelPresent: false, vadPresent: false,
                           speakerModelsPresent: false, microphone: .notAsked, microphoneRestricted: false,
                           screenAudio: .notAsked, screenAudioAskedThisRun: false, notesReady: true)
        s.notesReady = !name.hasPrefix("onboarding-notes") // D-3: the note writer's page in the dots
        let pages = OnboardingFlow.pages(s, from: .welcome)
        var screen = OnboardingScreen.welcome
        var download = OnboardingModel.Download.idle
        var copied = false, whereShown = false
        var step: SetupStep? = .models, busy = false, waiting = false, queued: SetupStep?
        switch name {
        case "onboarding-models": screen = .step(.models)
        case "onboarding-downloading":
            screen = .step(.models)
            download = .running(done: 640_000_000, total: 1_730_000_000, minutesLeft: 3)
        case "onboarding-failed":
            screen = .step(.models)
            download = .failed("Download of Large v3 Turbo failed: The request timed out.")
        case "onboarding-import-failed":
            screen = .step(.models)
            download = .importFailed("That file isn't one of Earl's models.")
        case "onboarding-microphone": screen = .step(.microphone)
        case "onboarding-microphone-off": screen = .step(.microphone); s.microphone = .denied
        case "onboarding-admin":
            screen = .step(.microphone)
            s.microphone = .denied
            s.microphoneRestricted = true
            copied = true
        case "onboarding-screenaudio": screen = .step(.screenAudio)
        case "onboarding-relaunch": screen = .step(.relaunch); s.screenAudioAskedThisRun = true
        case "onboarding-done": screen = .done
        case "onboarding-done-where": screen = .done; whereShown = true
        case "onboarding-notes-queued":
            // The listening tools still downloading: Download was pressed, the notes model waits.
            screen = .step(.notes)
            download = .running(done: 1_100_000_000, total: 1_730_000_000, minutesLeft: 2)
            busy = true
            queued = .notes
        case "onboarding-notes", "onboarding-notes-downloading":
            screen = .step(.notes)
            if name.hasSuffix("downloading") {
                step = .notes
                let total = BuiltInModel.forMemory(ProcessInfo.processInfo.physicalMemory).bytes
                download = .running(done: total * 2 / 5, total: total, minutesLeft: 4)
            }
        case "onboarding-notes-failed":
            screen = .step(.notes)
            step = .notes
            download = .failed("Download of the note writer failed: The request timed out.")
        case "onboarding-relaunch-downloading", "onboarding-relaunch-waiting":
            // The listening tools still downloading in the background.
            screen = .step(.relaunch)
            s.screenAudioAskedThisRun = true
            download = .running(done: 1_100_000_000, total: 1_730_000_000, minutesLeft: 2)
            busy = true
            waiting = name.hasSuffix("waiting")
        default: break
        }
        let model = OnboardingModel(demo: s, screen: screen, pages: pages, download: download, downloadStep: step,
                                    copiedNote: copied, whereShown: whereShown, demoDownloading: busy,
                                    relaunchWaiting: waiting, queuedStep: queued)
        try await panel(name, width: OnboardingView.size.width) { OnboardingView(model: model) }
    }

    /// A call in full swing: three faces on the call, the second one talking.
    private func whileRecording(_ body: () async throws -> Void) async throws {
        let events = data.events()
        state.calendar.showDemo(events: [events.ongoing, events.next], calendars: state.calendar.calendars)
        let meeting = try data.recording(event: events.ongoing)
        state.reload()
        state.demoRecording(meeting.id, startedAt: meeting.info.startedAt, elapsed: 23 * 60 + 47, levels: (them: 0.8, me: 0.05))
        state.liveStage.showDemo(LiveSnapshot(
            faces: [LiveFace(voice: 0, label: "Speaker 1", seconds: 412, isActive: false),
                    LiveFace(voice: 1, label: "Speaker 2", seconds: 286, isActive: true),
                    LiveFace(voice: 2, label: "Speaker 3", seconds: 94, isActive: false)],
            meSeconds: 318, meTalking: false, micIsEcho: false, mouthVoice: 1,
            // U-4: the chat band's last few turns; Speaker 2 is still talking.
            turns: [LiveTurn(id: 1, voice: 1, start: 1290, end: 1318),
                    LiveTurn(id: 2, voice: 0, start: 1320, end: 1362),
                    LiveTurn(id: 3, voice: -1, start: 1364, end: 1376),
                    LiveTurn(id: 4, voice: 2, start: 1378, end: 1381),
                    LiveTurn(id: 5, voice: 1, start: 1383, end: 1412)],
            turnOpen: true))
        state.selection = .meeting(meeting.id)
        try await body()
        state.liveStage.showDemo(nil)
        state.demoRecording(nil)
        state.calendar.showDemo(events: [events.next], calendars: state.calendar.calendars)
        try remove(meeting.id)
    }

    private func remove(_ id: String) throws {
        try FileManager.default.removeItem(at: meetingsDir.appendingPathComponent(id))
        state.reload()
    }

    // MARK: Capture

    /// The Meetings window at its default size, with its title bar and toolbar.
    private func window(_ name: String) async throws {
        let size = NSSize(width: 1180, height: 760) // U-3: the default window size
        let window = DemoWindow(contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Earl"
        window.toolbarStyle = .unified
        let root = MeetingsView().environmentObject(state).environmentObject(state.engine)
        try await capture(name, window: window, content: NSHostingController(rootView: root), frame: true)
    }

    /// A view without window chrome, as tall as it wants to be.
    private func panel(_ name: String, width: CGFloat, @ViewBuilder _ content: () -> some View) async throws {
        let root = content()
            .frame(width: width)
            .fixedSize(horizontal: false, vertical: true)
            .environmentObject(state)
            .environmentObject(state.engine)
        let controller = NSHostingController(rootView: root)
        let height = max(40, controller.view.fittingSize.height)
        let window = DemoWindow(contentRect: NSRect(x: -20000, y: -20000, width: width, height: height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        try await capture(name, window: window, content: controller, frame: false)
    }

    private func capture(_ name: String, window: NSWindow, content: NSViewController, frame: Bool) async throws {
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        let size = window.contentRect(forFrameRect: window.frame).size
        window.contentViewController = content
        window.setContentSize(size)
        // Offscreen, transparent and click-through: nothing shows or takes focus.
        // It's still ordered in, so AppKit lays it out like a real window.
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.orderBack(nil)
        // Let onAppear, .task and the first animations settle.
        try await Task.sleep(for: .seconds(1.5))
        // A real window opens with nothing selected; don't show the title field's selection.
        window.makeFirstResponder(nil)
        try await Task.sleep(for: .seconds(0.2))
        guard let view = frame ? window.contentView?.superview : window.contentView else { return }
        view.layoutSubtreeIfNeeded()
        let png = try snapshot(view)
        try png.write(to: options.out.appendingPathComponent("\(name).png"))
        print("Wrote \(name).png")
        window.orderOut(nil)
        window.contentViewController = nil
        window.close()
        try await Task.sleep(for: .seconds(0.2))
    }

    // MARK: Drawing

    /// cacheDisplay alone draws AppKit views but leaves out SwiftUI content
    /// nested inside them (split view columns, scroll views, list cells),
    /// Liquid Glass shapes, and draws backdrop blurs as black. So the picture
    /// is built in layers, back to front: the window as cacheDisplay sees it,
    /// with backdrops hidden; each SwiftUI view cacheDisplay skipped; the
    /// title bar again, since it sits above the content; and flat stand-ins
    /// for glass shapes.
    private enum Layer {
        /// A view, optionally only inside `clip` (in the root's coordinates).
        case draw(NSView, clip: NSRect? = nil)
        /// A view without its subviews.
        case drawAlone(NSView)
        /// Plain window background.
        case fill(NSRect)
    }

    private static func isSwiftUI(_ v: NSView) -> Bool {
        let name = NSStringFromClass(type(of: v))
        guard name.hasPrefix("SwiftUI.") || name.contains("7SwiftUI") else { return false }
        // AppKit controls and containers inside SwiftUI: cacheDisplay draws those.
        return !(v is NSControl || v is NSClipView || v is NSScrollView || v is NSTableView
                 || name.contains("PlatformViewHost") || name.contains("ScrollView") || name.contains("RowView"))
    }

    private static func isBackdrop(_ v: NSView) -> Bool {
        let layer = v.layer.map { NSStringFromClass(type(of: $0)) } ?? ""
        return layer.contains("Backdrop") || NSStringFromClass(type(of: v)).contains("BlurryAlleyway")
            || isGlassRenderer(v)
    }

    /// The view that draws an NSGlassEffectView's glass (it draws it opaque offscreen).
    private static func isGlassRenderer(_ v: NSView) -> Bool {
        let name = NSStringFromClass(type(of: v))
        // Leaves only: glass containers host the content they hold.
        return name.contains("NSCoreHostingView") && name.contains("GlassEffect") && v.subviews.isEmpty
    }

    private static func visible(_ v: NSView) -> Bool {
        !v.isHidden && v.alphaValue > 0.01 && (v.layer?.opacity ?? 1) > 0.01
    }

    private func layers(in root: NSView) -> (layers: [Layer], backdrops: [NSView]) {
        var out: [Layer] = []
        var backdrops: [NSView] = []
        var drawn: [NSView] = []
        // `covered`: a SwiftUI ancestor was drawn, and its drawing already
        // includes this view. An AppKit view in between breaks that.
        func walk(_ v: NSView, covered: Bool) {
            guard Self.visible(v) else { return }
            if Self.isBackdrop(v) {
                backdrops.append(v)
                return
            }
            let swiftUI = Self.isSwiftUI(v)
            if v !== root {
                if swiftUI && !covered {
                    out.append(.draw(v))
                    drawn.append(v)
                } else if NSStringFromClass(type(of: v)).contains("ListTableRowView") {
                    out.append(.drawAlone(v)) // the selection, without the cells (drawn next)
                } else if NSStringFromClass(type(of: v)) == "NSTitlebarContainerView" {
                    out.append(.draw(v)) // above the content, so drawn again on top
                }
            }
            v.subviews.forEach { walk($0, covered: swiftUI) }
            // Rows scrolled under a bottom inset (the sidebar's Under the Hood
            // button) would show through without the blur: end them at a hard
            // edge, then draw the inset's content again.
            if let scroll = v as? NSScrollView, scroll.contentInsets.bottom > 0 {
                let b = scroll.bounds
                let band = NSRect(x: b.minX, y: scroll.isFlipped ? b.maxY - scroll.contentInsets.bottom : b.minY,
                                  width: b.width, height: scroll.contentInsets.bottom)
                let rect = scroll.convert(band, to: root)
                out.append(.fill(rect))
                for a in drawn where scroll.isDescendant(of: a) { out.append(.draw(a, clip: rect)) }
            }
        }
        walk(root, covered: false)
        return (out, backdrops)
    }

    /// Where SwiftUI draws Liquid Glass shapes (glass buttons), which
    /// cacheDisplay leaves out, in `root`'s coordinates.
    private func glassShapes(in root: NSView) -> [NSRect] {
        var out: [NSRect] = []
        // A titled window's title bar has glass spanning the window; leave it out.
        let maxWidth = root.window?.styleMask.contains(.titled) == true ? root.bounds.width * 0.9 : .infinity
        func add(_ r: NSRect) {
            if r.width > 1, r.height > 1, r.width < maxWidth, !out.contains(r) { out.append(r) }
        }
        func walk(_ layer: CALayer) {
            if NSStringFromClass(type(of: layer)) == "SwiftUI.SDFLayer" {
                add(root.layer.map { layer.convert(layer.bounds, to: $0) } ?? .zero)
            }
            layer.sublayers?.forEach(walk)
        }
        root.layer.map(walk)
        // AppKit glass (the sidebar, toolbar platters), whose renderer is hidden.
        func views(_ v: NSView) {
            guard !v.isHidden || Self.isGlassRenderer(v) else { return }
            if Self.isGlassRenderer(v) { add(v.convert(v.bounds, to: root)) }
            v.subviews.forEach(views)
        }
        views(root)
        return out
    }

    /// A sidebar list's cell or section header (under glass).
    private static func isVibrantListContent(_ v: NSView) -> Bool {
        let name = NSStringFromClass(type(of: v))
        guard name.contains("ListTable") else { return false } // rows, cells, section headers
        var a = v.superview
        while let s = a {
            if NSStringFromClass(type(of: s)).contains("GlassEffect") { return true }
            a = s.superview
        }
        return false
    }

    /// Inverts the brightness of dark pixels, keeping light ones (the
    /// selected row's text) and transparency.
    private static func lightenDark(_ rep: NSBitmapImageRep) {
        guard let data = rep.bitmapData, rep.samplesPerPixel == 4, rep.bitsPerSample == 8 else { return }
        for y in 0..<rep.pixelsHigh {
            let row = data + y * rep.bytesPerRow
            for x in 0..<rep.pixelsWide {
                let p = row + x * 4
                let a = Double(p[3]) / 255
                guard a > 0.02 else { continue }
                // Premultiplied: divide by alpha to get the colour.
                let rgb = (0..<3).map { Double(p[$0]) / 255 / a }
                guard 0.3 * rgb[0] + 0.59 * rgb[1] + 0.11 * rgb[2] < 0.5 else { continue }
                for i in 0..<3 { p[i] = UInt8(max(0, min(255, (1 - rgb[i]) * a * 255))) }
            }
        }
    }

    /// `view` at 2×, as cacheDisplay draws it.
    private func bitmap(of view: NSView) throws -> NSBitmapImageRep {
        let bounds = view.bounds
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: max(1, Int(bounds.width * 2)), pixelsHigh: max(1, Int(bounds.height * 2)),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { throw PipelineError.message("Couldn't make a bitmap") }
        rep.size = bounds.size
        view.cacheDisplay(in: bounds, to: rep)
        return rep
    }

    private func snapshot(_ root: NSView) throws -> Data {
        let (layers, backdrops) = layers(in: root)
        backdrops.forEach { $0.isHidden = true }
        defer { backdrops.forEach { $0.isHidden = false } }

        let bounds = root.bounds
        guard let out = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * 2), pixelsHigh: Int(bounds.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { throw PipelineError.message("Couldn't make a bitmap") }
        out.size = bounds.size
        let base = try bitmap(of: root)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        let background = { (rect: NSRect) in
            self.appearance.performAsCurrentDrawingAppearance {
                NSColor.windowBackgroundColor.setFill()
                rect.fill()
            }
        }
        background(bounds)
        base.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        // Rects in the root's coordinates, as drawn into the (unflipped) image.
        let image = { (r: NSRect) in
            root.isFlipped ? NSRect(x: r.minX, y: bounds.height - r.maxY, width: r.width, height: r.height) : r
        }
        for layer in layers {
            switch layer {
            case .draw(let v, let clip):
                let rect = image(v.convert(v.bounds, to: root))
                guard rect.width >= 1, rect.height >= 1 else { continue }
                NSGraphicsContext.saveGraphicsState()
                // Only the part the window shows (rows past the sidebar's edge don't).
                image(v.convert(v.visibleRect, to: root)).clip()
                if let clip { image(clip).clip() }
                let rep = try bitmap(of: v)
                // Vibrant content (the sidebar list) draws in colours meant to be
                // blended with what's behind; offscreen, dark mode text comes out
                // dark on dark. Lighten it to what the blend would show.
                if options.dark && Self.isVibrantListContent(v) { Self.lightenDark(rep) }
                rep.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                NSGraphicsContext.restoreGraphicsState()
            case .drawAlone(let v):
                let shown = v.subviews.filter { !$0.isHidden }
                shown.forEach { $0.isHidden = true }
                defer { shown.forEach { $0.isHidden = false } }
                NSGraphicsContext.saveGraphicsState()
                image(v.convert(v.visibleRect, to: root)).clip()
                try bitmap(of: v).draw(in: image(v.convert(v.bounds, to: root)), from: .zero, operation: .sourceOver,
                                       fraction: 1, respectFlipped: true, hints: nil)
                NSGraphicsContext.restoreGraphicsState()
            case .fill(let rect):
                background(image(rect))
            }
        }
        // Glass shapes as flat capsules. Their tint (accent, red) isn't known.
        appearance.performAsCurrentDrawingAppearance {
            for rect in glassShapes(in: root).map(image) {
                let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                                        xRadius: min(rect.height / 2, 18), yRadius: min(rect.height / 2, 18))
                NSColor.labelColor.withAlphaComponent(0.07).setFill()
                path.fill()
                NSColor.labelColor.withAlphaComponent(0.14).setStroke()
                path.lineWidth = 1
                path.stroke()
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let png = out.representation(using: .png, properties: [:]) else {
            throw PipelineError.message("Couldn't encode \(bounds.size) as PNG")
        }
        return png
    }
}
