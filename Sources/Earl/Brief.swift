import AppKit
import Combine
import SwiftUI
import UserNotifications

// S-2: Earl's brief. Before a meeting of a series, the loose ends of the last
// few meetings on a tray: your open to-dos, what others owe, the questions
// left open, who's coming. Assembled from notes Earl already has, with no LLM
// call, so it's instant and every line traces back to a meeting.

// MARK: - The model

/// Someone on the brief's "Who's coming".
struct BriefPerson: Equatable, Identifiable {
    var name: String
    var look: AvatarLook
    /// In the voice library, so Earl will know them by ear.
    var voiceKnown: Bool
    /// Spoke in the last meeting of the series.
    var spokeLastTime: Bool

    var id: String { name }
}

/// An open question from the last meeting.
struct BriefQuestion: Equatable, Identifiable {
    var text: String
    var meetingID: String
    var date: Date

    var id: String { meetingID + "|" + text }
}

struct Brief {
    var title: String
    /// nil on a series page with nothing coming.
    var event: CalendarCandidate?
    /// The newest member with notes.
    var lastMeeting: Meeting?
    /// Earl's line.
    var lead: String
    /// Your open to-dos across the series, newest first.
    var yours: [ActionItem]
    /// Everyone else's open to-dos, grouped by owner.
    var others: [ActionItem]
    var questions: [BriefQuestion]
    var people: [BriefPerson]
    /// Every member, newest first.
    var history: [Meeting]

    static let todoLimit = 8
    static let questionLimit = 5
    /// To-dos come from this many of the newest meetings with notes…
    static let todoMeetings = 3
    /// …that are at most this old.
    static let todoWindow: TimeInterval = 30 * 86_400
    /// Stricter than to-do carry-over: two different tasks must not merge.
    static let sameTask = 0.85

    static func make(event: CalendarCandidate?, series members: [Meeting], userName: String?, now: Date,
                     isVoiceKnown: (_ name: String, _ email: String?) -> Bool = { _, _ in false },
                     calendar: Calendar = .current) -> Brief {
        let history = members.sorted { $0.info.startedAt > $1.info.startedAt }
        let withNotes = history.filter { $0.info.status == .done && !$0.summary.isEmpty }
        let last = withNotes.first
        let title = event.map { MeetingSeries.displayName(history).isEmpty ? $0.title : MeetingSeries.displayName(history) }
            ?? MeetingSeries.displayName(history)

        let (yours, everyone) = openTodos(in: withNotes, userName: userName, now: now)
        // K-1: at a town hall or a talk, what the speakers owe isn't yours to chase.
        let listening = last?.info.notesKind.flatMap(MeetingKind.init(rawValue:))?.isListening == true
        let others = listening ? [] : everyone
        let questions = last.map { m in
            FrontPageNotes.parse(m.summary, meetingID: m.id).open.prefix(questionLimit)
                .map { BriefQuestion(text: $0, meetingID: m.id, date: m.info.startedAt) }
        } ?? []
        let people = people(event: event, last: last, userName: userName, isVoiceKnown: isVoiceKnown)
        let lead = EarlVoice.brief(yours: yours.count, others: others.map { $0.owner ?? "Someone" },
                                   last: last?.info.startedAt ?? history.first?.info.startedAt,
                                   now: now, calendar: calendar)
        return Brief(title: title.isEmpty ? (event?.title ?? "") : title, event: event, lastMeeting: last,
                     lead: lead, yours: yours, others: others, questions: questions, people: people, history: history)
    }

