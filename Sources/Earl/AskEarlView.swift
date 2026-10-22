import AppKit
import SwiftUI

// S-3: Ask Earl on the page. A calm field at the foot of the front page, an
// answer drawer that rises over the lower notes, the Ask page for questions
// across every meeting, and the ⌘K row that leads there.

// MARK: - State

/// One place to ask: a meeting's page (its own session) or the Ask page.
@MainActor
final class AskSession: ObservableObject {
    enum Phase: Equatable {
        case idle
        /// Retrieving and waiting for the first words.
        case looking
        case streaming
        /// `setup`: LM Studio or the model is missing (offer Settings).
        case failed(String, setup: Bool)
    }

    /// nil on the Ask page.
    let meetingID: String?
    @Published var scope: AskScope
    @Published var text = ""
    @Published var open = false
    @Published private(set) var phase = Phase.idle
    /// Answers so far, oldest first; the last one is shown open.
    @Published private(set) var history: [EarlAnswer] = []
    /// The question being answered.
    @Published private(set) var pending: String?
    @Published private(set) var liveText = ""
    @Published var expanded: Set<UUID> = []
    /// What a citation may point to while streaming.
    private(set) var limits: [String: Double] = [:]
    private var task: Task<Void, Never>?

    init(meetingID: String?) {
        self.meetingID = meetingID
        scope = meetingID.map(AskScope.meeting) ?? .all
    }

    var isBusy: Bool { phase == .looking || phase == .streaming }

    func load(meetings: [Meeting]) {
        if let meetingID, let meeting = meetings.first(where: { $0.id == meetingID }) {
            history = AskHistory.load(AskHistory.url(for: meeting))
        } else if meetingID == nil {
            history = AskHistory.load(AskHistory.globalURL)
        }
    }

