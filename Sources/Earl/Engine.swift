import AppKit
import AVFoundation
import CoreGraphics
import Foundation

/// Everything the "Under the Hood" page shows: permissions, the Whisper setup,
/// the local AI server and storage use. Refreshed on demand.
@MainActor
final class Engine: ObservableObject {
    enum Permission { case granted, denied, notAsked }

    @Published private(set) var microphone: Permission = .notAsked
    @Published private(set) var screenAudio: Permission = .notAsked
    @Published private(set) var microphoneName: String?
    /// D-2: the Mac's administrator decides about the microphone (a privacy profile).
    @Published private(set) var microphoneRestricted = false
    /// D-2: asked for screen audio in this run; macOS only turns it on after a restart.
    @Published private(set) var screenAudioAskedThisRun = false

    @Published private(set) var whisperVersion: String?
    @Published private(set) var whisperInstalled = false
    @Published private(set) var installedModels: [String: Int64] = [:] // file name -> bytes
    @Published private(set) var vadInstalled = false
    /// D-3: built-in note writers on this Mac: file name -> bytes.
    @Published private(set) var builtInInstalled: [String: Int64] = [:]

    /// D-3: what writes the notes: LM Studio, Ollama, the built-in engine, the user's server, or nothing yet.
    @Published private(set) var notesBackend: NotesBackend = NotesEngine.current
    @Published private(set) var server = Summarizer.ServerStatus(reachable: false, isLMStudio: false, models: [])
    @Published private(set) var checkedServer = false
    @Published private(set) var startingServer = false

    @Published private(set) var storageBytes: Int64 = 0
    @Published private(set) var audioBytes: Int64 = 0
    @Published private(set) var meetingCount = 0

    /// Active model downloads: file name -> progress 0...1.
    @Published private(set) var downloads: [String: Double] = [:]
    @Published var downloadError: String?
    /// D-3: why a download failed, by file, so each card (and onboarding step)
    /// shows only its own file's failure.
    @Published private(set) var downloadFailures: [String: String] = [:]

    /// Result of the Test button.
    @Published private(set) var testOutput = ""
    @Published private(set) var testSpeed: Double?
    @Published private(set) var testRunning = false
    @Published private(set) var testError: String?

    private var downloaders: [String: Downloader] = [:]

    var selectedModel: LLMModel? { server.models.first { $0.id == notesModel } }

    /// The model the notes are written with.
    var notesModel: String { NotesEngine.model(for: notesBackend, fallback: Prefs.llmModel) }

    /// The notes server's URL; the setting while the built-in one isn't running.
    var notesURL: String { NotesEngine.baseURL(for: notesBackend) ?? Prefs.llmURL }

    func refresh(meetings: [Meeting]) async {
        refreshLocal(meetings: meetings)
        await refreshNotesBackend()
        server = await serverStatus()
        checkedServer = true
    }

    /// The notes server as the Summaries card shows it. D-3: the built-in one
    /// is running when BuiltInServer runs it, whatever the URL setting says.
    private func serverStatus() async -> Summarizer.ServerStatus {
        guard notesBackend.isBuiltIn else { return await Summarizer.serverStatus(baseURL: notesURL) }
        return Summarizer.ServerStatus(reachable: await BuiltInServer.shared.runningModel != nil, isLMStudio: false, models: [])
    }

    /// D-3: looks for LM Studio and Ollama on this Mac and applies the choice.
    func refreshNotesBackend() async {
        adopt(await NotesEngine.resolve())
    }

    /// D-3: a choice made elsewhere (processing a meeting resolves again), shown at once.
    func adopt(_ backend: NotesBackend) {
        if backend != notesBackend { notesBackend = backend }
    }

