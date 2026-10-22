import AppKit
import EventKit
import SwiftUI

// R2-1: name recordings after the calendar event and know who was invited.
// Everything is read locally through EventKit; work calendars (Microsoft 365,
// Google) arrive via Apple Calendar's Internet Accounts.

// MARK: - Settings

extension Prefs.Key {
    static let calendarEnabled = "calendarEnabled"
    /// Comma-separated calendar identifiers the user switched off. Empty means all on.
    static let calendarsOff = "calendarsOff"
    static let userName = "userName"
}

extension Prefs {
    /// Only has an effect once calendar access is allowed.
    static var calendarEnabled: Bool { Prefs.defaults.object(forKey: Key.calendarEnabled) as? Bool ?? true }
    static var calendarsOff: Set<String> {
        CallApps.parseOff(Prefs.defaults.string(forKey: Key.calendarsOff) ?? "")
    }
    /// Your name, typed in Settings or learned from the calendar. `nil` when unknown.
    static var userName: String? {
        get {
            let name = Prefs.defaults.string(forKey: Key.userName)?.trimmingCharacters(in: .whitespaces) ?? ""
            return name.isEmpty ? nil : name
        }
        set { Prefs.defaults.set(newValue, forKey: Key.userName) }
    }
}

// MARK: - Saved data

/// Someone invited to the meeting.
struct Attendee: Codable, Hashable {
    var name: String
    var email: String?
    var isMe: Bool
}

extension MeetingInfo {
    /// "with Sarah, Tom and 3 others", from the calendar attendees other than you.
    var attendeeLine: String? {
        attendees.flatMap(AttendeeName.line)
    }

    /// Names to give Whisper so it spells them right.
    var attendeeNames: [String] { attendees?.map(\.name) ?? [] }
}

// MARK: - Candidates and matching

/// A calendar event, reduced to what matching and saving need.
struct CalendarCandidate: Identifiable, Hashable {
    enum Response { case accepted, tentative, pending, declined, unknown }

    /// See `CalendarEventID`.
    var id: String
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    /// People invited other than you.
    var attendeeCount: Int
    var myStatus: Response
    /// Meeting links found in the event, best first.
    var urls: [String]
    var organizer: String?
    var attendees: [Attendee]
    var calendarName: String?

    var timeText: String {
        "\(start.formatted(date: .omitted, time: .shortened)) – \(end.formatted(date: .omitted, time: .shortened))"
    }
}

/// Identifies one occurrence of an event: the item's external identifier plus
/// the occurrence start, so recurring events resolve to the right day.
enum CalendarEventID {
    private static let separator = "|"

    static func make(externalID: String, occurrence: Date) -> String {
        externalID + separator + ISO8601DateFormatter().string(from: occurrence)
    }

    static func parse(_ id: String) -> (externalID: String, occurrence: Date)? {
        guard let r = id.range(of: separator, options: .backwards),
              let date = ISO8601DateFormatter().date(from: String(id[r.upperBound...])) else { return nil }
        return (String(id[..<r.lowerBound]), date)
    }
}

/// Picks the event a recording belongs to. Pure, so it can be tested without EventKit.
enum CalendarMatcher {
    /// A recording started this early still belongs to the event.
    static let earlyStart: TimeInterval = 15 * 60
    /// The menu bar shows "Up next" this long before an event.
    static let upNextLead: TimeInterval = 10 * 60

    static func best(from candidates: [CalendarCandidate], at date: Date, callApp: String?) -> CalendarCandidate? {
        let eligible = candidates.filter { isEligible($0, at: date) }
        // All-day events, declined ones and solo blocks ("Focus time") only
        // count when nothing better is around.
        let preferred = eligible.filter(isRealMeeting)
        let pool = preferred.isEmpty ? eligible : preferred
        let service = service(forCallApp: callApp)
        return pool.max { a, b in
            let sa = score(a, at: date, service: service), sb = score(b, at: date, service: service)
            if sa != sb { return sa < sb }
            // Ties go to the closest start.
            return abs(a.start.timeIntervalSince(date)) > abs(b.start.timeIntervalSince(date))
        }
    }

