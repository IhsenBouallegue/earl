import Foundation

// S-1: what kind of meeting this was, so the notes take its shape. A daily
// stand-up wants "who's on what", not the Summary / Decisions / Action items
// of a client workshop. Decided from the calendar, the length and the voices,
// without asking the model.
//
// K-1: not every meeting decides things. At a town hall leaders inform many
// people; at a talk (webinar, demo, training) one or two people present. In
// the library, 11 of 26 meetings with notes had the author say 5 % or less,
// and every one got "Decisions" and "Action items" anyway. The author's choice,
// once per series, wins over all of this.

enum MeetingKind: String, Equatable, CaseIterable {
    case standup, oneOnOne, general
    case townHall, talk // K-1

    /// What the page and the menu call it.
    var label: String {
        switch self {
        case .standup: "Stand-up"
        case .oneOnOne: "One-to-one"
        case .general: "Working meeting"
        case .townHall: "Town hall"
        case .talk: "Talk or demo"
        }
    }

    /// "Write these notes as …": one line on what the shape keeps.
    var explanation: String {
        switch self {
        case .standup: "One line per person: what they're on, any blocker"
        case .oneOnOne: "What you learned and what you owe"
        case .general: "Decisions, to-dos and open questions"
        case .townHall: "Announcements, what's asked of you, the Q&A"
        case .talk: "Key points worth keeping, the Q&A"
        }
    }

    /// You came to listen: nothing is decided, and others' to-dos aren't kept.
    var isListening: Bool { self == .townHall || self == .talk }

    /// Title words that mean a stand-up ("daily scrum" is covered by "daily").
    static let standupWords = ["daily", "stand-up", "standup", "stand up", "jour fixe"]
    /// Title marks of a one-to-one.
    static let oneOnOneMarks = ["1:1", "1on1", "1-on-1", "one on one", "<>"]
    /// Stand-ups are short; a weekly "jour fixe" of an hour is a meeting.
    static let standupMaxMinutes = 30.0

    /// K-1: whole words or phrases in the title.
    static let townHallWords = ["town hall", "townhall", "all hands", "all-hands", "allhands", "company meeting",
                                "company update", "ama", "betriebsversammlung", "mitarbeiterversammlung",
                                "belegschaftsversammlung", "vollversammlung"]
    static let talkWords = ["webinar", "webcast", "keynote", "demo", "showcase", "training", "lecture",
                            "presentation", "tech talk", "lunch & learn", "lunch and learn", "brown bag",
                            "schulung", "vortrag", "präsentation", "vorstellung", "info session",
                            "infoveranstaltung", "walkthrough", "preview"]

    /// K-1: you said at most this share of the words: you were listening.
    static let listenerShare = 0.05
    /// One voice with at least this share of the call is presenting.
    static let presenterShare = 0.55
    /// A talk has at least this many invited (a 7-person weekly where one
    /// person reports is still a working meeting).
    static let talkAudience = 10
    /// So many invitees and nobody presenting alone: a town hall.
    static let audienceSize = 25
    /// Above this share of the words, a "demo" in the title is yours.
    static let presenterOwnShare = 0.2
    /// Listening is only judged on meetings this long.
    static let listeningMinMinutes = 10.0

    /// The talk shares the transcript gives: yours, and the loudest other voice's
    /// (nil when the call wasn't separated into voices).
    struct Talk: Equatable {
        var mine: Double
        var top: Double?
        var words: Int
    }

    /// The kind to write the notes in: yours if you chose one, else decided,
    /// else what the model said last time, else a working meeting.
    static func of(_ meeting: Meeting, in meetings: [Meeting]) -> MeetingKind {
        if let chosen = chosen(for: meeting, in: meetings) { return chosen }
        if let decided = decide(meeting, in: meetings) { return decided }
        return meeting.info.notesKind.flatMap(MeetingKind.init(rawValue:)) ?? .general
    }

