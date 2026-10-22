import AppKit
import SwiftUI
import UserNotifications

// R2-6: the next meeting in the sidebar, and recordings armed to start with a
// calendar event. "Record" on an event that's already running starts now;
// "Record at 14:00" on an upcoming one arms it.

// MARK: - Picking the next meeting

extension CalendarMatcher {
    /// The next real meeting (others invited, not declined, not all-day): the
    /// one closest to `date` that's still running or starts later today, or the
    /// first one tomorrow when today is done. Events in `excluding` (already
    /// recorded) are skipped.
    static func nextMeeting(from candidates: [CalendarCandidate], at date: Date,
                            excluding: Set<String> = [], calendar: Calendar = .current) -> CalendarCandidate? {
        let tomorrow = calendar.startOfDay(for: date).addingTimeInterval(24 * 3600)
        guard let dayAfter = calendar.date(byAdding: .day, value: 1, to: tomorrow) else { return nil }
        let real = candidates.filter { isRealMeeting($0) && !excluding.contains($0.id) && $0.end > date }
        let today = real.filter { $0.start < tomorrow }
        if let next = today.min(by: { abs($0.start.timeIntervalSince(date)) < abs($1.start.timeIntervalSince(date)) }) {
            return next
        }
        return real.filter { $0.start >= tomorrow && $0.start < dayAfter }.min { $0.start < $1.start }
    }

    static func isOngoing(_ c: CalendarCandidate, at date: Date) -> Bool {
        c.start <= date && c.end > date
    }

    /// "now", "in 25 min", "in 1 h 20 min", "tomorrow".
    static func relativeText(_ c: CalendarCandidate, at date: Date, calendar: Calendar = .current) -> String {
        if c.start <= date { return "now" }
        if !calendar.isDate(c.start, inSameDayAs: date) { return "tomorrow" }
        let minutes = Int((c.start.timeIntervalSince(date) / 60).rounded(.up))
        if minutes < 60 { return "in \(minutes) min" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "in \(h) h" : "in \(h) h \(m) min"
    }

    /// "25 min left", for a meeting in progress.
    static func leftText(_ c: CalendarCandidate, at date: Date) -> String {
        let minutes = max(1, Int((c.end.timeIntervalSince(date) / 60).rounded(.up)))
        if minutes < 60 { return "\(minutes) min left" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(h) h left" : "\(h) h \(m) min left"
    }

    /// "14:00", in the user's clock style.
    static func clock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}

extension AttendeeName {
    /// "with Sarah, Tom and 3 others", from everyone but you.
    static func line(_ attendees: [Attendee]) -> String? {
        let names = attendees.filter { !$0.isMe }.map { firstName($0.name) }
        switch names.count {
        case 0: return nil
        case 1: return "with \(names[0])"
        case 2: return "with \(names[0]) and \(names[1])"
        case 3: return "with \(names[0]), \(names[1]) and \(names[2])"
        default: return "with \(names[0]), \(names[1]) and \(names.count - 2) others"
        }
    }
}

// MARK: - Armed recordings

/// A recording that starts by itself with a calendar event. Codable, so it
/// survives a relaunch.
struct ArmedRecording: Codable, Equatable {
    var eventID: String
    var title: String
    var start: Date
    var end: Date
    var attendees: [Attendee]
    var organizer: String?
    var urls: [String]
    var calendarName: String?

    init(_ event: CalendarCandidate) {
        eventID = event.id
        title = event.title
        start = event.start
        end = event.end
        attendees = event.attendees
        organizer = event.organizer
        urls = event.urls
        calendarName = event.calendarName
    }

    /// The event again, for linking the recording.
    var candidate: CalendarCandidate {
        CalendarCandidate(id: eventID, title: title, start: start, end: end, isAllDay: false,
                          attendeeCount: attendees.filter { !$0.isMe }.count, myStatus: .accepted,
                          urls: urls, organizer: organizer, attendees: attendees, calendarName: calendarName)
    }
}

/// When an armed recording starts. Pure, so it can be tested without timers.
enum ArmingRules {
    /// A call detected this long before the start begins the recording early.
    static let callWindow: TimeInterval = 2 * 60
    /// Firing later than this means the Mac was asleep (or Earl wasn't running).
    static let lateAfter: TimeInterval = 60

    enum Action: Equatable {
        case wait(until: Date)
        case start
        /// Started after the start time because the Mac was asleep; say so.
        case startLate
        /// The event ended before Earl got the chance.
        case missed
    }

    static func action(for armed: ArmedRecording, at now: Date) -> Action {
        if now >= armed.end { return .missed }
        if now < armed.start { return .wait(until: armed.start) }
        return now.timeIntervalSince(armed.start) > lateAfter ? .startLate : .start
    }

    /// A detected call starts the armed recording early.
    static func startsOnCall(_ armed: ArmedRecording, at now: Date) -> Bool {
        now >= armed.start.addingTimeInterval(-callWindow) && now < armed.end
    }

    /// A recording started by hand this close to the event belongs to it, and
    /// fulfils the armed recording.
    static func claims(_ armed: ArmedRecording, recordingAt now: Date) -> Bool {
        now >= armed.start.addingTimeInterval(-CalendarMatcher.earlyStart) && now < armed.end
    }
}

extension Prefs.Key {
    static let armedRecording = "armedRecording"
}

/// Keeps the one armed recording, persists it, and wakes once at its start
/// time. Never polls.
@MainActor
final class ArmedRecorder: ObservableObject {
    /// Where the armed recording is kept. `standard` uses UserDefaults; tests
    /// pass an in-memory one.
    struct Storage {
        var read: () -> Data?
        var write: (Data?) -> Void

        static let standard = Storage(
            read: { UserDefaults.standard.data(forKey: Prefs.Key.armedRecording) },
            write: { UserDefaults.standard.set($0, forKey: Prefs.Key.armedRecording) })
    }

    @Published private(set) var armed: ArmedRecording?

    /// Called when it's time to record. `late` means the start time passed while the Mac slept.
    var onStart: ((ArmedRecording, _ late: Bool) -> Void)?
    var onMissed: ((ArmedRecording) -> Void)?

    private let storage: Storage
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?

    init(storage: Storage = .standard) {
        self.storage = storage
        armed = storage.read().flatMap { try? JSONDecoder().decode(ArmedRecording.self, from: $0) }
    }

    /// Checks the saved recording (after a launch) and watches for wake.
    func start(now: Date = Date()) {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.evaluate() }
        }
        evaluate(at: now)
    }