    /// Ongoing, or starting within 15 minutes.
    static func isEligible(_ c: CalendarCandidate, at date: Date) -> Bool {
        c.end > date && c.start <= date.addingTimeInterval(earlyStart)
    }

    static func isRealMeeting(_ c: CalendarCandidate) -> Bool {
        !c.isAllDay && c.myStatus != .declined && c.attendeeCount > 0
    }

    static func score(_ c: CalendarCandidate, at date: Date, service: MeetingLink.Service?) -> Int {
        var s = c.start <= date ? 100 : 50
        if let service, c.urls.contains(where: { MeetingLink.service(of: $0) == service }) { s += 40 }
        s += min(c.attendeeCount, 10)
        switch c.myStatus {
        case .accepted: s += 10
        case .unknown: s += 8
        case .pending: s += 6
        case .tentative: s += 4
        case .declined: s -= 60
        }
        if c.isAllDay { s -= 80 }
        if c.attendeeCount == 0 { s -= 20 }
        return s
    }

    /// The meeting service a call app uses, from R1-2's app name.
    static func service(forCallApp app: String?) -> MeetingLink.Service? {
        guard let app = app?.lowercased() else { return nil }
        if app.contains("teams") { return .teams }
        if app.contains("zoom") { return .zoom }
        if app.contains("webex") { return .webex }
        // A call in a browser is most likely Google Meet.
        let browsers = ["chrome", "safari", "firefox", "edge", "arc", "brave", "browser"]
        if browsers.contains(where: app.contains) { return .meet }
        return nil
    }

    /// The event for the menu bar's "Up next" row: a real meeting that is in
    /// progress or starts within 10 minutes, the one starting closest to now.
    static func upNext(from candidates: [CalendarCandidate], at date: Date) -> CalendarCandidate? {
        candidates
            .filter { isRealMeeting($0) && $0.end > date && $0.start <= date.addingTimeInterval(upNextLead) }
            .min { abs($0.start.timeIntervalSince(date)) < abs($1.start.timeIntervalSince(date)) }
    }

    /// "in 4 min" or "now".
    static func startText(_ c: CalendarCandidate, at date: Date) -> String {
        let minutes = Int((c.start.timeIntervalSince(date) / 60).rounded(.up))
        return minutes <= 0 ? "now" : "in \(minutes) min"
    }
}

/// Finds video meeting links in an event's URL, location and notes.
enum MeetingLink {
    enum Service { case teams, zoom, meet, webex }

    private static let hosts = [#"teams\.microsoft\.com"#, #"teams\.live\.com"#, #"zoom\.us/j"#,
                                #"meet\.google\.com"#, #"webex\.com"#]
    private static let regex = try! NSRegularExpression(
        pattern: #"(?:https?://)?(?:[A-Za-z0-9-]+\.)*(?:"# + hosts.joined(separator: "|") + #")[^\s<>"'\])]*"#,
        options: .caseInsensitive)
    private static let safeLinkRegex = try! NSRegularExpression(
        pattern: #"https?://[A-Za-z0-9.-]*safelinks\.protection\.outlook\.com/[^\s<>"']*"#, options: .caseInsensitive)

    /// Links in the order the fields are given, without duplicates.
    static func find(in fields: [String?]) -> [String] {
        var found: [String] = []
        for field in fields.compactMap({ $0 }) {
            let text = unwrapSafeLinks(field)
            let ns = text as NSString
            for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                var link = ns.substring(with: m.range).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
                if !link.lowercased().hasPrefix("http") { link = "https://" + link }
                if !found.contains(link) { found.append(link) }
            }
        }
        return found
    }

    static func service(of link: String) -> Service? {
        let l = link.lowercased()
        if l.contains("teams.microsoft.com") || l.contains("teams.live.com") { return .teams }
        if l.contains("zoom.us/j") { return .zoom }
        if l.contains("meet.google.com") { return .meet }
        if l.contains("webex.com") { return .webex }
        return nil
    }

    /// Outlook often wraps links as Safe Links, with the real URL percent-encoded
    /// in the `url` parameter.
    private static func unwrapSafeLinks(_ text: String) -> String {
        let ns = text as NSString
        var out = text
        for m in safeLinkRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let wrapped = ns.substring(with: m.range)
            guard let inner = URLComponents(string: wrapped)?.queryItems?.first(where: { $0.name == "url" })?.value,
                  let range = Range(m.range, in: out) else { continue }
            out.replaceSubrange(range, with: inner)
        }
        return out
    }
}

