import Foundation

enum MeetingStatus: String, Codable {
    case recording, transcribing, summarizing, done, failed
}

struct MeetingInfo: Codable, Hashable {
    var title: String
    /// True until the user renames the meeting or the summarizer suggests a title.
    var titleIsDefault: Bool
    var startedAt: Date
    var duration: TimeInterval
    var status: MeetingStatus
    var error: String?

    // How the meeting was processed, shown in the Details tab.
    var language: String?
    var microphone: String?
    var transcriptionModel: String?
    var transcriptionSeconds: Double?
    var summaryModel: String?
    var summarySeconds: Double?
    var summaryTokensPerSecond: Double?

    // R1-3 vocabulary: the terms Whisper was prompted with.
    var vocabularyTerms: [String]?
    // R1-2 call detection: the call app in use when the recording started.
    var callApp: String?
    var callAppBundleID: String?
    // calendar (R2-1): the linked event, as it was when linked.
    var calendarEventID: String?
    var calendarTitle: String?
    var organizer: String?
    var attendees: [Attendee]?
    var meetingURL: String?
    var calendarStart: Date?
    var calendarEnd: Date?
    // speakers (R2-2): voice separation on the call audio.
    var speakerModel: String?
    var speakerCount: Int?
    var diarizationSeconds: Double?
    /// Why voices weren't separated, when they should have been.
    var speakerNote: String?
    // speaker names (R2-3): a speaker was named or merged after the summary was written.
    var namesChangedSinceSummary: Bool?
    // echo (R2-4): what played the call, and how much echo left the mic track.
    var outputDevice: String?
    /// nil when the device didn't tell.
    var usedSpeakers: Bool?
    /// 0 when the gate ran and found no echo; nil when it didn't run.
    var echoRemovedSeconds: Double?
    // reliable notes (R2-7): the context the summary model ran with, and
    // whether Earl loaded it with that context.
    var summaryContext: Int?
    var summaryContextByEarl: Bool?
    // U-2: the front page's headline, from the notes ("HEADLINE:"). nil on
    // older meetings, which show their title instead.
    var headline: String?
    // W-1: you said "Not now" to Earl's who's-who question on this meeting.
    var whosWhoDismissed: Bool?
    // K-1: the shape the notes were written in (`MeetingKind`), and whether
    // you chose it (then the series' next meetings follow it).
    var notesKind: String?
    var notesKindByUser: Bool?
}

/// One speaker turn in the transcript. Times are seconds from the start of the recording.
struct Turn: Codable, Hashable, Identifiable {
    var start: Double
    var end: Double
    var speaker: String
    var text: String
    /// R2-2: the voice, e.g. "S1" (see speakers.json). nil when not separated.
    var speakerID: String?

    var id: String { "\(speaker)-\(start)" }
    var isMe: Bool { speaker == "Me" }
}

struct MeetingFile: Hashable, Identifiable {
    let name: String
    let bytes: Int64
    var id: String { name }

    var isAudio: Bool { name.hasSuffix(".wav") }

    var description: String {
        switch name {
        case "system.wav", "system-16k.wav": return "Audio of the other participants"
        case "mic.wav", "mic-16k.wav": return "Audio from your microphone"
        case "transcript.md": return "Summary and transcript, readable anywhere"
        case "summary.md": return "Summary"
        case "transcript.json": return "Transcript used by Earl"
        case "meeting.json": return "Title, times and models"
        case "whisper.log": return "Transcription log"
        case "whisper-system.json", "whisper-mic.json": return "Raw Whisper output"
        case "speakers.json": return "Voices found in the meeting"
        case "todos-done.json": return "Ticked to-dos, kept when summarizing again" // R3-2
        case "reminders.json": return "To-dos sent to Reminders" // R3-2
        case "questions.json": return "Questions you asked Earl" // S-3
        default: return ""
        }
    }
}

struct Meeting: Identifiable, Hashable {
    let id: String
    let folder: URL
    var info: MeetingInfo
    var turns: [Turn]
    var summary: String
    var files: [MeetingFile]
    var speakers: [Speaker] = [] // R2-2
    /// D-4: meeting.json didn't decode (made by a newer Earl?). In memory only: Earl
    /// shows it as damaged and never writes to its folder.
    var isUnreadable = false

    var hasAudio: Bool { files.contains(where: \.isAudio) }
    var totalBytes: Int64 { files.reduce(0) { $0 + $1.bytes } }
    var audioBytes: Int64 { files.filter(\.isAudio).reduce(0) { $0 + $1.bytes } }
    var durationText: String { Format.duration(info.duration) }

    /// Transcript as plain text, used as input for the summarizer.
    var transcriptText: String {
        turns.map { "[\(Self.timestamp($0.start))] \(displayName(for: $0)): \($0.text)" }.joined(separator: "\n")
    }

    var markdown: String {
        var out = "# \(info.title)\n\n_\(info.startedAt.formatted(date: .long, time: .shortened)) · \(durationText)_\n\n"
        if !summary.isEmpty { out += summary + "\n\n" }
        if !turns.isEmpty {
            out += "## Transcript\n\n"
            out += turns.map { "**[\(Self.timestamp($0.start))] \(displayName(for: $0)):** \($0.text)" }.joined(separator: "\n\n")
            out += "\n"
        }
        return out
    }

