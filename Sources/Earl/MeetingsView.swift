import SwiftUI

struct MeetingsView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var engine: Engine
    @State private var query = ""
    /// U-3: ⌘K shows the search field at the top of the sidebar; Esc hides it.
    @State private var searching = false

    /// The old page gets out of the way quickly and the new one fades in, so
    /// the two never sit half-faded on top of each other. Nothing slides here:
    /// the masthead stays put, and a meeting's content settles in under it.
    private var pageTurn: AnyTransition {
        .asymmetric(insertion: .opacity.animation(.timingCurve(0.2, 0.9, 0.1, 1, duration: 0.22)),
                    removal: .opacity.animation(.easeOut(duration: 0.08)))
    }

    var body: some View {
        NavigationSplitView {
            Sidebar(query: $query, searching: $searching)
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 320)
        } detail: {
            // The ZStack stays while the page inside it is swapped, so the
            // transition has a parent to play in.
            ZStack {
                detail
                    .id(state.selection)
                    .transition(pageTurn)
            }
            .animation(.easeOut(duration: 0.22), value: state.selection)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .environment(\.mastheadRecord, true)
            .ignoresSafeArea(.container, edges: .top)
            .paperBackground()
        }
        // No toolbar: Record lives at the end of each page's masthead, which
        // sits level with the window's buttons.
        .toolbar(removing: .sidebarToggle)
        .onAppear {
            // Show in the Dock and app switcher while the window is open.
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
            state.reload()
            if state.selection == nil, let first = state.meetings.first {
                state.selection = .meeting(first.id)
            }
            if let demo = DemoMode.searchQuery { // U-0
                query = demo
                searching = true
            }
        }
        .onDisappear {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        switch state.selection {
        case .engine:
            VStack(spacing: 0) {
                Masthead("Settings")
                ScrollView {
                    EngineView(showsMasthead: false)
                        .frame(maxWidth: 720, alignment: .leading)
                        .padding(.horizontal, Paper.Space.pageX)
                        .padding(.top, PageGrid.top)
                        .padding(.bottom, PageGrid.bottom)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .navigationTitle("")
        case .todos: // R3-2
            TodosView(reminders: state.reminders)
        case .series(let key): // S-2
            BriefPage(key: key).id(key)
        case .ask: // S-3
            AskPage()
        case .meeting(let id):
            if let meeting = state.meeting(id) {
                if meeting.id == state.recordingID {
                    RecordingView(meeting: meeting)
                } else {
                    MeetingDetail(meeting: meeting, query: query)
                        .id(meeting.id)
                }
            } else {
                EmptyLibraryView()
            }
        case nil:
            EmptyLibraryView()
        }
    }

}

// MARK: - Record, in the masthead

/// The one loud thing, at the end of every page's masthead, level with the
/// window's buttons. While recording, the recording screen has its own big
/// Stop, so elsewhere it's a quiet one.
struct RecordControl: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Group {
            if state.isRecording {
                if state.selection != state.recordingID.map(SidebarItem.meeting) {
                    Button {
                        state.stopRecording()
                    } label: {
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 2).fill(Paper.stop).frame(width: 9, height: 9)
                            Text("Stop  \(state.elapsedText)").monospacedDigit()
                        }
                    }
                    .buttonStyle(.paperSecondary)
                    .fixedSize()
                    .help("Stop recording (⇧⌘R)")
                }
            } else if case .series(let key) = state.selection, let event = state.upcomingEvent(forSeries: key) { // S-2
                BriefRecordButton(armed: state.armed, event: event)
            } else if !state.meetings.isEmpty || state.selection != nil {
                // The empty library has its own Record in the middle; one is enough.
                Button("Record") { state.startRecording() }
                    .buttonStyle(.paperRecord)
                    .fixedSize()
                    .disabled(state.isStarting)
                    .help("Start recording (⇧⌘R)")
            }
        }
        .controlSize(.small)
    }
}

