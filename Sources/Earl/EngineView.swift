import ServiceManagement
import SwiftUI

/// "Under the Hood": what Earl runs, where things live, and the settings for each part.
struct EngineView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var engine: Engine

    @AppStorage(Prefs.Key.storagePath) private var storagePath = Prefs.defaultStoragePath
    @AppStorage(Prefs.Key.keepAudio) private var keepAudio = true
    @AppStorage(Prefs.Key.textOnly) private var textOnly = false // P-1
    @AppStorage(Prefs.Key.whisperModel) private var whisperModel = Prefs.defaultWhisperModel
    @AppStorage(Prefs.Key.language) private var language = Prefs.defaultLanguage
    @AppStorage(Prefs.Key.summariesEnabled) private var summariesEnabled = true
    @AppStorage(Prefs.Key.llmURL) private var llmURL = Prefs.defaultLLMURL
    @AppStorage(Prefs.Key.llmModel) private var llmModel = Prefs.defaultLLMModel

    /// The main window draws the masthead itself, edge to edge, like every page.
    var showsMasthead = true

    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var checkAutomatically = Updates.shared.automaticallyChecks
    @State private var showOtherServer = false
    @State private var copiedDiagnostics = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsMasthead { Masthead("Settings").padding(.bottom, 20) }
            intro
            pipeline.padding(.top, Paper.Space.lg)
            // U-3: the cards in four titled groups, so the long page reads in order.
            group("Calls") {
                recordingCard
                ShortcutSettings() // R1-1
                CallDetectionSettings() // R1-2
                CalendarSettings() // R2-1
                BriefSettings() // S-2
            }
            group("Transcripts") {
                transcriptionCard
                VocabularySettings()
                SpeakerSettings() // R2-2
            }
            group("Notes") {
                summaryCard
            }
            group("This Mac") {
                PrivacySettings() // P-1
                storageCard
                generalCard
            }
            Button(copiedDiagnostics ? "Copied" : "Copy diagnostics") { copyDiagnostics() }
                .buttonStyle(.paperSecondary)
                .padding(.top, 40)
        }
        .font(.settingsRow)
        .foregroundStyle(Paper.ink)
        .task {
            // Keep the page live while it's visible (server state, downloads, storage).
            while !Task.isCancelled {
                await state.refreshEngine()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func group(_ title: String, @ViewBuilder _ cards: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Paper.Space.lg) {
            Text(title)
                .font(.paperHeadline(size: 24))
                .foregroundStyle(Paper.ink)
            cards()
        }
        .padding(.top, 40)
    }

    // MARK: - Overview

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Under the hood").font(.paperHeadline).foregroundStyle(Paper.ink)
            Text("Everything runs on this Mac. Earl only talks to your local AI server, and to Hugging Face when you download a model.")
                .font(.paperLede)
                .foregroundStyle(Paper.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The three stages as a flow.
    private var pipeline: some View {
        HStack(alignment: .top, spacing: 0) {
            stage("Record", icon: "mic", detail: "Mic + call audio",
                  status: recordingOK ? .ok : .attention, statusText: recordingOK ? "Ready" : "Needs permission")
            arrow
            stage("Transcribe", icon: "waveform", detail: WhisperModelOption.displayName(forPath: whisperModel),
                  status: whisperOK ? .ok : .attention, statusText: whisperOK ? "Ready" : "Not set up")
            arrow
            stage("Summarize", icon: "sparkles", detail: summariesEnabled ? shortModel : "Off",
                  status: !summariesEnabled ? .idle : engine.server.reachable ? .ok : .idle,
                  statusText: !summariesEnabled ? "Off" : engine.server.reachable ? "Ready" : "Starts when needed")
        }
        .surface()
    }

    private var arrow: some View {
        Image(systemName: "arrow.right")
            .font(.system(size: 14))
            .foregroundStyle(Paper.inkMuted)
            .frame(width: 28)
            .padding(.top, 9)
    }

    private func stage(_ title: String, icon: String, detail: String, status: StatusLabel.Kind, statusText: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Paper.ink)
                .frame(width: 34, height: 34)
                .background(Paper.paperSoft, in: RoundedRectangle(cornerRadius: Paper.Radius.button, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Paper.Radius.button, style: .continuous).strokeBorder(Paper.hairline))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.paperLabel)
                Text(detail).font(.settingsNote).foregroundStyle(Paper.inkMuted).lineLimit(1)
                StatusLabel(kind: status, text: statusText).font(.settingsNote)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var recordingOK: Bool { engine.microphone == .granted && engine.screenAudio == .granted }
    private var whisperOK: Bool { engine.whisperInstalled && FileManager.default.fileExists(atPath: whisperModel) }
    private var shortModel: String {
        if case .builtIn(let m) = engine.notesBackend { return m.displayName } // D-3: "Qwen3.5 9B", not its id
        let model = engine.notesModel
        return model.split(separator: "/").last.map(String.init) ?? model
    }

    // MARK: - Recording

    private var recordingCard: some View {
        Card(title: "Recording",
             subtitle: "Your microphone and everything this Mac plays are saved as two separate tracks.") {
            VStack(spacing: 12) {
                permissionRow("Microphone", "Your voice, labelled Me", engine.microphone, pane: "Privacy_Microphone")
                SettingsRule()
                permissionRow("Screen & System Audio", "The call, labelled Them. No video is kept.",
                              engine.screenAudio, pane: "Privacy_ScreenCapture")
                SettingsRule()
                InfoRow(label: "Input device", value: engine.microphoneName ?? "None") {
                    Button("Sound Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!)
                    }
                    .buttonStyle(.paperSecondary)
                }
            }
        }
    }

    private func permissionRow(_ title: String, _ subtitle: String, _ status: Engine.Permission, pane: String) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.settingsRowTitle)
                Text(subtitle).font(.settingsNote).foregroundStyle(Paper.inkMuted)
            }
            Spacer()
            if status == .granted {
                StatusLabel(kind: .ok, text: "Allowed").font(.settingsRow)
            } else {
                StatusLabel(kind: .attention, text: "Not allowed").font(.settingsRow)
                Button("Open Settings") { state.openPrivacySettings(pane) }
                    .buttonStyle(.paperSecondary)
            }
        }
    }

    // MARK: - Transcription

    private var transcriptionCard: some View {
        Card(title: "Transcription",
             subtitle: engine.whisperInstalled
                ? "whisper.cpp \(engine.whisperVersion ?? "") on the GPU, with silence detection \(engine.vadInstalled ? "on" : "unavailable")."
                : "The transcriber is missing. Install Earl again from the latest download.") {
            VStack(spacing: 2) {
                ForEach(WhisperModelOption.all) { option in
                    whisperRow(option)
                }
            }

            if let error = engine.whisperDownloadFailure {
                StatusLabel(kind: .attention, text: error).font(.settingsNote)
            }

            SettingsRule()

            HStack {
                Text("Spoken language").font(.settingsRow)
                Spacer()
                Picker("Spoken language", selection: $language) {
                    ForEach(Prefs.languages, id: \.code) { Text($0.name).tag($0.code) }
                }
                .labelsHidden()
                .fixedSize()
            }
            Text("Automatic detection picks one language per track. Choose one if your meetings mix languages.")
                .font(.settingsNote)
                .foregroundStyle(Paper.inkMuted)
        }
    }

    private func whisperRow(_ option: WhisperModelOption) -> some View {
        let installed = engine.installedModels[option.file]
        let selected = whisperModel == option.path
        let progress = engine.downloads[option.file]

        return ListRow(selected: selected) {
            RadioMark(selected: selected)
                .opacity(installed == nil ? 0.35 : 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(option.name).font(.settingsRowTitle)
                Text(option.note).font(.settingsNote).foregroundStyle(Paper.inkMuted)
            }
            Spacer()
            if let progress {
                ProgressView(value: progress).frame(width: 80)
                Text("\(Int(progress * 100))%").font(.settingsNote.monospacedDigit()).foregroundStyle(Paper.inkMuted)
                Button {
                    engine.cancelDownload(option)
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Cancel download")
            } else if let bytes = installed {
                Text(Format.bytes(bytes)).font(.settingsNote.monospacedDigit()).foregroundStyle(Paper.inkMuted)
                if !selected {
                    Button {
                        engine.deleteModel(option)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Paper.inkMuted)
                    .help("Move \(option.name) to the Trash")
                }
            } else {
                Button("Download \(option.approxSize)") { engine.download(option) }
                    .buttonStyle(.paperSecondary)
                    .controlSize(.small)
            }
        }
        .onTapGesture {
            if installed != nil { whisperModel = option.path }
        }
    }

    // MARK: - Summaries

    private var summaryCard: some View {
        // D-3: Earl picks the note writer by what's on this Mac; the card says which.
        let backend = engine.notesBackend
        return Card(title: "Summaries", subtitle: NotesEngine.label(backend)) {
            Toggle("Write notes after each meeting", isOn: $summariesEnabled)

            if summariesEnabled {
                serverRow(backend)

                // D-3: no LM Studio or Ollama models: the built-in note writer, downloaded like the transcription models.
                if backend == .none || backend.isBuiltIn {
                    VStack(spacing: 2) {
                        ForEach(builtInModels, id: \.id) { builtInRow($0, active: backend == .builtIn(model: $0)) }
                    }
                    if let error = builtInModels.lazy.compactMap(engine.downloadFailure).first {
                        StatusLabel(kind: .attention, text: error).font(.settingsNote)
                    }
                }

                if backend != .none && !engine.server.models.isEmpty {
                    NotesModelList(models: engine.server.models, active: engine.notesModel) // R2-7
                    Text("Small models (around 4B) are quick but can mix up who does what. Larger ones (27B) get it right more often but take longer. Earl loads the model with enough context for each meeting.")
                        .font(.settingsNote)
                        .foregroundStyle(Paper.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    NotesOptions(models: engine.server.models, active: engine.notesModel) // R2-7
                }

                if backend != .none {
                    SettingsRule()
                    testArea
                }

                DisclosureGroup("Use another server…", isExpanded: $showOtherServer) {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Server URL", text: $llmURL)
                        TextField("Model ID", text: $llmModel)
                        Text("Any OpenAI-compatible server, such as a team server. Leave the address at \(Prefs.defaultLLMURL) and Earl uses LM Studio or Ollama on this Mac by itself. For an Ollama server, Earl adds a copy of the model with room for long meetings.")
                            .font(.settingsNote)
                            .foregroundStyle(Paper.inkMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .textFieldStyle(.roundedBorder)
                    .padding(.top, 8)
                }
                .font(.settingsRow)
                .task(id: llmURL) {
                    // Typing a URL: look again once the typing pauses.
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled else { return }
                    await state.refreshEngine()
                }
                .onChange(of: llmModel) { Task { await state.refreshEngine() } } // the pick shows at once
            }
        }
    }

    /// This Mac's tier first, then any other built-in note writer on disk (so it can go).
    private var builtInModels: [BuiltInModel] {
        let mine = BuiltInModel.forMemory(ProcessInfo.processInfo.physicalMemory)
        return [mine] + BuiltInModel.all.filter { $0 != mine && engine.builtInInstalled[$0.file] != nil }
    }

    /// A built-in note writer: Download, its progress, or its size and the Trash, like the whisper rows.
    private func builtInRow(_ model: BuiltInModel, active: Bool) -> some View {
        let installed = engine.builtInInstalled[model.file]
        let progress = engine.downloads[model.file]
        return ListRow(selected: active) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.displayName).font(.settingsRowTitle)
                Text(active ? "Writes your notes, on this Mac." : "Built in. Runs on this Mac when LM Studio and Ollama aren't here.")
                    .font(.settingsNote).foregroundStyle(Paper.inkMuted)
            }
            Spacer()
            if let progress {
                ProgressView(value: progress).frame(width: 80)
                Text("\(Int(progress * 100))%").font(.settingsNote.monospacedDigit()).foregroundStyle(Paper.inkMuted)
                Button {
                    engine.cancelDownload(model)
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Cancel download")
            } else if let bytes = installed {
                Text(Format.bytes(bytes)).font(.settingsNote.monospacedDigit()).foregroundStyle(Paper.inkMuted)
                Button {
                    Task { await engine.deleteModel(model) }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Paper.inkMuted)
                .help("Move \(model.displayName) to the Trash")
            } else {
                Button("Download \(model.approxSize)") { engine.download(model) }
                    .buttonStyle(.paperSecondary)
                    .controlSize(.small)
            }
        }
    }

    /// Whether the note writer is running, and what can be done about it.
    @ViewBuilder
    private func serverRow(_ backend: NotesBackend) -> some View {
        HStack(spacing: 8) {
            switch backend {
            case .none:
                StatusLabel(kind: .attention, text: "No LM Studio or Ollama on this Mac.").font(.settingsRow)
            case .builtIn:
                StatusLabel(kind: engine.server.reachable ? .ok : .idle,
                            text: engine.server.reachable ? "Running" : "Earl starts it when needed.").font(.settingsRow)
            case .custom(let url):
                if engine.server.reachable {
                    StatusLabel(kind: .ok, text: "Server running").font(.settingsRow)
                } else {
                    StatusLabel(kind: .attention, text: "Earl can't reach \(url).").font(.settingsRow)
                }
            case .ollama:
                StatusLabel(kind: engine.server.reachable ? .ok : .idle,
                            text: engine.server.reachable ? "Ollama running" : "Ollama is off.").font(.settingsRow)
            case .lmStudio:
                if engine.server.reachable {
                    StatusLabel(kind: .ok, text: "Server running").font(.settingsRow)
                } else {
                    StatusLabel(kind: .idle, text: "Server off. Earl starts it when needed.").font(.settingsRow)
                }
            }
            Spacer()
            if case .lmStudio = backend {
                if !engine.server.reachable && Summarizer.hasLMStudio {
                    Button(engine.startingServer ? "Starting…" : "Start Now") {
                        Task { await engine.startServer() }
                    }
                    .disabled(engine.startingServer)
                }
                Button("Open LM Studio") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/LM Studio.app"))
                }
            }
        }
        .buttonStyle(.paperSecondary)
    }

    private var testArea: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button {
                    Task { await engine.runTest() }
                } label: {
                    Label(engine.testRunning ? "Testing…" : "Test \(shortModel)", systemImage: "play")
                }
                .buttonStyle(.paperSecondary)
                .disabled(engine.testRunning)
                Spacer()
                if let speed = engine.testSpeed {
                    Text("\(Int(speed)) tokens per second")
                        .font(.settingsRow.monospacedDigit())
                        .foregroundStyle(Paper.inkMuted)
                }
            }
            if let error = engine.testError {
                StatusLabel(kind: .attention, text: error).font(.settingsRow)
            } else if !engine.testOutput.isEmpty {
                Text(engine.testOutput)
                    .font(.settingsRow)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .surface(padding: 12, radius: Theme.rowRadius)
            }
        }
    }

    // MARK: - Storage

    private var storageCard: some View {
        Card(title: "Storage") {
            HStack(spacing: 32) {
                stat(Format.bytes(engine.storageBytes), "in total")
                stat(Format.bytes(engine.audioBytes), "of audio")
                stat("\(engine.meetingCount)", engine.meetingCount == 1 ? "meeting" : "meetings")
            }
            SettingsRule()
            InfoRow(label: "Meetings", value: storagePath) {
                HStack {
                    Button("Show") { NSWorkspace.shared.open(Prefs.storageURL) }
                    Button("Change…", action: chooseFolder)
                }
                .buttonStyle(.paperSecondary)
            }
            InfoRow(label: "Models", value: RecordingView.tilde(Prefs.modelsDir)) {
                Button("Show") { NSWorkspace.shared.open(Prefs.modelsDir) }
                    .buttonStyle(.paperSecondary)
            }
            SettingsRule()
            Toggle("Keep audio after transcribing", isOn: textOnly ? .constant(false) : $keepAudio)
                .disabled(textOnly)
            HStack(alignment: .top) {
                Text(textOnly ? "Off while “Keep only the text” is on, under Privacy."
                              : "About 115 MB per hour. Keeping it lets you transcribe again with a better model later.")
                    .font(.settingsNote)
                    .foregroundStyle(Paper.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if engine.audioBytes > 0 {
                    Button("Delete Old Audio…") { state.deleteAllAudio() }
                        .buttonStyle(.paperSecondary)
                }
            }
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 22, weight: .semibold).monospacedDigit())
            Text(label).font(.settingsNote).foregroundStyle(Paper.inkMuted)
        }
    }

    // MARK: - General

    private var generalCard: some View {
        Card(title: "General") {
            Toggle("Open Earl at login", isOn: $openAtLogin)
                .onChange(of: openAtLogin) { _, on in
                    try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                }
            updatesRows
        }
    }

    /// D-4: the version, a manual check and the daily check. Quiet when this build has no feed.
    @ViewBuilder private var updatesRows: some View {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String
        Text(build.map { "Earl \(version) (build \($0))" } ?? "Earl \(version)")
            .foregroundStyle(Paper.inkMuted)
        if Updates.shared.isRunning {
            Toggle("Check automatically", isOn: $checkAutomatically)
                .onChange(of: checkAutomatically) { _, on in Updates.shared.automaticallyChecks = on }
            Button("Check for Updates…") { Updates.shared.checkNow() }
                .buttonStyle(.paperSecondary)
        } else {
            Text("Updates aren't set up in this build.").foregroundStyle(Paper.inkMuted)
        }
    }

    private func copyDiagnostics() {
        let text = Diagnostics.report(Diagnostics.snapshot(engine: engine, meetings: state.meetings))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedDiagnostics = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copiedDiagnostics = false
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = Prefs.storageURL
        if panel.runModal() == .OK, let url = panel.url {
            storagePath = (url.path as NSString).abbreviatingWithTildeInPath
            state.reload()
        }
    }
}

// MARK: - U-3: settings type and rules

extension Font {
    /// A settings row: labels, toggles, values.
    static let settingsRow = Font.system(size: 14)
    /// The name of a model or permission in a row.
    static let settingsRowTitle = Font.system(size: 14, weight: .medium)
    /// Explanations under a control, sizes, paths. The 13 pt floor.
    static let settingsNote = Font.system(size: 13)
}

/// A tan hairline between the parts of a settings card (instead of the grey
/// system divider).
struct SettingsRule: View {
    var body: some View {
        Rectangle().fill(Paper.hairline).frame(height: 1)
    }
}