    /// `of`, asking the model when the numbers can't tell and it hasn't been
    /// asked before. Returns the kind and why, for the log.
    static func resolve(_ meeting: Meeting, in meetings: [Meeting],
                        ask: () async -> MeetingKind?) async -> (kind: MeetingKind, reason: String) {
        if meeting.info.notesKindByUser == true, let k = meeting.info.notesKind.flatMap(MeetingKind.init(rawValue:)) {
            return (k, "your choice")
        }
        if let k = chosen(for: meeting, in: meetings) { return (k, "your choice for the series") }
        if let k = decide(meeting, in: meetings) { return (k, "title, length and voices") }
        if let k = meeting.info.notesKind.flatMap(MeetingKind.init(rawValue:)) { return (k, "the model, earlier") }
        // The series doesn't change kind from week to week.
        if let k = MeetingSeries.earlier(than: meeting, in: meetings)
            .first(where: { $0.info.notesKind != nil && decide($0, in: meetings) == nil })?
            .info.notesKind.flatMap(MeetingKind.init(rawValue:)) {
            return (k, "the series, earlier")
        }
        if let k = await ask() { return (k, "the model") }
        return (.general, "the model couldn't tell")
    }

    /// Your choice for this meeting, else the newest one in its series.
    static func chosen(for meeting: Meeting, in meetings: [Meeting]) -> MeetingKind? {
        if meeting.info.notesKindByUser == true, let k = meeting.info.notesKind.flatMap(MeetingKind.init(rawValue:)) {
            return k
        }
        let series = MeetingSeries.members(of: meeting, in: meetings)
            .filter { $0.id != meeting.id && $0.info.notesKindByUser == true }
            .max { $0.info.startedAt < $1.info.startedAt }
        return series?.info.notesKind.flatMap(MeetingKind.init(rawValue:))
    }

    /// Decided from the meeting alone, or nil when only the model can tell
    /// (you listened to several voices: an all-hands or a working meeting?).
    static func decide(_ meeting: Meeting, in meetings: [Meeting]) -> MeetingKind? {
        let series = MeetingSeries.members(of: meeting, in: meetings).map(\.info.startedAt)
        return decide(title: meeting.info.calendarTitle ?? meeting.info.title,
                      minutes: meeting.info.duration / 60,
                      seriesDates: series,
                      voices: voices(in: meeting),
                      attendees: meeting.info.attendees?.count,
                      talk: talk(in: meeting))
    }

    /// `voices`: people heard, you included, or nil when the call audio wasn't
    /// separated into voices (then "Them" may be anyone). Without `talk`, the
    /// S-1 rules; nil means "ask the model".
    static func decide(title: String, minutes: Double, seriesDates: [Date], voices: Int?, attendees: Int?,
                       talk: Talk? = nil) -> MeetingKind? {
        let t = title.lowercased()
        let standupTitle = standupWords.contains { t.contains($0) }
        if minutes <= standupMaxMinutes && (standupTitle || meetsOften(seriesDates)) { return .standup }
        // K-1: the title says it.
        if hasWord(t, townHallWords) { return .townHall }
        // A demo you gave yourself is a working meeting: its feedback becomes to-dos.
        if hasWord(t, talkWords) && (talk?.mine ?? 0) <= presenterOwnShare { return .talk }
        // K-1: you listened.
        if let talk, minutes >= listeningMinMinutes, talk.words >= 300, talk.mine <= listenerShare {
            // One voice holding the floor in a small group is a status update,
            // not a talk: it takes an audience.
            let audience = attendees.map { $0 >= talkAudience } ?? (minutes >= 30)
            if let top = talk.top, top >= presenterShare, audience { return .talk }
            if let attendees, attendees >= audienceSize { return .townHall }
            if (voices ?? 0) >= 3 { return nil }
        }
        if voices == 2 || attendees == 2 || oneOnOneMarks.contains(where: { t.contains($0) }) { return .oneOnOne }
        return .general
    }

    /// "demo" in "Product demo" and "Demo: X", not in "Demokratie".
    static func hasWord(_ title: String, _ words: [String]) -> Bool {
        let tokens = title.split { !$0.isLetter && !$0.isNumber && $0 != "&" && $0 != "-" }.map(String.init)
        let joined = " " + tokens.joined(separator: " ") + " "
        return words.contains { joined.contains(" " + $0 + " ") }
    }

