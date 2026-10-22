import SwiftUI

// R3-3: remembers the voices of people you've named, so Earl can name them
// again in later meetings. Voice prints are biometric data, so this is opt-in,
// stays in one file on this Mac, and every voice can be deleted.

extension Prefs.Key {
    static let rememberVoices = "rememberVoices"
    /// Whether the naming popover has asked once for consent.
    static let voicesConsentAsked = "voicesConsentAsked"
}

extension Prefs {
    static var rememberVoices: Bool {
        // P-1: "Keep only the text" turns voice memory off, whatever was chosen here.
        get { (Prefs.defaults.object(forKey: Key.rememberVoices) as? Bool ?? false) && !textOnly }
        set { Prefs.defaults.set(newValue, forKey: Key.rememberVoices) }
    }
    static var voicesConsentAsked: Bool {
        get { Prefs.defaults.object(forKey: Key.voicesConsentAsked) as? Bool ?? false }
        set { Prefs.defaults.set(newValue, forKey: Key.voicesConsentAsked) }
    }
    static let voicesURL = supportDir.appendingPathComponent("voices.json")
}

/// One remembered person: a few voice prints from meetings where you named them.
struct Voice: Codable, Hashable, Identifiable {
    var id: UUID
    var name: String
    var email: String?
    /// Voice prints (R2-2 embeddings), oldest first.
    var samples: [[Float]]
    /// Where each sample came from, as "meetingID/speakerID", in step with
    /// `samples`: renaming or clearing that speaker takes its sample back.
    var sources: [String]
    /// When the voice was last learned or recognised.
    var updatedAt: Date
    /// Meetings in which you named this person.
    var meetings: Int

    init(id: UUID = UUID(), name: String, email: String? = nil, samples: [[Float]] = [], sources: [String] = [],
         updatedAt: Date = Date(), meetings: Int = 0) {
        self.id = id
        self.name = name
        self.email = email
        self.samples = samples
        self.sources = sources
        self.updatedAt = updatedAt
        self.meetings = meetings
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        email = try c.decodeIfPresent(String.self, forKey: .email)
        samples = try c.decode([[Float]].self, forKey: .samples)
        sources = try c.decodeIfPresent([String].self, forKey: .sources) ?? []
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        meetings = try c.decode(Int.self, forKey: .meetings)
    }
}

/// The voices and the rules for learning and recognising them, on plain values
/// so they can be tested.
struct VoiceLibrary: Equatable {
    var voices: [Voice] = []

    /// Keeps the newest few prints: enough to cover a cold or a bad
    /// microphone, few enough that an old mistake washes out.
    static let maxSamples = 10
    /// Voice prints from less talk time than this are too noisy to learn from.
    static let minLearnSeconds = 20.0
    /// Voices with less talk time than this aren't matched (see `threshold`).
    static let minMatchSeconds = 10.0

    /// Similarity needed to name a voice, on the maximum over a voice's
    /// samples. Calibrated on 12 synthetic meetings (VoiceMemoryEvalTests):
    /// the same `say` voice in a later meeting scored ≥ 0.95, pitch- or
    /// speed-shifted 0.65–0.97; other people ≤ 0.62, except Karen against
    /// Samantha, the pair R2-2 confuses, at up to 0.67. 0.75 named 85 % of
    /// known people (all unshifted ones) and nobody wrongly.
    static let strictThreshold: Float = 0.75
    /// When the voice's name or email is among the meeting's attendees, a
    /// person who is expected anyway needs less: 92 % named, and still above
    /// the Karen/Samantha twin when Sarah is invited but absent (0.65 named
    /// Karen "Sarah" 3 times out of 44).
    static let attendeeThreshold: Float = 0.70

    // MARK: Learning