    func ask(_ question: String? = nil, meetings: [Meeting]) {
        let q = (question ?? text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        task?.cancel()
        text = q
        pending = q
        liveText = ""
        phase = .looking
        open = true
        let scope = scope
        let current = meetingID
        task = Task { [weak self] in
            let request = await Task.detached(priority: .userInitiated) {
                AskContext.request(question: q, scope: scope, meetings: meetings)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.limits = request.meetings
            let starts = Dictionary(meetings.map { ($0.id, $0.info.startedAt) }, uniquingKeysWith: { a, _ in a })
            do {
                let raw = try await AskEngine().ask(request) { [weak self] text in
                    guard let self, !Task.isCancelled else { return }
                    self.liveText = text
                    if !text.isEmpty { self.phase = .streaming }
                }
                guard !Task.isCancelled else { return }
                let parsed = AskCitations.parse(raw, limits: request.meetings, current: current) { id, s in
                    starts[id].map { AskCitations.label(start: $0, seconds: s) } ?? Meeting.timestamp(s)
                }
                let answer = EarlAnswer(question: q, scope: scope, text: parsed.text, citations: parsed.citations,
                                        date: Date(),
                                        notFound: Self.notFound(parsed, request: request, question: q))
                AskHistory.append(answer, to: AskHistory.url(for: scope, meetings: meetings))
                self.history = Array((self.history + [answer]).suffix(AskHistory.limit))
                self.pending = nil
                self.phase = .idle
            } catch is CancellationError {
            } catch let error as URLError where error.code == .cancelled {
            } catch {
                guard !Task.isCancelled else { return }
                self.phase = .failed(error.localizedDescription, setup: error is AskError)
            }
        }
    }

    /// The model said [[none]], or answered a question with nothing found
    /// and nothing cited. A recap or draft written from records is an answer
    /// even without citations.
    static func notFound(_ parsed: AskCitations.Parsed, request: AskRequest, question: String) -> Bool {
        if parsed.notFound { return true }
        guard parsed.citations.isEmpty else { return false }
        if request.material.isEmpty { return true }
        return !request.foundAnything && !AskIntent.isTask(question)
    }

    func cancel() {
        task?.cancel()
        task = nil
        if isBusy {
            pending = nil
            phase = .idle
        }
    }

    func close() {
        cancel()
        open = false
        if case .failed = phase { phase = .idle; pending = nil }
    }

    /// U-0: the demo shows the drawer with the stored answers.
    func showDemo(meetings: [Meeting]) {
        load(meetings: meetings)
        text = history.last?.question ?? ""
        open = !history.isEmpty
    }
}

/// What crosses screens: a question from ⌘K for the Ask page, and a moment
/// to play when a citation opens another meeting.
@MainActor
final class AskCenter: ObservableObject {
    static let shared = AskCenter()
    let all = AskSession(meetingID: nil)
    var pendingMoment: (meetingID: String, seconds: Double)?
}

// MARK: - The meeting page hook

extension View {
    /// The ask field under the front page and the drawer above it (S-3).
    func askEarl(meeting: Meeting, enabled: Bool, onPlay: ((Turn) -> Void)?) -> some View {
        modifier(AskEarlPanel(meeting: meeting, enabled: enabled, onPlay: onPlay))
    }
}

private struct AskEarlPanel: ViewModifier {
    @EnvironmentObject private var state: AppState
    let meeting: Meeting
    let enabled: Bool
    var onPlay: ((Turn) -> Void)?

    @StateObject private var session: AskSession
    @FocusState private var focused: Bool

    init(meeting: Meeting, enabled: Bool, onPlay: ((Turn) -> Void)?) {
        self.meeting = meeting
        self.enabled = enabled
        self.onPlay = onPlay
        _session = StateObject(wrappedValue: AskSession(meetingID: meeting.id))
    }

    private var seriesMembers: [Meeting] {
        MeetingSeries.members(of: meeting, in: state.meetings).filter(\.hasContent)
    }

    func body(content: Content) -> some View {
        VStack(spacing: 0) {
            content
                .overlay {
                    if enabled { layer }
                }
            if enabled {
                AskField(session: session, focused: $focused, placeholder: "Ask anything…",
                         scopes: scopes) { session.ask(meetings: state.meetings) }
            }
        }
        .onAppear {
            session.load(meetings: state.meetings)
            if DemoMode.askOpen { session.showDemo(meetings: state.meetings) } // U-0
            if let moment = AskCenter.shared.pendingMoment, moment.meetingID == meeting.id {
                AskCenter.shared.pendingMoment = nil
                cite(Citation(meetingID: moment.meetingID, seconds: moment.seconds, label: ""))
            }
        }
        .onDisappear { session.cancel() }
    }

    private var scopes: [(AskScope, String)] {
        var out: [(AskScope, String)] = [(.meeting(meeting.id), "This meeting")]
        if let key = MeetingSeries.key(for: meeting), seriesMembers.count >= 2 {
            out.append((.series(key), "\(MeetingSeries.displayName(seriesMembers)) series"))
        }
        out.append((.all, "All meetings"))
        return out
    }

    @ViewBuilder
    private var layer: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                if session.open {
                    // Clicking outside closes the drawer.
                    Color.black.opacity(0.0001)
                        .contentShape(Rectangle())
                        .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { session.close() } }
                    AskDrawer(session: session, maxHeight: geo.size.height * 0.6, currentMeeting: meeting,
                              onCite: cite, onSettings: { state.selection = .engine })
                        .padding(.horizontal, 22)
                        .padding(.bottom, 12)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else if focused && session.text.isEmpty {
                    suggestions
                        .padding(.horizontal, 22)
                        .padding(.bottom, 12)
                        .transition(.opacity)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .bottom)
        }
        .animation(.easeOut(duration: 0.22), value: session.open)
        .animation(.easeOut(duration: 0.15), value: focused && session.text.isEmpty)
    }

    /// Up to three questions to start with, and the way back to earlier ones.
    private var suggestions: some View {
        HStack(spacing: 8) {
            ForEach(suggestionList, id: \.self) { q in
                Button(q) { session.ask(q, meetings: state.meetings) }
                    .buttonStyle(.paperSecondary)
            }
            Spacer(minLength: 8)
            if !session.history.isEmpty {
                MoreLine(text: session.history.count == 1 ? "1 earlier question" : "\(session.history.count) earlier questions") {
                    session.open = true
                }
            }
        }
    }