    /// The series met on 3 or more different weekdays in one calendar week.
    static func meetsOften(_ dates: [Date], calendar: Calendar = .current) -> Bool {
        let weeks = Dictionary(grouping: dates) {
            calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: $0)
        }
        return weeks.values.contains { Set($0.map { calendar.component(.weekday, from: $0) }).count >= 3 }
    }

    /// You (if you spoke) plus the separated voices on the call track.
    static func voices(in meeting: Meeting) -> Int? {
        guard meeting.info.speakerModel != nil else { return nil }
        let them = Set(meeting.turns.filter { $0.speaker != "Me" }.compactMap(\.speakerID))
        let me = meeting.turns.contains { $0.speaker == "Me" } ? 1 : 0
        return them.count + me
    }

    /// Who said how much, in words.
    static func talk(in meeting: Meeting) -> Talk {
        var mine = 0
        var others: [String: Int] = [:]
        for turn in meeting.turns {
            let n = turn.text.split(whereSeparator: \.isWhitespace).count
            if turn.isMe { mine += n } else { others[turn.speakerID ?? "Them", default: 0] += n }
        }
        let total = mine + others.values.reduce(0, +)
        guard total > 0 else { return Talk(mine: 0, top: nil, words: 0) }
        let separated = meeting.info.speakerModel != nil
        let top = separated ? others.values.max().map { Double($0) / Double(total) } : nil
        return Talk(mine: Double(mine) / Double(total), top: top, words: total)
    }
}

// MARK: - Asking the model (K-1)

/// When the numbers can't tell, one short question to the notes model.
enum KindGuess {
    static let maxChars = 12_000

    static let system = "You classify meetings from their transcript. Answer with one word."

    static func prompt(transcript: String, title: String, userName: String?, facts: String? = nil) -> String {
        let me = userName.map { "\($0) ('Me')" } ?? "The user ('Me')"
        return """
            Meeting title: \(title)
            \(me) barely spoke in this meeting.\(facts.map { " " + $0 } ?? "")

            \(excerpt(transcript))

            Which describes this meeting best?
            WORKING: a group discussing, planning or deciding things together.
            TOWNHALL: several leaders or organisers informing a large audience (news, updates, announcements), maybe with questions.
            TALK: one or two people presenting, demonstrating or teaching to listeners.

            Answer with exactly one word: WORKING, TOWNHALL or TALK.
            """
    }

    /// The start, the middle and the end: an all-hands may open with one
    /// long presentation.
    static func excerpt(_ transcript: String) -> String {
        guard transcript.count > maxChars else { return transcript }
        let part = maxChars / 3
        let chars = Array(transcript)
        let mid = chars.count / 2 - part / 2
        return [String(chars[0..<part]), String(chars[mid..<mid + part]), String(chars[(chars.count - part)...])]
            .joined(separator: "\n…\n")
    }

    /// What the numbers say, in a sentence.
    static func facts(_ meeting: Meeting) -> String {
        let talk = MeetingKind.talk(in: meeting)
        var out: [String] = []
        if let voices = MeetingKind.voices(in: meeting) { out.append("\(voices) voices were heard") }
        if let top = talk.top { out.append("the one who spoke most said \(Int((top * 100).rounded())) % of the words") }
        if let invited = meeting.info.attendees?.count, invited > 0 { out.append("\(invited) people were invited") }
        guard !out.isEmpty else { return "" }
        let joined = out.joined(separator: ", ")
        return joined.prefix(1).uppercased() + joined.dropFirst() + "."
    }

    /// The model's word, anywhere in a short answer; nil when it isn't clear.
    static func parse(_ answer: String) -> MeetingKind? {
        let a = answer.uppercased()
        let found: [(String, MeetingKind)] = [("TOWNHALL", .townHall), ("TOWN HALL", .townHall),
                                              ("TALK", .talk), ("WORKING", .general)]
        let hits = Set(found.filter { a.contains($0.0) }.map(\.1))
        return hits.count == 1 ? hits.first : nil
    }

    static func ask(_ meeting: Meeting, userName: String?, model: String) async -> MeetingKind? {
        var summarizer = Summarizer()
        summarizer.model = model
        let prompt = prompt(transcript: meeting.transcriptText, title: meeting.info.calendarTitle ?? meeting.info.title,
                            userName: userName, facts: facts(meeting))
        let answer = try? await summarizer.answer(system: system, prompt: prompt, maxTokens: 400, reasoning: false)
        return answer.flatMap(parse)
    }
}