/// Readable names for calendar participants.
enum AttendeeName {
    /// The participant's name, or one derived from the email when the name is
    /// missing or is itself an address. `nil` when there's nothing to go on.
    static func display(name: String?, email: String?) -> String? {
        let n = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !n.isEmpty, !n.contains("@") { return unflipped(n) }
        return fromEmail(n.contains("@") ? n : email ?? "")
    }

    /// "sarah.mueller@x.com" → "Sarah Mueller".
    static func fromEmail(_ email: String) -> String? {
        var local = email.replacingOccurrences(of: "mailto:", with: "", options: [.caseInsensitive, .anchored])
        guard let at = local.firstIndex(of: "@") else { return nil }
        local = String(local[..<at])
        if let plus = local.firstIndex(of: "+") { local = String(local[..<plus]) }
        let parts = local.split(whereSeparator: { ".-_".contains($0) }).filter { !$0.allSatisfy(\.isNumber) }
        guard !parts.isEmpty else { return nil }
        return parts.map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }.joined(separator: " ")
    }

    /// Exchange directories often say "Mueller, Sarah".
    static func unflipped(_ name: String) -> String {
        let parts = name.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return name }
        return "\(parts[1]) \(parts[0])"
    }

    static func firstName(_ name: String) -> String {
        name.split(separator: " ").first.map(String.init) ?? name
    }

    /// The address in a participant's `mailto:` URL.
    static func email(from url: URL?) -> String? {
        guard let url, url.scheme?.lowercased() == "mailto" else { return nil }
        let raw = url.absoluteString.dropFirst("mailto:".count)
        let address = (String(raw).removingPercentEncoding ?? String(raw)).trimmingCharacters(in: .whitespaces)
        return address.contains("@") ? address : nil
    }
}

// MARK: - Summary context

/// What the summarizer is told about the meeting beyond the transcript.
struct SummaryContext {
    var title: String?
    var participants: [String]
    var userName: String?

    /// `nil` when there's nothing to add.
    init?(_ info: MeetingInfo, userName: String? = Prefs.userName) {
        title = info.calendarTitle
        // Q-3: cleaned the same way the Whisper prompt is, so a mailing list
        // or an "-Extern" suffix doesn't reach the notes model as a name.
        participants = WhisperPrompt.cleanedAttendeeNames(info.attendees ?? [])
        self.userName = userName ?? info.attendees?.first(where: \.isMe)?.name
        if title == nil && participants.isEmpty && self.userName == nil { return nil }
    }

    /// One line for the top of the user message.
    var line: String {
        var parts: [String] = []
        if let title { parts.append("Meeting: \(title).") }
        if !participants.isEmpty { parts.append("Participants: \(participants.joined(separator: ", ")).") }
        if let userName { parts.append("'Me' in the transcript is \(userName).") }
        return parts.joined(separator: " ") + "\n\n"
    }
}

// MARK: - EventKit

/// Reads events through EventKit. Never asks for access on its own: the user
/// allows it from Settings.
@MainActor
final class CalendarService: ObservableObject {
    struct CalendarInfo: Identifiable, Hashable {
        let id: String
        let title: String
        let source: String
    }

    @Published private(set) var status = EKEventStore.authorizationStatus(for: .event)
    @Published private(set) var calendars: [CalendarInfo] = []
    /// R2-6: events still to come today and tomorrow (and running ones), for
    /// the "Next meeting" card and the "Up next" row.
    @Published private(set) var upcomingEvents: [CalendarCandidate] = []

    /// An event picked from the "Up next" row, used by the next recording.
    private var chosen: CalendarCandidate?
    private var observer: NSObjectProtocol?
    private lazy var store: EKEventStore = {
        let store = EKEventStore()
        observer = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        return store
    }()

