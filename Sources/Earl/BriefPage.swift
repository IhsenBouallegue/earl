import SwiftUI

// S-2: the brief page, a small front page about a meeting that hasn't happened
// yet. Same paper as the meeting page: masthead, the series name as the
// headline, Earl's note as the one focal point, then a few short columns and
// the back issues. With nothing coming it's the series page.

struct BriefPage: View {
    @EnvironmentObject private var state: AppState
    let key: String

    var body: some View {
        TimelineView(.everyMinute) { context in
            let now = context.date
            let brief = state.brief(forSeries: key, now: now)
            VStack(spacing: 0) {
                BriefMasthead(brief: brief, now: now)
                GeometryReader { geo in
                    // The meeting page's grid: the page on the left, a soft column of
                    // sources on the right (there the conversation, here the meetings).
                    let rail = brief.history.isEmpty ? 0
                        : min(MeetingDetail.conversationWidth, max(320, geo.size.width * 0.38))
                    HStack(spacing: 0) {
                        ScrollView {
                            BriefColumns(brief: brief, now: now,
                                         wide: geo.size.width - rail - 2 * Paper.Space.pageX >= 400)
                                .padding(.horizontal, Paper.Space.pageX)
                                .padding(.top, PageGrid.top)
                                .padding(.bottom, PageGrid.bottom)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .scrollIndicators(.automatic)
                        if rail > 0 {
                            Rectangle().fill(Paper.hairline).frame(width: 1)
                            SeriesMeetingsColumn(meetings: brief.history).frame(width: rail)
                        }
                    }
                }
            }
            .animation(.easeOut(duration: 0.2), value: brief.yours.map(\.id))
        }
        .paperBackground(.paper)
        .navigationTitle("")
    }
}

// MARK: - Masthead

/// "BRIEF · THURSDAY, OCTOBER 8 · 9:30 · IN 40 MIN · TEAMS", or on a series
/// page "SERIES · 6 MEETINGS SINCE SEP 25".
struct BriefMasthead: View {
    let brief: Brief
    let now: Date

    var body: some View {
        Masthead(Self.text(brief, now: now))
    }

    static func text(_ brief: Brief, now: Date) -> String {
        if let event = brief.event {
            var parts = ["Brief", event.start.formatted(.dateTime.weekday(.wide).day().month(.wide)),
                         CalendarMatcher.clock(event.start)]
            let relative = CalendarMatcher.relativeText(event, at: now)
            if relative != "tomorrow" { parts.append(relative) }
            if let app = BriefFormat.callApp(urls: event.urls) { parts.append(app) }
            return parts.joined(separator: " · ")
        }
        let n = brief.history.count
        var line = "Series · \(n == 1 ? "1 meeting" : "\(n) meetings")"
        if let first = brief.history.last?.info.startedAt {
            line += " since " + first.formatted(.dateTime.month(.abbreviated).day())
        }
        return line
    }
}

enum BriefFormat {
    /// The call app a meeting link points to.
    static func callApp(urls: [String]) -> String? {
        for url in urls {
            let host = URL(string: url)?.host?.lowercased() ?? ""
            if host.contains("teams.microsoft") || host.contains("teams.live") { return "Teams" }
            if host.hasSuffix("zoom.us") || host.contains(".zoom.") { return "Zoom" }
            if host == "meet.google.com" { return "Meet" }
            if host.contains("webex") { return "Webex" }
            if host.contains("slack.com") { return "Slack" }
            if host.contains("facetime.apple.com") { return "FaceTime" }
        }
        return nil
    }

    /// "Tue, Oct 6", for the back issues and hover hints.
    static func shortDay(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }
}

// MARK: - The page

private struct BriefColumns: View {
    @EnvironmentObject private var state: AppState
    let brief: Brief
    let now: Date
    let wide: Bool

    var body: some View {
        // The meeting page's slots, in its order: headline and subline, the
        // people, Earl's card, then what it's about on the left and what's
        // yours on the right.
        VStack(alignment: .leading, spacing: 0) {
            headline.padding(.bottom, 14)
            if !brief.people.isEmpty {
                BriefPeople(people: brief.people).padding(.bottom, 18)
            }
            BriefingCard(lead: brief.event == nil ? EarlVoice.whereThingsStand : EarlVoice.beforeYouGoIn,
                         text: brief.lead)
                .padding(.bottom, 26)
            columns
        }
    }

    private var headline: some View {
        VStack(alignment: .leading, spacing: PageGrid.subline) {
            Text(brief.title)
                .font(.paperHeadline)
                .tracking(-0.4)
                .lineLimit(3)
                .foregroundStyle(Paper.ink)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if let last = brief.lastMeeting {
                LastTimeLine(meeting: last, now: now) { state.selection = .meeting(last.id) }
            }
        }
    }

