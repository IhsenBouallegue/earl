import Foundation

// S-3: Ask Earl. Questions about a meeting, a series or everything, answered
// by the local notes model from the records on disk, with cited moments.
// Retrieval is plain BM25 over transcript windows (no embeddings): the
// library is small, the words people search for are the words they said,
// and nothing needs downloading.

/// What a question is about.
enum AskScope: Codable, Hashable {
    case meeting(String)
    /// A series key (MeetingSeries.key).
    case series(String)
    case all
}

/// A moment an answer rests on.
struct Citation: Codable, Hashable {
    var meetingID: String
    var seconds: Double
    /// "Tue 9:41": the meeting's day and the clock time of the moment.
    var label: String
}

struct EarlAnswer: Codable, Hashable, Identifiable {
    var id = UUID()
    var question: String
    var scope: AskScope
    /// Markdown, with valid citations left in as `[[<meetingID>@<mm:ss>]]`.
    var text: String
    var citations: [Citation]
    var date: Date
    /// The records didn't say (Earl leads with "The notes don't say.").
    var notFound: Bool?
}

// MARK: - Words

enum AskText {
    /// Lowercased, accents folded, split on anything that isn't a letter or digit.
    static func words(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    /// The words that count for search: no stopwords, lightly stemmed.
    static func terms(_ text: String) -> [String] {
        words(text).filter { $0.count > 1 && !stopwords.contains($0) }.map(stem)
    }

    /// Strips one common German or English ending, keeping at least three letters,
    /// so "patching" meets "patch" and "Wartungsfenster" meets "Wartungsfensters".
    static func stem(_ word: String) -> String {
        for ending in endings where word.hasSuffix(ending) && word.count - ending.count >= 3 {
            return String(word.dropLast(ending.count))
        }
        return word
    }

    private static let endings = ["ing", "ed", "en", "er", "es", "e", "s"]

    static let stopwords: Set<String> = [
        // English
        "a", "about", "after", "again", "all", "also", "am", "an", "and", "any", "are", "as", "at", "be", "because",
        "been", "before", "but", "by", "can", "could", "did", "do", "does", "for", "from", "had", "has", "have", "he",
        "her", "him", "his", "how", "i", "if", "in", "into", "is", "it", "its", "just", "me", "my", "no", "not", "of",
        "on", "or", "our", "out", "she", "so", "some", "than", "that", "the", "their", "them", "then", "there", "they",
        "this", "to", "too", "up", "us", "was", "we", "were", "what", "when", "where", "which", "who", "why", "will",
        "with", "would", "you", "your", "yes", "okay", "ok", "yeah", "right", "think", "say", "said", "tell", "told",
        // German (folded: ä→a, ö→o, ü→u)
        "aber", "als", "also", "am", "an", "auch", "auf", "aus", "bei", "bin", "bis", "da", "das", "dass", "dem", "den",
        "der", "des", "die", "doch", "du", "ein", "eine", "einem", "einen", "einer", "es", "fur", "gibt", "hab", "habe",
        "haben", "hat", "hatte", "ich", "ihr", "im", "ist", "ja", "jetzt", "kann", "mal", "man", "mit", "nach", "nicht",
        "noch", "nur", "oder", "schon", "sehr", "sich", "sie", "sind", "so", "uber", "um", "und", "uns", "von", "vor",
        "war", "was", "wenn", "wer", "wie", "wir", "wird", "wo", "zu", "zum", "zur", "genau", "gesagt", "sagt",
        "wann", "warum", "welche", "welcher", "eigentlich", "halt", "dann", "denn", "gut",
    ]
}

// MARK: - Chunks

/// A window of a transcript: about 8 turns or 1,200 characters, overlapping
/// the next by 2 turns so an answer that straddles a border is found whole.
struct AskChunk: Hashable {
    var meetingID: String
    /// Seconds from the start of the recording, of the first turn.
    var start: Double
    /// Display names, so a renamed speaker is found by name.
    var speakers: [String]
    /// "[mm:ss] Name: text" lines, as the model sees them.
    var text: String
    var terms: [String]

    static let maxTurns = 8
    static let maxChars = 1200
    static let overlap = 2

