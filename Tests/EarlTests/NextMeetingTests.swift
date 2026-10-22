import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Earl

struct NextMeetingTests {
    static var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    let cal = Self.utc
    /// Midnight UTC, 15 Jan 2027.
    let day = Date(timeIntervalSince1970: 1_800_000_000 - 1_800_000_000.truncatingRemainder(dividingBy: 86400))
    func at(_ hours: Double) -> Date { day.addingTimeInterval(hours * 3600) }

    func event(_ id: String, _ start: Double, _ end: Double, people: Int = 3,
               status: CalendarCandidate.Response = .accepted, allDay: Bool = false) -> CalendarCandidate {
        CalendarCandidate(id: id, title: id, start: at(start), end: at(end), isAllDay: allDay,
                          attendeeCount: people, myStatus: status, urls: [], organizer: nil,
                          attendees: [], calendarName: nil)
    }

    func next(_ events: [CalendarCandidate], _ hour: Double, excluding: Set<String> = []) -> String? {
        CalendarMatcher.nextMeeting(from: events, at: at(hour), excluding: excluding, calendar: cal)?.id
    }

    @Test func laterToday() {
        let events = [event("done", 8, 9), event("planning", 14, 15), event("retro", 16, 17)]
        #expect(next(events, 10) == "planning")
        #expect(next(events, 15.5) == "retro")
    }

    @Test func ongoingCountsAsNow() {
        let events = [event("standup", 9.9, 10.25), event("planning", 14, 15)]
        #expect(next(events, 10) == "standup")
        #expect(CalendarMatcher.relativeText(events[0], at: at(10), calendar: cal) == "now")
        // An all-morning workshop gives way to a meeting starting sooner than it started.
        let long = [event("workshop", 8, 12), event("sync", 10.25, 10.5)]
        #expect(next(long, 10) == "sync")
    }

    @Test func tomorrowWhenTodayIsDone() {
        let events = [event("today", 9, 10), event("tomorrow-late", 24 + 15, 24 + 16),
                      event("tomorrow-early", 24 + 9, 24 + 10), event("day-after", 48 + 9, 48 + 10)]
        #expect(next(events, 18) == "tomorrow-early")
        #expect(CalendarMatcher.relativeText(event("t", 24 + 9, 24 + 10), at: at(18), calendar: cal) == "tomorrow")
        // Nothing today or tomorrow: nothing, not the day after.
        #expect(next([event("day-after", 48 + 9, 48 + 10)], 18) == nil)
    }

    @Test func skipsDeclinedAllDaySoloAndRecorded() {
        let events = [event("declined", 11, 12, status: .declined),
                      event("holiday", 0, 24, people: 0, allDay: true),
                      event("offsite", 0, 24, allDay: true),
                      event("focus", 11, 13, people: 0),
                      event("recorded", 11, 12),
                      event("real", 13, 14)]
        #expect(next(events, 10, excluding: ["recorded"]) == "real")
        #expect(next(events, 10) == "recorded")
        #expect(next([event("declined", 11, 12, status: .declined)], 10) == nil)
    }

    @Test func relativeText() {
        let e = event("e", 12, 13)
        #expect(CalendarMatcher.relativeText(e, at: at(11.75), calendar: cal) == "in 15 min")
        #expect(CalendarMatcher.relativeText(e, at: at(11), calendar: cal) == "in 1 h")
        #expect(CalendarMatcher.relativeText(e, at: at(10.5), calendar: cal) == "in 1 h 30 min")
        #expect(CalendarMatcher.relativeText(e, at: at(12), calendar: cal) == "now")
        #expect(CalendarMatcher.leftText(e, at: at(12.5)) == "30 min left")
        #expect(CalendarMatcher.leftText(event("w", 9, 13), at: at(10.5)) == "2 h 30 min left")
    }

    @Test func attendeeLine() {
        func p(_ n: String, me: Bool = false) -> Attendee { Attendee(name: n, email: nil, isMe: me) }
        #expect(AttendeeName.line([p("Alex Me", me: true)]) == nil)
        #expect(AttendeeName.line([p("Sarah Lee"), p("Alex", me: true)]) == "with Sarah")
        #expect(AttendeeName.line([p("Sarah"), p("Tom"), p("Ana"), p("Bo"), p("Cy")]) == "with Sarah, Tom and 3 others")
    }
}

// MARK: - Arming

struct ArmingRulesTests {
    /// Far enough in the future that the recorder's real timer never fires during a test.
    let t0 = Date().addingTimeInterval(30 * 86400).rounded()
    func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

    func event(_ id: String = "planning", from start: Double = 0, to end: Double = 60) -> CalendarCandidate {
        CalendarCandidate(id: id, title: "Sprint Planning", start: at(start), end: at(end), isAllDay: false,
                          attendeeCount: 2, myStatus: .accepted, urls: ["https://teams.microsoft.com/l/x"],
                          organizer: "Sarah",
                          attendees: [Attendee(name: "Sarah", email: "s@x.com", isMe: false),
                                      Attendee(name: "Alex", email: nil, isMe: true),
                                      Attendee(name: "Tom", email: nil, isMe: false)],
                          calendarName: "Work")
    }