    var isAllowed: Bool { status == .fullAccess }
    /// Allowed and switched on.
    var isActive: Bool { isAllowed && Prefs.calendarEnabled }

    private var timer: Timer?

    init() {
        refresh()
        // Keeps "Up next" current; the query is cheap and only runs when allowed.
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshUpcoming() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// U-0: demo mode shows these instead of reading EventKit.
    private var demo: (events: [CalendarCandidate], calendars: [CalendarInfo])?

    func showDemo(events: [CalendarCandidate], calendars: [CalendarInfo]) {
        demo = (events, calendars)
        refresh()
    }

    func refresh() {
        if let demo { // U-0
            status = .fullAccess
            calendars = demo.calendars
            upcomingEvents = demo.events
            return
        }
        status = EKEventStore.authorizationStatus(for: .event)
        guard isAllowed else {
            calendars = []
            upcomingEvents = []
            return
        }
        calendars = store.calendars(for: .event)
            .map { CalendarInfo(id: $0.calendarIdentifier, title: $0.title, source: $0.source?.title ?? "") }
            .sorted { ($0.source, $0.title) < ($1.source, $1.title) }
        refreshUpcoming()
    }

    /// R2-6: everything the next-meeting logic may pick, until the end of tomorrow.
    func refreshUpcoming() {
        if demo != nil { return } // U-0
        let now = Date()
        let today = Calendar.current.startOfDay(for: now)
        let end = Calendar.current.date(byAdding: .day, value: 2, to: today) ?? today.addingTimeInterval(48 * 3600)
        let events = isActive ? events(from: now.addingTimeInterval(-12 * 3600), to: end).filter { $0.end > now } : []
        if events != upcomingEvents { upcomingEvents = events }
    }

    /// Asks for full access. Only called from Settings, never mid-recording.
    func requestAccess() async -> Bool {
        let granted = (try? await store.requestFullAccessToEvents()) ?? false
        refresh()
        return granted
    }

    // MARK: Queries

    /// Events that could belong to a recording starting at `date`.
    func candidates(around date: Date) -> [CalendarCandidate] {
        events(from: date.addingTimeInterval(-12 * 3600), to: date.addingTimeInterval(CalendarMatcher.earlyStart + 60))
    }

    /// All events on the day of `date`, for the link sheet.
    func events(onDayOf date: Date) -> [CalendarCandidate] {
        let start = Calendar.current.startOfDay(for: date)
        return events(from: start, to: start.addingTimeInterval(24 * 3600))
    }

    /// The event for a recording starting now: the one picked from "Up next"
    /// if it still fits, otherwise the best match.
    func match(at date: Date, callApp: String?) -> CalendarCandidate? {
        guard isActive else { return nil }
        defer { chosen = nil }
        if let chosen, chosen.end > date { return chosen }
        return CalendarMatcher.best(from: candidates(around: date), at: date, callApp: callApp)
    }

    /// Remembers the "Up next" event so the recording started from it links to it.
    func choose(_ event: CalendarCandidate) {
        chosen = event
    }

    /// Your name as the calendar knows it, from the recent events you attend.
    func myName() -> String? {
        guard isAllowed else { return nil }
        let now = Date()
        for event in events(from: now.addingTimeInterval(-14 * 24 * 3600), to: now.addingTimeInterval(7 * 24 * 3600)) {
            if let me = event.attendees.first(where: \.isMe) { return me.name }
        }
        return nil
    }

    private func events(from start: Date, to end: Date) -> [CalendarCandidate] {
        guard isAllowed else { return [] }
        let off = Prefs.calendarsOff
        let cals = store.calendars(for: .event).filter { !off.contains($0.calendarIdentifier) }
        guard !cals.isEmpty else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: cals)
        return store.events(matching: predicate).map(Self.candidate).sorted { $0.start < $1.start }
    }

