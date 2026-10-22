import Foundation

// S-1: notes that remember. What the notes model is told about earlier
// meetings of the same series: last time's decisions and open questions, and
// the to-dos still open. Built from the notes, never the transcripts, so it
// stays short, and labelled as context so it isn't mistaken for today.

enum SeriesContext {
    static let heading = "Earlier in this series (for context only; the transcript is what happened today):"
    static let maxChars = 2000
    static let maxTodos = 12
    /// To-dos come from this many earlier meetings.
    static let todoMeetings = 3
    /// Older meetings say little about today.
    static let maxAge: TimeInterval = 30 * 86_400

    /// The earlier meetings worth reading: in the series, with notes, at most 30 days old, newest first.
    static func earlier(than meeting: Meeting, in meetings: [Meeting]) -> [Meeting] {
        MeetingSeries.earlier(than: meeting, in: meetings)
            .filter { !$0.summary.isEmpty && meeting.info.startedAt.timeIntervalSince($0.info.startedAt) <= maxAge }
    }

    /// The context block, or nil when the meeting is in no series or nothing earlier has notes.
    /// K-1 `listening`: a town hall or talk carries no decisions, and only your to-dos.
    static func text(for meeting: Meeting, in meetings: [Meeting], userName: String?, listening: Bool = false) -> String? {
        let earlier = Array(earlier(than: meeting, in: meetings).prefix(todoMeetings))
        guard let last = earlier.first else { return nil }

        let notes = FrontPageNotes.parse(last.summary, meetingID: last.id)
        var decisions = listening ? [] : notes.decisions.map(clip)
        var open = listening ? [] : notes.open.map(clip)
        var todos: [String] = []
        // To-dos you ticked off on the last meeting, so today's notes can say
        // they're done instead of forgetting them.
        var ticked = ActionItems.parse(last.summary, meetingID: last.id).filter(\.done).prefix(6).map { item in
            clip((item.owner.map { "\(ActionItems.isMine(owner: $0, userName: userName) ? (userName ?? "Me") : $0): " } ?? "") + item.text)
        }
        // The brief's rule: a task said again keeps its newest line, and one
        // ticked or reported done in a later meeting isn't open.
        let (mine, others) = Brief.openTodos(in: earlier, userName: userName, now: meeting.info.startedAt)
        let order = Dictionary(earlier.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        // Newest meeting first, the notes' own order within one meeting.
        let items = (mine + (listening ? [] : others)).enumerated().sorted { a, b in
            let (ma, mb) = (order[a.element.meetingID] ?? 0, order[b.element.meetingID] ?? 0)
            return ma != mb ? ma < mb : a.offset < b.offset
        }.map(\.element)
        for item in items {
            let date = earlier.first { $0.id == item.meetingID }.map { day($0.info.startedAt) } ?? ""
            let owner = item.owner.map { ActionItems.isMine(owner: $0, userName: userName) ? (userName ?? "Me") : $0 }
            todos.append(clip((owner.map { "\($0): " } ?? "") + item.text) + " (set \(date))")
        }
        todos = Array(todos.prefix(maxTodos))

        let headline = last.info.headline.map { " \($0)" } ?? ""
        func build() -> String {
            var out = "\(heading)\n\nLast time (\(day(last.info.startedAt))):\(headline)\n"
            if !decisions.isEmpty { out += "Decisions:\n" + decisions.map { "- \($0)\n" }.joined() }
            if !open.isEmpty { out += "Open questions:\n" + open.map { "- \($0)\n" }.joined() }
            if !todos.isEmpty { out += "\nOpen to-dos:\n" + todos.map { "- \($0)\n" }.joined() }
            if !ticked.isEmpty { out += "\nTicked off as done since:\n" + ticked.map { "- \($0)\n" }.joined() }
            return out.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !decisions.isEmpty || !open.isEmpty || !todos.isEmpty || !ticked.isEmpty || !headline.isEmpty else { return nil }
        // Over the limit: drop the oldest to-dos first, then last time's
        // questions and decisions from the end.
        var out = build()
        while out.count > maxChars {
            if !ticked.isEmpty { ticked.removeLast() }
            else if !todos.isEmpty { todos.removeLast() }
            else if !open.isEmpty { open.removeLast() }
            else if !decisions.isEmpty { decisions.removeLast() }
            else { return String(out.prefix(maxChars)) }
            out = build()
        }
        return out
    }

    /// One bullet at most this long, so a rambling one can't take the room.
    static func clip(_ s: String) -> String {
        s.count <= 240 ? s : String(s.prefix(239)) + "…"
    }

    /// "Tue, Oct 6": in English, like the rest of the prompt.
    static func day(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, MMM d"
        return f.string(from: date)
    }

    /// What `AppState.process` sets on the prompt, and its log line.
    static func prepare(for meeting: Meeting, in meetings: [Meeting], userName: String?, kind: MeetingKind? = nil)
        -> (text: String?, kind: MeetingKind, log: String) {
        let kind = kind ?? MeetingKind.of(meeting, in: meetings) // K-1: AppState resolves it first
        let text = text(for: meeting, in: meetings, userName: userName, listening: kind.isListening)
        let count = min(todoMeetings, earlier(than: meeting, in: meetings).count)
        let log = text.map { "Series: \(count) earlier meetings, \($0.count) chars of context" } ?? "Series: none"
        return (text, kind, log + " · kind: \(kind.rawValue)")
    }

    /// The meeting a "Since last time" section refers to: the newest earlier
    /// one of the series with notes.
    static func previous(of meeting: Meeting, in meetings: [Meeting]) -> Meeting? {
        earlier(than: meeting, in: meetings).first
    }
}
