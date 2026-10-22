import SwiftUI

// MARK: - Meeting

/// U-2: one page. The front page on the left (FrontPage.swift), the
/// conversation on the right (Conversation.swift), under a masthead.
struct MeetingDetail: View {
    @EnvironmentObject private var state: AppState
    let meeting: Meeting
    let query: String

    /// U-0: DemoMode opens the page in one of these states. `.transcript`
    /// finds a phrase in the conversation, `.details` opens the full summary.
    enum Tab { case summary, transcript, details }

    @State private var expanded = false
    @State private var editingTitle = false
    @State private var finding = false
    @State private var findText = ""
    @State private var linkingCalendar = false // R2-1
    @State private var pastingInvite = false // R3-4
    // R3-1: held in @State, not observed, so ticks don't redraw the whole page.
    @State private var player = MeetingPlayer()
    /// The conversation beside the notes; hidden, the page is one column. It
    /// comes back by itself when you play a moment or find a word.
    @AppStorage("showsConversation") private var showsConversation = true

    private var job: Job? { state.job(meeting.id) }

    static let conversationWidth: CGFloat = 390
    static let singleColumnWidth: CGFloat = 860

    /// The panel slides in a beat after the page opens; already in for the demo.
    @State private var panelIn = DemoMode.isActive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Opening and closing the conversation: firm, no overshoot.
    static let panelMotion = Animation.spring(duration: 0.32, bounce: 0)

    private func reveal() {
        guard !showsConversation else { return }
        withAnimation(Self.panelMotion) { showsConversation = true }
    }

    /// The floating panel comes in from the right edge and leaves the same way.
    private var panelTransition: AnyTransition {
        reduceMotion ? .opacity
            : .asymmetric(insertion: .offset(x: 48).combined(with: .opacity),
                          removal: .offset(x: 32).combined(with: .opacity))
    }