    private static func candidate(_ e: EKEvent) -> CalendarCandidate {
        var attendees: [Attendee] = []
        var myStatus = CalendarCandidate.Response.unknown
        for p in e.attendees ?? [] where p.participantType != .room && p.participantType != .resource {
            let email = AttendeeName.email(from: p.url)
            if p.isCurrentUser { myStatus = response(p.participantStatus) }
            guard let name = AttendeeName.display(name: p.name, email: email) else { continue }
            attendees.append(Attendee(name: name, email: email, isMe: p.isCurrentUser))
        }
        var organizer: String?
        if let o = e.organizer {
            let email = AttendeeName.email(from: o.url)
            organizer = AttendeeName.display(name: o.name, email: email)
            // Some servers leave the organizer out of the attendees; they're in the meeting too.
            if let name = organizer, !attendees.isEmpty,
               !attendees.contains(where: { ($0.email != nil && $0.email?.lowercased() == email?.lowercased()) || $0.name == name }) {
                attendees.insert(Attendee(name: name, email: email, isMe: o.isCurrentUser), at: 0)
            }
            if myStatus == .unknown, o.isCurrentUser { myStatus = .accepted }
        }
        if e.status == .canceled { myStatus = .declined }

        let occurrence = e.occurrenceDate ?? e.startDate ?? Date()
        let externalID = e.calendarItemExternalIdentifier ?? e.calendarItemIdentifier
        return CalendarCandidate(
            id: CalendarEventID.make(externalID: externalID, occurrence: occurrence),
            title: e.title?.isEmpty == false ? e.title : "Untitled event",
            start: e.startDate, end: e.endDate, isAllDay: e.isAllDay,
            attendeeCount: attendees.filter { !$0.isMe }.count,
            myStatus: myStatus,
            urls: MeetingLink.find(in: [e.url?.absoluteString, e.location, e.notes]),
            organizer: organizer, attendees: attendees, calendarName: e.calendar?.title)
    }

    private static func response(_ status: EKParticipantStatus) -> CalendarCandidate.Response {
        switch status {
        case .accepted, .completed, .delegated: return .accepted
        case .tentative: return .tentative
        case .pending, .inProcess: return .pending
        case .declined: return .declined
        default: return .unknown
        }
    }

    // MARK: Calendar app

    /// Shows the event in Calendar, or just opens Calendar if it's gone.
    func openInCalendar(eventID: String) {
        if isAllowed, let parsed = CalendarEventID.parse(eventID) {
            let day = parsed.occurrence
            let predicate = store.predicateForEvents(
                withStart: day.addingTimeInterval(-24 * 3600), end: day.addingTimeInterval(24 * 3600), calendars: nil)
            let event = store.events(matching: predicate).first {
                ($0.calendarItemExternalIdentifier ?? $0.calendarItemIdentifier) == parsed.externalID
                    && abs(($0.occurrenceDate ?? $0.startDate).timeIntervalSince(day)) < 1
            }
            if let event, let id = event.eventIdentifier {
                let f = DateFormatter()
                f.locale = Locale(identifier: "en_US_POSIX")
                f.timeZone = TimeZone(identifier: "UTC")
                f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
                // Recurring events need the occurrence in the path to open the right day.
                let path = event.hasRecurrenceRules ? "\(f.string(from: day))/\(id)" : id
                if let url = URL(string: "ical://ekevent/\(path)?method=show&options=more"),
                   NSWorkspace.shared.open(url) { return }
            }
        }
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
            NSWorkspace.shared.openApplication(at: app, configuration: .init())
        }
    }
}

// MARK: - Linking meetings

extension AppState {
    /// Right after capture starts: link the recording to the event it's part of.
    func autoLinkCalendarEvent(_ id: String) {
        guard let info = meeting(id)?.info,
              let event = calendar.match(at: info.startedAt, callApp: info.callApp) else { return }
        linkCalendarEvent(id, to: event)
    }

    func linkCalendarEvent(_ id: String, to event: CalendarCandidate) {
        changeInfo(id) { info in
            // Take the event's title unless the user or the summary named the meeting.
            if info.titleIsDefault || info.title == info.calendarTitle {
                info.title = event.title
                info.titleIsDefault = false
            }
            info.calendarEventID = event.id
            info.calendarTitle = event.title
            info.calendarStart = event.start
            info.calendarEnd = event.end
            info.organizer = event.organizer
            info.attendees = event.attendees.isEmpty ? nil : event.attendees
            info.meetingURL = event.urls.first
        }
        if Prefs.userName == nil, let me = event.attendees.first(where: \.isMe) {
            Prefs.userName = me.name
        }
    }