    private var suggestionList: [String] {
        var out = ["What do I owe?"]
        if seriesMembers.count >= 2 { out.append("What changed since last time?") }
        out.append("Write a recap email")
        return out
    }

    private func cite(_ c: Citation) {
        if c.meetingID == meeting.id {
            guard let onPlay else { return }
            let turns = meeting.turns.sorted { $0.start < $1.start }
            let turn = turns.last { $0.start <= c.seconds + 0.5 } ?? turns.first
                ?? Turn(start: c.seconds, end: c.seconds, speaker: "Them", text: "")
            onPlay(turn)
        } else {
            AskCenter.shared.pendingMoment = (c.meetingID, c.seconds)
            state.selection = .meeting(c.meetingID)
        }
    }
}

// MARK: - The field

/// One quiet field floating on the paper, like the conversation panel beside
/// it: Earl, the question, and what it's about.
struct AskField: View {
    @ObservedObject var session: AskSession
    var focused: FocusState<Bool>.Binding
    var placeholder: String
    /// The scope menu; one entry hides it.
    var scopes: [(AskScope, String)]
    /// The Ask page keeps the field to its reading measure.
    var maxWidth: CGFloat = .infinity
    var submit: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            EarlAvatar(size: 22)
            TextField(placeholder, text: $session.text,
                      prompt: Text(placeholder).foregroundStyle(Paper.inkMuted))
                .textFieldStyle(.plain)
                .font(.paperBody)
                .foregroundStyle(Paper.ink)
                .focused(focused)
                .onSubmit(submit)
                .onExitCommand {
                    if session.open { withAnimation(.easeOut(duration: 0.2)) { session.close() } }
                    else { focused.wrappedValue = false }
                }
            if scopes.count > 1 { scopeMenu }
        }
        .padding(.leading, 8)
        .padding(.trailing, 12)
        .frame(height: 36)
        .background(Paper.card, in: RoundedRectangle(cornerRadius: Paper.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Paper.Radius.card, style: .continuous)
            .strokeBorder(focused.wrappedValue ? Paper.ticketDash : Paper.hairline))
        .shadow(color: .black.opacity(0.1), radius: 14, x: 0, y: 6)
        .frame(maxWidth: maxWidth)
        .padding(.horizontal, 22)
        .padding(.top, 6)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
        .background {
            Button("Ask Earl") { focused.wrappedValue = true }
                .keyboardShortcut("j", modifiers: .command)
                .hidden()
        }
        .help("Ask Earl (⌘J)")
    }

    private var scopeMenu: some View {
        Menu {
            ForEach(scopes, id: \.0) { scope, name in
                Button {
                    session.scope = scope
                } label: {
                    if scope == session.scope { Label(name, systemImage: "checkmark") } else { Text(name) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(scopes.first { $0.0 == session.scope }?.1 ?? scopes[0].1).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").imageScale(.small)
            }
            .font(.system(size: 13))
            .foregroundStyle(Paper.inkMuted)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("What to ask about")
    }
}

// MARK: - The drawer

/// A paper card rising from the field: earlier questions folded to a line,
/// the latest open, Earl's answer with its moments.
private struct AskDrawer: View {
    @ObservedObject var session: AskSession
    let maxHeight: CGFloat
    let currentMeeting: Meeting
    var onCite: (Citation) -> Void
    var onSettings: () -> Void

    @State private var contentHeight: CGFloat = 0

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Paper.Radius.panel, style: .continuous)
        ScrollViewReader { proxy in
            ScrollView {
                AskThread(session: session, currentMeetingID: currentMeeting.id, onCite: onCite, onSettings: onSettings)
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 18)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                    // Also behind the content itself, so the offscreen snapshot
                    // (which draws scroll content as its own layer) shows the card.
                    .background(Paper.card)
            }
            .scrollIndicators(.automatic)
            .frame(height: min(max(contentHeight, 60), maxHeight))
            .onChange(of: session.history.count, initial: true) { _, _ in proxy.scrollTo(AskThread.bottom, anchor: .bottom) }
            .onChange(of: session.liveText) { _, _ in proxy.scrollTo(AskThread.bottom, anchor: .bottom) }
        }
        .background(Paper.card, in: shape)
        .overlay(shape.strokeBorder(Paper.hairline))
        .overlay(alignment: .topTrailing) {
            Button { withAnimation(.easeOut(duration: 0.2)) { session.close() } } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Paper.inkMuted)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close (Esc)")
            .padding(6)
        }
        .clipShape(shape)
        .shadow(color: Color(red: 43 / 255, green: 33 / 255, blue: 24 / 255).opacity(0.16), radius: 20, x: 0, y: 10)
        .onExitCommand { withAnimation(.easeOut(duration: 0.2)) { session.close() } }
    }
}