// MARK: - Sidebar

/// U-3: Earl's greeting, the next meeting when it's close, To-dos, the meetings
/// by day, then Search and Settings. A ScrollView with its own rows instead of
/// a List, so the selected row can be a white card on linen; arrow keys still
/// move the selection.
private struct Sidebar: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var engine: Engine
    @Binding var query: String
    @Binding var searching: Bool

    @AppStorage(Prefs.Key.userName) private var userName = ""
    @FocusState private var focus: Focus?
    @Namespace private var selectionCard
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Earl glances at what you open, and nods when you tick something off.
    @State private var glances = 0
    @State private var ticks = 0

    enum Focus: Hashable { case list, search }

    private var filtered: [Meeting] {
        query.isEmpty ? state.meetings : AskSearch.filter(state.meetings, query: query) // S-3: questions by their words
    }

    private var sections: [(label: String, meetings: [Meeting])] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: filtered) { calendar.startOfDay(for: $0.info.startedAt) }
        return groups.keys.sorted(by: >).map { day in (SidebarDay.label(for: day), groups[day] ?? []) }
    }

    /// What the arrow keys walk through, top to bottom.
    private var order: [SidebarItem] {
        [.todos] + (query.isEmpty ? SidebarSeriesSection.series(state.meetings).prefix(SidebarSeriesSection.shown).map { .series($0.key) } : [])
            + sections.flatMap { $0.meetings.map { SidebarItem.meeting($0.id) } }
    }

    private var myOpenTodos: Int {
        state.actionItems.filter { !$0.done && ActionItems.isMine(owner: $0.owner, userName: Prefs.userName) }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            greeting
            if searching {
                searchField.padding(.bottom, 10)
            } else {
                SidebarNextMeeting(calendar: state.calendar, armed: state.armed) // R2-6
            }
            TodosSidebarRow(count: myOpenTodos, selected: state.selection == .todos) { select(.todos) } // R3-2
            list
            footer
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .paperBackground(.sidebar)
        // The white card glides from the old row to the new one.
        .environment(\.sidebarSelection, selectionCard)
        .animation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.08), value: state.selection)
        .onChange(of: state.selection) { glances += 1 }
        .onChange(of: state.actionItems.filter(\.done).count) { old, new in if new > old { ticks += 1 } }
        .onChange(of: searching) { _, on in
            focus = on ? .search : .list
            if !on { query = "" }
        }
    }

    private var greeting: some View {
        HStack(spacing: 10) {
            EarlAvatar(size: 32, idle: true, nod: state.notesFinished + ticks, glance: glances)
            // Called from the view on purpose: it notes that Earl saw you today.
            Text(EarlVoice.greeting(name: userName.isEmpty ? nil : userName))
                .font(.earlVoice(size: 21))
                .foregroundStyle(Paper.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 14)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Paper.inkMuted)
            TextField("Search meetings", text: $query, prompt: Text("Search meetings").foregroundStyle(Paper.inkMuted))
                .textFieldStyle(.plain)
                .foregroundStyle(Paper.ink)
                .focused($focus, equals: .search)
                .onSubmit {
                    if AskQuestion.isQuestion(query) { return askEarl() } // S-3
                    if let first = filtered.first { select(.meeting(first.id)) }
                    focus = .list
                }
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.upArrow) { move(-1); return .handled }
            Button {
                searching = false
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(Paper.inkMuted)
            }
            .buttonStyle(.borderless)
            .help("Close search (Esc)")
        }
        .font(.paperChat)
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(Paper.card, in: RoundedRectangle(cornerRadius: Paper.Radius.button, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Paper.Radius.button, style: .continuous).strokeBorder(Paper.hairline))
        .onExitCommand { searching = false }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if AskQuestion.isQuestion(query) { AskSearchRow(query: query, action: askEarl) } // S-3
                    if query.isEmpty { SidebarSeriesSection(select: select) } // S-2: meetings that recur, bundled
                    if !sections.isEmpty { SidebarSectionTitle(title: query.isEmpty ? "Meetings" : "Found") }
                    ForEach(sections, id: \.label) { section in
                        // A day is a quiet subheading under "Meetings", lined up with the times.
                        Text(section.label)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Paper.inkMuted)
                            .padding(.horizontal, 10)
                            .padding(.top, section.label == sections.first?.label ? 0 : 12)
                            .padding(.bottom, 2)
                        ForEach(section.meetings) { meeting in
                            SidebarMeetingRow(meeting: meeting, selected: state.selection == .meeting(meeting.id)) {
                                select(.meeting(meeting.id))
                            }
                            .id(SidebarItem.meeting(meeting.id))
                            .contextMenu { rowMenu(meeting) }
                        }
                    }
                    if !query.isEmpty && filtered.isEmpty {
                        Text("No meetings mention “\(query)”.")
                            .font(.paperChat)
                            .foregroundStyle(Paper.inkMuted)
                            .padding(.horizontal, 10)
                            .padding(.top, 14)
                    } else if state.meetings.isEmpty {
                        Text("No meetings yet")
                            .font(.paperChat)
                            .foregroundStyle(Paper.inkMuted)
                            .padding(.horizontal, 10)
                            .padding(.top, 14)
                    }
                }
                .padding(.bottom, 10)
            }
            .scrollIndicators(.never)
            .focusable()
            .focusEffectDisabled()
            .focused($focus, equals: .list)
            .onKeyPress(.downArrow) { move(1); return .handled }
            .onKeyPress(.upArrow) { move(-1); return .handled }
            .onExitCommand { if searching { searching = false } }
            .onChange(of: state.selection) { _, item in
                guard let item, case .meeting = item else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(item) }
            }
        }
        .defaultFocus($focus, .list)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            // D-2: setup isn't finished; this opens the setup window where it left off.
            if engineNeedsYou {
                Button { AppDelegate.openOnboarding?() } label: {
                    Label("Finish getting ready", systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(Paper.error)
                        .fontWeight(.medium)
                }
                .help("Open the setup window")
            }
            footerRow
        }
        .buttonStyle(.plain)
        .labelStyle(.titleAndIcon)
        .font(.system(size: 14))
        .padding(.horizontal, 8)
        .padding(.vertical, 12)
    }

    private var footerRow: some View {
        HStack {
            Button {
                searching.toggle()
            } label: {
                Label("Search ⌘K", systemImage: "magnifyingglass")
            }
            .keyboardShortcut("k", modifiers: .command)
            .help("Search your meetings")
            Spacer()
            Button {
                select(.engine)
            } label: {
                Label("Settings", systemImage: "gearshape")
                    .foregroundStyle(state.selection == .engine ? Paper.ink : Paper.inkMuted)
                    .fontWeight(state.selection == .engine ? .semibold : .regular)
            }
            .help("Under the hood")
        }
        .foregroundStyle(Paper.inkMuted)
    }

    /// D-2: something SetupGuide still lists (tools, microphone, screen audio).
    private var engineNeedsYou: Bool { SetupGuide.next(engine.setupState) != nil }

    private func select(_ item: SidebarItem) {
        state.selection = item
    }

    /// S-3: the search as a question to Earl, on the Ask page.
    private func askEarl() {
        AskCenter.shared.ask(query, state: state)
        searching = false
    }

    private func move(_ step: Int) {
        let items = order
        guard !items.isEmpty else { return }
        guard let current = state.selection, let i = items.firstIndex(of: current) else {
            state.selection = items[step > 0 ? 0 : items.count - 1]
            return
        }
        state.selection = items[min(max(i + step, 0), items.count - 1)]
    }

    @ViewBuilder
    private func rowMenu(_ meeting: Meeting) -> some View {
        Button("Show in Finder") { state.reveal(meeting.id) }
        Button("Copy as Markdown") { state.copyMarkdown(meeting.id) }
        Divider()
        Button("Delete…", role: .destructive) { state.delete(meeting.id) }
            .disabled(meeting.id == state.recordingID || state.isBusy(meeting.id))
    }
}

