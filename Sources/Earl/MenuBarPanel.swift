import SwiftUI

/// The panel that drops down from the menu bar icon. U-5: warm paper, Earl's
/// greeting, the next meeting, one big Record (or the faces and Stop while
/// recording), the last three meetings, and a linen footer.
struct MenuBarPanel: View {
    static let width: CGFloat = 320

    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var engine: Engine
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                header
                if state.isRecording {
                    recording
                } else {
                    CallOfferBanner(detector: state.callDetector, calendar: state.calendar) // R1-2
                    MenuBarNextMeeting(calendar: state.calendar, armed: state.armed) // R2-1, R2-6
                    recordButton
                }
                jobs
                if !state.isRecording { recent }
            }
            .padding(.horizontal, 14)
            .padding(.top, 16)
            .padding(.bottom, 12)
            footer
        }
        .frame(width: Self.width)
        .background(Paper.paper)
        .task { await state.refreshEngine() }
    }

    // MARK: Header

    @ViewBuilder
    private var header: some View {
        if state.isRecording {
            HStack(spacing: 12) {
                LivePill(elapsed: elapsed)
                Spacer(minLength: 8)
                Text(state.recordingID.flatMap { state.meeting($0)?.info.title } ?? "")
                    .font(.system(size: 14))
                    .foregroundStyle(Paper.inkMuted)
                    .lineLimit(1)
            }
            .padding(.horizontal, 2)
            .padding(.bottom, 2)
        } else {
            HStack(spacing: 12) {
                EarlAvatar(size: 34)
                // Called from the view on purpose: it counts today as a day Earl was seen.
                Text(EarlVoice.greeting(name: Prefs.userName))
                    .font(.earlVoice(size: 21))
                    .foregroundStyle(Paper.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 2)
            .padding(.bottom, 2)
        }
    }

    private var elapsed: TimeInterval {
        guard let start = state.recordingStartedAt else { return 0 }
        return max(0, state.now.timeIntervalSince(start))
    }

    // MARK: Record and Stop

    private var recordButton: some View {
        Button {
            state.startRecording()
        } label: {
            HStack {
                Text(state.isStarting ? "Starting…" : "Record")
                Spacer(minLength: 8)
                MenuBarShortcut(shortcut: state.shortcut) // R1-1
            }
        }
        .buttonStyle(.paperRecord)
        .disabled(state.isStarting)
    }

    private var recording: some View {
        VStack(spacing: 12) {
            // MiniStage draws its own card and caption (U-4).
            MiniStage(stage: state.liveStage) // R2-5
                .frame(maxWidth: .infinity)
            Button {
                state.stopRecording()
            } label: {
                HStack {
                    Text("Stop")
                    Spacer(minLength: 8)
                    MenuBarShortcut(shortcut: state.shortcut)
                }
            }
            .buttonStyle(.paperStop)
        }
    }

    // MARK: Lists

    @ViewBuilder
    private var jobs: some View {
        let jobs = state.jobs.prefix(3)
        if !jobs.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(jobs)) { job in
                    Button { show(.meeting(job.id)) } label: {
                        JobSummaryRow(job: job, title: state.meeting(job.id)?.info.title ?? "Meeting")
                            .padding(.horizontal, 8)
                            .padding(.vertical, 7)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(HoverRowStyle())
                }
            }
            .padding(.top, 2)
        }
    }

    @ViewBuilder
    private var recent: some View {
        let recent = state.meetings.filter { $0.id != state.recordingID && !state.isBusy($0.id) }.prefix(3)
        if !recent.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(recent)) { m in
                    Button {
                        show(.meeting(m.id))
                    } label: {
                        HStack(spacing: 10) {
                            Text(m.info.title)
                                .font(.paperChat)
                                .foregroundStyle(Paper.ink)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(MenuBarFormat.when(m.info.startedAt))
                                .font(.system(size: 13).monospacedDigit())
                                .foregroundStyle(Paper.inkMuted)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(HoverRowStyle())
                }
            }
            .padding(.top, 2)
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            // D-2: while setup isn't finished, the line opens the setup window instead.
            let setupLeft = SetupGuide.next(engine.setupState) != nil
            Button { setupLeft ? AppDelegate.openOnboarding?() : show(.engine) } label: {
                EngineStatusLine()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(setupLeft ? "Finish getting ready" : "Under the Hood")
            HStack(spacing: 18) {
                Button("Open Earl") { show(nil) }
                Button("Settings") { show(.engine) }
                if Updates.shared.isRunning { // D-4: only where a feed is set up
                    Button("Check for Updates…") { Updates.shared.checkNow() }
                }
                Spacer(minLength: 0)
                Button("Quit") { state.quit() }
                    .help("Quit Earl. A recording in progress is stopped and kept.")
            }
            .buttonStyle(FooterButtonStyle())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Paper.sidebar)
        .overlay(alignment: .top) { Rectangle().fill(Paper.hairline).frame(height: 1) }
    }

    private func show(_ item: SidebarItem?) {
        if let item { state.selection = item }
        openWindow(id: "meetings")
        NSApp.activate()
    }
}