    /// Unticked to-dos of the newest meetings with notes, newest first. A task
    /// that came up again keeps only its newest line, and one ticked in a
    /// later meeting counts as done.
    static func openTodos(in withNotes: [Meeting], userName: String?, now: Date)
        -> (yours: [ActionItem], others: [ActionItem]) {
        let recent = withNotes.prefix(todoMeetings).filter { now.timeIntervalSince($0.info.startedAt) <= todoWindow }
        var seen: [ActionItem] = []
        var open: [ActionItem] = []
        // S-1: a newer meeting's notes saying "Done: …" close an older to-do,
        // the same as a tick would.
        var doneSince: [String] = []
        for meeting in recent {
            for item in ActionItems.parse(meeting.summary, meetingID: meeting.id) {
                if !seen.contains(where: { ActionItems.similarity($0.text, item.text) >= sameTask })
                    && doneSince.contains(where: { closes($0, item.text) }) {
                    seen.append(item) // done since; hides itself and any older copy
                    continue
                }
                guard !seen.contains(where: { ActionItems.similarity($0.text, item.text) >= sameTask }) else { continue }
                seen.append(item)
                if !item.done { open.append(item) }
            }
            doneSince += FrontPageNotes.parse(meeting.summary, meetingID: meeting.id).since
                .filter(SinceLastTime.isDone).map(doneText)
        }
        let mine = open.filter { ActionItems.isMine(owner: $0.owner, userName: userName) }
        // Grouped by owner, in the order the owners first come up.
        var owners: [String] = []
        for item in open where !ActionItems.isMine(owner: item.owner, userName: userName) {
            let o = ActionItems.normalize(item.owner ?? "")
            if !owners.contains(o) { owners.append(o) }
        }
        let others = owners.flatMap { o in
            open.filter { !ActionItems.isMine(owner: $0.owner, userName: userName) && ActionItems.normalize($0.owner ?? "") == o }
        }
        return (Array(mine.prefix(todoLimit)), Array(others.prefix(todoLimit)))
    }

    /// The event's attendees (or the last meeting's), people who spoke last
    /// time first. Without either, the last meeting's named voices.
    static func people(event: CalendarCandidate?, last: Meeting?, userName: String?,
                       isVoiceKnown: (String, String?) -> Bool) -> [BriefPerson] {
        let speakers = last?.speakers ?? []
        let looks = SpeakerFaces.looks(for: speakers)
        var invited = (event?.attendees ?? last?.info.attendees ?? []).filter {
            !$0.isMe && !ActionItems.isMine(owner: $0.name, userName: userName)
        }
        if invited.isEmpty {
            invited = speakers.compactMap { s in
                guard let name = s.name, !name.isEmpty, !Speaker.isYou(s, in: speakers) else { return nil }
                return Attendee(name: name, email: nil, isMe: false)
            }
        }
        var out: [BriefPerson] = []
        for a in invited where !out.contains(where: { $0.name == a.name }) {
            let speaker = speaker(named: a.name, in: speakers)
            out.append(BriefPerson(name: a.name, look: speaker.flatMap { looks[$0.id] } ?? .voice(3),
                                   voiceKnown: isVoiceKnown(a.name, a.email), spokeLastTime: speaker != nil))
        }
        // Stable: people who spoke last time first, otherwise as invited.
        return out.enumerated().sorted { l, r in
            l.element.spokeLastTime != r.element.spokeLastTime ? l.element.spokeLastTime : l.offset < r.offset
        }.map(\.element)
    }

    private static func speaker(named name: String, in speakers: [Speaker]) -> Speaker? {
        let n = ActionItems.normalize(name), first = ActionItems.normalize(AttendeeName.firstName(name))
        let named = speakers.filter { !($0.name ?? "").isEmpty && $0.seconds > 0 }
        if let exact = named.first(where: { ActionItems.normalize($0.name ?? "") == n }) { return exact }
        let byFirst = named.filter { ActionItems.normalize($0.name ?? "") == first
            || ActionItems.normalize(AttendeeName.firstName($0.name ?? "")) == first }
        return byFirst.count == 1 ? byFirst[0] : nil
    }
}

// MARK: - Earl's line

extension EarlVoice {
    /// The lead-in of the brief card.
    static let beforeYouGoIn = "Before you go in —"
    /// The series page's, with nothing coming.
    static let whereThingsStand = "Where things stand —"