/// "Today", "Yesterday", "Tuesday", then "Sep 12, 2026".
enum SidebarDay {
    static func label(for date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        let day = calendar.startOfDay(for: date)
        if calendar.isDate(day, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(day, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        if let week = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)), day >= week, day <= now {
            return day.formatted(.dateTime.weekday(.wide))
        }
        return day.formatted(date: .abbreviated, time: .omitted)
    }
}

/// A row in the sidebar: 36 pt, white card with a soft shadow when selected.
struct SidebarRowBackground: ViewModifier {
    var selected: Bool
    var height: CGFloat = 36
    @State private var hovering = false
    @Environment(\.sidebarSelection) private var namespace

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Paper.Radius.row, style: .continuous)
        content
            .padding(.horizontal, 10)
            .frame(height: height)
            .contentShape(shape)
            .background {
                if selected {
                    shape.fill(Paper.selection).shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
                        .modifier(SidebarSelectionCard(namespace: namespace))
                } else if hovering {
                    shape.fill(Paper.ink.opacity(0.07))
                }
            }
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.14), value: hovering)
    }
}

private struct SidebarSelectionKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

extension EnvironmentValues {
    /// Shared by the sidebar's rows, so there's one selection card to move.
    var sidebarSelection: Namespace.ID? {
        get { self[SidebarSelectionKey.self] }
        set { self[SidebarSelectionKey.self] = newValue }
    }
}

