import CoreML
import FluidAudio
import Foundation
import SwiftUI

// R2-5: live speaker tracking for the recording screen's stage, with
// FluidAudio's streaming Sortformer (option A of the spec). On the T-1
// meetings it put the right face on the talking voice 68–92 % of the time,
// against 26–53 % for rolling WeSpeaker prints (option B), whose 1.5 s
// prints of different voices were nearly as alike as prints of the same one.
// Sortformer tracks at most four voices; a fifth shares a face. The offline
// R2-2 diarization stays the source of truth for the transcript.

// MARK: - Model

extension Prefs {
    /// FluidAudio keeps the streaming model in a folder of its own under this one.
    static let liveSpeakerModelsDir = modelsDir.appendingPathComponent("live-speakers", isDirectory: true)
}

/// The streaming Sortformer model: fast v2.1, palettized (106 MB instead of
/// 230 MB, and the same faces on the T-1 meetings).
enum LiveSpeakerModel {
    static let name = "Streaming Sortformer"
    static let detail = "Tells up to four voices apart as they talk, for the faces on the recording screen"
    static let approxSize = "106 MB"

    static let config: SortformerConfig = {
        var config = SortformerConfig.fastV2_1
        config.precision = .palettized
        return config
    }()

    static var repoDir: URL { Prefs.liveSpeakerModelsDir.appendingPathComponent(Repo.sortformer.folderName, isDirectory: true) }
    static var modelURL: URL { repoDir.appendingPathComponent(ModelNames.Sortformer.bundle(for: config) ?? "") }

    /// Checked before loading: FluidAudio would otherwise download a missing model on its own.
    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: modelURL.appendingPathComponent("coremldata.bin").path)
    }

    static var installedBytes: Int64 {
        let files = FileManager.default.enumerator(at: repoDir, includingPropertiesForKeys: [.fileSizeKey])
        var total: Int64 = 0
        while let url = files?.nextObject() as? URL {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    /// Loads the installed model straight from disk, so nothing is downloaded here.
    static func load() throws -> SortformerModels {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        return try SortformerModels(config: config, main: MLModel(contentsOf: modelURL, configuration: configuration))
    }

    static func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        _ = try await SortformerModels.loadFromHuggingFace(config: config, cacheDirectory: Prefs.liveSpeakerModelsDir) { p in
            progress(p.fractionCompleted)
        }
    }
}

// MARK: - Streaming diarization

/// Speaker activity from a streaming diarizer: one probability per voice slot
/// and frame.
struct LiveFrames {
    /// Seconds of the first finalized frame from the start of the stream.
    var start: Double = 0
    var finalized: [[Float]] = []
    /// The newest frame, finalized or not: who talks right now.
    var latest: [Float]?
}

protocol LiveDiarizing: AnyObject {
    var frameSeconds: Double { get }
    /// Takes 16 kHz audio and returns whatever frames it completed.
    func feed(_ samples: [Float]) throws -> LiveFrames
}

final class SortformerStream: LiveDiarizing {
    private let diarizer: SortformerDiarizer
    let frameSeconds: Double
    private let slots: Int

    init(models: SortformerModels, config: SortformerConfig = LiveSpeakerModel.config) {
        diarizer = SortformerDiarizer(config: config)
        diarizer.initialize(models: models)
        frameSeconds = Double(config.frameDurationSeconds)
        slots = config.numSpeakers
    }

    func feed(_ samples: [Float]) throws -> LiveFrames {
        guard let r = try diarizer.process(samples: samples)?.chunkResult else { return LiveFrames() }
        var frames = LiveFrames(start: Double(r.startFrame) * frameSeconds)
        for f in 0..<r.finalizedFrameCount {
            frames.finalized.append((0..<slots).map { r.probability(speaker: $0, frame: f, numSpeakers: slots) })
        }
        if r.tentativeFrameCount > 0 {
            frames.latest = (0..<slots).map { r.tentativeProbability(speaker: $0, frame: r.tentativeFrameCount - 1, numSpeakers: slots) }
        } else {
            frames.latest = frames.finalized.last
        }
        return frames
    }
}

// MARK: - Faces

struct LiveSegment: Codable, Equatable {
    var start: Double
    var end: Double
}

/// Turns the diarizer's voice slots into faces: a slot gets a face once it
/// has talked 1.5 s, and loses it again if it talked under 3 s in its first
/// 30 s (a cough, a laugh, a bit of echo). Faces keep their number for the
/// whole recording, so each keeps its accessory.
struct LiveFaces {
    struct Config {
        var threshold: Float = 0.5
        var confirmSeconds = 1.5
        var minTalk = 3.0
        var pruneAfter = 30.0
    }