    /// Earl's one line on a brief. Warm and short; never jokes about work
    /// left undone. `others` holds the owner of each open to-do of others.
    static func brief(yours: Int, others: [String], last: Date?, now: Date, calendar: Calendar = .current) -> String {
        guard let last else { return "First of these. I'll take notes." }
        let from = "from " + dayPhrase(last, now: now, calendar: calendar)
        let pick = stableIndex(now, count: 2, calendar: calendar)
        let owed = owedClause(others)
        switch (yours, owed) {
        case (0, nil):
            return pick == 0 ? "Nothing outstanding \(from). You go in clean."
                             : "All square \(from). You go in clean."
        case (0, let owed?):
            return "Nothing of yours is open \(from). \(owed.capitalizedFirst)."
        case (let n, nil):
            let count = n == 1 ? "One of yours is" : "\(word(n).capitalizedFirst) of yours are"
            return pick == 0 ? "\(count) still open \(from)." : "\(count) still waiting \(from)."
        case (let n, let owed?):
            let count = n == 1 ? "One of yours is" : "\(word(n).capitalizedFirst) of yours are"
            // "…, and Dominik owes one." reads well; two names after "and" don't.
            return owed.contains(" and ") || owed.contains(" others ")
                ? "\(count) still open \(from). \(owed.capitalizedFirst)."
                : "\(count) still open \(from), and \(owed)."
        }
    }

    /// "Priya owes one", "Priya and Tom owe one each", "Priya and Tom owe
    /// three between them", "three others owe five".
    private static func owedClause(_ owners: [String]) -> String? {
        guard !owners.isEmpty else { return nil }
        var names: [String] = []
        for o in owners {
            let first = AttendeeName.firstName(o)
            if !names.contains(where: { ActionItems.normalize($0) == ActionItems.normalize(first) }) { names.append(first) }
        }
        let n = word(owners.count)
        switch names.count {
        case 1: return "\(names[0]) owes \(n)"
        case 2 where owners.count == 2: return "\(names[0]) and \(names[1]) owe one each"
        case 2: return "\(names[0]) and \(names[1]) owe \(n) between them"
        default: return "\(word(names.count)) others owe \(n)"
        }
    }

    /// Numbers as words up to ten.
    static func word(_ n: Int) -> String {
        let words = ["no", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]
        return words.indices.contains(n) ? words[n] : "\(n)"
    }

    /// "earlier today", "yesterday", "Tuesday" (this past week), "Sep 28".
    static func dayPhrase(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                           to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case ...0: return "earlier today"
        case 1: return "yesterday"
        case 2...6:
            var f = Date.FormatStyle.dateTime.weekday(.wide)
            f.calendar = calendar
            f.timeZone = calendar.timeZone
            return date.formatted(f)
        default:
            var f = Date.FormatStyle.dateTime.month(.abbreviated).day()
            f.calendar = calendar
            f.timeZone = calendar.timeZone
            return date.formatted(f)
        }
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

// MARK: - Finding the brief

extension AppState {
    /// The upcoming calendar event of a series, if one is coming today or tomorrow.
    func upcomingEvent(forSeries key: String, now: Date = Date()) -> CalendarCandidate? {
        guard calendar.isActive else { return nil }
        let recorded = Set(meetings.compactMap(\.info.calendarEventID))
        return calendar.upcomingEvents
            .filter { CalendarMatcher.isRealMeeting($0) && !recorded.contains($0.id) && $0.end > now
                && MeetingSeries.key(title: $0.title) == key }
            .min { $0.start < $1.start }
    }

    /// Recorded meetings of a series, newest first.
    func seriesMembers(_ key: String) -> [Meeting] {
        meetings.filter { MeetingSeries.key(for: $0) == key }.sorted { $0.info.startedAt > $1.info.startedAt }
    }

    /// The brief for a series: about its next event when one is coming.
    func brief(forSeries key: String, now: Date = Date()) -> Brief {
        Brief.make(event: upcomingEvent(forSeries: key, now: now), series: seriesMembers(key),
                   userName: Prefs.userName, now: now, isVoiceKnown: BriefVoices.isKnown)
    }

    /// The brief for an event, when its series has past meetings.
    func brief(for event: CalendarCandidate, now: Date = Date()) -> Brief? {
        // The sidebar card and the menu bar ask every second while recording;
        // the answer only changes with the meetings (reload clears) or the minute.
        let cacheKey = "\(event.id)|\(event.start.timeIntervalSince1970)|\(Int(now.timeIntervalSince1970 / 60))"
        if let hit = BriefCache.entries[cacheKey] { return hit }
        let brief = makeBrief(for: event, now: now)
        if BriefCache.entries.count > 50 { BriefCache.entries.removeAll() }
        BriefCache.entries[cacheKey] = brief
        return brief
    }