private struct SidebarSelectionCard: ViewModifier {
    let namespace: Namespace.ID?

    func body(content: Content) -> some View {
        if let namespace {
            content.matchedGeometryEffect(id: "selection", in: namespace)
        } else {
            content
        }
    }
}

/// An agenda line: the time first, then the title. The live clock while
/// recording, a quiet word while it's processed, "Needs you" when it failed.
struct SidebarMeetingRow: View {
    @EnvironmentObject private var state: AppState
    let meeting: Meeting
    let selected: Bool
    let action: () -> Void

    /// Wide enough for "15:00", or "11:20 AM" where the clock has AM and PM.
    static let timeWidth: CGFloat = {
        let format = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? ""
        return format.contains("a") ? 62 : 40
    }()

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                leading
                    .frame(width: Self.timeWidth, alignment: .leading)
                Text(title)
                    .font(.paperChat)
                    .foregroundStyle(Paper.ink)
                    .lineLimit(1)
                Spacer(minLength: 4)
                trailing
            }
            .modifier(SidebarRowBackground(selected: selected, height: 32))
        }
        .buttonStyle(.plain)
        .help(meeting.info.title)
    }

    private var clock: String { meeting.info.startedAt.formatted(date: .omitted, time: .shortened) }

    /// The time sits beside it, so a default title doesn't repeat it.
    private var title: String {
        meeting.info.titleIsDefault ? "Untitled call" : meeting.info.title
    }

    @ViewBuilder
    private var leading: some View {
        if meeting.id == state.recordingID {
            HStack(spacing: 5) {
                Circle().fill(Paper.live).frame(width: 7, height: 7)
                Text("Live").font(.paperLabel).foregroundStyle(Paper.masthead)
            }
        } else {
            Text(clock)
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(Paper.inkMuted)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if meeting.id == state.recordingID {
            Text(state.elapsedText).monospacedDigit()
                .font(.paperLabel)
                // Text in the masthead red: the LIVE red is too dark to read on the night sidebar.
                .foregroundStyle(Paper.masthead)
        } else if let job = state.job(meeting.id) {
            // A small spinner, not a word: the title keeps the room.
            ProgressView()
                .controlSize(.mini)
                .tint(Paper.inkMuted)
                .help(job.step == .queued ? "Waiting its turn" : job.step == .transcribing ? "Transcribing" : "Writing the notes")
                .accessibilityLabel(job.step == .queued ? "Waiting" : job.step == .transcribing ? "Transcribing" : "Writing notes")
        } else if meeting.info.status == .failed {
            // A mark, not words: the title keeps the room, the page says what went wrong.
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(Paper.error)
                .help("Needs you: this meeting didn't finish processing")
                .accessibilityLabel("Needs you")
        }
    }
}