    var body: some View {
        let job = job
        let pageQuery = findText.isEmpty ? query : findText
        let transcribing = job?.step == .transcribing
        VStack(spacing: 0) {
            masthead
            GeometryReader { geo in
                // 390 as designed; a little narrower in a small window, so the front page keeps its two columns.
                let chat = showsConversation ? min(Self.conversationWidth, max(320, geo.size.width * 0.38)) : 0
                HStack(spacing: 0) {
                    FrontPage(meeting: meeting, job: job, query: pageQuery,
                              wide: geo.size.width - chat - 2 * Paper.Space.pageX >= 400,
                              // One column reads best at a book's measure, not the window's width.
                              measure: showsConversation ? nil : Self.singleColumnWidth,
                              expanded: $expanded, editingTitle: $editingTitle,
                              onPlay: job == nil && MeetingPlayer.canPlay(meeting)
                                  ? { reveal(); player.play(turn: $0, in: meeting) } : nil,
                              onClip: job == nil && MeetingPlayer.canPlay(meeting) // W-1
                                  ? { reveal(); player.playClip($0, seconds: $1, in: meeting) } : nil)
                    if showsConversation {
                        ConversationColumn(meeting: meeting,
                                           turns: transcribing ? (job?.liveTurns ?? []).sorted { $0.start < $1.start } : meeting.turns,
                                           live: transcribing, query: query, findText: $findText, finding: $finding,
                                           player: player, enabled: job == nil,
                                           emptyText: emptyConversation)
                            // A floating panel: rounded, a hairline, a soft wide
                            // shadow, inset from the window's edges.
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Paper.hairline))
                            .shadow(color: .black.opacity(0.14), radius: 20, x: 0, y: 10)
                            .padding(.top, 10)
                            .padding(.trailing, 12)
                            .padding(.bottom, 12)
                            .offset(x: panelIn || reduceMotion ? 0 : 48)
                            .opacity(panelIn ? 1 : 0)
                            .frame(width: chat)
                            .transition(panelTransition)
                    }
                }
            }
        }
        .paperBackground(.paper)
        .sheet(isPresented: $linkingCalendar) { CalendarLinkSheet(calendar: state.calendar, meeting: meeting) } // R2-1
        .sheet(isPresented: $pastingInvite) { PasteInviteSheet(meeting: meeting) } // R3-4
        // The headline is the title; keep the toolbar clear.
        .navigationTitle("")
        .onAppear {
            switch DemoMode.detailTab { // U-0
            case .transcript?:
                showsConversation = true
                finding = true
                findText = "empty state"
            case .details?:
                expanded = true
            default:
                break
            }
            state.reminders.loadSent(meetings: state.meetings) // R3-2
            if !panelIn {
                DispatchQueue.main.async {
                    withAnimation(Self.panelMotion.delay(0.12)) { panelIn = true }
                }
            }
        }
        .alert("Reminders", isPresented: Binding(get: { state.reminders.error != nil },
                                                 set: { if !$0 { state.reminders.error = nil } })) {
            Button("Open System Settings") { state.openPrivacySettings("Privacy_Reminders") }
            Button("OK", role: .cancel) {}
        } message: {
            Text(state.reminders.error ?? "")
        }
    }

    private var emptyConversation: String {
        if job != nil { return "The conversation appears here as it's transcribed." }
        if meeting.info.status == .failed { return "Nothing was transcribed yet. Try again to get the conversation." }
        return "Nothing was said, or it hasn't been transcribed."
    }

    // MARK: Masthead

    private var masthead: some View {
        Masthead {
            HStack(spacing: 6) { // S-2: the title (the series link), then the date line
                if let title = mastheadTitle { SeriesMastheadLink(meeting: meeting, label: title) }
                Text(mastheadText)
            }
        } trailing: {
            if job == nil && !meeting.summary.isEmpty { NotesKindMenu(meeting: meeting) } // K-1
            conversationToggle
            moreMenu
        }
    }

    /// The meeting's name, said once: on top when the headline says something
    /// else, never twice. A default title ("Meeting Oct 8 at 11:30") repeats
    /// the date line, so it's left out. Nil: no name on top.
    private var mastheadTitle: String? {
        let info = meeting.info
        guard !info.titleIsDefault else { return nil }
        if let headline = info.headline, headline != info.title { return info.title }
        // The title is the headline: on top only the series' name, when it differs.
        guard let key = MeetingSeries.key(for: meeting), case let members = state.seriesMembers(key),
              members.count >= 2 else { return nil }
        let name = MeetingSeries.displayName(members)
        return name.caseInsensitiveCompare(info.title) == .orderedSame ? nil : name
    }

    private var mastheadText: String {
        let info = meeting.info
        var parts = [
            info.startedAt.formatted(.dateTime.weekday(.wide).day().month(.wide)),
            info.startedAt.formatted(date: .omitted, time: .shortened),
        ]
        if info.duration > 0 { parts.append(meeting.durationText) }
        // The call app (R1-2) stays in Details; the date line keeps to when and how long.
        return parts.joined(separator: " · ")
    }

    private var conversationToggle: some View {
        Button {
            withAnimation(Self.panelMotion) { showsConversation.toggle() }
        } label: {
            Image(systemName: "text.bubble")
                .symbolVariant(showsConversation ? .fill : .none)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(showsConversation ? Paper.ink : Paper.inkMuted)
                .frame(width: 28, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("t", modifiers: [.command, .option])
        .help(showsConversation ? "Hide the conversation (⌥⌘T)" : "Show the conversation (⌥⌘T)")
        .accessibilityLabel(showsConversation ? "Hide the conversation" : "Show the conversation")
        .background {
            // ⌘F finds in the conversation even while it's hidden.
            if !showsConversation {
                Button("Find") { reveal(); finding = true }
                    .keyboardShortcut("f", modifiers: .command)
                    .hidden()
            }
        }
    }

    /// Every action the old toolbar menu had, plus renaming.
    private var moreMenu: some View {
        Menu {
            Button("Rename…") { editingTitle = true }
            Button("Copy as Markdown") { state.copyMarkdown(meeting.id) }
            Button("Show in Finder") { state.reveal(meeting.id) }
            Divider()
            // R2-1
            Button("Link Calendar Event…") { linkingCalendar = true }
            Button("Paste Invite…") { pastingInvite = true } // R3-4
            Button("Unlink Calendar Event") { state.unlinkCalendarEvent(meeting.id) }
                .disabled(meeting.info.calendarEventID == nil && !meeting.info.hasPastedInvite) // R3-4
            Divider()
            Button("Summarize Again") { state.resummarize(meeting.id) }
                .disabled(state.isBusy(meeting.id) || meeting.turns.isEmpty)
            Button("Transcribe Again") { state.retranscribe(meeting.id) }
                .disabled(state.isBusy(meeting.id) || !meeting.hasAudio)
            Divider()
            Button("Delete…", role: .destructive) { state.delete(meeting.id) }
                .disabled(state.isBusy(meeting.id))
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Paper.inkMuted)
                .frame(width: 28, height: 20)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
    }
}

// MARK: - Live processing

/// Earl while a meeting is processed: a plain progress line, and Cancel.
struct ProcessingCard: View {
    @EnvironmentObject private var state: AppState
    let job: Job

    var body: some View {
        BriefingCard(lead: EarlVoice.oneMoment, text: line) {
            VStack(alignment: .leading, spacing: 10) {
                if job.step == .transcribing {
                    PaperProgress(value: job.transcriptionProgress)
                }
                HStack(spacing: 10) {
                    Text(detail)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let started = job.startedAt {
                        Text("·")
                        Text(started, style: .timer).monospacedDigit()
                    }
                    Spacer(minLength: 8)
                    Button("Cancel") { state.cancel(job.id) }
                        .buttonStyle(.paperSecondary)
                }
                .font(.system(size: 13))
                .foregroundStyle(Paper.inkMuted)
            }
        }
    }

    private var line: String {
        switch job.step {
        case .queued:
            return "Waiting until I've finished the meeting before this one."
        case .transcribing:
            return "Listening back… \(Int((job.transcriptionProgress * 100).rounded())) %"
        case .summarizing:
            return job.liveText.isEmpty && job.thinkingChars > 0 ? "Thinking it over, then writing the notes…"
                : "Writing the notes…"
        }
    }

    private var detail: String {
        switch job.step {
        case .queued:
            return "Queued"
        case .transcribing:
            return job.model + (job.language.map { " · \(Prefs.languageName($0))" } ?? "")
        case .summarizing:
            let speed = job.tokensPerSecond > 0 ? " · \(Int(job.tokensPerSecond)) tok/s" : ""
            return "LM Studio · \(job.model)\(speed)"
        }
    }
}

/// A thin ink bar on a hairline track.
struct PaperProgress: View {
    var value: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Paper.hairline)
                Capsule().fill(Paper.ink).frame(width: geo.size.width * min(max(value, 0), 1))
            }
        }
        .frame(height: 4)
        .animation(.easeOut(duration: 0.3), value: value)
        .accessibilityValue("\(Int(value * 100)) percent")
    }
}