/// Earlier questions as one line each, then the latest answer or the one
/// being written. Shared by the drawer and the Ask page.
struct AskThread: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var session: AskSession
    /// The meeting the page is about, so its moments show only the clock.
    var currentMeetingID: String?
    var showsScope = false
    var onCite: (Citation) -> Void
    var onSettings: () -> Void

    static let bottom = "ask-bottom"

    var body: some View {
        let open = session.pending == nil ? session.history.last?.id : nil
        VStack(alignment: .leading, spacing: 0) {
            ForEach(session.history) { answer in
                if answer.id == open || session.expanded.contains(answer.id) {
                    AnswerBlock(answer: answer, currentMeetingID: currentMeetingID, showsScope: showsScope,
                                collapsible: answer.id != open, onCite: onCite,
                                onCollapse: { session.expanded.remove(answer.id) },
                                onAskAgain: session.isBusy ? nil : { session.ask(answer.question, meetings: state.meetings) })
                    .padding(.vertical, 10)
                } else {
                    EarlierLine(answer: answer, showsScope: showsScope) { session.expanded.insert(answer.id) }
                }
            }
            if let question = session.pending {
                VStack(alignment: .leading, spacing: 10) {
                    QuestionLine(text: question)
                    pendingBody
                }
                .padding(.vertical, 10)
            }
            Color.clear.frame(height: 1).id(Self.bottom)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var pendingBody: some View {
        switch session.phase {
        case .failed(let message, let setup):
            VStack(alignment: .leading, spacing: 10) {
                Label(setup ? "LM Studio isn't answering." : "I couldn't answer that.", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Paper.error)
                Text(message)
                    .font(.paperBody)
                    .foregroundStyle(Paper.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if setup {
                    Button("Open Settings", action: onSettings).buttonStyle(.paperSecondary)
                }
            }
        case .streaming where !session.liveText.isEmpty:
            let parsed = AskCitations.parse(session.liveText, limits: session.limits, current: session.meetingID) { _, s in
                Meeting.timestamp(s)
            }
            EarlReplies(lead: parsed.notFound ? AnswerBlock.notFoundLead : AnswerBlock.foundLead) {
                AnswerText(text: parsed.text, citations: parsed.citations, currentMeetingID: currentMeetingID,
                           onCite: onCite)
            }
        default:
            HStack(spacing: 12) {
                EarlAvatar(size: 28, glintOnAppear: true)
                Text("Earl is looking…").font(.paperBody).foregroundStyle(Paper.inkMuted)
            }
        }
    }
}

/// The question, quietly, above Earl's answer.
private struct QuestionLine: View {
    let text: String
    var scope: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(text)
                .font(.paperLabel)
                .foregroundStyle(Paper.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if let scope { Text("· " + scope).font(.system(size: 13)).foregroundStyle(Paper.inkMuted) }
        }
        .padding(.trailing, 28) // clear of the close button
    }
}

/// An earlier question, folded to one line; click to open it.
private struct EarlierLine: View {
    let answer: EarlAnswer
    var showsScope = false
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .imageScale(.small)
                    .foregroundStyle(Paper.inkMuted)
                Text(answer.question)
                    .font(.system(size: 14))
                    .foregroundStyle(hovering ? Paper.ink : Paper.inkMuted)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(when)
                    .font(.system(size: 13))
                    .foregroundStyle(Paper.inkMuted)
                    .opacity(hovering ? 1 : 0)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .padding(.trailing, 28)
    }

    private var when: String {
        let scope = showsScope ? AnswerBlock.scopeName(answer.scope).map { $0 + " · " } ?? "" : ""
        return scope + answer.date.formatted(.relative(presentation: .named))
    }
}