    func isArmed(_ event: CalendarCandidate) -> Bool { armed?.eventID == event.id }

    /// Arms `event`, replacing any other armed recording.
    func arm(_ event: CalendarCandidate, now: Date = Date()) {
        set(ArmedRecording(event))
        evaluate(at: now)
    }

    func cancel() {
        set(nil)
    }

    /// Acts on the armed recording if it's due, otherwise sleeps until it is.
    @discardableResult
    func evaluate(at now: Date = Date()) -> ArmingRules.Action? {
        guard let armed else {
            reschedule(nil)
            return nil
        }
        let action = ArmingRules.action(for: armed, at: now)
        switch action {
        case .wait(let until):
            reschedule(until)
        case .start, .startLate:
            set(nil)
            onStart?(armed, action == .startLate)
        case .missed:
            set(nil)
            onMissed?(armed)
        }
        return action
    }

    /// A watched app started a call. Returns true when that started the armed recording.
    func callDetected(at now: Date = Date()) -> Bool {
        guard let armed, ArmingRules.startsOnCall(armed, at: now) else { return false }
        set(nil)
        onStart?(armed, false)
        return true
    }

    /// A recording started some other way. Returns the armed event when the
    /// recording belongs to it, which also disarms it.
    func claim(recordingAt now: Date = Date()) -> ArmedRecording? {
        guard let armed, ArmingRules.claims(armed, recordingAt: now) else { return nil }
        set(nil)
        return armed
    }

    private func set(_ value: ArmedRecording?) {
        armed = value
        storage.write(value.flatMap { try? JSONEncoder().encode($0) })
        if value == nil { reschedule(nil) }
    }

    private func reschedule(_ date: Date?) {
        timer?.invalidate()
        timer = nil
        guard let date else { return }
        let timer = Timer(fire: date, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.evaluate() }
        }
        // Tolerance keeps it cheap; a second late is fine.
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}

// MARK: - Wiring

extension AppState {
    /// Called once from `init`.
    func setUpNextMeeting() {
        armed.onStart = { [weak self] armed, late in self?.startArmed(armed, late: late) }
        armed.onMissed = { armed in
            NextMeetingNotice.post(title: "Didn't record \(armed.title)",
                                   body: "Your Mac was asleep until after it ended.")
        }
        callDetector.claimsCall = { [weak self] _ in
            guard let self, !self.isRecording, !self.isStarting else { return false }
            return self.armed.callDetected()
        }
        callDetector.onAnnounce = { [weak self] title, body, recording in
            self?.offerPanel.confirm(title: title, body: body, recording: recording)
        }
        offerPanel.attach(to: callDetector, calendar: calendar) // U-5: names the meeting in the offer
        armed.start()
    }