    func unlinkCalendarEvent(_ id: String) {
        changeInfo(id) { info in
            if info.title == info.calendarTitle {
                info.title = MeetingInfo.defaultTitle(info.startedAt)
                info.titleIsDefault = true
            }
            info.calendarEventID = nil
            info.calendarTitle = nil
            info.calendarStart = nil
            info.calendarEnd = nil
            info.organizer = nil
            info.attendees = nil
            info.meetingURL = nil
        }
    }

    /// Records the "Up next" event.
    func record(_ event: CalendarCandidate) {
        calendar.choose(event)
        startRecording()
    }

    private func changeInfo(_ id: String, _ change: (inout MeetingInfo) -> Void) {
        guard var m = store.load(Prefs.storageURL.appendingPathComponent(id)) else { return }
        change(&m.info)
        try? store.save(m.info, in: m.folder)
        if m.info.status != .recording { store.saveMarkdown(m) }
        reload()
    }
}

extension MeetingInfo {
    /// The title `MeetingStore.create` gives a new meeting.
    static func defaultTitle(_ startedAt: Date) -> String {
        "Meeting \(startedAt.formatted(date: .abbreviated, time: .shortened))"
    }
}

// MARK: - Views

/// "Up next: Sprint Planning · in 4 min" in the menu bar panel. R2-6: the same
/// meeting as the sidebar card, whenever there's one left today; compact when
/// it's more than 10 minutes away.
struct UpNextRow: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var calendar: CalendarService
    @ObservedObject var armed: ArmedRecorder

    var body: some View {
        TimelineView(.everyMinute) { context in
            let now = context.date
            let recorded = Set(state.meetings.compactMap(\.info.calendarEventID))
            if calendar.isActive,
               let event = CalendarMatcher.nextMeeting(from: calendar.upcomingEvents, at: now, excluding: recorded),
               Calendar.current.isDate(event.start, inSameDayAs: now) || event.start <= now {
                let compact = event.start.timeIntervalSince(now) > CalendarMatcher.upNextLead
                let isArmed = armed.isArmed(event)
                HStack(spacing: 10) {
                    Image(systemName: isArmed ? "alarm.fill" : "calendar")
                        .font(compact ? .body : .title3)
                        .foregroundStyle(Paper.ink)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(compact ? event.title : "Up next: \(event.title)")
                            .font(compact ? .settingsRow : .settingsRowTitle)
                            .lineLimit(1)
                        Group {
                            if isArmed {
                                ArmedLabel(start: event.start)
                            } else if compact {
                                Text("\(CalendarMatcher.clock(event.start)) · \(CalendarMatcher.relativeText(event, at: now))")
                            } else {
                                Text("\(CalendarMatcher.relativeText(event, at: now)) · \(event.attendeeCount + 1) people")
                            }
                        }
                        .font(.settingsNote)
                        .foregroundStyle(Paper.inkMuted)
                    }
                    Spacer(minLength: 0)
                    EventRecordButton(armed: armed, event: event, now: now, controlSize: compact ? .small : .regular)
                }
                .surface(padding: compact ? 8 : 12, radius: 12)
            }
        }
        .task { calendar.refreshUpcoming() }
    }
}

/// The "Calendar event" card in a meeting's Details tab.
struct CalendarEventCard: View {
    @EnvironmentObject private var state: AppState
    let meeting: Meeting

    @State private var pastingInvite = false // R3-4