    /// Adds `embedding` as a sample of `name`, creating the voice if needed.
    /// A sample from the same speaker in the same meeting replaces the old one.
    mutating func learn(_ embedding: [Float], name: String, email: String? = nil, source: String, now: Date = Date()) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !embedding.isEmpty else { return }
        let meeting = Self.meetingID(of: source)
        guard let i = index(named: name) else {
            voices.append(Voice(name: name, email: email, samples: [embedding], sources: [source], updatedAt: now, meetings: 1))
            return
        }
        var v = voices[i]
        if let j = v.sources.firstIndex(of: source) {
            v.samples.remove(at: j)
            v.sources.remove(at: j)
        } else if !v.sources.contains(where: { Self.meetingID(of: $0) == meeting }) {
            v.meetings += 1
        }
        v.samples.append(embedding)
        v.sources.append(source)
        while v.samples.count > Self.maxSamples {
            v.samples.removeFirst()
            v.sources.removeFirst()
        }
        if v.email == nil { v.email = email }
        v.updatedAt = now
        voices[i] = v
    }

    /// Takes back the sample learned from `source` under `name`: the name was
    /// corrected or cleared. A voice left without samples is removed.
    mutating func unlearn(name: String, source: String) {
        guard let i = index(named: name), let j = voices[i].sources.firstIndex(of: source) else { return }
        voices[i].samples.remove(at: j)
        voices[i].sources.remove(at: j)
        let meeting = Self.meetingID(of: source)
        if !voices[i].sources.contains(where: { Self.meetingID(of: $0) == meeting }) {
            voices[i].meetings = max(0, voices[i].meetings - 1)
        }
        if voices[i].samples.isEmpty { voices.remove(at: i) }
    }

    /// Learns from a meeting's speakers after you named some: every confirmed
    /// name with enough talk time, and takes back samples of names that were
    /// changed, cleared or merged away since `before`.
    mutating func update(meetingID: String, before: [Speaker], after: [Speaker], attendees: [Attendee],
                         now: Date = Date()) {
        func confirmed(_ s: Speaker) -> String? {
            guard s.nameSource == .confirmed, let n = s.name, !n.isEmpty else { return nil }
            return n
        }
        for old in before {
            guard let oldName = confirmed(old) else { continue }
            let new = after.first { $0.id == old.id }
            if new.flatMap(confirmed)?.lowercased() != oldName.lowercased() {
                unlearn(name: oldName, source: "\(meetingID)/\(old.id)")
            }
        }
        for s in after where s.track == "Them" && s.seconds >= Self.minLearnSeconds {
            guard let name = confirmed(s) else { continue }
            let old = before.first { $0.id == s.id }
            // Unchanged speakers were learned when they were named (pass no
            // `before` to learn them all, as after consent).
            if let old, old.name == s.name, old.nameSource == .confirmed, old.embedding == s.embedding { continue }
            learn(s.embedding, name: name, email: Self.attendee(named: name, in: attendees)?.email,
                  source: "\(meetingID)/\(s.id)", now: now)
        }
    }

    // MARK: Recognising

    /// How alike `embedding` is to a voice: the best of its samples. On the
    /// calibration set this did as well as the mean of the samples for
    /// strangers and a little better for the hardest match (0.71 vs 0.69), and
    /// one sample from an unusual call can't drag the others down.
    static func similarity(_ embedding: [Float], to voice: Voice) -> Float {
        voice.samples.map { SpeakerEdit.cosine(embedding, $0) }.max() ?? 0
    }

    /// The similarity `voice` needs in a meeting with these attendees.
    static func threshold(for voice: Voice, attendees: [Attendee], strict: Float = strictThreshold,
                          invited: Float = attendeeThreshold) -> Float {
        attendees.contains { !$0.isMe && isSamePerson(voice, $0) } ? invited : strict
    }

    struct Match: Equatable {
        var speakerID: String
        var voiceID: UUID
        var score: Float
    }

    /// Voices for the unnamed call speakers, one to one, most alike first.
    /// Names already in the meeting (carried over from before) aren't given twice.
    func matches(for speakers: [Speaker], attendees: [Attendee], strict: Float = strictThreshold,
                 invited: Float = attendeeThreshold) -> [Match] {
        let taken = Set(speakers.compactMap { $0.name?.lowercased() })
        let candidates = speakers.filter {
            $0.track == "Them" && ($0.name ?? "").isEmpty && !$0.embedding.isEmpty && $0.seconds >= Self.minMatchSeconds
        }
        var pairs: [Match] = []
        for s in candidates {
            for v in voices where !taken.contains(v.name.lowercased()) {
                let score = Self.similarity(s.embedding, to: v)
                if score >= Self.threshold(for: v, attendees: attendees, strict: strict, invited: invited) {
                    pairs.append(Match(speakerID: s.id, voiceID: v.id, score: score))
                }
            }
        }
        return Self.assign(pairs)
    }

    /// Greedy one-to-one: the highest score first; each speaker and each voice is used once.
    static func assign(_ pairs: [Match]) -> [Match] {
        var usedSpeakers = Set<String>(), usedVoices = Set<UUID>(), out: [Match] = []
        for p in pairs.sorted(by: { $0.score > $1.score })
        where !usedSpeakers.contains(p.speakerID) && !usedVoices.contains(p.voiceID) {
            usedSpeakers.insert(p.speakerID)
            usedVoices.insert(p.voiceID)
            out.append(p)
        }
        return out
    }

    /// Names the matched speakers, with `nameSource` "voice" and the number of
    /// meetings behind the voice as evidence.
    func apply(_ matches: [Match], to speakers: [Speaker]) -> [Speaker] {
        matches.reduce(speakers) { speakers, m in
            guard let v = voices.first(where: { $0.id == m.voiceID }) else { return speakers }
            return SpeakerEdit.rename(speakers, id: m.speakerID, to: v.name, source: .voice,
                                      evidence: v.meetings == 1 ? "1 meeting" : "\(v.meetings) meetings")
        }
    }

    // MARK: Helpers

    func index(named name: String) -> Int? {
        let key = name.trimmingCharacters(in: .whitespaces).lowercased()
        return voices.firstIndex { $0.name.lowercased() == key }
    }

    static func meetingID(of source: String) -> String {
        source.split(separator: "/").dropLast().joined(separator: "/")
    }

    /// Same email, the same full name, or a first name that fits ("Sarah" and "Sarah Miller").
    static func isSamePerson(_ voice: Voice, _ attendee: Attendee) -> Bool {
        if let a = voice.email?.lowercased(), let b = attendee.email?.lowercased(), !a.isEmpty, a == b { return true }
        let v = voice.name.lowercased().split(separator: " ").map(String.init)
        let n = attendee.name.lowercased().split(separator: " ").map(String.init)
        guard let vf = v.first, let nf = n.first else { return false }
        if v == n { return true }
        return (v.count == 1 || n.count == 1) && vf == nf
    }

    static func attendee(named name: String, in attendees: [Attendee]) -> Attendee? {
        attendees.first { !$0.isMe && isSamePerson(Voice(name: name), $0) }
    }
}