    static func chunks(of meeting: Meeting) -> [AskChunk] {
        let turns = meeting.turns.sorted { $0.start < $1.start }
        var out: [AskChunk] = []
        var i = 0
        while i < turns.count {
            var end = i
            var chars = 0
            var lines: [String] = []
            var names: [String] = []
            while end < turns.count && lines.count < maxTurns {
                let name = meeting.displayName(for: turns[end])
                let line = "[\(Meeting.timestamp(turns[end].start))] \(name): \(turns[end].text)"
                if !lines.isEmpty && chars + line.count > maxChars { break }
                lines.append(line)
                if !names.contains(name) { names.append(name) }
                chars += line.count + 1
                end += 1
            }
            let text = lines.joined(separator: "\n")
            out.append(AskChunk(meetingID: meeting.id, start: turns[i].start, speakers: names, text: text,
                                terms: AskText.terms(text)))
            if end >= turns.count { break }
            i = max(i + 1, end - overlap)
        }
        return out
    }
}

/// Chunks per meeting, built when first asked and kept until the transcript
/// or the speaker names change on disk.
final class AskIndex: @unchecked Sendable {
    static let shared = AskIndex()

    private let lock = NSLock()
    private var cache: [String: (signature: String, chunks: [AskChunk])] = [:]

    func chunks(of meeting: Meeting) -> [AskChunk] {
        let signature = Self.signature(meeting)
        lock.lock()
        if let hit = cache[meeting.id], hit.signature == signature {
            lock.unlock()
            return hit.chunks
        }
        lock.unlock()
        let chunks = AskChunk.chunks(of: meeting)
        lock.lock()
        cache[meeting.id] = (signature, chunks)
        lock.unlock()
        return chunks
    }

    /// The modification times of the transcript and the speakers (names
    /// change the chunks too); in memory only, the turns themselves.
    static func signature(_ meeting: Meeting) -> String {
        let times = ["transcript.json", "speakers.json"].map { name -> String in
            let path = meeting.folder.appendingPathComponent(name).path
            let date = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
            return date.map { String($0.timeIntervalSince1970) } ?? "-"
        }
        if times.allSatisfy({ $0 == "-" }) {
            var hasher = Hasher()
            hasher.combine(meeting.turns)
            hasher.combine(meeting.speakers.map(\.name))
            return "mem:\(hasher.finalize())"
        }
        return times.joined(separator: "|") + "|\(meeting.turns.count)"
    }
}

// MARK: - Ranking

enum AskRank {
    static let k1 = 1.2
    static let b = 0.75
    /// Added when the question names one of the chunk's speakers.
    static let speakerBonus = 1.5

    struct Scored {
        var chunk: AskChunk
        var score: Double
    }

    /// BM25 over `chunks`, best first; ties keep the order of the meeting.
    static func rank(_ question: String, chunks: [AskChunk]) -> [Scored] {
        let query = Array(Set(AskText.terms(question)))
        let asked = Set(AskText.words(question))
        let n = Double(chunks.count)
        let avg = max(1, chunks.reduce(0) { $0 + Double($1.terms.count) } / max(1, n))
        var df: [String: Int] = [:]
        for chunk in chunks {
            for term in Set(chunk.terms) where query.contains(term) { df[term, default: 0] += 1 }
        }
        let scored = chunks.enumerated().map { index, chunk -> (Int, Scored) in
            var tf: [String: Int] = [:]
            for term in chunk.terms { tf[term, default: 0] += 1 }
            let length = Double(chunk.terms.count)
            var score = 0.0
            for term in query {
                guard let f = tf[term], let d = df[term] else { continue }
                let idf = log(1 + (n - Double(d) + 0.5) / (Double(d) + 0.5))
                let ff = Double(f)
                score += idf * ff * (k1 + 1) / (ff + k1 * (1 - b + b * length / avg))
            }
            if chunk.speakers.contains(where: { names(of: $0).contains(where: asked.contains) }) {
                score += speakerBonus
            }
            return (index, Scored(chunk: chunk, score: score))
        }
        return scored.sorted { $0.1.score != $1.1.score ? $0.1.score > $1.1.score : $0.0 < $1.0 }.map(\.1)
    }