    struct Face: Equatable {
        var slot: Int
        /// The voice's number on the stage (0-based).
        var index: Int
        var talk: Double
        var confirmedAt: Double
        var segments: [LiveSegment]
    }

    var config = Config()
    private(set) var faces: [Face] = []
    private var pending: [Int: (talk: Double, segments: [LiveSegment])] = [:]
    private(set) var activeSlot: Int?
    private var nextIndex = 0

    init(config: Config = Config()) { self.config = config }

    /// The face of the voice talking now, or last.
    var activeFace: Int? { faces.first { $0.slot == activeSlot }?.index }

    /// Adds one finalized frame of slot probabilities.
    mutating func add(_ probabilities: [Float], at start: Double, duration: Double) {
        let end = start + duration
        for (slot, p) in probabilities.enumerated() where p > config.threshold {
            if let i = faces.firstIndex(where: { $0.slot == slot }) {
                faces[i].talk += duration
                Self.extend(&faces[i].segments, start, end)
                continue
            }
            var entry = pending[slot] ?? (0, [])
            entry.talk += duration
            Self.extend(&entry.segments, start, end)
            if entry.talk >= config.confirmSeconds {
                faces.append(Face(slot: slot, index: nextIndex, talk: entry.talk, confirmedAt: end, segments: entry.segments))
                nextIndex += 1
                pending[slot] = nil
            } else {
                pending[slot] = entry
            }
        }
    }

    /// The newest frame: its loudest slot above the threshold holds the floor.
    mutating func setLatest(_ probabilities: [Float]) {
        guard let best = probabilities.indices.max(by: { probabilities[$0] < probabilities[$1] }),
              probabilities[best] > config.threshold else { return }
        activeSlot = best
    }

    /// Drops faces that hardly talked; their slot can earn a new face later.
    mutating func prune(at time: Double) {
        faces.removeAll { time - $0.confirmedAt > config.pruneAfter && $0.talk < config.minTalk }
    }

    private static func extend(_ segments: inout [LiveSegment], _ start: Double, _ end: Double) {
        if let last = segments.last, start - last.end < 0.25 {
            segments[segments.count - 1].end = end
        } else {
            segments.append(LiveSegment(start: start, end: end))
        }
    }
}

// MARK: - Tracker

/// Follows who is talking on the call audio and whether you are talking on
/// the microphone. Not thread-safe: the stage runs it on its own queue, and
/// the evaluation calls it directly.
final class LiveSpeakerTracker {
    /// The streaming model, once loaded. Without it there's one "Them" voice.
    var diarizer: LiveDiarizing? { didSet { modelStart = time } }
    /// Where the model's stream starts on the call audio's clock: it loads
    /// while recording runs.
    private var modelStart: Double = 0
    private(set) var faces: LiveFaces

    private var systemLevels: [Float] = []
    private var micLevels: [Float] = []
    private var systemRemainder: [Float] = []
    private var micRemainder: [Float] = []
    private var systemFloor: Float = -70
    private var micFloor: Float = -70

    /// Seconds of call audio processed.
    private(set) var time: Double = 0
    private var lastSystemSpeech: Double = -10
    private var lastMicSpeech: Double = -10
    private var echoUntil: Double = -10
    private(set) var remoteTalk: Double = 0
    private(set) var meTalk: Double = 0
    /// Time spent in the model, for the log.
    private(set) var modelSeconds: Double = 0
    private(set) var lastError: String?

    private static let historyFrames = 600 // 6 s of 10 ms frames

    init(diarizer: LiveDiarizing? = nil, faces: LiveFaces.Config = .init()) {
        self.diarizer = diarizer
        self.faces = LiveFaces(config: faces)
    }

    /// Whether the call audio has speech now (with a short hangover between words).
    var remoteTalking: Bool { time - lastSystemSpeech < 0.35 }
    /// The mic is mostly hearing the call through the speakers.
    var micIsEcho: Bool { time < echoUntil }
    var meTalking: Bool { time - lastMicSpeech < 0.35 && !micIsEcho }