// MARK: - Details

/// What the Details tab used to hold, now at the end of the full summary:
/// the calendar event or invite, how the meeting was processed, and its files.
struct MeetingDetailsTab: View {
    @EnvironmentObject private var state: AppState
    let meeting: Meeting

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            CalendarEventCard(meeting: meeting) // R2-1
            Card(title: "How it was processed", subtitle: "Everything ran on this Mac. Nothing was uploaded.") {
                VStack(alignment: .leading, spacing: 8) {
                    if let app = meeting.info.callApp { // R1-2, moved off the date line
                        InfoRow("Call", CallApps.shortName(name: app, bundleID: meeting.info.callAppBundleID))
                    }
                    InfoRow("Microphone", meeting.info.microphone ?? "Default input")
                    // R2-4: what played the call, and the echo taken off the mic.
                    if let output = meeting.info.outputDevice { InfoRow("Output", output) }
                    if let echo = EchoHint.removedText(meeting.info.echoRemovedSeconds) { InfoRow("Echo", echo) }
                    InfoRow("Language", meeting.info.language.map(Prefs.languageName) ?? "Unknown")
                    InfoRow("Transcription", transcriptionText)
                    // R1-3: the vocabulary Whisper was given; hover to see it.
                    if let terms = meeting.info.vocabularyTerms, !terms.isEmpty {
                        InfoRow("Vocabulary", terms.count == 1 ? "1 term" : "\(terms.count) terms")
                            .help(terms.joined(separator: ", "))
                    }
                    // R2-2: voices found on the call, or why they weren't separated.
                    if let speakers = speakersText { InfoRow("Speakers", speakers) }
                    InfoRow("Summary", summaryText)
                    if let context = NotesContextText.text(meeting.info) { InfoRow("Context", context) } // R2-7
                }
            }