// MARK: - Storage

/// The voice library on disk, shared by processing, the popover and Settings.
@MainActor
final class VoiceStore: ObservableObject {
    static let shared = VoiceStore(url: Prefs.voicesURL)

    let url: URL
    /// The setting, replaceable in tests so they never touch your real voices.
    let isEnabled: () -> Bool
    @Published private(set) var library: VoiceLibrary

    init(url: URL, isEnabled: @escaping () -> Bool = { Prefs.rememberVoices }) {
        self.url = url
        self.isEnabled = isEnabled
        library = VoiceLibrary(voices: Self.read(url))
    }

    var voices: [Voice] { library.voices }

    nonisolated static func read(_ url: URL) -> [Voice] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? decode(data)) ?? []
    }

    /// D-4: the one place voices.json is decoded (the app and the compatibility tests).
    nonisolated static func decode(_ data: Data) throws -> [Voice] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([Voice].self, from: data)
    }

    /// Writes the file readable by you only, or removes it when no voices are left.
    nonisolated static func write(_ voices: [Voice], to url: URL) throws {
        let fm = FileManager.default
        guard !voices.isEmpty else {
            if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(voices)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Created 0600 from the start, then moved into place, so the prints are never readable by others.
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".voices-\(UUID().uuidString).json")
        guard fm.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard rename(tmp.path, url.path) == 0 else {
            try? fm.removeItem(at: tmp)
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private func change(_ body: (inout VoiceLibrary) -> Void) {
        var lib = library
        body(&lib)
        guard lib != library else { return }
        library = lib
        do {
            try Self.write(lib.voices, to: url)
        } catch {
            NSLog("Earl: couldn't save voices: \(error)")
        }
    }

    /// After you named speakers in a meeting. Does nothing unless you opted in.
    func learn(meetingID: String, before: [Speaker], after: [Speaker], attendees: [Attendee]) {
        guard isEnabled() else { return }
        change { $0.update(meetingID: meetingID, before: before, after: after, attendees: attendees) }
    }

    /// Names the unnamed call voices that sound like someone you've named
    /// before. Returns the speakers and a line for the log.
    func recognise(_ speakers: [Speaker], attendees: [Attendee]) -> (speakers: [Speaker], log: String?) {
        guard isEnabled(), !library.voices.isEmpty else { return (speakers, nil) }
        let matches = library.matches(for: speakers, attendees: attendees)
        guard !matches.isEmpty else { return (speakers, "Recognised by voice: none") }
        let named = library.apply(matches, to: speakers)
        let ids = Set(matches.map(\.voiceID))
        change { lib in
            for i in lib.voices.indices where ids.contains(lib.voices[i].id) { lib.voices[i].updatedAt = Date() }
        }
        let line = matches.map { m in
            "\(m.speakerID) = \(named.first { $0.id == m.speakerID }?.name ?? "?") (\(String(format: "%.2f", m.score)))"
        }.joined(separator: ", ")
        return (named, "Recognised by voice: " + line)
    }

    func delete(_ id: UUID) {
        change { $0.voices.removeAll { $0.id == id } }
    }

    func forgetAll() {
        library = VoiceLibrary()
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - Speakers named by voice

extension Speaker {
    var isRecognised: Bool { nameSource == .voice && !(name ?? "").isEmpty }

    /// "Recognised by voice (Sarah, 3 meetings)".
    var recognisedHelp: String? {
        guard isRecognised, let name else { return nil }
        return "Recognised by voice (\(name)\(evidence.map { ", \($0)" } ?? ""))"
    }

    static func recognisedByVoice(_ turn: Turn, in speakers: [Speaker]) -> Bool {
        speakers.first { $0.id == turn.speakerID }?.isRecognised ?? false
    }
}

extension AppState {
    /// After consent: learns every name already confirmed in this meeting.
    func learnVoices(meetingID: String) {
        guard let meeting = store.load(Prefs.storageURL.appendingPathComponent(meetingID)) else { return }
        VoiceStore.shared.learn(meetingID: meetingID, before: [], after: meeting.speakers,
                                attendees: meeting.info.attendees ?? [])
    }
}

// MARK: - Views

/// The small waveform next to a name Earl recognised by voice.
struct RecognisedMark: View {
    var body: some View {
        Image(systemName: "waveform")
            .font(.paperLabel)
            .foregroundStyle(Paper.inkMuted)
            .accessibilityLabel("Recognised by voice")
    }
}

/// Asked once in the naming popover, after the first name you confirm.
struct VoiceConsentPrompt: View {
    @EnvironmentObject private var state: AppState
    let meetingID: String
    var done: () -> Void

    static var shouldAsk: Bool { !Prefs.voicesConsentAsked && !Prefs.rememberVoices && !Prefs.textOnly }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Remember voices?", systemImage: "waveform").font(.paperTitle)
            Text("Remember voices so Earl can recognise people next time? Voice fingerprints stay on this Mac.")
                .font(.settingsRow)
                .fixedSize(horizontal: false, vertical: true)
            Text("You can see and delete them in Settings, under Speakers.")
                .font(.settingsNote)
                .foregroundStyle(Paper.inkMuted)
            HStack {
                Spacer()
                Button("Not now") {
                    Prefs.voicesConsentAsked = true
                    done()
                }
                .buttonStyle(.paperSecondary)
                Button("Remember voices") {
                    Prefs.voicesConsentAsked = true
                    Prefs.rememberVoices = true
                    state.learnVoices(meetingID: meetingID)
                    done()
                }
                .buttonStyle(.paperPrimary)
            }
        }
    }
}

/// The R3-3 part of the Speakers card: the switch and the voices kept.
struct VoiceSettings: View {
    @AppStorage(Prefs.Key.rememberVoices, store: Prefs.defaults) private var remember = false
    @AppStorage(Prefs.Key.textOnly, store: Prefs.defaults) private var textOnly = false // P-1
    @ObservedObject private var store = VoiceStore.shared
    @State private var offerForget = false
    @State private var confirmForgetAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Remember voices across meetings", isOn: textOnly ? .constant(false) : $remember)
                .disabled(textOnly)
                .help(textOnly ? "Off while “Keep only the text” is on, under Privacy."
                               : "Voices you name are recognised in later meetings. Voice fingerprints stay on this Mac.")
                .onChange(of: remember) { _, on in
                    Prefs.voicesConsentAsked = true
                    if !on, !store.voices.isEmpty { offerForget = true }
                }
            if (remember && !textOnly) || !store.voices.isEmpty {
                if store.voices.isEmpty {
                    Text("No voices yet. Name someone in a meeting and Earl will know them next time.")
                        .font(.settingsNote)
                        .foregroundStyle(Paper.inkMuted)
                } else {
                    VStack(spacing: 0) {
                        ForEach(store.voices.sorted { $0.updatedAt > $1.updatedAt }) { voice in
                            row(voice)
                        }
                    }
                    HStack {
                        Text("Voice fingerprints stay on this Mac.")
                            .font(.settingsNote)
                            .foregroundStyle(Paper.inkMuted)
                        Spacer()
                        Button("Forget all voices") { confirmForgetAll = true }
                            .buttonStyle(.paperSecondary)
                            .controlSize(.small)
                    }
                }
            }
        }
        .alert("Forget the stored voices too?", isPresented: $offerForget) {
            Button("Forget voices", role: .destructive) { store.forgetAll() }
            Button("Keep them", role: .cancel) {}
        } message: {
            Text("Earl won't use them while this is off. Kept, \(count) stay on this Mac until you forget them.")
        }
        .alert("Forget all voices?", isPresented: $confirmForgetAll) {
            Button("Forget all", role: .destructive) { store.forgetAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(count) will be deleted from this Mac. Names already in your meetings stay.")
        }
    }

    private var count: String {
        store.voices.count == 1 ? "1 voice" : "\(store.voices.count) voices"
    }

    private func row(_ voice: Voice) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform").foregroundStyle(Paper.inkMuted)
            VStack(alignment: .leading, spacing: 2) {
                Text(voice.name).font(.settingsRowTitle)
                Text(Self.detail(voice)).font(.settingsNote).foregroundStyle(Paper.inkMuted)
            }
            Spacer()
            Button {
                store.delete(voice.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Paper.inkMuted)
            .help("Forget \(voice.name)'s voice")
        }
        .padding(.vertical, 6)
    }

    /// "3 samples · 2 meetings · last heard yesterday".
    static func detail(_ voice: Voice, now: Date = Date()) -> String {
        let samples = voice.samples.count == 1 ? "1 sample" : "\(voice.samples.count) samples"
        let meetings = voice.meetings == 1 ? "1 meeting" : "\(voice.meetings) meetings"
        let heard = voice.updatedAt.formatted(.relative(presentation: .named, unitsStyle: .wide))
        return "\(samples) · \(meetings) · last heard \(heard)"
    }
}