    @ViewBuilder
    private var columns: some View {
        let left = !brief.questions.isEmpty
        let right = !brief.yours.isEmpty || !brief.others.isEmpty
        let leftColumn = VStack(alignment: .leading, spacing: 22) {
            if !brief.questions.isEmpty {
                section("Still open", note: brief.lastMeeting.map {
                    "from " + EarlVoice.dayPhrase($0.info.startedAt, now: now)
                }) {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(brief.questions) { q in
                            PageBullet(text: PageText.attributed(q.text, query: ""))
                                .help("From \(BriefFormat.shortDay(q.date))")
                        }
                    }
                }
            }
        }
        let rightColumn = VStack(alignment: .leading, spacing: 22) {
            if !brief.yours.isEmpty {
                section("Your to-dos") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(brief.yours) { item in BriefTicket(item: item, mine: true) }
                    }
                }
            }
            if !brief.others.isEmpty {
                section("Everyone else", count: brief.others.count) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(brief.others) { item in BriefTicket(item: item, mine: false) }
                    }
                }
            }
        }
        if wide && right {
            HStack(alignment: .top, spacing: Paper.Space.xl) {
                leftColumn.frame(maxWidth: .infinity, alignment: .topLeading)
                rightColumn.frame(maxWidth: .infinity, alignment: .topLeading)
            }
        } else {
            VStack(alignment: .leading, spacing: 22) {
                if left { leftColumn }
                if right { rightColumn }
            }
        }
    }

    /// The meeting page's section head: serif title, then a count or a note.
    private func section(_ title: String, note: String? = nil, count: Int? = nil,
                         @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.paperTitle).foregroundStyle(Paper.ink)
                if let count, count > 0 { Text("\(count)").font(.system(size: 13)).foregroundStyle(Paper.inkMuted) }
                if let note { Text(note).font(.system(size: 13)).foregroundStyle(Paper.inkMuted) }
            }
            content()
        }
    }
}

/// "Last time, Tuesday: Onboarding ships to 20 % on October 6", a quiet link.
private struct LastTimeLine: View {
    let meeting: Meeting
    let now: Date
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let day = EarlVoice.dayPhrase(meeting.info.startedAt, now: now)
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Last time, \(day): \(Text(meeting.info.headline ?? meeting.info.title).foregroundStyle(Paper.ink))")
                    .font(PageGrid.sublineFont)
                    .foregroundStyle(Paper.inkMuted)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Image(systemName: "arrow.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Paper.inkMuted)
                    .opacity(hovering ? 1 : 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Open the last meeting")
    }
}

/// A to-do on the brief. Yours tick through the to-do path (summary.md);
/// others' carry the owner's face. Where it came from shows on hover.
private struct BriefTicket: View {
    @EnvironmentObject private var state: AppState
    let item: ActionItem
    let mine: Bool
    @State private var hovering = false

    var body: some View {
        let meeting = state.meeting(item.meetingID)
        Ticket(mine: mine) {
            if mine {
                Button { withAnimation(.easeOut(duration: 0.2)) { state.toggleTodo(item) } } label: {
                    TicketBox(checked: item.done)
                }
                .buttonStyle(.plain)
                .help("Mark as done")
            } else if let owner = item.owner {
                SpeakerAvatar.badge(TodoOwner.look(for: owner, in: meeting?.speakers ?? []) ?? .voice(3), size: 20)
            }
            label
                .frame(maxWidth: .infinity, alignment: .leading)
            if let meeting {
                Button { state.selection = .meeting(meeting.id) } label: {
                    Text(BriefFormat.shortDay(meeting.info.startedAt))
                        .font(.paperLabel)
                        .foregroundStyle(Paper.inkMuted)
                }
                .buttonStyle(.plain)
                .opacity(hovering ? 1 : 0)
                .help("Open the meeting it came from")
            }
        }
        .onHover { hovering = $0 }
    }

    private var label: some View {
        var text = PageText.attributed(item.text, query: "")
        if !mine, let owner = item.owner {
            var name = AttributedString(AttendeeName.firstName(owner) + " · ")
            name.font = .system(size: 15, weight: .semibold)
            text = name + text
        }
        return Text(text).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
    }
}

/// Faces in a wrap; a small ear for voices Earl already knows.
private struct BriefPeople: View {
    let people: [BriefPerson]

    var body: some View {
        FlowLayout(spacing: 16, lineSpacing: 10) {
            ForEach(people) { person in
                HStack(spacing: 7) {
                    SpeakerAvatar.badge(person.look, size: 26)
                    Text(AttendeeName.firstName(person.name))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Paper.ink)
                    if person.voiceKnown {
                        Image(systemName: "waveform")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Paper.inkMuted)
                            .accessibilityLabel("Voice known")
                    }
                }
                .fixedSize()
                .help(help(person))
            }
        }
    }

    private func help(_ p: BriefPerson) -> String {
        var parts = [p.name]
        if p.spokeLastTime { parts.append("spoke last time") }
        if p.voiceKnown { parts.append("Earl knows the voice") }
        return parts.joined(separator: " · ")
    }
}

/// The series' meetings in the soft right column, where a meeting page has
/// its conversation: the same header, the same paper, newest first.
private struct SeriesMeetingsColumn: View {
    @EnvironmentObject private var state: AppState
    let meetings: [Meeting]

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                // The masthead already counts them.
                Text("Meetings").font(.paperTitle).foregroundStyle(Paper.ink)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 10)
            .frame(minHeight: 50)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(meetings) { m in
                        SeriesMeetingRow(meeting: m) { state.selection = .meeting(m.id) }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 18)
            }
            .scrollIndicators(.automatic)
        }
        .paperBackground(.soft)
    }
}