/// The next-meeting card, on the same terms as R2-6's "Up next" row: a
/// meeting later today, or one in progress, that isn't recorded yet.
private struct MenuBarNextMeeting: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var calendar: CalendarService
    @ObservedObject var armed: ArmedRecorder
    @Environment(\.openWindow) private var openWindow // S-2

    var body: some View {
        TimelineView(.everyMinute) { context in
            let now = context.date
            let recorded = Set(state.meetings.compactMap(\.info.calendarEventID))
            if calendar.isActive,
               let event = CalendarMatcher.nextMeeting(from: calendar.upcomingEvents, at: now, excluding: recorded),
               Calendar.current.isDate(event.start, inSameDayAs: now) || event.start <= now {
                NextMeetingCardView(
                    content: .event(event), now: now,
                    isArmed: { armed.isArmed($0) },
                    recordDisabled: state.isRecording || state.isStarting,
                    onRecord: { state.recordOrArm($0) },
                    onCancel: { armed.cancel() },
                    onOpen: { calendar.openInCalendar(eventID: $0.id) })
                    // The card brings the sidebar's 10 pt inset; the panel has its own.
                    .padding(.horizontal, -10)
                    .padding(.vertical, -4)
                if let brief = state.brief(for: event, now: now) { // S-2
                    MenuBarBriefLine(brief: brief) {
                        if let key = MeetingSeries.key(title: event.title) { state.selection = .series(key) }
                        openWindow(id: "meetings")
                        NSApp.activate()
                    }
                }
            }
        }
        .task { calendar.refreshUpcoming() }
    }
}

/// The shortcut beside Record and Stop, quiet on the ink button.
private struct MenuBarShortcut: View {
    @ObservedObject var shortcut: GlobalShortcut

    var body: some View {
        if let combo = shortcut.active {
            Text(combo.display)
                .font(.system(size: 13, weight: .medium))
                .opacity(0.8)
        }
    }
}

/// Open Earl, Settings, Quit: plain words on the linen footer.
private struct FooterButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13.5, weight: .medium))
            .foregroundStyle(hovering || configuration.isPressed ? Paper.ink : Paper.inkMuted)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

enum MenuBarFormat {
    /// "9:30" today, "Yesterday", "Mon" this week, then "12 Sep".
    static func when(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                           to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case 1: return "Yesterday"
        case 2..<7: return date.formatted(.dateTime.weekday(.abbreviated))
        default: return date.formatted(.dateTime.day().month(.abbreviated))
        }
    }
}

/// One-line health summary: the models in use, or what needs attention.
/// U-5: plain words; a problem in the error colour.
struct EngineStatusLine: View {
    @EnvironmentObject private var engine: Engine

    var body: some View {
        if let problem {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.circle.fill")
                Text(problem)
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Paper.error)
            .lineLimit(1)
        } else {
            Text(models)
                .font(.system(size: 13))
                .foregroundStyle(Paper.inkMuted)
                .lineLimit(1)
        }
    }

    /// D-2: anything SetupGuide still lists; the line opens the setup window.
    private var problem: String? {
        SetupGuide.next(engine.setupState) == nil ? nil : "Finish getting ready"
    }

    private var models: String {
        let whisper = WhisperModelOption.displayName(forPath: Prefs.whisperModel)
        guard Prefs.summariesEnabled else { return whisper }
        let model = engine.notesModel
        let llm = model.split(separator: "/").last.map(String.init) ?? model
        return "\(whisper) · \(llm)"
    }
}

/// A processing job as a quiet progress line (menu bar panel).
struct JobSummaryRow: View {
    let job: Job
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.paperChat)
                    .foregroundStyle(Paper.ink)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let detail {
                    Text(detail)
                        .font(.system(size: 13).monospacedDigit())
                        .foregroundStyle(Paper.inkMuted)
                }
            }
            if job.step != .queued {
                QuietProgressBar(value: job.step == .transcribing ? job.transcriptionProgress : nil)
            }
            Text(job.step == .queued ? "Waiting for the previous meeting" : job.status)
                .font(.system(size: 13))
                .foregroundStyle(Paper.inkMuted)
                .lineLimit(1)
        }
    }

    private var detail: String? {
        switch job.step {
        case .transcribing: "\(Int(job.transcriptionProgress * 100))%"
        case .summarizing: job.tokensPerSecond > 0 ? "\(Int(job.tokensPerSecond)) tok/s" : nil
        case .queued: nil
        }
    }
}

/// A thin ink line on a tan track. Without a value it slides gently, for
/// the notes step, which has no known length.
private struct QuietProgressBar: View {
    var value: Double?

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Paper.hairline)
                if let value {
                    Capsule().fill(Paper.ink).frame(width: max(3, width * min(1, max(0, value))))
                } else {
                    TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                        let t = context.date.timeIntervalSinceReferenceDate
                        let phase = (t / 1.6).truncatingRemainder(dividingBy: 1)
                        Capsule().fill(Paper.ink)
                            .frame(width: width * 0.3)
                            .offset(x: (width * 1.3) * phase - width * 0.3)
                    }
                    .clipShape(Capsule())
                }
            }
        }
        .frame(height: 3)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue(value.map { "\(Int($0 * 100)) percent" } ?? "In progress")
    }
}