    /// Feeds new 16 kHz audio from both tracks. Either may be empty.
    func process(system newSystem: [Float], mic newMic: [Float]) {
        if !newSystem.isEmpty {
            systemRemainder += newSystem
            let whole = systemRemainder.count / LiveAudio.frameSamples * LiveAudio.frameSamples
            for db in LiveAudio.frameLevels(systemRemainder[..<whole]) {
                time += LiveAudio.frameSeconds
                systemLevels.append(db)
                if Self.isSpeech(db, floor: &systemFloor, gate: -52) {
                    lastSystemSpeech = time
                    remoteTalk += LiveAudio.frameSeconds
                }
            }
            systemRemainder.removeFirst(whole)
            trim(&systemLevels)
            runModel(newSystem)
        }
        if !newMic.isEmpty {
            micRemainder += newMic
            let whole = micRemainder.count / LiveAudio.frameSamples * LiveAudio.frameSamples
            for db in LiveAudio.frameLevels(micRemainder[..<whole]) {
                micLevels.append(db)
                if Self.isSpeech(db, floor: &micFloor, gate: -50) {
                    lastMicSpeech = time
                    if !micIsEcho { meTalk += LiveAudio.frameSeconds }
                }
            }
            micRemainder.removeFirst(whole)
            trim(&micLevels)
        }
        if EchoCheck.isEcho(mic: micLevels, system: systemLevels) { echoUntil = time + 0.5 }
    }

    private func runModel(_ samples: [Float]) {
        guard let diarizer else { return }
        let started = Date()
        do {
            let frames = try diarizer.feed(samples)
            for (k, p) in frames.finalized.enumerated() {
                faces.add(p, at: modelStart + frames.start + Double(k) * diarizer.frameSeconds,
                          duration: diarizer.frameSeconds)
            }
            if let latest = frames.latest { faces.setLatest(latest) }
            if !frames.finalized.isEmpty { faces.prune(at: time) }
        } catch {
            // Keep recording and fall back to one "Them" face.
            lastError = error.localizedDescription
            self.diarizer = nil
        }
        modelSeconds += Date().timeIntervalSince(started)
    }

    /// Frames well above the noise floor, which follows the quietest recent
    /// frames: down fast, up at 1 dB/s.
    private static func isSpeech(_ db: Float, floor: inout Float, gate: Float) -> Bool {
        floor = db < floor ? max(db, floor - 1) : floor + 0.01
        floor = max(floor, -90)
        return db > max(floor + 10, gate)
    }

    private func trim(_ a: inout [Float]) {
        if a.count > Self.historyFrames + 200 { a.removeFirst(a.count - Self.historyFrames) }
    }

    /// The call-audio faces for the stage: one "Them" until two voices are
    /// told apart, then one per voice.
    func remoteFaces() -> [LiveFace] {
        let all = faces.faces.sorted { $0.index < $1.index }
        let talking = remoteTalking
        guard all.count >= 2 else {
            return [LiveFace(voice: all.first?.index ?? 0, label: "Them", seconds: remoteTalk, isActive: talking)]
        }
        let active = faces.activeFace
        return all.map { f in
            LiveFace(voice: f.index, label: "Speaker \(f.index + 1)", seconds: f.talk, isActive: talking && f.index == active)
        }
    }

    /// The voice getting the call audio's level now: the active face, or the only one.
    var mouthVoice: Int? {
        let all = faces.faces
        if all.count < 2 { return all.first?.index ?? 0 }
        return faces.activeFace
    }

    /// The faces, saved as `live-speakers.json` when recording stops.
    func voices() -> [LiveVoice] {
        faces.faces.sorted { $0.index < $1.index }.map { f in
            LiveVoice(index: f.index, avatar: AvatarLook.accessory(forVoice: f.index).rawValue, seconds: f.talk,
                      segments: f.segments)
        }
    }
}

// MARK: - State for the UI

/// One face on the stage.
struct LiveFace: Identifiable, Equatable {
    /// The voice's number (0-based); picks the accessory. -1 is you.
    var voice: Int
    var label: String
    var seconds: Double
    var isActive: Bool
    var id: Int { voice }
    var isMe: Bool { voice < 0 }
}

/// What the stage reads, published by the tracker's queue.
struct LiveSnapshot: Equatable {
    var faces: [LiveFace] = [LiveFace(voice: 0, label: "Them", seconds: 0, isActive: false)]
    var meSeconds: Double = 0
    var meTalking = false
    /// Your mic is hearing the call, so your face keeps still.
    var micIsEcho = false
    var mouthVoice: Int? = 0
    /// U-4: the latest turns, oldest first, for the chat band.
    var turns: [LiveTurn] = []
    /// U-4: the newest turn's voice is still talking.
    var turnOpen = false
}