    func refreshLocal(meetings: [Meeting]? = nil) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: microphone = .granted
        case .notDetermined: microphone = .notAsked
        default: microphone = .denied
        }
        microphoneRestricted = AVCaptureDevice.authorizationStatus(for: .audio) == .restricted
        screenAudio = CGPreflightScreenCaptureAccess() ? .granted : .notAsked
        microphoneName = Recorder.microphoneName

        let fm = FileManager.default
        whisperInstalled = fm.isExecutableFile(atPath: Prefs.whisperPath)
        // Homebrew installs into .../Cellar/<formula>/<version>/bin; read the version from the path.
        let resolved = URL(fileURLWithPath: Prefs.whisperPath).resolvingSymlinksInPath().pathComponents
        if Prefs.whisperPath == Prefs.bundledHelper("whisper-cli") {
            whisperVersion = Bundle.main.object(forInfoDictionaryKey: "EarlWhisperVersion") as? String
        } else if let i = resolved.firstIndex(of: "Cellar"), resolved.count > i + 2 {
            whisperVersion = resolved[i + 2]
        } else {
            whisperVersion = nil
        }

        var models: [String: Int64] = [:]
        let urls = (try? fm.contentsOfDirectory(at: Prefs.modelsDir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        for url in urls where url.lastPathComponent.hasPrefix("ggml-") && !url.lastPathComponent.contains("silero") {
            models[url.lastPathComponent] = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        installedModels = models
        vadInstalled = fm.fileExists(atPath: Prefs.vadModel)
        var notes: [String: Int64] = [:]
        for model in BuiltInModel.all where model.fileURL != nil { notes[model.file] = model.bytes }
        if notes != builtInInstalled { builtInInstalled = notes }

        if let meetings {
            storageBytes = meetings.reduce(0) { $0 + $1.totalBytes }
            audioBytes = meetings.reduce(0) { $0 + $1.audioBytes }
            meetingCount = meetings.count
        }
    }

    /// U-0: a healthy, fixed setup for UI snapshots, without probing this Mac.
    func showDemo(whisperModels: [String: Int64], server: Summarizer.ServerStatus, meetings: [Meeting],
                  notesBackend: NotesBackend = .lmStudio(model: "google/gemma-4-e4b"), builtIn: [String: Int64] = [:]) {
        self.notesBackend = notesBackend
        builtInInstalled = builtIn
        NotesEngine.current = notesBackend
        microphone = .granted
        screenAudio = .granted
        microphoneName = "MacBook Pro Microphone"
        whisperInstalled = true
        whisperVersion = "1.7.6"
        installedModels = whisperModels
        vadInstalled = true
        self.server = server
        checkedServer = true
        storageBytes = meetings.reduce(0) { $0 + $1.totalBytes }
        audioBytes = meetings.reduce(0) { $0 + $1.audioBytes }
        meetingCount = meetings.count
    }

    /// U-0: a download in progress, for snapshots.
    func showDemoDownload(file: String, progress: Double) { downloads[file] = progress }

    // MARK: - Setup (D-2)

    /// What's left before the first meeting, as SetupGuide sees it.
    var setupState: SetupState {
        SetupState(transcriberPresent: whisperInstalled,
                   whisperModelPresent: FileManager.default.fileExists(atPath: Prefs.whisperModel),
                   vadPresent: vadInstalled, speakerModelsPresent: Diarizer().isInstalled,
                   microphone: microphone, microphoneRestricted: microphoneRestricted,
                   screenAudio: screenAudio, screenAudioAskedThisRun: screenAudioAskedThisRun,
                   notesReady: SetupState.notesReady(summariesEnabled: Prefs.summariesEnabled, backend: notesBackend))
    }

    /// Shows macOS's microphone question (only the first time; after that it's System Settings).
    func requestMicrophone() async {
        _ = await Recorder.requestMicrophoneAccess()
        refreshLocal()
    }

    /// Puts Earl in the Screen & System Audio Recording list and opens that pane.
    /// The switch only takes effect after a restart, which the next launch remembers.
    func requestScreenAudio() {
        CGRequestScreenCaptureAccess()
        Self.openPrivacySettings("Privacy_ScreenCapture")
        screenAudioAskedThisRun = true
        Prefs.defaults.set(true, forKey: Prefs.Key.screenAudioAsked)
    }

    static func openPrivacySettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Starts a fresh copy of Earl, then quits this one.
    func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            guard error == nil else { return } // never quit without a new copy running
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }

    func startServer() async {
        startingServer = true
        await Summarizer.startLMStudioServer()
        await refreshNotesBackend()
        server = await serverStatus()
        startingServer = false
    }

    func runTest() async {
        testRunning = true
        testOutput = ""
        testSpeed = nil
        testError = nil
        await refreshNotesBackend() // D-3: the model just picked, not the one from the last look
        do {
            let speed = try await Summarizer().test { [weak self] event in
                switch event {
                case .progress(let text, let thinking, _, let perSecond):
                    self?.testOutput = text.isEmpty && thinking > 0 ? "Thinking… (\(thinking) characters)" : text
                    self?.testSpeed = perSecond
                case .status(let s): self?.testOutput = s
                case .newPass: break
                }
            }
            testSpeed = speed ?? testSpeed
        } catch {
            testError = error.localizedDescription
        }
        testRunning = false
        server = await serverStatus()
    }

    // MARK: - Model downloads

    /// One file Earl downloads into its models folder: a transcription model or the built-in note writer.
    struct ModelFile: Equatable {
        var file: String
        var name: String
        var url: URL
        var sha256: String
        var destination: URL

        init(_ option: WhisperModelOption) {
            self.init(file: option.file, name: option.name, url: option.url, sha256: option.sha256,
                      destination: URL(fileURLWithPath: option.path))
        }

        init(_ model: BuiltInModel) {
            self.init(file: model.file, name: model.name, url: model.url, sha256: model.sha256, destination: model.path)
        }

        init(file: String, name: String, url: URL, sha256: String, destination: URL) {
            self.file = file
            self.name = name
            self.url = url
            self.sha256 = sha256
            self.destination = destination
        }

        /// The file a checksum belongs to: a transcription model, else a built-in note writer.
        static func matching(sha256: String) -> ModelFile? {
            WhisperModelOption.matching(sha256: sha256).map(ModelFile.init) ?? BuiltInModel.matching(sha256: sha256).map(ModelFile.init)
        }
    }

    func download(_ option: WhisperModelOption) { download(ModelFile(option)) }

    /// D-3: the built-in note writer, checked against its SHA-256 like the transcription models.
    func download(_ model: BuiltInModel) { download(ModelFile(model)) }

    private func download(_ item: ModelFile) {
        guard downloaders[item.file] == nil else { return }
        downloadError = nil
        downloadFailures[item.file] = nil
        downloads[item.file] = 0
        let downloader = Downloader(url: item.url, destination: item.destination, expectedSHA256: item.sha256) { [weak self] progress in
            Task { @MainActor in self?.downloads[item.file] = progress }
        } completion: { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                self.downloads[item.file] = nil
                self.downloaders[item.file] = nil
                if let error {
                    let message = "Download of \(item.name) failed: \(error.localizedDescription)"
                    self.downloadError = message
                    self.downloadFailures[item.file] = message
                }
                self.refreshLocal()
                if error == nil, BuiltInModel.matching(sha256: item.sha256) != nil { await self.refreshNotesBackend() }
            }
        }
        downloaders[item.file] = downloader
        downloader.start()
    }

    /// D-2: install a model file the user already has (from a colleague or a drive), matched by checksum:
    /// a transcription model or, D-3, the built-in note writer.
    /// The task ends when the file is in place or `downloadError` says why not.
    @discardableResult
    func importModel(from url: URL) -> Task<Void, Never> {
        downloadError = nil
        return Task { [weak self] in
            let hash = await Task.detached { try? ModelFiles.sha256(of: url) }.value
            guard let self else { return }
            guard let hash else { self.downloadError = "Earl couldn't read that file."; return }
            guard let item = ModelFile.matching(sha256: hash) else {
                self.downloadError = "That file isn't one of Earl's models."
                return
            }
            guard self.downloaders[item.file] == nil else {
                self.downloadError = "Earl is already downloading this file."
                return
            }
            // D-3: a larger tier's note writer would make this Mac swap.
            if let model = BuiltInModel.matching(sha256: hash),
               let refusal = BuiltInModel.importRefusal(model, memory: ProcessInfo.processInfo.physicalMemory) {
                self.downloadError = refusal
                return
            }
            self.downloads[item.file] = 1
            let failure: String? = await Task.detached {
                do { try ModelFiles.install(from: url, to: item.destination, sha256: item.sha256); return nil }
                catch { return error.localizedDescription }
            }.value
            self.downloads[item.file] = nil
            if let failure {
                self.downloadError = "Couldn't add \(item.name): \(failure)"
            } else if let option = WhisperModelOption.matching(sha256: hash),
                      let path = Self.whisperPreference(afterImporting: option,
                                                        chosenExists: FileManager.default.fileExists(atPath: Prefs.whisperModel)) {
                // Like a download: the chosen model is gone, so the one just added becomes it.
                Prefs.defaults.set(path, forKey: Prefs.Key.whisperModel)
            }
            self.refreshLocal()
            if failure == nil, BuiltInModel.matching(sha256: hash) != nil { await self.refreshNotesBackend() }
        }
    }

    /// The transcription model to choose after adding `option` by hand: it, when the
    /// chosen one isn't on this Mac; nil (keep the choice) otherwise, or for silence detection.
    nonisolated static func whisperPreference(afterImporting option: WhisperModelOption, chosenExists: Bool) -> String? {
        option == .vad || chosenExists ? nil : option.path
    }

    func cancelDownload(_ option: WhisperModelOption) { cancelDownload(file: option.file) }

    func cancelDownload(_ model: BuiltInModel) { cancelDownload(file: model.file) }

    /// D-3: why this note writer's download failed, if it did.
    func downloadFailure(_ model: BuiltInModel) -> String? { downloadFailures[model.file] }

    /// The last failed transcription download, for the Transcription card.
    var whisperDownloadFailure: String? {
        (WhisperModelOption.all + [.vad]).lazy.compactMap { self.downloadFailures[$0.file] }.first
    }

    private func cancelDownload(file: String) {
        downloaders[file]?.cancel()
        downloaders[file] = nil
        downloads[file] = nil
    }

    func deleteModel(_ option: WhisperModelOption) {
        try? FileManager.default.trashItem(at: URL(fileURLWithPath: option.path), resultingItemURL: nil)
        installedModels[option.file] = nil
    }

    /// D-3: the built-in note writer to the Trash; notes then need LM Studio, Ollama or a new download.
    func deleteModel(_ model: BuiltInModel) async {
        try? FileManager.default.trashItem(at: model.path, resultingItemURL: nil)
        builtInInstalled[model.file] = nil
        // Its server holds the deleted file in memory: stop it now unless a
        // meeting is being processed (then the idle stop does it later).
        if await BuiltInServer.shared.runningModel == model.path.path { await BuiltInServer.shared.stopUnlessBusy() }
        await refreshNotesBackend()
        server = await serverStatus()
    }
}

/// Downloads one file with progress reporting.
final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let url: URL
    private let destination: URL
    private let expectedSHA256: String?
    private let onProgress: (Double) -> Void
    private let completion: (Error?) -> Void
    private var session: URLSession?

    init(url: URL, destination: URL, expectedSHA256: String?, onProgress: @escaping (Double) -> Void, completion: @escaping (Error?) -> Void) {
        self.url = url
        self.destination = destination
        self.expectedSHA256 = expectedSHA256
        self.onProgress = onProgress
        self.completion = completion
    }

    func start() {
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        self.session = session
        session.downloadTask(with: url).resume()
    }

    func cancel() {
        session?.invalidateAndCancel()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            completion(PipelineError.message("HTTP \(status)"))
            session.finishTasksAndInvalidate()
            return
        }
        do {
            if let expectedSHA256 {
                onProgress(1) // "Checking…" while the file is hashed (delegate queue, off the main thread)
                try ModelFiles.verify(location, sha256: expectedSHA256)
            }
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            completion(nil)
        } catch {
            completion(error)
        }
        session.finishTasksAndInvalidate()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error, (error as? URLError)?.code != .cancelled {
            completion(error)
        }
    }
}