/// One answered question: the question, then Earl. Copy on hover.
struct AnswerBlock: View {
    @EnvironmentObject private var state: AppState
    let answer: EarlAnswer
    var currentMeetingID: String?
    var showsScope = false
    /// An earlier answer opened by hand: clicking the question folds it.
    var collapsible = false
    var onCite: (Citation) -> Void
    var onCollapse: () -> Void = {}
    /// Offered under "The notes don't say.": an older answer may predate a
    /// better Earl, or the question may read better asked again.
    var onAskAgain: (() -> Void)?

    @State private var hovering = false
    @State private var copied = false

    static let foundLead = "Here's what I have —"
    static let notFoundLead = "The notes don't say."

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                if collapsible {
                    Button(action: onCollapse) {
                        QuestionLine(text: answer.question, scope: showsScope ? Self.scopeName(answer.scope) : nil)
                    }
                    .buttonStyle(.plain)
                } else {
                    QuestionLine(text: answer.question, scope: showsScope ? Self.scopeName(answer.scope) : nil)
                }
            }
            EarlReplies(lead: answer.notFound == true ? Self.notFoundLead : Self.foundLead) {
                AnswerText(text: answer.text, citations: answer.citations, currentMeetingID: currentMeetingID,
                           onCite: onCite)
                if answer.notFound == true, let onAskAgain {
                    Button("Ask again", action: onAskAgain)
                        .buttonStyle(.paperSecondary)
                        .padding(.top, 6)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if hovering {
                    Button(copied ? "Copied" : "Copy") { copy() }
                        .buttonStyle(.plain)
                        .font(.paperLabel)
                        .foregroundStyle(Paper.ink)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(Paper.card, in: Capsule())
                        .overlay(Capsule().strokeBorder(Paper.hairline))
                        .offset(y: 14)
                        .transition(.opacity)
                }
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    /// "Daily KICC series"; nil for one meeting or all of them.
    static func scopeName(_ scope: AskScope) -> String? {
        switch scope {
        case .meeting: nil
        case .all: nil // the Ask page is about all of them already
        case .series(let key): key.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ") + " series"
        }
    }

    private func copy() {
        let plain = AnswerText.plain(answer.text, citations: answer.citations)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(plain, forType: .string)
        copied = true
    }
}

/// Earl's face, a handwritten lead, then the answer in body text.
private struct EarlReplies<Body: View>: View {
    let lead: String
    @ViewBuilder var content: Body

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            EarlAvatar(size: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(lead).font(.earlVoice(size: 19)).foregroundStyle(Paper.ink)
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - The answer's text

/// Markdown (paragraphs, bullets, bold) with each citation as a small chip
/// after its sentence. Clicking a chip plays the moment.
struct AnswerText: View {
    @EnvironmentObject private var state: AppState
    let text: String
    let citations: [Citation]
    var currentMeetingID: String?
    var onCite: (Citation) -> Void

    enum Block: Equatable {
        case paragraph(String)
        case bullet(String)
        case numbered(String, String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(Self.blocks(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let s):
                    line(s)
                case .bullet(let s):
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Text("•").foregroundStyle(Paper.inkMuted)
                        line(s)
                    }
                case .numbered(let n, let s):
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(n).foregroundStyle(Paper.inkMuted).monospacedDigit()
                        line(s)
                    }
                }
            }
        }
        .font(.paperBody)
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "earl-cite", let i = Int(url.host ?? ""), citations.indices.contains(i) else {
                return .systemAction
            }
            onCite(citations[i])
            return .handled
        })
    }

    private func line(_ s: String) -> some View {
        Text(Self.attributed(s, citations: citations, currentMeetingID: currentMeetingID,
                             currentStart: currentMeetingID.flatMap { state.meeting($0)?.info.startedAt }))
            .font(.paperBody)
            .lineSpacing(4)
            .foregroundStyle(Paper.ink)
            .tint(Paper.ink)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    static func blocks(_ text: String) -> [Block] {
        var out: [Block] = []
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty { out.append(.paragraph(paragraph.joined(separator: " "))) }
            paragraph = []
        }
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }
            if let first = line.first, "-*•".contains(first), line.dropFirst().first == " " {
                flush()
                out.append(.bullet(String(line.dropFirst(2))))
            } else if let dot = line.firstIndex(of: "."), dot > line.startIndex, line[..<dot].allSatisfy(\.isNumber),
                      line[line.index(after: dot)...].first == " " {
                flush()
                out.append(.numbered(String(line[...dot]), line[line.index(after: dot)...].trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix("#") {
                flush()
                out.append(.paragraph("**" + line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces) + "**"))
            } else {
                paragraph.append(line)
            }
        }
        flush()
        return out
    }

    /// Inline Markdown with each `[[id@mm:ss]]` turned into a chip link.
    static func attributed(_ s: String, citations: [Citation], currentMeetingID: String?,
                           currentStart: Date? = nil) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        func markdown(_ t: Substring) -> AttributedString {
            (try? AttributedString(markdown: String(t), options: options)) ?? AttributedString(t)
        }
        var out = AttributedString()
        var rest = Substring(s)
        while let m = rest.firstMatch(of: AskCitations.pattern) {
            var before = markdown(rest[..<m.range.lowerBound])
            // Keep the sentence's last character with its chip on one line.
            if before.characters.last == " " { before.characters.removeLast() }
            out += before
            let seconds = AskCitations.seconds(String(m.2)) ?? -1
            if let i = citations.firstIndex(where: { $0.meetingID == String(m.1) && $0.seconds == seconds }) {
                out += chip(citations[i], index: i, currentMeetingID: currentMeetingID, currentStart: currentStart)
            }
            rest = rest[m.range.upperBound...]
        }
        out += markdown(rest)
        return out
    }

    /// "9:41" in the meeting you're on, "Tue 9:41" for another one.
    static func chipLabel(_ c: Citation, currentMeetingID: String?, currentStart: Date?) -> String {
        if c.meetingID == currentMeetingID, let currentStart {
            return AskCitations.clock(start: currentStart, seconds: c.seconds)
        }
        return c.label.isEmpty ? Meeting.timestamp(c.seconds) : c.label
    }

    private static func chip(_ c: Citation, index: Int, currentMeetingID: String?, currentStart: Date?) -> AttributedString {
        var chip = AttributedString("\u{00A0}" + chipLabel(c, currentMeetingID: currentMeetingID, currentStart: currentStart)
                                        .replacingOccurrences(of: " ", with: "\u{00A0}") + "\u{00A0}")
        chip.font = .system(size: 13, weight: .semibold).monospacedDigit()
        chip.foregroundColor = Paper.ink
        chip.backgroundColor = Paper.hairline
        chip.link = URL(string: "earl-cite://\(index)")
        return AttributedString("\u{00A0}") + chip
    }

    /// For Copy: Markdown with the chips as "(Tue 9:41)".
    static func plain(_ text: String, citations: [Citation]) -> String {
        var out = ""
        var rest = Substring(text)
        while let m = rest.firstMatch(of: AskCitations.pattern) {
            out += rest[..<m.range.lowerBound]
            let seconds = AskCitations.seconds(String(m.2)) ?? -1
            if let c = citations.first(where: { $0.meetingID == String(m.1) && $0.seconds == seconds }) {
                out += "(\(c.label.isEmpty ? Meeting.timestamp(c.seconds) : c.label))"
            }
            rest = rest[m.range.upperBound...]
        }
        return out + rest
    }
}