/// Runs the tracker on its own queue, fed by the recorder's taps.
final class LiveEngine: @unchecked Sendable {
    let systemTap = LiveTap()
    let micTap = LiveTap()
    /// Called on the engine's queue after each tick.
    var onUpdate: ((LiveSnapshot) -> Void)?

    private let queue = DispatchQueue(label: "earl.live", qos: .utility)
    private var timer: DispatchSourceTimer?
    private let tracker = LiveSpeakerTracker()
    private var history = LiveTurnHistory() // U-4
    private let systemResampler = Resampler()
    private let micResampler = Resampler()
    private let lock = NSLock()
    private var _snapshot = LiveSnapshot()
    private var stopped = false
    private var dropped = 0

    /// Latest state, safe to read from any thread (the stage reads it every frame).
    var snapshot: LiveSnapshot { lock.withLock { _snapshot } }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.1, repeating: 0.1, leeway: .milliseconds(20))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    func setDiarizer(_ diarizer: LiveDiarizing) {
        queue.async { if !self.stopped { self.tracker.diarizer = diarizer } }
    }

    /// Stops and returns the faces found, for `live-speakers.json`.
    func stop() -> [LiveVoice] {
        timer?.cancel()
        timer = nil
        return queue.sync {
            stopped = true
            let voices = tracker.voices()
            tracker.diarizer = nil
            NSLog("Earl: live stage spent %.1f s in the model over %.0f s of call audio; %d samples dropped%@",
                  tracker.modelSeconds, tracker.time, dropped, tracker.lastError.map { "; \($0)" } ?? "")
            return voices
        }
    }

    private func tick() {
        let s = systemTap.drain(), m = micTap.drain()
        dropped += s.dropped + m.dropped
        tracker.process(system: systemResampler.convert(s.samples, rate: s.rate),
                        mic: micResampler.convert(m.samples, rate: m.rate))
        // U-4: the call's voice holds the floor over the mic, which often hears it too.
        let talker: Int? = tracker.remoteTalking ? tracker.mouthVoice : tracker.meTalking ? -1 : nil
        history.update(talker: talker, at: tracker.time)
        let snap = LiveSnapshot(faces: tracker.remoteFaces(), meSeconds: tracker.meTalk, meTalking: tracker.meTalking,
                                micIsEcho: tracker.micIsEcho, mouthVoice: tracker.mouthVoice,
                                turns: history.shown, turnOpen: history.isOpen)
        lock.withLock { _snapshot = snap }
        onUpdate?(snap)
    }
}

/// The stage's state on the main actor. Faces are published at most ten
/// times a second (and only when they change); mouths read `live` directly
/// every frame, like the level meters, so 60 fps never goes through @Published.
@MainActor
final class LiveStage: ObservableObject {
    @Published private(set) var faces: [LiveFace] = LiveSnapshot().faces
    @Published private(set) var meSeconds: Double = 0
    /// "Speaker 2 joined", for a few seconds.
    @Published private(set) var announcement: String?
    /// U-4: the latest turns for the chat band, with ends in whole seconds so
    /// they change about once a second.
    @Published private(set) var turns: [LiveTurn] = []
    /// U-4: the newest turn is still going (its bubble shows typing dots).
    @Published private(set) var turnOpen = false
    private(set) var engine: LiveEngine?
    private var loadTask: Task<Void, Never>?
    private var announcementTask: Task<Void, Never>?

    /// Latest tracker state, for the per-frame mouth animation.
    var live: LiveSnapshot { engine?.snapshot ?? demo ?? LiveSnapshot() }

    /// U-0: a frozen stage for UI snapshots; nil ends it.
    private var demo: LiveSnapshot?

    func showDemo(_ snapshot: LiveSnapshot?) {
        demo = snapshot
        faces = (snapshot ?? LiveSnapshot()).faces.map { f in
            var f = f
            f.isActive = false // as in apply(): the stage reads who talks every frame
            return f
        }
        meSeconds = snapshot?.meSeconds ?? 0
        turns = snapshot?.turns ?? [] // U-4
        turnOpen = snapshot?.turnOpen ?? false
    }

    /// A fresh engine for a new recording; its taps go to the recorder.
    func prepare() -> LiveEngine {
        end()
        let engine = LiveEngine()
        self.engine = engine
        faces = LiveSnapshot().faces
        meSeconds = 0
        announcement = nil
        turns = [] // U-4
        turnOpen = false
        return engine
    }