    private func makeBrief(for event: CalendarCandidate, now: Date) -> Brief? {
        guard let key = MeetingSeries.key(title: event.title) else { return nil }
        let members = seriesMembers(key).filter { $0.hasContent && $0.info.startedAt < event.start }
        guard !members.isEmpty else { return nil }
        return Brief.make(event: event, series: members, userName: Prefs.userName, now: now,
                          isVoiceKnown: BriefVoices.isKnown)
    }

    /// Opens the brief or series page in the main window.
    func openSeries(_ key: String) {
        selection = .series(key)
        AppDelegate.openMeetings?()
    }
}

enum BriefVoices {
    /// In the voice library by full name or email.
    @MainActor static func isKnown(name: String, email: String?) -> Bool {
        let n = ActionItems.normalize(name)
        return VoiceStore.shared.voices.contains { v in
            ActionItems.normalize(v.name) == n
                || (email != nil && v.email?.caseInsensitiveCompare(email ?? "") == .orderedSame)
        }
    }
}

// MARK: - The nudge

/// When to nudge. Pure, so the once-per-occurrence rule can be tested.
enum BriefNudgeRules {
    static let lead: TimeInterval = 10 * 60

    /// One nudge per occurrence: the event ID plus its start.
    static func occurrence(_ event: CalendarCandidate) -> String {
        "\(event.id)|\(Int(event.start.timeIntervalSince1970))"
    }

    /// Events in their nudge window (ten minutes before the start, until the
    /// start) that haven't been nudged.
    static func due(_ events: [CalendarCandidate], now: Date, sent: Set<String>) -> [CalendarCandidate] {
        events.filter { now >= $0.start.addingTimeInterval(-lead) && now < $0.start && !sent.contains(occurrence($0)) }
    }

    /// When to look next: the earliest window opening after `now`.
    static func nextWake(_ events: [CalendarCandidate], now: Date) -> Date? {
        events.map { $0.start.addingTimeInterval(-lead) }.filter { $0 > now }.min()
    }

    /// Only a series meeting with anything open earns a nudge.
    static func worthNudging(_ brief: Brief?) -> Bool {
        guard let brief else { return false }
        return !brief.yours.isEmpty || !brief.others.isEmpty
    }
}

extension Prefs.Key {
    static let briefNudge = "briefNudge"
    static let briefNudgesSent = "briefNudgesSent"
}

extension Prefs {
    /// "Brief me 10 minutes before a meeting in a series", on by default.
    static var briefNudge: Bool {
        UserDefaults.standard.object(forKey: Key.briefNudge) as? Bool ?? true
    }

    /// Occurrences already nudged, newest last.
    static var briefNudgesSent: [String] {
        get { UserDefaults.standard.stringArray(forKey: Key.briefNudgesSent) ?? [] }
        set { UserDefaults.standard.set(Array(newValue.suffix(40)), forKey: Key.briefNudgesSent) }
    }
}

/// Wakes once at the next nudge window, like the armed recording's timer, and
/// re-plans whenever the calendar or the meetings change. Never polls.
@MainActor
final class BriefNudger {
    static let shared = BriefNudger()
    static let notificationPrefix = "earl.brief|"

    private weak var state: AppState?
    private var timer: Timer?
    private var bag: Set<AnyCancellable> = []