    /// "Record" on an ongoing event, or "Record at 14:00" on an upcoming one.
    func recordOrArm(_ event: CalendarCandidate, now: Date = Date()) {
        if CalendarMatcher.isOngoing(event, at: now) {
            if armed.isArmed(event) { armed.cancel() }
            record(event)
        } else {
            armed.arm(event, now: now)
        }
    }

    /// Hook in `startRecording`: a recording that begins near the armed event
    /// belongs to it. Returns true when it linked the meeting.
    func claimArmedRecording(_ id: String) -> Bool {
        guard let armed = armed.claim() else { return false }
        linkCalendarEvent(id, to: armed.candidate)
        return true
    }

    private func startArmed(_ armed: ArmedRecording, late: Bool) {
        // Already recording (by hand, or an accepted offer): that recording wins.
        guard !isRecording, !isStarting else { return }
        record(armed.candidate)
        let title = "Recording \(armed.title)"
        let body = late
            ? "Your Mac was asleep at \(CalendarMatcher.clock(armed.start)), so Earl started now."
            : "Started as planned."
        NextMeetingNotice.post(title: title, body: body)
        offerPanel.confirm(title: title, body: body, recording: true)
    }
}

enum NextMeetingNotice {
    static func post(title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

// MARK: - Views

/// The Record / "Record at 14:00" / armed controls for a calendar event.
struct EventRecordButton: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var armed: ArmedRecorder
    let event: CalendarCandidate
    let now: Date
    var controlSize: ControlSize = .regular

    var body: some View {
        EventRecordControls(event: event, now: now, isArmed: armed.isArmed(event),
                            recordDisabled: state.isRecording || state.isStarting,
                            controlSize: controlSize,
                            onRecord: { state.recordOrArm(event) },
                            onCancel: { armed.cancel() })
    }
}

/// The controls themselves, without app state, so they can be rendered in tests.
struct EventRecordControls: View {
    let event: CalendarCandidate
    let now: Date
    let isArmed: Bool
    var recordDisabled = false
    var controlSize: ControlSize = .regular
    var onRecord: () -> Void = {}
    var onCancel: () -> Void = {}

    var body: some View {
        Group {
            if isArmed {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)
                    .help("Don't record this meeting automatically")
            } else if CalendarMatcher.isOngoing(event, at: now) {
                Button(action: onRecord) { Label("Record", systemImage: "record.circle") }
                    .buttonStyle(.bordered)
                    .disabled(recordDisabled)
                    .help("Start recording now")
            } else {
                Button(action: onRecord) {
                    Label("Record at \(CalendarMatcher.clock(event.start))", systemImage: "alarm")
                }
                .buttonStyle(.bordered)
                .help("Earl starts recording when the meeting starts, or when the call does")
            }
        }
        .controlSize(controlSize)
        .labelStyle(.titleAndIcon)
    }
}

/// "Will record at 14:00", shown under an armed event.
struct ArmedLabel: View {
    let start: Date

    var body: some View {
        Label("Will record at \(CalendarMatcher.clock(start))", systemImage: "alarm.fill")
            .foregroundStyle(Theme.accent)
            .labelStyle(.titleAndIcon)
    }
}

/// Pinned at the top of the Meetings sidebar.
struct NextMeetingCard: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var calendar: CalendarService
    @ObservedObject var armed: ArmedRecorder
    @AppStorage(Prefs.Key.calendarEnabled) private var enabled = true

    var body: some View {
        TimelineView(.everyMinute) { context in
            let now = context.date
            let content = content(at: now)
            NextMeetingCardView(
                content: content, now: now,
                isArmed: { armed.isArmed($0) },
                recordDisabled: state.isRecording || state.isStarting,
                onRecord: { state.recordOrArm($0) },
                onCancel: { armed.cancel() },
                onOpen: { calendar.openInCalendar(eventID: $0.id) },
                onConnect: { state.selection = .engine })
        }
        .task { calendar.refreshUpcoming() }
    }

    private func content(at now: Date) -> NextMeetingCardView.Content {
        guard calendar.isAllowed, enabled else { return .connect }
        let recorded = Set(state.meetings.compactMap(\.info.calendarEventID))
        if let event = CalendarMatcher.nextMeeting(from: calendar.upcomingEvents, at: now, excluding: recorded) {
            return .event(event)
        }
        return .empty
    }
}