    var body: some View {
        let info = meeting.info
        Group {
            if let eventID = info.calendarEventID {
                Card(title: "Calendar event", subtitle: "As it was when the meeting was linked.") {
                    eventDetails(info)
                    SettingsRule()
                    HStack {
                        Spacer()
                        Button("Unlink") { state.unlinkCalendarEvent(meeting.id) }
                        Button("Open in Calendar") { state.calendar.openInCalendar(eventID: eventID) }
                    }
                    .buttonStyle(.paperSecondary)
                }
            } else if info.hasPastedInvite { // R3-4
                Card(title: "Invite", subtitle: "Pasted by you.") {
                    eventDetails(info)
                    SettingsRule()
                    HStack {
                        Spacer()
                        Button("Remove") { state.unlinkCalendarEvent(meeting.id) }
                        Button("Paste Invite…") { pastingInvite = true }
                    }
                    .buttonStyle(.paperSecondary)
                }
            } else { // R3-4
                Card(title: "Calendar event",
                     subtitle: "Not linked to an event. If no calendar on this Mac knows the meeting, paste the invite.") {
                    HStack {
                        Spacer()
                        Button("Paste Invite…") { pastingInvite = true }
                            .buttonStyle(.paperSecondary)
                    }
                }
            }
        }
        .sheet(isPresented: $pastingInvite) { PasteInviteSheet(meeting: meeting) }
    }

    private func eventDetails(_ info: MeetingInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            InfoRow("Event", info.calendarTitle ?? "Untitled event")
            if let start = info.calendarStart, let end = info.calendarEnd {
                InfoRow("Time", "\(start.formatted(date: .abbreviated, time: .shortened)) – \(end.formatted(date: .omitted, time: .shortened))")
            }
            if let organizer = info.organizer { InfoRow("Organizer", organizer) }
            if let attendees = info.attendees, !attendees.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("Attendees")
                        .foregroundStyle(Paper.inkMuted)
                        .frame(width: 120, alignment: .leading)
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(attendees, id: \.self) { a in
                            HStack(spacing: 6) {
                                Text(a.name)
                                if a.isMe { Text("You").font(.paperLabel).foregroundStyle(Paper.youText) }
                            }
                            .help(a.email ?? "")
                        }
                    }
                    .textSelection(.enabled)
                }
                .font(.settingsRow)
            }
            if let link = info.meetingURL, let url = URL(string: link) {
                InfoRow(label: "Meeting link", value: link) {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                    }
                    .buttonStyle(.borderless)
                    .help("Open the meeting link")
                }
                .lineLimit(1)
                .truncationMode(.middle)
            }
        }
    }
}

/// Picks the calendar event a meeting belongs to, to fix a wrong or missing match.
struct CalendarLinkSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var calendar: CalendarService
    let meeting: Meeting

    @State private var events: [CalendarCandidate] = []
    @State private var selected: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Link Calendar Event").font(.paperTitle)
                Text("Events on \(meeting.info.startedAt.formatted(date: .complete, time: .omitted)), closest to when the recording started.")
                    .font(.settingsRow)
                    .foregroundStyle(Paper.inkMuted)
            }

            if !calendar.isAllowed {
                StatusLabel(kind: .attention, text: "Earl can't read your calendar. Allow access under the hood.")
                    .font(.settingsRow)
            } else if events.isEmpty {
                Text("No events that day. A rare meeting-free day.")
                    .foregroundStyle(Paper.inkMuted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(events) { event in
                            Button { selected = event.id } label: { row(event) }
                                .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 320)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.paperSecondary)
                    .keyboardShortcut(.cancelAction)
                Button("Link") {
                    if let event = events.first(where: { $0.id == selected }) {
                        state.linkCalendarEvent(meeting.id, to: event)
                    }
                    dismiss()
                }
                .buttonStyle(.paperPrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(selected == nil || selected == meeting.info.calendarEventID)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            let start = meeting.info.startedAt
            events = calendar.events(onDayOf: start).sorted {
                abs($0.start.timeIntervalSince(start)) < abs($1.start.timeIntervalSince(start))
            }
            selected = meeting.info.calendarEventID
        }
    }

    private func row(_ event: CalendarCandidate) -> some View {
        ListRow(selected: selected == event.id) {
            RadioMark(selected: selected == event.id)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title).lineLimit(1)
                Text(details(event))
                    .font(.settingsNote)
                    .foregroundStyle(Paper.inkMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private func details(_ event: CalendarCandidate) -> String {
        var parts = [event.isAllDay ? "All day" : event.timeText]
        if event.attendeeCount > 0 { parts.append("\(event.attendeeCount + 1) people") }
        if event.myStatus == .declined { parts.append("Declined") }
        if let cal = event.calendarName { parts.append(cal) }
        return parts.joined(separator: " · ")
    }
}

/// The Calendar card under the hood.
struct CalendarSettings: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        CalendarCard(calendar: state.calendar)
    }
}