// MARK: - The Ask page

/// Questions across every meeting: the masthead, the answers full width,
/// the field at the bottom.
struct AskPage: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var session = AskCenter.shared.all
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Masthead("Ask Earl · All meetings")
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        // The same headline slot as every other page.
                        // The masthead names the page; the headline asks.
                        Text("What would you like to know?")
                            .font(.paperHeadline)
                            .foregroundStyle(Paper.ink)
                        Text("Anything said in any of your meetings.")
                            .font(PageGrid.sublineFont)
                            .foregroundStyle(Paper.inkMuted)
                            .padding(.top, PageGrid.subline)
                        Group {
                            if session.history.isEmpty && session.pending == nil {
                                empty
                            } else {
                                AskThread(session: session, currentMeetingID: nil, showsScope: true,
                                          onCite: open, onSettings: { state.selection = .engine })
                            }
                        }
                        .padding(.top, 26)
                    }
                    .frame(maxWidth: 680, alignment: .leading)
                    .padding(.horizontal, Paper.Space.pageX)
                    .padding(.top, PageGrid.top)
                    .padding(.bottom, PageGrid.bottom)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: session.history.count, initial: true) { _, _ in proxy.scrollTo(AskThread.bottom, anchor: .bottom) }
                .onChange(of: session.liveText) { _, _ in proxy.scrollTo(AskThread.bottom, anchor: .bottom) }
            }
            AskField(session: session, focused: $focused, placeholder: "Ask about any meeting…",
                     scopes: [(.all, "All meetings")], maxWidth: 680 + 2 * Paper.Space.pageX - 44) {
                session.ask(meetings: state.meetings)
            }
        }
        .paperBackground(.paper)
        .navigationTitle("")
        .onAppear {
            session.load(meetings: state.meetings)
            if !session.isBusy { session.scope = .all }
            if !DemoMode.isActive { focused = true }
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 14) {
            EarlAvatar(size: 40)
            EarlLine(lead: "At your service.",
                     text: "I keep every word, discreetly. Ask me who promised what, when something was decided, "
                         + "or what changed since last time.",
                     leadSize: 21, textFont: .paperLede)
        }
    }

    private func open(_ c: Citation) {
        AskCenter.shared.pendingMoment = (c.meetingID, c.seconds)
        state.selection = .meeting(c.meetingID)
    }
}