/// One issue: the date over its headline, like a dated clipping.
private struct SeriesMeetingRow: View {
    let meeting: Meeting
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(BriefFormat.shortDay(meeting.info.startedAt))
                    if meeting.info.duration > 0 { Text("· \(meeting.durationText)") }
                }
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(Paper.inkMuted)
                Text(meeting.info.headline ?? meeting.info.title)
                    .font(.paperBody)
                    .foregroundStyle(Paper.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .background(hovering ? Paper.ink.opacity(0.05) : .clear,
                        in: RoundedRectangle(cornerRadius: Paper.Radius.row, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(meeting.info.title)
    }
}

// MARK: - The toolbar

/// Where Record sits: "Record at 9:30" for the coming event, or the armed state.
struct BriefRecordButton: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var armed: ArmedRecorder
    let event: CalendarCandidate

    var body: some View {
        let now = Date()
        Group {
            if armed.isArmed(event) {
                Button { armed.cancel() } label: {
                    Label("Will record at \(CalendarMatcher.clock(event.start))", systemImage: "alarm.fill")
                        .labelStyle(TightLabel())
                }
                .buttonStyle(.paperSecondary)
                .help("Click to cancel. Earl records when the meeting starts, or when the call does.")
            } else {
                Button(CalendarMatcher.isOngoing(event, at: now) ? "Record"
                       : "Record at \(CalendarMatcher.clock(event.start))") { state.recordOrArm(event) }
                    .buttonStyle(.paperRecord)
                    .disabled(state.isRecording || state.isStarting)
                    .help(CalendarMatcher.isOngoing(event, at: now) ? "Start recording now"
                          : "Earl starts recording when the meeting starts, or when the call does")
            }
        }
        .fixedSize()
    }
}

// MARK: - Ways in

/// The meeting masthead's series link: "PRODUCT SYNC · 4 OF 6", with
/// "‹ previous · next ›" on hover.
struct SeriesMastheadLink: View {
    @EnvironmentObject private var state: AppState
    let meeting: Meeting
    /// What it reads: the meeting's title, or nil for the series name. Outside
    /// a series the label is plain text.
    var label: String?
    @State private var hovering = false

    var body: some View {
        if let key = MeetingSeries.key(for: meeting), case let members = state.seriesMembers(key),
           members.count >= 2, let index = members.firstIndex(where: { $0.id == meeting.id }) {
            do {
                let number = members.count - index
                let older = members.indices.contains(index + 1) ? members[index + 1] : nil
                let newer = index > 0 ? members[index - 1] : nil
                HStack(spacing: 2) {
                    Button { state.selection = .series(key) } label: {
                        Text(label ?? MeetingSeries.displayName(members))
                            .underline(hovering, color: Paper.inkMuted)
                            .foregroundStyle(hovering ? Paper.ink : Paper.inkMuted)
                    }
                    .buttonStyle(.plain)
                    .help("Meeting \(number) of \(members.count) in the series: what's still open, and every meeting")
                    // The separator to the date gives way to ‹ › on hover.
                    ZStack {
                        Text("·").foregroundStyle(Paper.inkMuted).opacity(hovering ? 0 : 1)
                        HStack(spacing: 4) {
                            chevron("chevron.left", to: older, help: "Previous in the series")
                            chevron("chevron.right", to: newer, help: "Next in the series")
                        }
                        .opacity(hovering ? 1 : 0)
                    }
                }
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
            }
        } else if let label {
            HStack(spacing: 6) {
                Text(label)
                Text("·")
            }
        }
    }

    @ViewBuilder
    private func chevron(_ symbol: String, to target: Meeting?, help: String) -> some View {
        Button { if let target { state.selection = .meeting(target.id) } } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Paper.inkMuted)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(target == nil)
        .opacity(target != nil ? 1 : 0.35)
        .help(help)
    }
}

/// Under the next meeting in the menu bar: Earl's lead and "Open brief".
struct MenuBarBriefLine: View {
    let brief: Brief
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(brief.lead)
                .font(.paperBody)
                .foregroundStyle(Paper.ink)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            // The same quiet link as the sidebar card, not a second big button
            // next to Record.
            BriefCardLink(open: nil, action: onOpen)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 2)
        .padding(.top, 2)
    }
}

extension Brief {
    /// The sidebar card's line: "2 of yours open", or nothing but "Brief".
    var cardLine: String? {
        yours.isEmpty ? nil : "\(yours.count) of yours open"
    }
}

/// "2 of yours open · Brief →" on the next-meeting card.
struct BriefCardLink: View {
    let open: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let open {
                    Text(open + " ·").foregroundStyle(Paper.inkMuted)
                }
                Text("Brief").foregroundStyle(Paper.ink).underline(hovering, color: Paper.inkMuted)
                Image(systemName: "arrow.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Paper.ink)
            }
            .font(.paperLabel)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("What's still open from the last meetings of this series")
    }
}