    /// Starts tracking once capture runs. The model loads off the main actor;
    /// until then, or without it, the call is one "Them" face.
    func start(separate: Bool = Prefs.separateSpeakers) {
        guard let engine else { return }
        engine.onUpdate = { [weak self] snap in
            Task { @MainActor in self?.apply(snap, from: engine) }
        }
        engine.start()
        guard separate, LiveSpeakerModel.isInstalled else { return }
        loadTask = Task.detached(priority: .utility) {
            do {
                let models = try LiveSpeakerModel.load()
                if !Task.isCancelled { engine.setDiarizer(SortformerStream(models: models)) }
            } catch {
                NSLog("Earl: live stage runs without telling voices apart: \(error)")
            }
        }
    }

    /// Stops tracking and saves the faces next to the recording.
    @discardableResult
    func end(saveIn folder: URL? = nil) -> [LiveVoice] {
        loadTask?.cancel()
        loadTask = nil
        guard let engine else { return [] }
        engine.onUpdate = nil
        let voices = engine.stop()
        self.engine = nil
        if let folder { LiveVoice.save(voices, in: folder) }
        return voices
    }

    private func apply(_ snap: LiveSnapshot, from engine: LiveEngine) {
        guard engine === self.engine else { return }
        // Talk time shows whole seconds at most; don't redraw for less.
        let rounded = snap.faces.map { f -> LiveFace in
            var f = f
            f.seconds = f.seconds.rounded()
            f.isActive = false // the stage reads who talks every frame
            return f
        }
        if rounded != faces {
            let before = Set(faces.map(\.voice))
            if rounded.count >= 2, let new = rounded.first(where: { !before.contains($0.voice) }) {
                announce("\(new.label) joined")
            }
            faces = rounded
        }
        if snap.meSeconds.rounded() != meSeconds { meSeconds = snap.meSeconds.rounded() }
        // U-4
        let shown = snap.turns.map { t -> LiveTurn in
            var t = t
            t.end = t.start + t.seconds.rounded()
            return t
        }
        if shown != turns { turns = shown }
        if snap.turnOpen != turnOpen { turnOpen = snap.turnOpen }
    }

    private func announce(_ text: String) {
        announcement = text
        announcementTask?.cancel()
        announcementTask = Task {
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { announcement = nil }
        }
    }
}

// MARK: - Turn history (U-4)

/// One stretch of one voice talking, for the recording screen's chat band.
/// Live shows who talks and for how long, never what is said.
struct LiveTurn: Identifiable, Equatable {
    var id: Int
    /// The voice's number, as on `LiveFace`; -1 is you.
    var voice: Int
    /// Seconds of call audio.
    var start: Double
    var end: Double

    var seconds: Double { end - start }
    var isMe: Bool { voice < 0 }

    /// Dots in the bubble: one per 7 s of talk, at least one, at most twelve.
    static func dots(for seconds: Double) -> Int {
        min(12, max(1, Int((seconds / 7).rounded(.up))))
    }
}

/// The last few turns, fed ten times a second with whoever talks. Pauses of
/// the same voice stay one turn; a blip too short to be a turn (a cough, an
/// "mm") is dropped once someone else talks. Bounded, so a two-hour call keeps
/// only the newest `limit` turns.
struct LiveTurnHistory {
    var limit = 12
    /// A pause shorter than this, by the same voice, doesn't start a new turn.
    var mergeGap = 2.0
    /// Turns shorter than this don't show, and are dropped when someone else talks.
    var minTurn = 0.6

    private(set) var turns: [LiveTurn] = []
    /// The newest turn's voice is talking right now.
    private(set) var isOpen = false
    private var nextID = 0

    /// The turns to draw: a turn still under `minTurn` waits.
    var shown: [LiveTurn] {
        guard let last = turns.last, last.seconds < minTurn else { return turns }
        return Array(turns.dropLast())
    }

    /// `talker` is the voice talking at `time` (-1 for you), or nil for silence.
    mutating func update(talker: Int?, at time: Double) {
        guard let talker else {
            isOpen = false
            return
        }
        isOpen = true
        if extendLast(talker, to: time) { return }
        if let last = turns.last, last.seconds < minTurn {
            turns.removeLast()
            if extendLast(talker, to: time) { return }
        }
        turns.append(LiveTurn(id: nextID, voice: talker, start: time, end: time))
        nextID += 1
        if turns.count > limit { turns.removeFirst(turns.count - limit) }
    }

    private mutating func extendLast(_ talker: Int, to time: Double) -> Bool {
        guard let last = turns.last, last.voice == talker, time - last.end <= mergeGap else { return false }
        turns[turns.count - 1].end = max(last.end, time)
        return true
    }
}