/// The card's look, without app state. U-1: the paper next-meeting card, a red
/// "In 10 min" kicker, the title in Georgia, time and people, and a "Record
/// when it starts" switch. Used in the sidebar and the menu bar.
struct NextMeetingCardView: View {
    enum Content { case connect, empty, event(CalendarCandidate) }

    let content: Content
    let now: Date
    var isArmed: (CalendarCandidate) -> Bool = { _ in false }
    var recordDisabled = false
    var onRecord: (CalendarCandidate) -> Void = { _ in }
    var onCancel: () -> Void = {}
    var onOpen: (CalendarCandidate) -> Void = { _ in }
    var onConnect: () -> Void = {}
    /// S-2: the brief line under the time, when the event's series has past
    /// meetings: `.some("2 of yours open")`, or `.some(nil)` for "Brief" alone.
    var briefLine: (CalendarCandidate) -> String?? = { _ in nil }
    var onBrief: (CalendarCandidate) -> Void = { _ in }

    var body: some View {
        Group {
            switch content {
            case .connect: connect
            case .empty: empty
            case .event(let event): card(event)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    private var connect: some View {
        Button(action: onConnect) {
            HStack(spacing: 10) {
                Image(systemName: "calendar.badge.plus")
                    .foregroundStyle(Paper.inkMuted)
                    .frame(width: 20)
                Text("Connect your calendar")
                    .font(.system(size: 14))
                    .foregroundStyle(Paper.inkMuted)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13))
                    .foregroundStyle(Paper.inkMuted.opacity(0.7))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverRowStyle())
        .help("See your next meeting here, and record it on time")
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("No more meetings today").font(.paperTitle(size: 15)).foregroundStyle(Paper.ink)
            Text("Enjoy the quiet.").font(.system(size: 13)).foregroundStyle(Paper.inkMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .paperCard(padding: 12)
    }

    private func card(_ event: CalendarCandidate) -> some View {
        let armed = isArmed(event)
        let ongoing = CalendarMatcher.isOngoing(event, at: now)
        return VStack(alignment: .leading, spacing: 8) {
            Button { onOpen(event) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(kicker(event, ongoing: ongoing))
                        .font(.system(size: 13, weight: .bold).monospacedDigit())
                        .foregroundStyle(Paper.masthead)
                    Text(event.title)
                        .font(.paperTitle(size: 16))
                        .foregroundStyle(Paper.ink)
                        .lineLimit(2)
                    Text(details(event))
                        .font(.system(size: 13))
                        .foregroundStyle(Paper.inkMuted)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open in Calendar")
            if let line = briefLine(event) { BriefCardLink(open: line) { onBrief(event) }.padding(.top, -3) } // S-2

            if ongoing && !armed {
                Button { onRecord(event) } label: { Text("Record") }
                    .buttonStyle(.paperPrimary)
                    .disabled(recordDisabled)
                    .help("Start recording now")
            } else {
                // The switch first, as in the design, then its label.
                HStack(spacing: 8) {
                    Toggle("Record when it starts", isOn: Binding(get: { armed }, set: { $0 ? onRecord(event) : onCancel() }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .tint(Paper.ok)
                    Text("Record when it starts").font(.system(size: 13)).foregroundStyle(Paper.ink)
                }
                .help(armed ? "Earl will record at \(CalendarMatcher.clock(event.start)), or when the call starts"
                            : "Earl starts recording when the meeting starts, or when the call does")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .paperCard(padding: 12)
    }

    /// "In 10 min", "Tomorrow", "Now · 25 min left".
    private func kicker(_ event: CalendarCandidate, ongoing: Bool) -> String {
        if ongoing { return "Now · \(CalendarMatcher.leftText(event, at: now))" }
        let text = CalendarMatcher.relativeText(event, at: now)
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    /// "11:46 – 12:31 · Priya, Jordan and 2 others".
    private func details(_ event: CalendarCandidate) -> String {
        let today = Calendar.current.isDate(event.start, inSameDayAs: now)
        var parts = [today ? event.timeText : "Tomorrow, \(event.timeText)"]
        if let with = AttendeeName.line(event.attendees) {
            parts.append(with.hasPrefix("with ") ? String(with.dropFirst(5)) : with)
        }
        return parts.joined(separator: " · ")
    }
}