    /// The words of a display name that can stand for the person, "Speaker 2" and "Me" excluded.
    private static func names(of speaker: String) -> [String] {
        guard speaker != "Me", speaker != "Them", !speaker.hasPrefix("Speaker ") else { return [] }
        return AskText.words(speaker).filter { $0.count > 2 }
    }
}

// MARK: - Context

/// What the model is given for one question.
struct AskRequest {
    var system: String
    var user: String
    /// The records, without the instructions (for the context size).
    var material: String
    /// The meetings citations may point to, with their length in seconds.
    var meetings: [String: Double]
    /// Some transcript or notes matched the question.
    var foundAnything: Bool
}

enum AskContext {
    /// Characters of records per question: ~5k tokens, well inside the 16k
    /// context Earl loads at least (LMStudioModels.minContext).
    static let budget = 16_000
    /// At most this many lines in the "all meetings" list.
    static let listLimit = 60

    /// Asked to answer "from the records and nothing else" with a citation
    /// per sentence, qwen3.8-27b refused summaries, ticket notes and recaps
    /// ("no single line answers this"): work done *with* the meeting is
    /// always answerable when there's a record, and citations are a help, not
    /// a condition.
    static let system = """
        You are Earl, a discreet butler who sat in on the user's meetings and kept the records below. Do what \
        the user asks with these records: answer questions, summarise, write recaps, emails, ticket notes or \
        lists, say what someone said or wants, compare meetings. Answer in the language of the question. In \
        transcripts, "Me" is the user: call them "you". For a question, be brief: a few sentences or short \
        bullets. For something to write, write it in full, ready to paste, at the length the task needs. \
        Stick to what the records say; never invent facts, names or numbers. \
        Where a sentence rests on a transcript line, you may cite that moment right after it as \
        [[<meeting id>@<mm:ss>]], copying the id and time from the line exactly; never cite a moment that isn't \
        in the records. A summary or a draft needs no citation on every line. \
        Only when the user asks for a fact the records don't contain, start your reply with [[none]] and say so \
        in one sentence; a summary, recap or draft of a meeting that has records is never [[none]]. \
        Use Markdown only for bullets, bold and short headings.
        """

    /// A recap or a draft wants the whole meeting, not the best-matching lines:
    /// ~12k tokens, inside the 32k context the notes model usually runs with.
    static let taskBudget = 36_000

    static func request(question: String, scope: AskScope, meetings: [Meeting], now: Date = Date(),
                        budget: Int? = nil, index: AskIndex = .shared) -> AskRequest {
        let budget = budget ?? (AskIntent.isTask(question) ? taskBudget : Self.budget)
        let usable = meetings.filter(\.hasContent)
        var parts: [String] = []
        var cited: [Meeting] = []
        var found = false
        let scopeLine: String

        switch scope {
        case .meeting(let id):
            let meeting = meetings.first { $0.id == id }
            scopeLine = "The question is about one meeting."
            if let meeting {
                cited = [meeting]
                let notes = notesBlock(meeting, limit: budget / 2)
                let whole = transcriptBlock(meeting, text: meeting.turns.map(line(in: meeting)).joined(separator: "\n"))
                if notes.count + whole.count <= budget {
                    parts = [notes, whole].filter { !$0.isEmpty }
                    found = !meeting.turns.isEmpty || !meeting.summary.isEmpty
                } else {
                    parts = notes.isEmpty ? [] : [notes]
                    let (blocks, any) = topChunks(question, in: [meeting], room: budget - notes.count, index: index)
                    parts += blocks
                    found = any || !notes.isEmpty
                }
            }
        case .series(let key):
            let members = usable.filter { MeetingSeries.key(for: $0) == key }
                .sorted { $0.info.startedAt > $1.info.startedAt }
            cited = members
            scopeLine = "The question is about a meeting series: \(MeetingSeries.displayName(members))."
            // Notes take at most half; the rest goes to the best moments.
            let each = members.isEmpty ? 0 : max(500, budget / 2 / members.count)
            var notesUsed = 0
            for m in members {
                let block = notesBlock(m, limit: each)
                guard !block.isEmpty, notesUsed + block.count <= budget / 2 else { continue }
                parts.append(block)
                notesUsed += block.count
            }
            let (blocks, any) = topChunks(question, in: members, room: budget - notesUsed, index: index)
            parts += blocks
            found = any || notesUsed > 0
        case .all:
            cited = usable
            scopeLine = "The question is about all of the user's meetings."
            let list = usable.sorted { $0.info.startedAt > $1.info.startedAt }.prefix(listLimit).map { m in
                "- \(m.id) · \(day(m.info.startedAt)) · \(headline(m))"
            }
            let listBlock = list.isEmpty ? "" : "All meetings, newest first:\n" + list.joined(separator: "\n")
            if !listBlock.isEmpty { parts.append(listBlock) }
            let (blocks, any) = topChunks(question, in: usable, room: budget - listBlock.count, index: index)
            parts += blocks
            found = any
        }

        let material = parts.joined(separator: "\n\n")
        let user = """
            Today is \(day(now)).
            \(scopeLine)

            \(material.isEmpty ? "(There are no records.)" : material)

            Question: \(question)
            """
        var limits: [String: Double] = [:]
        for m in cited {
            limits[m.id] = max(m.info.duration, m.turns.map(\.end).max() ?? 0)
        }
        return AskRequest(system: system, user: user, material: material, meetings: limits, foundAnything: found)
    }