    @Test func rules() {
        let armed = ArmedRecording(event())
        #expect(ArmingRules.action(for: armed, at: at(-10)) == .wait(until: at(0)))
        #expect(ArmingRules.action(for: armed, at: at(0)) == .start)
        #expect(ArmingRules.action(for: armed, at: at(0.9)) == .start)
        // Woke up after the start: record only while the event runs, and say so.
        #expect(ArmingRules.action(for: armed, at: at(20)) == .startLate)
        #expect(ArmingRules.action(for: armed, at: at(60)) == .missed)
    }

    @Test func callWindow() {
        let armed = ArmedRecording(event())
        #expect(!ArmingRules.startsOnCall(armed, at: at(-2.1)))
        #expect(ArmingRules.startsOnCall(armed, at: at(-2)))
        #expect(ArmingRules.startsOnCall(armed, at: at(-0.5)))
        #expect(!ArmingRules.startsOnCall(armed, at: at(60)))
        // A recording by hand up to 15 minutes early belongs to the event.
        #expect(ArmingRules.claims(armed, recordingAt: at(-14)))
        #expect(!ArmingRules.claims(armed, recordingAt: at(-16)))
    }

    @Test func candidateRoundTrip() throws {
        let original = event()
        let armed = ArmedRecording(original)
        let decoded = try JSONDecoder().decode(ArmedRecording.self, from: JSONEncoder().encode(armed))
        #expect(decoded == armed)
        let back = decoded.candidate
        #expect(back.id == original.id && back.title == original.title)
        #expect(back.start == original.start && back.end == original.end)
        #expect(back.attendees == original.attendees && back.attendeeCount == 2)
        #expect(back.urls == original.urls && back.organizer == "Sarah")
    }
}

@MainActor
struct ArmedRecorderTests {
    /// An in-memory stand-in for UserDefaults.
    final class Box { var data: Data? }

    let t0 = Date().addingTimeInterval(30 * 86400).rounded()
    func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

    func event(_ id: String, from start: Double = 0, to end: Double = 60) -> CalendarCandidate {
        CalendarCandidate(id: id, title: id, start: at(start), end: at(end), isAllDay: false,
                          attendeeCount: 1, myStatus: .accepted, urls: [], organizer: nil,
                          attendees: [Attendee(name: "Sarah", email: nil, isMe: false)], calendarName: nil)
    }

    func recorder(_ box: Box) -> ArmedRecorder {
        ArmedRecorder(storage: .init(read: { box.data }, write: { box.data = $0 }))
    }

    @Test func survivesRelaunch() {
        let box = Box()
        let first = recorder(box)
        first.arm(event("planning"), now: at(-30))
        #expect(box.data != nil)
        let second = recorder(box)
        #expect(second.armed?.eventID == "planning")
        #expect(second.isArmed(event("planning")))
        second.cancel()
        #expect(box.data == nil)
        #expect(recorder(box).armed == nil)
    }

    @Test func armingReplaces() {
        let box = Box()
        let r = recorder(box)
        r.arm(event("planning"), now: at(-30))
        r.arm(event("retro", from: 120, to: 150), now: at(-30))
        #expect(r.armed?.eventID == "retro")
        #expect(!r.isArmed(event("planning")))
        #expect(recorder(box).armed?.eventID == "retro")
    }

    @Test func startsOnTime() {
        let r = recorder(Box())
        var started: [(String, Bool)] = []
        r.onStart = { started.append(($0.eventID, $1)) }
        r.arm(event("planning"), now: at(-30))
        #expect(r.evaluate(at: at(-1)) == .wait(until: at(0)))
        #expect(started.isEmpty)
        #expect(r.evaluate(at: at(0)) == .start)
        #expect(started.count == 1 && started[0].0 == "planning" && started[0].1 == false)
        #expect(r.armed == nil)
        // Only once.
        #expect(r.evaluate(at: at(1)) == nil)
        #expect(started.count == 1)
    }

    @Test func wakeAfterStartWhileRunning() {
        let box = Box()
        recorder(box).arm(event("planning"), now: at(-30))
        // Relaunched (or woken) 20 minutes into the meeting.
        let r = recorder(box)
        var late: Bool?
        r.onStart = { _, l in late = l }
        #expect(r.evaluate(at: at(20)) == .startLate)
        #expect(late == true)
        #expect(box.data == nil)
    }

    @Test func wakeAfterTheEventEnded() {
        let box = Box()
        recorder(box).arm(event("planning"), now: at(-30))
        let r = recorder(box)
        var started = false
        var missed: String?
        r.onStart = { _, _ in started = true }
        r.onMissed = { missed = $0.eventID }
        #expect(r.evaluate(at: at(61)) == .missed)
        #expect(!started)
        #expect(missed == "planning")
        #expect(r.armed == nil)
    }

