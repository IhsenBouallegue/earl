import FluidAudio
import SwiftUI

// R2-2: tells the voices on a track apart (speaker diarization) with
// FluidAudio's offline pipeline: pyannote segmentation, WeSpeaker embeddings
// and VBx clustering, as Core ML models on the Neural Engine.

extension Prefs.Key {
    static let separateSpeakers = "separateSpeakers"
    static let separateMicSpeakers = "separateMicSpeakers"
}

extension Prefs {
    static var separateSpeakers: Bool { Prefs.defaults.object(forKey: Key.separateSpeakers) as? Bool ?? true }
    static var separateMicSpeakers: Bool {
        Prefs.defaults.object(forKey: Key.separateMicSpeakers) as? Bool ?? false
    }
    /// FluidAudio keeps its repo in a folder of its own under this one.
    static let speakerModelsDir = modelsDir.appendingPathComponent("speakers", isDirectory: true)
}

/// Who spoke when on one track. Speaker indices are 0-based and local to the track.
struct Diarization {
    var segments: [(start: Double, end: Double, speaker: Int)]
    var speakers: [(index: Int, embedding: [Float], seconds: Double)]
}

struct Diarizer {
    static let modelName = "pyannote + WeSpeaker"
    static let modelDetail = "pyannote segmentation, WeSpeaker voice prints and VBx clustering, on the Neural Engine"
    static let approxSize = "22 MB"

    var modelsDir = Prefs.speakerModelsDir
    var config = Diarizer.defaultConfig
    /// Merges a quiet person's voice back together when the clustering split
    /// it into tiny voices, and folds voices of under 3 s, which on the
    /// synthetic meetings were never a real person (see SpeakerConsolidation).
    /// nil turns it off.
    var consolidation: SpeakerConsolidation.Options? = .init(foldSeconds: 3)

    /// FluidAudio's pyannote defaults, tuned on tools/eval-diarization.sh: a
    /// window every second instead of every two, and voice prints from speech
    /// as short as 0.4 s, so one- or two-second replies get their own speaker
    /// instead of being absorbed by a neighbour (≈90 % → 96 % of words right,
    /// at about twice the diarization time).
    static var defaultConfig: OfflineDiarizerConfig {
        var config = OfflineDiarizerConfig()
        config.segmentation.stepRatio = 0.1
        config.embedding.minSegmentDurationSeconds = 0.4
        return config
    }

    /// Everything FluidAudio's offline pipeline loads, relative to `repoDir`.
    private static let requiredFiles = [
        ModelNames.OfflineDiarizer.segmentationFile, ModelNames.OfflineDiarizer.fbankFile,
        ModelNames.OfflineDiarizer.embeddingFile, ModelNames.OfflineDiarizer.pldaRhoFile,
    ].map { "\($0)/coremldata.bin" } + [ModelNames.OfflineDiarizer.pldaParameters]

    var repoDir: URL { modelsDir.appendingPathComponent(Repo.diarizer.folderName, isDirectory: true) }

    /// Checked before every run: FluidAudio would otherwise download missing
    /// models on its own, without the user seeing it.
    var isInstalled: Bool {
        Self.requiredFiles.allSatisfy { FileManager.default.fileExists(atPath: repoDir.appendingPathComponent($0).path) }
    }