    // MARK: Blocks

    static func headline(_ m: Meeting) -> String {
        let title = m.info.titleIsDefault ? "Call" : m.info.title
        if let h = m.info.headline, h != title { return "\(title): \(h)" }
        return title
    }

    private static func header(_ m: Meeting) -> String {
        "Meeting \(m.id) · \(day(m.info.startedAt)) · \(headline(m))"
    }

    static func notesBlock(_ m: Meeting, limit: Int) -> String {
        let notes = m.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !notes.isEmpty else { return "" }
        let head = header(m) + " · notes:\n"
        return head + trimmed(notes, to: max(200, limit - head.count))
    }

    private static func transcriptBlock(_ m: Meeting, text: String) -> String {
        text.isEmpty ? "" : header(m) + " · transcript:\n" + text
    }

    private static func line(in m: Meeting) -> (Turn) -> String {
        { "[\(Meeting.timestamp($0.start))] \(m.displayName(for: $0)): \($0.text)" }
    }

    /// The best chunks across `meetings` that fit in `room`, grouped by
    /// meeting (newest first) and in time order within it. Without any match
    /// (a recap, say), the earliest chunks fill the room.
    static func topChunks(_ question: String, in meetings: [Meeting], room: Int,
                          index: AskIndex) -> (blocks: [String], found: Bool) {
        let all = meetings.flatMap { index.chunks(of: $0) }
        let ranked = AskRank.rank(question, chunks: all)
        let found = ranked.first.map { $0.score > 0 } ?? false
        // A recap or a draft: the matching moments first, then the rest of the room.
        let fill = AskIntent.isTask(question)
        var used = 0
        var picked: [AskChunk] = []
        for s in ranked where (found && !fill) ? s.score > 0 : true {
            let cost = s.chunk.text.count + 120
            guard used + cost <= room else { continue }
            picked.append(s.chunk)
            used += cost
        }
        let byMeeting = Dictionary(grouping: picked, by: \.meetingID)
        let blocks = meetings.sorted { $0.info.startedAt > $1.info.startedAt }.compactMap { m -> String? in
            guard let chunks = byMeeting[m.id]?.sorted(by: { $0.start < $1.start }) else { return nil }
            return header(m) + " · from the transcript:\n" + mergedLines(chunks)
        }
        return (blocks, found)
    }

    /// The chunks' lines without the overlap repeated, "…" between gaps.
    private static func mergedLines(_ chunks: [AskChunk]) -> String {
        var seen = Set<String>()
        var out: [String] = []
        for (i, chunk) in chunks.enumerated() {
            let lines = chunk.text.components(separatedBy: "\n")
            if i > 0, let first = lines.first, !seen.contains(first) { out.append("…") }
            for line in lines where seen.insert(line).inserted { out.append(line) }
        }
        return out.joined(separator: "\n")
    }