    func matches(_ query: String) -> Bool {
        // Accents fold both ways: "prufung" (Ask's search words) finds "Prüfung".
        func has(_ s: String) -> Bool { s.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        return has(info.title) || has(summary) || turns.contains { has($0.text) }
            || speakers.contains { $0.name.map(has) ?? false } // R2-2
    }

    static func timestamp(_ seconds: Double) -> String {
        let s = Int(seconds)
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%02d:%02d", s / 60, s % 60)
    }
}

/// Meetings live on disk as plain folders: `<root>/<yyyy-MM-dd_HHmmss>/` containing
/// meeting.json, transcript.json, transcript.md, summary.md and the audio files.
struct MeetingStore {
    let root: URL

    static let audioFiles = ["system.wav", "mic.wav", "system-16k.wav", "mic-16k.wav"]

    private static let folderFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        return f
    }()

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    func loadAll() -> [Meeting] {
        let dirs = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return dirs.compactMap(load).sorted { $0.info.startedAt > $1.info.startedAt }
    }

    func load(_ folder: URL) -> Meeting? { Self.load(folder: folder) }

    static let unreadableMessage = "Earl couldn't read this meeting (made by a newer version?)."

    /// D-4: reads one meeting folder. Used by the app and by the compatibility tests.
    /// A folder with a meeting.json that doesn't decode comes back as a damaged
    /// meeting (status .failed) so it stays visible; only a folder without one is nil.
    static func load(folder: URL) -> Meeting? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("meeting.json")) else { return nil }
        let info: MeetingInfo
        do {
            info = try decoder.decode(MeetingInfo.self, from: data)
        } catch {
            NSLog("Earl: meeting.json in %@ didn't decode: %@", folder.lastPathComponent, String(describing: error))
            let started = (try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            let damaged = MeetingInfo(title: folder.lastPathComponent, titleIsDefault: true, startedAt: started,
                                      duration: 0, status: .failed, error: unreadableMessage)
            return Meeting(id: folder.lastPathComponent, folder: folder, info: damaged, turns: [], summary: "",
                           files: files(in: folder), speakers: [], isUnreadable: true)
        }
        let turns = (try? Data(contentsOf: folder.appendingPathComponent("transcript.json")))
            .flatMap { try? decoder.decode([Turn].self, from: $0) } ?? []
        let summary = (try? String(contentsOf: folder.appendingPathComponent("summary.md"), encoding: .utf8)) ?? ""
        return Meeting(id: folder.lastPathComponent, folder: folder, info: info, turns: turns,
                       summary: summary, files: files(in: folder), speakers: readSpeakers(in: folder))
    }

    private static func files(in folder: URL) -> [MeetingFile] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])) ?? []
        return urls.map { url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return MeetingFile(name: url.lastPathComponent, bytes: Int64(size))
        }
        .sorted { $0.bytes > $1.bytes }
    }

    func create(startedAt: Date, microphone: String?) throws -> Meeting {
        let folder = root.appendingPathComponent(Self.folderFormatter.string(from: startedAt), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var info = MeetingInfo(
            title: "Meeting \(startedAt.formatted(date: .abbreviated, time: .shortened))",
            titleIsDefault: true, startedAt: startedAt, duration: 0, status: .recording, error: nil)
        info.microphone = microphone
        try save(info, in: folder)
        return Meeting(id: folder.lastPathComponent, folder: folder, info: info, turns: [], summary: "", files: [])
    }

    struct UnreadableFolder: Error {}

    /// D-4: false when the folder holds a meeting.json that doesn't decode: a newer
    /// Earl wrote it, and nothing here may overwrite it. True when it's missing or valid.
    static func canWrite(folder: URL) -> Bool {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("meeting.json")) else { return true }
        return (try? decoder.decode(MeetingInfo.self, from: data)) != nil
    }

    private func guardWrite(_ folder: URL) throws {
        guard Self.canWrite(folder: folder) else { throw UnreadableFolder() }
    }

    func save(_ info: MeetingInfo, in folder: URL) throws {
        try guardWrite(folder)
        try Self.encoder.encode(info).write(to: folder.appendingPathComponent("meeting.json"), options: .atomic)
    }

    func saveTranscript(_ turns: [Turn], in folder: URL) throws {
        try guardWrite(folder)
        try Self.encoder.encode(turns).write(to: folder.appendingPathComponent("transcript.json"), options: .atomic)
    }

    func saveSummary(_ summary: String, in folder: URL) throws {
        try guardWrite(folder)
        try summary.write(to: folder.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
    }

    /// Writes transcript.md, a readable copy of the whole meeting for use outside the app.
    func saveMarkdown(_ meeting: Meeting) {
        guard !meeting.isUnreadable, Self.canWrite(folder: meeting.folder) else { return }
        try? meeting.markdown.write(
            to: meeting.folder.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
    }

    func deleteAudio(in folder: URL) {
        guard Self.canWrite(folder: folder) else { return }
        for name in Self.audioFiles {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }
}