    var installedBytes: Int64 {
        let files = FileManager.default.enumerator(at: repoDir, includingPropertiesForKeys: [.fileSizeKey])
        var total: Int64 = 0
        while let url = files?.nextObject() as? URL {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    /// Downloads and compiles the models into `modelsDir`, reporting progress 0...1.
    func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        _ = try await OfflineDiarizerModels.load(from: modelsDir) { p in progress(p.fractionCompleted) }
    }

    func run(audio: URL, minSpeakers: Int? = nil, maxSpeakers: Int? = nil) async throws -> Diarization {
        guard isInstalled else { throw PipelineError.message("The speaker model isn't downloaded.") }
        var config = config
        config.clustering.minSpeakers = minSpeakers
        config.clustering.maxSpeakers = maxSpeakers
        let manager = OfflineDiarizerManager(config: config)
        manager.initialize(models: try await OfflineDiarizerModels.load(from: modelsDir))
        let result = try await manager.process(audio)
        let diarization = Self.convert(result)
        return consolidation.map { SpeakerConsolidation.consolidate(diarization, options: $0) } ?? diarization
    }

    /// FluidAudio labels voices "S1", "S2", …; renumber them 0, 1, … by first appearance.
    private static func convert(_ result: DiarizationResult) -> Diarization {
        var index: [String: Int] = [:]
        var seconds: [Int: Double] = [:]
        var segments: [(start: Double, end: Double, speaker: Int)] = []
        for seg in result.segments.sorted(by: { $0.startTimeSeconds < $1.startTimeSeconds }) {
            let i = index[seg.speakerId] ?? index.count
            index[seg.speakerId] = i
            segments.append((Double(seg.startTimeSeconds), Double(seg.endTimeSeconds), i))
            seconds[i, default: 0] += Double(seg.durationSeconds)
        }
        let speakers = index.sorted { $0.value < $1.value }.map { id, i in
            (index: i, embedding: result.speakerDatabase?[id] ?? [], seconds: seconds[i] ?? 0)
        }
        return Diarization(segments: segments, speakers: speakers)
    }
}

/// Download state of the speaker model, shared by Settings and processing.
@MainActor
final class SpeakerModel: ObservableObject {
    static let shared = SpeakerModel()

    @Published private(set) var installedBytes: Int64?
    @Published private(set) var progress: Double?
    @Published private(set) var error: String?

    private var task: Task<Void, Never>?

    init() { refresh() }

    func refresh() {
        let diarizer = Diarizer()
        installedBytes = diarizer.isInstalled ? diarizer.installedBytes : nil
    }

    func download() {
        guard task == nil else { return }
        error = nil
        progress = 0
        task = Task {
            do {
                try await Diarizer().download { p in
                    Task { @MainActor in if self.progress != nil { self.progress = p } }
                }
            } catch {
                if !Task.isCancelled { self.error = "Download failed: \(error.localizedDescription)" }
            }
            progress = nil
            task = nil
            refresh()
        }
    }

    func cancel() {
        task?.cancel()
    }

    func delete() {
        try? FileManager.default.trashItem(at: Diarizer().repoDir, resultingItemURL: nil)
        refresh()
    }
}

/// The Speakers card under the hood.
struct SpeakerSettings: View {
    @AppStorage(Prefs.Key.separateSpeakers, store: Prefs.defaults) private var separate = true
    @AppStorage(Prefs.Key.separateMicSpeakers, store: Prefs.defaults) private var separateMic = false
    @ObservedObject private var model = SpeakerModel.shared

    var body: some View {
        Card(title: "Speakers",
             subtitle: "Earl tells the voices on the call apart, so the transcript says who said what instead of one big Them.") {
            Toggle("Tell voices apart", isOn: $separate)
            if separate {
                Toggle("Also separate voices on my microphone (people in the room with you)", isOn: $separateMic)
                GuessNamesToggle() // R2-3
                SettingsRule()
                modelRow
                LiveSpeakerModelRow() // R2-5
                if let error = model.error {
                    StatusLabel(kind: .attention, text: error).font(.settingsNote)
                }
            }
            // R3-3: outside the switch above, so stored voices can always be deleted.
            SettingsRule()
            VoiceSettings()
        }
        .onAppear { model.refresh() }
    }

    private var modelRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Diarizer.modelName).font(.settingsRowTitle)
                Text(Diarizer.modelDetail).font(.settingsNote).foregroundStyle(Paper.inkMuted)
                Text(RecordingView.tilde(Diarizer().repoDir)).font(.settingsNote).foregroundStyle(Paper.inkMuted)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if let progress = model.progress {
                ProgressView(value: progress).frame(width: 80)
                Text("\(Int(progress * 100))%").font(.settingsNote.monospacedDigit()).foregroundStyle(Paper.inkMuted)
                Button {
                    model.cancel()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Cancel download")
            } else if let bytes = model.installedBytes {
                StatusLabel(kind: .ok, text: "Downloaded").font(.settingsNote)
                Text(Format.bytes(bytes)).font(.settingsNote.monospacedDigit()).foregroundStyle(Paper.inkMuted)
                Button {
                    model.delete()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Paper.inkMuted)
                .help("Move the speaker model to the Trash")
            } else {
                Button("Download \(Diarizer.approxSize)") { model.download() }
                    .buttonStyle(.paperSecondary)
                    .controlSize(.small)
            }
        }
    }
}