    static func trimmed(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        let cut = text.prefix(limit)
        let end = cut.lastIndex(of: "\n") ?? cut.endIndex
        return String(cut[..<end]) + "\n…"
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEEE, d MMMM yyyy, HH:mm"
        return f
    }()

    static func day(_ date: Date) -> String { dayFormatter.string(from: date) }
}

// MARK: - Questions or tasks

enum AskIntent {
    /// Words of a request to write or sum up, English and German, stemmed
    /// by prefix.
    static let taskWords = ["summar", "recap", "overview", "draft", "write", "email", "mail", "ticket", "learn",
                            "list", "explain", "translate", "compare", "minutes", "brief", "notes for",
                            "zusammenfass", "überblick", "ueberblick", "entwurf", "schreib", "formulier", "gelernt",
                            "erklär", "erklaer", "übersetz", "uebersetz", "vergleich", "protokoll", "liste", "fasse",
                            "wichtigst", "fazit", "kurzfassung"]

    static func isTask(_ question: String) -> Bool {
        let words = question.lowercased().split { !$0.isLetter }.map(String.init)
        return words.contains { w in taskWords.contains { w.hasPrefix($0) } }
            || taskWords.contains { $0.contains(" ") && question.lowercased().contains($0) }
    }
}

// MARK: - Citations

enum AskCitations {
    /// `[[2026-10-07_093000@14:10]]`, also `@1:02:05`, `[[@14:10]]` and `[[none]]`.
    static let pattern = #/\[\[\s*([^\]@\s]*)\s*@\s*(\d{1,2}(?::\d{2}){1,2})\s*\]\]/#

    /// "14:10" → 850, "1:02:05" → 3725.
    static func seconds(_ stamp: String) -> Double? {
        let parts = stamp.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 || parts.count == 3 else { return nil }
        return Double(parts.reduce(0) { $0 * 60 + $1 })
    }

    struct Parsed {
        var text: String
        var citations: [Citation]
        var notFound: Bool
    }

    /// Keeps citations to a meeting in `limits` within its length (an empty
    /// ID means `current`), drops the rest from the text, and notes `[[none]]`.
    /// A half-written marker at the end (while streaming) is hidden.
    static func parse(_ raw: String, limits: [String: Double], current: String?,
                      label: (String, Double) -> String) -> Parsed {
        var text = raw
        var notFound = false
        if let none = text.range(of: "[[none]]", options: .caseInsensitive) {
            notFound = true
            text.removeSubrange(none)
        }
        if let open = text.range(of: "[[", options: .backwards), text.range(of: "]]", range: open.upperBound..<text.endIndex) == nil {
            text = String(text[..<open.lowerBound])
        }
        var citations: [Citation] = []
        var out = ""
        var rest = Substring(text)
        while let m = rest.firstMatch(of: pattern) {
            out += rest[..<m.range.lowerBound]
            let id = m.1.isEmpty ? (current ?? "") : String(m.1)
            if let s = seconds(String(m.2)), let limit = limits[id], s <= limit + 5 {
                let c = Citation(meetingID: id, seconds: s, label: label(id, s))
                out += marker(c)
                if !citations.contains(c) { citations.append(c) }
            } else {
                // Invented: drop it, and the space before it.
                while out.last == " " { out.removeLast() }
            }
            rest = rest[m.range.upperBound...]
        }
        out += rest
        return Parsed(text: out.trimmingCharacters(in: .whitespacesAndNewlines), citations: citations, notFound: notFound)
    }

    static func marker(_ c: Citation) -> String { "[[\(c.meetingID)@\(Meeting.timestamp(c.seconds))]]" }

    /// "Tue 9:41" (this week), "12 Sep 9:41" (earlier): the clock time of the moment.
    static func label(start: Date, seconds: Double, now: Date = Date(), calendar: Calendar = .current) -> String {
        let moment = start.addingTimeInterval(seconds)
        let clock = moment.formatted(date: .omitted, time: .shortened)
        let week = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)) ?? now
        let day = moment >= week ? moment.formatted(.dateTime.weekday(.abbreviated))
                                 : moment.formatted(.dateTime.day().month(.abbreviated))
        return "\(day) \(clock)"
    }

    /// Just the clock, for a moment in the meeting you're looking at.
    static func clock(start: Date, seconds: Double) -> String {
        start.addingTimeInterval(seconds).formatted(date: .omitted, time: .shortened)
    }
}