/// U-3: the R2-6 card, but in the sidebar only when it matters: in the half
/// hour before a meeting, during it, or when Earl is armed for it.
private struct SidebarNextMeeting: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var calendar: CalendarService
    @ObservedObject var armed: ArmedRecorder
    @AppStorage(Prefs.Key.calendarEnabled) private var enabled = true

    static let lead: TimeInterval = 30 * 60

    var body: some View {
        TimelineView(.everyMinute) { context in
            let now = context.date
            if let (event, phase) = upNext(at: now) {
                let brief = state.brief(for: event, now: now)
                let seriesKey = MeetingSeries.key(title: event.title)
                SidebarUpNext(event: event, now: now, phase: phase,
                          briefCount: brief?.yours.count, hasBrief: brief != nil && seriesKey != nil,
                          recordDisabled: state.isRecording || state.isStarting,
                          onOpen: {
                              if phase == .recording, let id = state.recordingID { state.selection = .meeting(id) }
                              else if brief != nil, let seriesKey { state.selection = .series(seriesKey) } // S-2
                              else { calendar.openInCalendar(eventID: event.id) }
                          },
                          onRecord: { state.recordOrArm(event) },
                          onCancel: { armed.cancel() })
                    .padding(.bottom, 2)
                    .transition(.opacity)
            }
        }
        .task { calendar.refreshUpcoming() }
    }

    /// The meeting being recorded, if it's on the calendar; else the next one
    /// in the half hour, one in progress, or one Earl is armed for.
    private func upNext(at now: Date) -> (CalendarCandidate, SidebarUpNext.Phase)? {
        guard calendar.isAllowed, enabled else { return nil }
        if let id = state.recordingID, let eventID = state.meeting(id)?.info.calendarEventID,
           let event = calendar.upcomingEvents.first(where: { $0.id == eventID }),
           CalendarMatcher.isOngoing(event, at: now) {
            return (event, .recording)
        }
        let recorded = Set(state.meetings.compactMap(\.info.calendarEventID))
        guard let event = CalendarMatcher.nextMeeting(from: calendar.upcomingEvents, at: now, excluding: recorded)
        else { return nil }
        if armed.isArmed(event) { return (event, .armed) }
        if CalendarMatcher.isOngoing(event, at: now) { return (event, .ongoing) }
        return event.start.timeIntervalSince(now) <= Self.lead ? (event, .soon) : nil
    }
}

// MARK: - Empty library

struct EmptyLibraryView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 22) {
            EarlAvatar(size: 56)
            VStack(spacing: 8) {
                // One handwritten lead-in, then one plain sentence.
                Text(state.meetings.isEmpty ? EarlVoice.readyWhenYouAre : "At your service.")
                    .font(.earlVoice(size: 24))
                    .foregroundStyle(Paper.ink)
                Text(state.meetings.isEmpty
                     ? "Press Record when your call begins. I'll listen quietly and hand you the notes afterwards, all on this Mac."
                     : "Pick a meeting on the left, or record a new one.")
                    .font(.paperLede)
                    .foregroundStyle(Paper.inkMuted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }
            if !state.isRecording {
                Button("Record") { state.startRecording() }
                    .buttonStyle(.paperRecord)
                    .frame(width: 180)
                    .disabled(state.isStarting)
                    .help("Start recording (⇧⌘R)")
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .paperBackground()
        .navigationTitle("")
    }
}