    func start(state: AppState) {
        self.state = state
        state.calendar.$upcomingEvents
            .combineLatest(state.$meetings)
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] _, _ in self?.evaluate() }
            .store(in: &bag)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in self?.evaluate() }
            .store(in: &bag)
    }

    func evaluate(now: Date = Date()) {
        timer?.invalidate()
        timer = nil
        guard let state, Prefs.briefNudge, !state.isRecording else { return }
        let events = state.calendar.upcomingEvents.filter {
            CalendarMatcher.isRealMeeting($0) && MeetingSeries.key(title: $0.title) != nil
        }
        var sent = Prefs.briefNudgesSent
        for event in BriefNudgeRules.due(events, now: now, sent: Set(sent)) {
            sent.append(BriefNudgeRules.occurrence(event))
            guard let brief = state.brief(for: event, now: now), BriefNudgeRules.worthNudging(brief),
                  let key = MeetingSeries.key(title: event.title) else { continue }
            post(title: "\(brief.title) in \(max(1, Int((event.start.timeIntervalSince(now) / 60).rounded()))) minutes",
                 body: brief.lead, key: key)
        }
        Prefs.briefNudgesSent = sent
        guard let wake = BriefNudgeRules.nextWake(events, now: now) else { return }
        let timer = Timer(fire: wake, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func post(title: String, body: String, key: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: Self.notificationPrefix + key + "|" + UUID().uuidString,
                                  content: content, trigger: nil))
    }

    /// A click on a brief notification opens the brief. False for any other notification.
    static func open(notificationID id: String) -> Bool {
        guard id.hasPrefix(notificationPrefix) else { return false }
        let key = id.dropFirst(notificationPrefix.count).split(separator: "|").first.map(String.init) ?? ""
        guard !key.isEmpty else { return false }
        shared.state?.openSeries(key)
        return true
    }
}

// MARK: - Settings

/// Settings → Calls: the nudge before a series meeting.
struct BriefSettings: View {
    @AppStorage(Prefs.Key.briefNudge) private var nudge = true

    var body: some View {
        Card(title: "Briefs",
             subtitle: "Before a meeting you've had before, Earl gathers what's still open from the last ones.") {
            Toggle("Brief me 10 minutes before a meeting in a series", isOn: $nudge)
                .font(.settingsRow)
                .onChange(of: nudge) { _, _ in BriefNudger.shared.evaluate() }
        }
    }
}

extension Brief {
    /// "Done: Tom sent the patch list." → "Tom sent the patch list."
    static func doneText(_ bullet: String) -> String {
        var t = bullet.trimmingCharacters(in: .whitespaces)
        for prefix in ["done:", "erledigt:", "completed:", "abgeschlossen:"] where t.lowercased().hasPrefix(prefix) {
            t = String(t.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        return t
    }

    /// Whether a "done" line is about this to-do: most of the to-do's words
    /// are in it ("send the patch list" / "Tom sent the patch list to Sarah").
    static func closes(_ done: String, _ todo: String) -> Bool {
        if ActionItems.similarity(done, todo) >= sameTask { return true }
        func words(_ s: String) -> Set<String> {
            Set(ActionItems.normalize(s).split(separator: " ").map { String($0.prefix(5)) }.filter { $0.count >= 3 })
        }
        let t = words(todo), d = words(done)
        guard t.count >= 2 else { return false }
        return Double(t.intersection(d).count) / Double(t.count) >= 0.75
    }
}

// One task, one line: in a series the same to-do is often written again at
// the next meeting. The To-dos page and its count show only the newest copy,
// and an older open copy goes once a later meeting ticks it or reports it done.
enum SeriesTodos {
    /// IDs of open items that a newer meeting of their series supersedes.
    static func superseded(in meetings: [Meeting]) -> Set<String> {
        var out = Set<String>()
        for members in MeetingSeries.groups(meetings).values { // newest first
            var later: [ActionItem] = []
            var doneSince: [String] = []
            for meeting in members {
                let items = ActionItems.parse(meeting.summary, meetingID: meeting.id)
                for item in items where !item.done {
                    if later.contains(where: { ActionItems.similarity($0.text, item.text) >= Brief.sameTask })
                        || doneSince.contains(where: { Brief.closes($0, item.text) }) {
                        out.insert(item.id)
                    }
                }
                later += items
                doneSince += FrontPageNotes.parse(meeting.summary, meetingID: meeting.id).since
                    .filter(SinceLastTime.isDone).map(Brief.doneText)
            }
        }
        return out
    }
}

/// Briefs per event and minute, cleared whenever the meetings reload.
@MainActor enum BriefCache {
    static var entries: [String: Brief?] = [:]
}