// MARK: - After recording

/// A face from the live stage, saved as `live-speakers.json` so the offline
/// speakers can wear the same accessory.
struct LiveVoice: Codable, Equatable {
    var index: Int
    var avatar: String
    var seconds: Double
    /// When the face talked, in seconds of call audio.
    var segments: [LiveSegment]

    static let file = "live-speakers.json"

    static func save(_ voices: [LiveVoice], in folder: URL) {
        guard !voices.isEmpty else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try? encoder.encode(voices).write(to: folder.appendingPathComponent(file), options: .atomic)
    }

    static func load(in folder: URL) -> [LiveVoice] {
        (try? Data(contentsOf: folder.appendingPathComponent(file)))
            .flatMap { try? JSONDecoder().decode([LiveVoice].self, from: $0) } ?? []
    }

    /// Gives each call-audio speaker the accessory of the live face that
    /// talked over the same stretches of their turns, one face per speaker,
    /// the biggest overlaps first. At least a second of overlap is needed.
    static func assignAvatars(_ speakers: [Speaker], turns: [Turn], from voices: [LiveVoice],
                              minimum: Double = 1) -> [Speaker] {
        var overlap: [String: [Int: Double]] = [:]
        for turn in turns where !turn.isMe {
            guard let id = turn.speakerID else { continue }
            for (j, v) in voices.enumerated() {
                let o = v.segments.reduce(0.0) { $0 + max(0, min($1.end, turn.end) - max($1.start, turn.start)) }
                if o > 0 { overlap[id, default: [:]][j, default: 0] += o }
            }
        }
        let pairs = overlap.flatMap { id, byVoice in byVoice.map { (id: id, voice: $0.key, seconds: $0.value) } }
            .sorted { ($0.seconds, $1.id) > ($1.seconds, $0.id) }
        var out = speakers
        var usedSpeakers = Set<String>(), usedVoices = Set<Int>()
        for p in pairs where p.seconds >= minimum && !usedSpeakers.contains(p.id) && !usedVoices.contains(p.voice) {
            guard let i = out.firstIndex(where: { $0.id == p.id && $0.track == "Them" }) else { continue }
            out[i].avatar = voices[p.voice].avatar
            usedSpeakers.insert(p.id)
            usedVoices.insert(p.voice)
        }
        return out
    }

    /// `speakers` with avatars from the meeting's live faces, if it has any.
    static func withAvatars(_ speakers: [Speaker], turns: [Turn], in folder: URL) -> [Speaker] {
        let voices = load(in: folder)
        return voices.isEmpty ? speakers : assignAvatars(speakers, turns: turns, from: voices)
    }
}

// MARK: - Settings

/// Download state of the streaming model, shown in the Speakers card.
@MainActor
final class LiveSpeakerModelState: ObservableObject {
    static let shared = LiveSpeakerModelState()

    @Published private(set) var installedBytes: Int64?
    @Published private(set) var progress: Double?
    @Published private(set) var error: String?
    private var task: Task<Void, Never>?

    init() { refresh() }

    func refresh() {
        installedBytes = LiveSpeakerModel.isInstalled ? LiveSpeakerModel.installedBytes : nil
    }

    func download() {
        guard task == nil else { return }
        error = nil
        progress = 0
        task = Task {
            do {
                try await LiveSpeakerModel.download { p in
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

    func cancel() { task?.cancel() }

    func delete() {
        try? FileManager.default.trashItem(at: LiveSpeakerModel.repoDir, resultingItemURL: nil)
        refresh()
    }
}

/// The live stage's model, as a row in the Speakers card.
struct LiveSpeakerModelRow: View {
    @ObservedObject private var model = LiveSpeakerModelState.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(LiveSpeakerModel.name).font(.settingsRowTitle)
                    Text(LiveSpeakerModel.detail).font(.settingsNote).foregroundStyle(Paper.inkMuted)
                    Text(RecordingView.tilde(LiveSpeakerModel.repoDir)).font(.settingsNote).foregroundStyle(Paper.inkMuted)
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
                    .help("Move the live speaker model to the Trash")
                } else {
                    Button("Download \(LiveSpeakerModel.approxSize)") { model.download() }
                        .buttonStyle(.paperSecondary)
                        .controlSize(.small)
                }
            }
            if let error = model.error {
                StatusLabel(kind: .attention, text: error).font(.settingsNote)
            }
        }
        .onAppear { model.refresh() }
    }
}