    @Test func earlyStartOnCall() {
        let r = recorder(Box())
        var started: String?
        r.onStart = { a, _ in started = a.eventID }
        r.arm(event("planning"), now: at(-30))
        // A call 5 minutes early doesn't count.
        #expect(!r.callDetected(at: at(-5)))
        #expect(started == nil)
        // One within 2 minutes of the start does.
        #expect(r.callDetected(at: at(-1.5)))
        #expect(started == "planning")
        #expect(r.armed == nil)
        #expect(!r.callDetected(at: at(-1)))
    }

    @Test func manualRecordingClaimsTheEvent() {
        let r = recorder(Box())
        r.arm(event("planning"), now: at(-60))
        #expect(r.claim(recordingAt: at(-20)) == nil)
        #expect(r.armed != nil)
        #expect(r.claim(recordingAt: at(-3))?.eventID == "planning")
        #expect(r.armed == nil)
    }

    @Test func armingAnOngoingEventStartsRightAway() {
        let r = recorder(Box())
        var started = false
        r.onStart = { _, _ in started = true }
        r.arm(event("planning"), now: at(0.5))
        #expect(started)
        #expect(r.armed == nil)
    }
}

private extension Date {
    func rounded() -> Date { Date(timeIntervalSince1970: timeIntervalSince1970.rounded()) }
}

// MARK: - Rendering

/// R2-6: renders the sidebar card and the floating panel to PNGs for
/// reviewing the look. Only runs with EARL_R26_PNG set to an output folder:
///
///     EARL_R26_PNG=/tmp/earl-r26 ./test.sh --filter NextMeetingRenderTests
@MainActor
struct NextMeetingRenderTests {
    nonisolated static let out = ProcessInfo.processInfo.environment["EARL_R26_PNG"]

    let now: Date = {
        var c = Calendar.current
        c.timeZone = .current
        return c.date(bySettingHour: 13, minute: 35, second: 0, of: Date()) ?? Date()
    }()

    func event(start: Double, end: Double) -> CalendarCandidate {
        let people = ["Sarah Lee", "Tom Baker", "Ana Ruiz", "Bo Chen", "Cy Park"].map {
            Attendee(name: $0, email: nil, isMe: false)
        } + [Attendee(name: "Alex", email: nil, isMe: true)]
        return CalendarCandidate(id: "e", title: "Sprint Planning", start: now.addingTimeInterval(start * 60),
                                 end: now.addingTimeInterval(end * 60), isAllDay: false, attendeeCount: 5,
                                 myStatus: .accepted, urls: [], organizer: "Sarah Lee", attendees: people,
                                 calendarName: "Work")
    }

    private func save(_ view: some View, _ scheme: ColorScheme, to url: URL) throws {
        let bg = scheme == .dark ? Color(white: 0.17) : Color(white: 0.95)
        let renderer = ImageRenderer(content: view.padding(16).background(bg).environment(\.colorScheme, scheme))
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        let rep = NSBitmapImageRep(cgImage: image)
        try #require(rep.representation(using: .png, properties: [:])).write(to: url)
    }

    private func sidebar(_ content: NextMeetingCardView.Content, armed: Bool = false) -> some View {
        NextMeetingCardView(content: content, now: now, isArmed: { _ in armed })
            .frame(width: 280)
    }

    @Test(.enabled(if: out != nil, "Set EARL_R26_PNG to render the card and panel"))
    func render() throws {
        let dir = URL(fileURLWithPath: Self.out!)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let upcoming = event(start: 25, end: 85)
        let ongoing = event(start: -5, end: 25)
        let teams = DetectedApp(key: "com.microsoft.teams2", name: "Microsoft Teams",
                                bundleID: "com.microsoft.teams2", pid: -1, callApp: CallApps.all[0])
        let views: [(String, AnyView)] = [
            ("card-upcoming", AnyView(sidebar(.event(upcoming)))),
            ("card-armed", AnyView(sidebar(.event(upcoming), armed: true))),
            ("card-now", AnyView(sidebar(.event(ongoing)))),
            ("card-empty", AnyView(sidebar(.empty))),
            ("card-connect", AnyView(sidebar(.connect))),
            ("panel-call-offer", AnyView(OfferPanelView(item: .callOffer(teams)))),
            ("panel-stop-offer", AnyView(OfferPanelView(item: .stopOffer(teams)))),
            ("panel-confirmation", AnyView(OfferPanelView(
                item: .confirmation(title: "Recording Sprint Planning", body: "Started as planned.", recording: true)))),
            ("menubar-icons", AnyView(HStack(spacing: 24) {
                ForEach([MenuBarIcon.idle, MenuBarIcon.offer, MenuBarIcon.recording], id: \.self) { icon in
                    Image(nsImage: icon).renderingMode(.template).resizable().frame(width: 36, height: 36)
                }
            }.foregroundStyle(.primary).padding(12))),
        ]
        for (name, view) in views {
            for scheme in [ColorScheme.light, .dark] {
                try save(view, scheme, to: dir.appendingPathComponent("\(name)-\(scheme == .dark ? "dark" : "light").png"))
            }
        }
        print("[r2-6] wrote PNGs to \(dir.path)")
    }
}