// MARK: - ⌘K

/// The first row of ⌘K search when the search reads like a question.
struct AskSearchRow: View {
    let query: String
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                EarlAvatar(size: 22)
                Text("\(Text("Ask Earl:").font(.system(size: 14.5, weight: .semibold))) \(Text(query.trimmingCharacters(in: .whitespaces)).font(.paperChat))")
                    .foregroundStyle(Paper.ink)
                    .lineLimit(2)
                Spacer(minLength: 4)
                Image(systemName: "return")
                    .font(.system(size: 13))
                    .foregroundStyle(Paper.inkMuted)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Paper.card, in: RoundedRectangle(cornerRadius: Paper.Radius.row, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Paper.Radius.row, style: .continuous)
                .strokeBorder(hovering ? Paper.ticketDash : Paper.hairline))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Ask Earl across all your meetings (Return)")
        .padding(.top, 10)
    }
}

extension AskCenter {
    /// Opens the Ask page with a question from ⌘K.
    func ask(_ question: String, state: AppState) {
        all.scope = .all
        all.ask(question, meetings: state.meetings)
        state.selection = .ask
    }
}

/// ⌘K with a question: the meetings that mention its words, rather than the
/// whole sentence (which no meeting contains).
enum AskSearch {
    static func filter(_ meetings: [Meeting], query: String) -> [Meeting] {
        guard AskQuestion.isQuestion(query) else { return meetings.filter { $0.matches(query) } }
        let terms = AskText.terms(query).filter { $0.count >= 4 }
        guard !terms.isEmpty else { return meetings }
        return meetings.filter { m in terms.contains { m.matches($0) } }
    }
}