private struct CalendarCard: View {
    @ObservedObject var calendar: CalendarService

    @AppStorage(Prefs.Key.calendarEnabled, store: Prefs.defaults) private var enabled = true
    @AppStorage(Prefs.Key.calendarsOff, store: Prefs.defaults) private var calendarsOff = ""
    @AppStorage(Prefs.Key.userName, store: Prefs.defaults) private var userName = ""

    var body: some View {
        Card(title: "Calendar",
             subtitle: "Earl names recordings after the calendar event and learns who was invited. It reads your calendar on this Mac only.") {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Calendar access").font(.settingsRowTitle)
                    Text("Read through Apple Calendar").font(.settingsNote).foregroundStyle(Paper.inkMuted)
                }
                Spacer()
                permission
            }

            Toggle("Use my calendar", isOn: useBinding)
                .font(.settingsRow)

            if calendar.isAllowed && enabled && !calendar.calendars.isEmpty {
                SettingsRule()
                Text("Calendars to use").font(.settingsRowTitle)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(calendar.calendars) { cal in
                        Toggle(isOn: binding(for: cal)) {
                            HStack(spacing: 6) {
                                Text(cal.title)
                                if !cal.source.isEmpty { Text(cal.source).foregroundStyle(Paper.inkMuted) }
                            }
                        }
                    }
                }
                .font(.settingsRow)
            }

            SettingsRule()

            HStack {
                Text("Your name").font(.settingsRow)
                Spacer()
                TextField("Your name", text: $userName, prompt: Text("As people call you in meetings"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
            }
            Text("Used in summaries instead of “Me”.")
                .font(.settingsNote)
                .foregroundStyle(Paper.inkMuted)

            SettingsRule()

            Text("Work calendar missing? Add your Microsoft or Google account in System Settings → Internet Accounts.")
                .font(.settingsNote)
                .foregroundStyle(Paper.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Internet Accounts") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension")!)
            }
            .buttonStyle(.paperSecondary)
        }
        .onAppear {
            calendar.refresh()
            prefillName()
        }
        .onChange(of: calendar.status) { _, _ in prefillName() }
    }

    @ViewBuilder
    private var permission: some View {
        switch calendar.status {
        case .fullAccess:
            StatusLabel(kind: .ok, text: "Allowed").font(.settingsRow)
        case .notDetermined:
            StatusLabel(kind: .idle, text: "Not asked yet").font(.settingsRow)
            Button("Allow Access") { Task { await allow() } }
                .buttonStyle(.paperSecondary)
        default:
            StatusLabel(kind: .attention, text: calendar.status == .writeOnly ? "Can only add events" : "Not allowed")
                .font(.settingsRow)
            Button("Open Settings") { openPrivacyPane() }
                .buttonStyle(.paperSecondary)
        }
    }

    /// Shows on only when it can work. Turning it on asks for access the first time.
    private var useBinding: Binding<Bool> {
        Binding(
            get: { enabled && calendar.isAllowed },
            set: { on in
                enabled = on
                guard on, !calendar.isAllowed else { calendar.refreshUpcoming(); return }
                if calendar.status == .notDetermined {
                    Task { await allow() }
                } else {
                    openPrivacyPane()
                }
            })
    }

    private func allow() async {
        if await calendar.requestAccess() { enabled = true }
    }

    private func openPrivacyPane() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    private func prefillName() {
        guard userName.trimmingCharacters(in: .whitespaces).isEmpty, let name = calendar.myName() else { return }
        userName = name
    }

    private func binding(for cal: CalendarService.CalendarInfo) -> Binding<Bool> {
        Binding(
            get: { !CallApps.parseOff(calendarsOff).contains(cal.id) },
            set: { on in
                var off = CallApps.parseOff(calendarsOff)
                if on { off.remove(cal.id) } else { off.insert(cal.id) }
                calendarsOff = off.sorted().joined(separator: ",")
                calendar.refreshUpcoming()
            })
    }
}