            Card(title: "Files") {
                VStack(spacing: 0) {
                    ForEach(Array(mainFiles.enumerated()), id: \.element.id) { i, file in
                        if i > 0 { rule }
                        fileRow(file)
                    }
                }
                if !technicalFiles.isEmpty {
                    DisclosureGroup("Technical files (\(technicalFiles.count))") {
                        VStack(spacing: 0) {
                            ForEach(Array(technicalFiles.enumerated()), id: \.element.id) { i, file in
                                if i > 0 { rule }
                                fileRow(file)
                            }
                        }
                        .padding(.top, 4)
                    }
                    .font(.system(size: 14))
                    .foregroundStyle(Paper.ink)
                }
                rule
                HStack(spacing: 10) {
                    Text("\(Format.bytes(meeting.totalBytes)) in \(RecordingView.tilde(meeting.folder))")
                        .font(.system(size: 13))
                        .foregroundStyle(Paper.inkMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Show in Finder") { state.reveal(meeting.id) }
                    Button("Delete Audio…") { state.deleteAudio(meeting.id) }
                        .disabled(state.isBusy(meeting.id) || !meeting.hasAudio)
                }
                .buttonStyle(.paperSecondary)
            }
        }
    }

    private var rule: some View { Rectangle().fill(Paper.hairline).frame(height: 1) }

    private static let mainNames: Set<String> = ["transcript.md", "summary.md"]
    private var mainFiles: [MeetingFile] {
        meeting.files.filter { $0.isAudio || Self.mainNames.contains($0.name) }
    }
    private var technicalFiles: [MeetingFile] {
        meeting.files.filter { !($0.isAudio || Self.mainNames.contains($0.name)) }
    }

    private func fileRow(_ file: MeetingFile) -> some View {
        HStack(spacing: 12) {
            Image(systemName: file.isAudio ? "waveform" : "doc.text")
                .foregroundStyle(Paper.inkMuted)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(file.name).foregroundStyle(Paper.ink)
                if !file.description.isEmpty {
                    Text(file.description).font(.system(size: 13)).foregroundStyle(Paper.inkMuted)
                }
            }
            Spacer()
            Text(Format.bytes(file.bytes))
                .monospacedDigit()
                .foregroundStyle(Paper.inkMuted)
            Button {
                state.open(meeting.id, file: file.name)
            } label: {
                Image(systemName: "arrow.up.right.square").foregroundStyle(Paper.inkMuted)
            }
            .buttonStyle(.borderless)
            .help("Open \(file.name)")
        }
        .font(.system(size: 14))
        .padding(.vertical, 8)
    }

    private var transcriptionText: String {
        guard let model = meeting.info.transcriptionModel else { return "Not yet" }
        let took = meeting.info.transcriptionSeconds.map { " · took \(Format.duration($0))" } ?? ""
        return "whisper.cpp, \(model)\(took)"
    }

    private var speakersText: String? {
        guard let model = meeting.info.speakerModel else { return meeting.info.speakerNote }
        let count = meeting.info.speakerCount ?? 0
        let found = count == 1 ? "1 voice" : "\(count) voices"
        let took = meeting.info.diarizationSeconds.map { " · took \(Format.duration($0))" } ?? ""
        return "\(found), \(model)\(took)"
    }

    private var summaryText: String {
        guard let model = meeting.info.summaryModel else { return "Not yet" }
        let took = meeting.info.summarySeconds.map { " · took \(Format.duration($0))" } ?? ""
        let speed = meeting.info.summaryTokensPerSecond.map { " at \(Int($0)) tok/s" } ?? ""
        return "LM Studio, \(model)\(took)\(speed)"
    }
}