// MARK: - Questions in search

enum AskQuestion {
    static let questionWords: Set<String> = [
        "what", "who", "when", "why", "how", "did", "was", "wer", "wie", "wann", "warum", "hat", "haben", "welche",
    ]

    /// A search that reads like a question: it has a "?", or starts with a
    /// question word and goes on ("what did" yes, a lone "how" no).
    static func isQuestion(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return false }
        if q.contains("?") { return q.count > 1 }
        let words = q.lowercased().split(whereSeparator: \.isWhitespace)
        guard words.count >= 2, let first = words.first else { return false }
        return questionWords.contains(String(first))
    }
}

// MARK: - History

enum AskHistory {
    static let limit = 30
    static let fileName = "questions.json"

    static var globalURL: URL { Prefs.supportDir.appendingPathComponent(fileName) }

    static func url(for meeting: Meeting) -> URL { meeting.folder.appendingPathComponent(fileName) }

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

    static func load(_ url: URL) -> [EarlAnswer] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? decoder.decode([EarlAnswer].self, from: data)) ?? []
    }

    /// Adds `answer` (replacing one with its ID) and keeps the last 30.
    @discardableResult
    static func append(_ answer: EarlAnswer, to url: URL) -> [EarlAnswer] {
        var list = load(url).filter { $0.id != answer.id }
        list.append(answer)
        list = Array(list.suffix(limit))
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encoder.encode(list).write(to: url, options: .atomic)
        return list
    }

    static func save(_ list: [EarlAnswer], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(Array(list.suffix(limit))).write(to: url, options: .atomic)
    }

    /// Where an answer is kept: its meeting's folder, or Application Support.
    static func url(for scope: AskScope, meetings: [Meeting]) -> URL {
        if case .meeting(let id) = scope, let m = meetings.first(where: { $0.id == id }) { return url(for: m) }
        return globalURL
    }
}

// MARK: - Asking

enum AskError: LocalizedError {
    /// LM Studio is off, or the notes model isn't there.
    case noModel

    var errorDescription: String? {
        "Earl needs a notes writer. Open Under the Hood to set one up."
    }
}

struct AskEngine {
    var summarizer: Summarizer = Self.freshSummarizer()
    /// D-3: look for the backend again before asking (off when a test sets the summarizer).
    var followsBackend = true

    static func freshSummarizer() -> Summarizer {
        var s = Summarizer()
        s.reasoning = false // thinking off: seconds, not minutes (R2-7)
        return s
    }

    /// Streams the answer; `onText` gets the visible text so far.
    func ask(_ request: AskRequest, onText: @escaping @MainActor (String) -> Void) async throws -> String {
        var summarizer = summarizer
        if followsBackend {
            guard await NotesEngine.resolve() != .none else { throw AskError.noModel }
            summarizer = Self.freshSummarizer()
        }
        // D-3: the built-in server isn't running yet; it starts with the request.
        let status = summarizer.backend.isBuiltIn ? Summarizer.ServerStatus(reachable: false, isLMStudio: false, models: [])
            : await Summarizer.serverStatus(baseURL: summarizer.baseURL)
        if status.reachable, !status.models.isEmpty, !status.models.contains(where: { $0.id == summarizer.model }) {
            throw AskError.noModel
        }
        let prepared = await summarizer.prepare(transcriptChars: request.user.count + request.system.count, onEvent: nil)
        if let derived = prepared?.model { summarizer.model = derived } // D-3: Ollama with room for it
        do {
            return try await summarizer.streamAnswer(system: request.system, prompt: request.user) { event in
                if case .progress(let text, _, _, _) = event { onText(text) }
            }
        } catch PipelineError.message(let m) where m.hasPrefix("Can't reach") {
            throw AskError.noModel
        }
    }
}
