import SwiftUI

// U-2: the meeting's front page. A headline that says what happened, the cast,
// Earl's briefing, then what was decided and who does what; the rest behind
// "Full summary". The conversation runs beside it (Conversation.swift).

// MARK: - Notes, sorted for the page

/// A meeting's notes (summary.md) sorted into the parts of the front page.
struct FrontPageNotes: Equatable {
    struct Section: Equatable {
        var title: String
        var bullets: [String]
    }

    enum Kind { case summary, decisions, actions, open, other, since, points, answered } // S-1: since; K-1: points, answered

    var summary: [String] = []
    /// S-1: what moved since the last meeting of the series.
    var since: [String] = []
    var decisions: [String] = []
    var open: [String] = []
    /// K-1: a town hall's announcements, a talk's key points.
    var points: [String] = []
    /// K-1: questions asked, with the answers given.
    var answered: [String] = []
    /// Every checkbox line, in any section.
    var todos: [ActionItem] = []
    /// Sections the page has no place for, kept for the full summary.
    var other: [Section] = []

    var isEmpty: Bool {
        summary.isEmpty && decisions.isEmpty && open.isEmpty && todos.isEmpty && other.isEmpty && since.isEmpty
            && points.isEmpty && answered.isEmpty
    }

    /// Headings are asked for in English, but older notes and some models
    /// write them in the meeting's language.
    static func kind(of heading: String) -> Kind {
        let h = heading.lowercased()
        func has(_ words: [String]) -> Bool { words.contains { h.contains($0) } }
        // S-1: first, so "Since last time: open items" isn't taken for open questions.
        if has(["since last time", "since the last", "seit dem letzten", "seit letztem"]) { return .since }
        if has(["round the table", "runde"]) { return .summary }
        // K-1: before "question" (open) and "for you" (actions).
        if has(["questions asked", "q&a", "q & a", "asked and answered", "fragen und antworten", "gestellte fragen"]) {
            return .answered
        }
        if has(["announce", "key point", "worth remembering", "takeaway", "ankündigung", "mitteilung", "kernpunkt",
                "kernaussage", "wichtigste punkte"]) {
            return .points
        }
        if has(["for you", "für dich", "für sie"]) { return .actions }
        if has(["action", "to-do", "todo", "aufgabe", "next step", "nächste schritte"]) { return .actions }
        if has(["decision", "decided", "entscheid", "beschlo", "beschluss"]) { return .decisions }
        if has(["open", "offen", "question", "frage"]) { return .open }
        if has(["summary", "zusammenfassung", "overview", "überblick"]) { return .summary }
        return .other
    }

    static func parse(_ markdown: String, meetingID: String) -> FrontPageNotes {
        var notes = FrontPageNotes()
        var kind = Kind.summary
        for (index, raw) in markdown.components(separatedBy: "\n").enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("#") {
                let heading = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                kind = Self.kind(of: heading)
                if kind == .other { notes.other.append(Section(title: heading, bullets: [])) }
                continue
            }
            if let item = ActionItems.parseLine(raw, meetingID: meetingID, index: index) {
                notes.todos.append(item)
                continue
            }
            let text = bulletText(line)
            guard !text.isEmpty else { continue }
            switch kind {
            case .summary: notes.summary.append(text)
            case .decisions: notes.decisions.append(text)
            case .open: notes.open.append(text)
            case .since: notes.since.append(text) // S-1
            case .points: notes.points.append(text) // K-1
            case .answered: notes.answered.append(text) // K-1
            case .actions:
                // A to-do without a checkbox: keep it, as a plain line.
                if notes.other.last?.title != "Action items" { notes.other.append(Section(title: "Action items", bullets: [])) }
                notes.other[notes.other.count - 1].bullets.append(text)
            case .other:
                if notes.other.isEmpty { notes.other.append(Section(title: "Notes", bullets: [])) }
                notes.other[notes.other.count - 1].bullets.append(text)
            }
        }
        return notes
    }

    /// "- text", "* text", "• text", "1. text" → "text"; other lines as they are.
    static func bulletText(_ line: String) -> String {
        var s = Substring(line)
        if let first = s.first, "-*•+".contains(first), s.dropFirst().first == " " {
            s = s.dropFirst(2)
        } else if let dot = s.firstIndex(of: "."), dot > s.startIndex, s[..<dot].allSatisfy(\.isNumber),
                  s[s.index(after: dot)...].first == " " {
            s = s[s.index(after: dot)...]
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// Earl's briefing: the first summary bullets as one short paragraph, two
    /// or three sentences. `count` says how many bullets it used.
    static func briefing(_ bullets: [String], limit: Int = 170) -> (text: String, count: Int) {
        var sentences: [String] = []
        var length = 0
        for bullet in bullets.prefix(3) {
            let sentence = bullet.last.map { ".!?…".contains($0) } == true ? bullet : bullet + "."
            if !sentences.isEmpty && length + sentence.count > limit { break }
            sentences.append(sentence)
            length += sentence.count + 1
        }
        return (sentences.joined(separator: " "), sentences.count)
    }
}

// MARK: - Who a to-do belongs to, and where it was said

enum FrontPageMatch {
    /// The speaker an action item's owner names: "Speaker 2", a full name, or
    /// a first name that only one speaker has.
    static func speaker(for owner: String, in speakers: [Speaker]) -> Speaker? {
        let o = ActionItems.normalize(owner)
        if o.hasPrefix("speaker "), let n = Int(o.dropFirst("speaker ".count)) {
            return speakers.first { $0.number == n && ($0.name ?? "").isEmpty }
        }
        let named = speakers.filter { !($0.name ?? "").isEmpty }
        if let exact = named.first(where: { ActionItems.normalize($0.name ?? "") == o }) { return exact }
        let first = String(o.split(separator: " ").first ?? "")
        let byFirst = named.filter { ActionItems.normalize(AttendeeName.firstName($0.name ?? "")) == first }
        return byFirst.count == 1 ? byFirst[0] : nil
    }

    /// The turn a to-do was most likely agreed in: the one sharing the most
    /// of its longer words, when it shares at least half of them (and two).
    /// Nothing is better than a wrong moment, so the bar is high.
    static func sourceTurn(for task: String, in turns: [Turn]) -> Turn? {
        let words = significantWords(task)
        guard words.count >= 2 else { return nil }
        var best: (turn: Turn, shared: Int)?
        for turn in turns {
            let shared = words.intersection(significantWords(turn.text)).count
            if shared > (best?.shared ?? 0) { best = (turn, shared) }
        }
        guard let best, best.shared >= 2, Double(best.shared) / Double(words.count) >= 0.5 else { return nil }
        return best.turn
    }

    private static func significantWords(_ text: String) -> Set<String> {
        Set(ActionItems.normalize(text).split(separator: " ").map(String.init).filter { $0.count >= 4 && !stopWords.contains($0) })
    }

    private static let stopWords: Set<String> = [
        "with", "that", "this", "from", "have", "will", "into", "about", "them", "they", "their", "there", "what",
        "when", "then", "than", "also", "just", "some", "before", "after", "does", "make", "sure",
        "eine", "einen", "einem", "einer", "nicht", "noch", "oder", "aber", "dass", "wird", "werden", "sind", "bitte",
    ]
}

// MARK: - The cast

/// One face in the cast row.
struct CastMember: Identifiable, Equatable {
    enum Label: Equatable {
        /// A confirmed or remembered name, or "You" / "Them".
        case name(String)
        /// Earl's guess, shown with a "?".
        case guess(String)
        /// "Speaker 3", in a dashed tag.
        case unnamed(String)
    }

    var id: String
    var look: AvatarLook
    var label: Label
    var isYou: Bool
    /// The voice behind it, when voices were separated.
    var speakerID: String?
    /// The full name, for the tooltip.
    var help: String?

    /// Everyone who spoke, in order of first speech (the voice colour order).
    static func cast(turns: [Turn], speakers: [Speaker]) -> [CastMember] {
        let looks = SpeakerFaces.looks(for: speakers)
        var seen = Set<String>()
        var out: [CastMember] = []
        let names = speakers.compactMap(\.name).filter { !$0.isEmpty }
        for turn in turns.sorted(by: { $0.start < $1.start }) {
            let key = turn.speakerID ?? turn.speaker
            guard seen.insert(key).inserted else { continue }
            let look = SpeakerFaces.look(for: turn, in: speakers, looks: looks)
            if Speaker.isMe(turn, in: speakers) {
                out.append(CastMember(id: key, look: look, label: .name("You"), isYou: true, speakerID: turn.speakerID))
                continue
            }
            let speaker = speakers.first { $0.id == turn.speakerID }
            let display = Speaker.displayName(for: turn, in: speakers)
            let label: Label
            if let speaker, let name = speaker.name, !name.isEmpty {
                // First names keep the row short, unless two people share one.
                let first = AttendeeName.firstName(name)
                let short = names.filter { AttendeeName.firstName($0) == first }.count > 1 ? name : first
                label = speaker.isGuess ? .guess(short) : .name(short)
            } else if speaker != nil, display.hasPrefix("Speaker ") {
                label = .unnamed(display)
            } else {
                label = .name(display)
            }
            let help = speaker?.isGuess == true ? "Guessed: " + (speaker?.evidence ?? "from the conversation")
                : speaker?.recognisedHelp ?? speaker?.name
            out.append(CastMember(id: key, look: look, label: label, isYou: false, speakerID: speaker?.id, help: help))
        }
        return out
    }
}

// MARK: - Text

enum PageText {
    /// Where a search matches: a warm tan, since yellow means "decided".
    static let findHighlight = Paper.ticketDash

    /// Inline Markdown (models write **bold**), with the search query marked.
    static func attributed(_ s: String, query: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        var text = (try? AttributedString(markdown: s, options: options)) ?? AttributedString(s)
        highlight(&text, query: query)
        return text
    }

    static func highlight(_ text: inout AttributedString, query: String) {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        var searchRange = text.startIndex..<text.endIndex
        while let range = text[searchRange].range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) {
            text[range].backgroundColor = findHighlight
            text[range].foregroundColor = Paper.ink // also inside your blue bubbles
            searchRange = range.upperBound..<text.endIndex
        }
    }

    static func matches(_ s: String, query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        return !query.isEmpty && s.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}

/// The highlighter under a decision: the lower part of each line, like a
/// marker pen (The One Yellow Rule).
struct MarkerRenderer: TextRenderer {
    var color: Color

    func draw(layout: Text.Layout, in ctx: inout GraphicsContext) {
        for line in layout {
            let b = line.typographicBounds.rect
            let rect = CGRect(x: b.minX - 1, y: b.minY + b.height * 0.52, width: b.width + 2, height: b.height * 0.44)
            ctx.fill(Path(rect), with: .color(color))
            ctx.draw(line)
        }
    }
}

/// Section names in the meeting's language: the notes are written in it.
struct PageWords {
    var decided = "Decided"
    var stillOpen = "Still open"
    var yourTodos = "Your to-dos"
    var everyoneElse = "Everyone else"
    // K-1: listening kinds.
    var announced = "Announced"
    var worthKeeping = "Worth remembering"
    var answered = "Asked and answered"
    var forYou = "For you"

    init(language: String?) {
        if language == "de" {
            decided = "Entschieden"
            stillOpen = "Noch offen"
            yourTodos = "Deine To-dos"
            everyoneElse = "Alle anderen"
            announced = "Angekündigt"
            worthKeeping = "Zum Merken"
            answered = "Gefragt und beantwortet"
            forYou = "Für dich"
        }
    }

    /// K-1: the title over a town hall's announcements or a talk's key points.
    func points(_ kind: MeetingKind) -> String { kind == .townHall ? announced : worthKeeping }
}

// MARK: - The page

struct FrontPage: View {
    @EnvironmentObject private var state: AppState
    let meeting: Meeting
    let job: Job?
    let query: String
    /// Two columns fit.
    let wide: Bool
    /// The widest the page reads; nil fills the column.
    var measure: CGFloat?
    @Binding var expanded: Bool
    @Binding var editingTitle: Bool
    /// Plays from a turn; nil without audio.
    var onPlay: ((Turn) -> Void)?
    /// W-1: plays a few seconds of a turn, for who's who; nil without audio.
    var onClip: ((Turn, Double) -> Void)?

    /// False until the page has appeared, so it can settle in, slot by slot.
    /// Already settled for the demo's snapshots.
    @State private var settled = DemoMode.isActive
    @State private var arrival = NotesArrival()

    private var liveNotes: Summarizer.Result? {
        guard let job, job.step == .summarizing, !job.liveText.isEmpty else { return nil }
        return Summarizer.parse(job.liveText)
    }

    private var notesText: String { liveNotes?.markdown ?? (job == nil ? meeting.summary : "") }

    var body: some View {
        let notes = FrontPageNotes.parse(notesText, meetingID: meeting.id)
        let failed = job == nil && meeting.info.status == .failed
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HeadlineBlock(meeting: meeting, headline: liveNotes?.headline ?? meeting.info.headline,
                              small: failed, editing: $editingTitle)
                    .padding(.bottom, 14)
                    .settleIn(0, settled)
                if job?.step != .transcribing && job?.step != .queued && !meeting.turns.isEmpty {
                    CastRow(meeting: meeting, interactive: job == nil)
                        .padding(.bottom, 18)
                        .settleIn(1, settled)
                }
                // E-1: renames patch the notes in place, so no "names changed" notice.
                lead(notes, failed: failed)
                    .padding(.bottom, 26)
                    .settleIn(2, settled)
                    .environment(\.notesArrival, arrival)
                if job?.step != .transcribing && job?.step != .queued && !meeting.turns.isEmpty {
                    // W-1, after "In short": the summary leads, Earl's question follows.
                    WhosWhoCard(meeting: meeting, interactive: job == nil, onClip: onClip).id(meeting.id)
                        .settleIn(3, settled)
                }
                if !notes.since.isEmpty { // S-1
                    SinceLastTime(meeting: meeting, items: notes.since, query: query, interactive: job == nil)
                        .padding(.bottom, 26)
                        .settleIn(3, settled)
                }
                if !notes.isEmpty {
                    NotesColumns(meeting: meeting, notes: notes, query: query, wide: wide, expanded: $expanded,
                                 interactive: job == nil, onPlay: onPlay)
                        .settleIn(4, settled)
                }
                if job == nil {
                    if expanded {
                        FullSummary(meeting: meeting, notes: notes, query: query, expanded: $expanded)
                            .padding(.top, 8)
                    } else if !NotesColumns.overflows(notes, userName: Prefs.userName) {
                        MoreLine(text: notes.isEmpty ? "Details" : "Full summary") { expanded = true }
                    }
                }
            }
            .frame(maxWidth: measure.map { $0 - 2 * Paper.Space.pageX } ?? .infinity, alignment: .leading)
            .padding(.horizontal, Paper.Space.pageX)
            .padding(.top, 22)
            .padding(.bottom, 34)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.automatic)
        // Opening a meeting, the page settles in top to bottom. Fresh notes,
        // and Earl also writes out his "In short —"; watched as they finish,
        // only the writing plays.
        .onAppear {
            if job == nil && state.takeFreshNotes(meeting.id) {
                arrive(whole: true)
            } else if !settled {
                DispatchQueue.main.async { settled = true }
            }
        }
        .onChange(of: job == nil) { _, done in
            if done && state.takeFreshNotes(meeting.id) { arrive(whole: false) }
        }
        .askEarl(meeting: meeting, enabled: job == nil && meeting.hasContent, onPlay: onPlay) // S-3
        // E-1, W-1: toasts at the top of the column, clear of Ask Earl's field and drawer.
        .overlay(alignment: .top) {
            VStack(spacing: 8) {
                NotesUndoToast(meetingID: meeting.id)
                VoicePropagationToastView(meetingID: meeting.id)
            }
            .padding(.top, 14)
        }
    }

    private func arrive(whole: Bool) {
        if whole { settled = false }
        arrival.inked = false
        DispatchQueue.main.async {
            settled = true
            arrival.inked = true
            arrival.nod += 1
        }
    }

    /// What sits under the cast: Earl's briefing, or what he's doing, or what went wrong.
    @ViewBuilder
    private func lead(_ notes: FrontPageNotes, failed: Bool) -> some View {
        if let job {
            ProcessingCard(job: job)
        } else if failed {
            FailedCard(meeting: meeting)
        } else if !notes.summary.isEmpty {
            let briefing = FrontPageNotes.briefing(notes.summary)
            BriefingCard(text: briefing.text, query: query) { new in // E-1
                state.editBriefing(meetingID: meeting.id, bullets: Array(notes.summary.prefix(briefing.count)), to: new)
            }
        } else if !meeting.summary.isEmpty {
            EmptyView()
        } else if !Prefs.summariesEnabled {
            BriefingCard(lead: EarlVoice.nothingYet, text: "Notes are turned off. You can turn them on in Settings.")
        } else if !meeting.turns.isEmpty {
            BriefingCard(lead: EarlVoice.nothingYet, text: "I haven't written the notes for this one.") {
                Button("Write the notes") { state.resummarize(meeting.id) }
                    .buttonStyle(.paperPrimary)
                    .disabled(state.isBusy(meeting.id))
            }
        } else {
            BriefingCard(lead: EarlVoice.nothingYet, text: "Nothing was said, or it hasn't been transcribed.") {
                if meeting.hasAudio {
                    Button("Transcribe again") { state.retranscribe(meeting.id) }
                        .buttonStyle(.paperSecondary)
                        .disabled(state.isBusy(meeting.id))
                }
            }
        }
    }
}

/// "› 1 more · Full summary" and friends.
struct MoreLine: View {
    var text: String
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text("› " + text)
                .font(.system(size: 14))
                .foregroundStyle(hovering ? Paper.ink : Paper.inkMuted)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .padding(.top, 2)
    }
}

// MARK: - Headline

/// The headline, and the meeting's title under it when they differ. "Edit"
/// appears on hover and opens the title for renaming. E-1: a separate
/// headline is edited in place (double-click, or its pencil on hover).
struct HeadlineBlock: View {
    @EnvironmentObject private var state: AppState
    let meeting: Meeting
    let headline: String?
    /// The failed page's quieter headline.
    var small = false
    @Binding var editing: Bool

    @State private var title = ""
    @State private var hovering = false
    @FocusState private var focused: Bool
    @State private var editingHeadline = false // E-1
    @State private var hoveringHeadline = false // E-1

    private var canEdit: Bool { !state.isBusy(meeting.id) }

    /// A default title ("Meeting Oct 8, 2026 at 11:30") only repeats the date
    /// line; it reads "Untitled call", as in the sidebar.
    private var shownHeadline: String {
        headline ?? (meeting.info.titleIsDefault ? "Untitled call" : meeting.info.title)
    }
    private var showsTitleLine: Bool { headline != nil && headline != meeting.info.title }

    var body: some View {
        VStack(alignment: .leading, spacing: PageGrid.subline) {
            if editing && !showsTitleLine {
                titleField.font(.paperHeadline(size: small ? 26 : 34))
            } else if editingHeadline, let headline { // E-1
                NoteField(original: headline, font: .paperHeadline(size: small ? 26 : 34), lineSpacing: 1,
                          hint: "Return saves · Esc cancels · empty shows the title") { new in
                    editingHeadline = false
                    if let new, new != headline { state.editHeadline(meetingID: meeting.id, to: new) }
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    // "20 %" stays on one line.
                    Text(shownHeadline.replacingOccurrences(of: " %", with: "\u{00A0}%"))
                        .font(.paperHeadline(size: small ? 26 : 34))
                        .tracking(-0.4)
                        .lineSpacing(1)
                        .lineLimit(3)
                        .foregroundStyle(Paper.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(shownHeadline) // the whole of a headline cut at three lines
                    if showsTitleLine && canEdit { // E-1
                        EditPencil(visible: hoveringHeadline) { editingHeadline = true }
                    }
                }
                .pencilGutter(showsTitleLine && canEdit)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { // E-1: the headline, or the title standing in for it
                    guard canEdit else { return }
                    if showsTitleLine { editingHeadline = true } else { editing = true }
                }
                .onHover { hoveringHeadline = $0 }
            }
            // The subline only when it says something: the title being
            // renamed, or who was invited when no one spoke.
            if (showsTitleLine && editing) || meta != nil {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    if showsTitleLine && editing {
                        titleField.font(PageGrid.sublineFont)
                    } else if let meta {
                        Text(meta)
                            .font(PageGrid.sublineFont)
                            .foregroundStyle(Paper.inkMuted)
                            .lineLimit(1)
                            .help(meeting.info.attendeeNames.joined(separator: ", "))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onAppear { title = meeting.info.title }
        .onChange(of: meeting.info.title) { _, new in if !focused { title = new } }
        .onChange(of: editing) { _, on in
            if on {
                title = meeting.info.title
                focused = true
            }
        }
        .onChange(of: focused) { _, isFocused in
            if !isFocused { commit() }
        }
    }

    /// Under the headline: who was invited, only when there's no cast row to
    /// show them. The title lives in the masthead, so it's never said twice.
    private var meta: String? {
        guard meeting.turns.isEmpty else { return nil }
        return meeting.info.attendeeLine.map { $0.prefix(1).uppercased() + $0.dropFirst() }
    }

    private var titleField: some View {
        TextField("Title", text: $title, axis: .vertical)
            .textFieldStyle(.plain)
            .foregroundStyle(Paper.ink)
            .focused($focused)
            .onSubmit { focused = false }
            .onExitCommand {
                title = meeting.info.title
                focused = false
            }
    }

    private func commit() {
        guard editing else { return }
        editing = false
        if title != meeting.info.title { state.rename(meeting.id, to: title) }
    }
}

// MARK: - Cast

/// A face and a name per voice. A guess shows "?": clicking asks inline
/// whether it's that person. Everyone else opens the naming popover.
struct CastRow: View {
    @EnvironmentObject private var state: AppState
    let meeting: Meeting
    var interactive = true

    @State private var asking: String?
    @State private var naming: String?
    @State private var showAll = false

    static let visible = 6

    var body: some View {
        let cast = CastMember.cast(turns: meeting.turns, speakers: meeting.speakers)
        let shown = showAll || cast.count <= Self.visible ? cast : Array(cast.prefix(Self.visible))
        VStack(alignment: .leading, spacing: 12) {
            FlowLayout(spacing: 14, lineSpacing: 8) {
                ForEach(shown) { member in chip(member) }
                if shown.count < cast.count {
                    Button { showAll = true } label: {
                        Text("+\(cast.count - shown.count)")
                            .font(.paperLabel)
                            .foregroundStyle(Paper.ink)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 2)
                            .background(Paper.hairline.opacity(0.7), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(cast.dropFirst(Self.visible).map(Self.name).joined(separator: ", "))
                }
            }
            if let id = asking, let speaker = meeting.speakers.first(where: { $0.id == id }), speaker.isGuess {
                question(speaker)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeOut(duration: 0.2), value: asking)
    }

    static func name(_ member: CastMember) -> String {
        switch member.label {
        case .name(let n), .unnamed(let n): n
        case .guess(let n): n + "?"
        }
    }

    @ViewBuilder
    private func chip(_ member: CastMember) -> some View {
        let unconfirmed = if case .guess = member.label { true } else { false }
        let content = HStack(spacing: 6) {
            SpeakerAvatar.badge(member.look, size: 24, unconfirmed: unconfirmed)
            switch member.label {
            case .name(let n):
                Text(n).font(.system(size: 14, weight: .semibold)).foregroundStyle(member.isYou ? Paper.youText : Paper.ink)
            case .guess(let n):
                Text(n + "?").font(.system(size: 14, weight: .semibold)).foregroundStyle(Paper.ink)
            case .unnamed(let n):
                SpeakerTag(name: n)
            }
        }
        .lineLimit(1)
        .fixedSize()
        .help(member.help ?? "")
        if interactive, let id = member.speakerID, !member.isYou {
            Button {
                if unconfirmed { asking = asking == id ? nil : id } else { naming = id }
            } label: { content.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .popover(isPresented: Binding(get: { naming == id }, set: { if !$0 { naming = nil } }),
                         arrowEdge: .bottom) {
                    SpeakerNamePopover(meeting: meeting, speakerID: id) { naming = nil }
                }
        } else {
            content
        }
    }

    /// "Is this Sarah Chen from the invite?" with Yes / Someone else.
    private func question(_ speaker: Speaker) -> some View {
        let guess = speaker.name ?? ""
        let attendee = (meeting.info.attendees ?? []).first { a in
            !a.isMe && (a.name.caseInsensitiveCompare(guess) == .orderedSame
                        || AttendeeName.firstName(a.name).caseInsensitiveCompare(guess) == .orderedSame)
        }
        let full = attendee?.name ?? guess
        return HStack(spacing: 12) {
            EarlAvatar(size: 26)
            Text("Is this \(Text(full).bold())\(attendee == nil ? "?" : " from the invite?")")
                .font(.paperBody)
                .foregroundStyle(Paper.ink)
                .help(speaker.evidence.map { "Earl heard: \($0)" } ?? "")
            Spacer(minLength: 8)
            Button("Yes") {
                if full != guess {
                    state.renameSpeaker(meetingID: meeting.id, speakerID: speaker.id, name: full)
                } else {
                    state.confirmSpeaker(meetingID: meeting.id, speakerID: speaker.id)
                }
                asking = nil
            }
            .buttonStyle(.paperPrimary)
            Button("Someone else") {
                asking = nil
                naming = speaker.id
            }
            .buttonStyle(.paperSecondary)
        }
        .disabled(state.isBusy(meeting.id))
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(Paper.paperSoft, in: RoundedRectangle(cornerRadius: Paper.Radius.card, style: .continuous))
    }
}

/// Lays chips out in rows, wrapping when the width runs out.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: min(width, proposal.width ?? width), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for i in row.items {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var items: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            let needed = row.items.isEmpty ? size.width : row.width + spacing + size.width
            if !row.items.isEmpty && needed > width {
                rows.append(row)
                row = Row()
            }
            row.width = row.items.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.items.append(i)
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}

// MARK: - Earl's cards

/// Earl's briefing: "In short —" and a short paragraph, on a white card.
struct BriefingCard<Actions: View>: View {
    var lead: String = EarlVoice.inShort
    var text: String
    var query = ""
    /// E-1: the paragraph can be edited in place.
    var onEdit: ((String) -> Void)?
    @ViewBuilder var actions: Actions

    @State private var editing = false // E-1
    @State private var hovering = false // E-1
    @Environment(\.notesArrival) private var arrival

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            EarlAvatar(size: 34, nod: arrival.nod)
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(lead).font(.earlVoice(size: 19)).foregroundStyle(Paper.ink)
                            .modifier(PenStroke(written: arrival.inked))
                        Spacer(minLength: 0)
                        if onEdit != nil && !editing { // E-1: on the lead's line, where there's room
                            EditPencil(visible: hovering) { editing = true }
                        }
                    }
                    if let onEdit, editing { // E-1
                        NoteField(original: text, font: .paperLede, lineSpacing: 4) { new in
                            editing = false
                            if let new, new != text { onEdit(new) }
                        }
                    } else if onEdit != nil {
                        paragraph.onTapGesture(count: 2) { editing = true }
                    } else {
                        paragraph.textSelection(.enabled)
                    }
                }
                actions
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .background(Paper.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Paper.hairline))
        .onHover { hovering = $0 } // E-1
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private var paragraph: some View {
        Text(PageText.attributed(text, query: query))
            .font(.paperLede)
            .lineSpacing(4)
            .foregroundStyle(Paper.ink)
            .fixedSize(horizontal: false, vertical: true)
            // Once the lead-in is written, the briefing comes up under it.
            .opacity(arrival.inked ? 1 : 0)
            .animation(arrival.inked ? .easeOut(duration: 0.25).delay(0.3) : nil, value: arrival.inked)
    }
}

// MARK: - Notes arriving

/// When fresh notes arrive: whether Earl has written his lead-in yet, and a
/// count that makes him nod.
struct NotesArrival: Equatable {
    var inked = true
    var nod = 0
}

private struct NotesArrivalKey: EnvironmentKey {
    static let defaultValue = NotesArrival()
}

extension EnvironmentValues {
    var notesArrival: NotesArrival {
        get { self[NotesArrivalKey.self] }
        set { self[NotesArrivalKey.self] = newValue }
    }
}

/// Earl's handwriting appearing left to right, as if he were writing it.
/// With Reduce Motion it fades in instead.
struct PenStroke: ViewModifier {
    let written: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if reduceMotion {
            content
                .opacity(written ? 1 : 0)
                .animation(written ? .easeOut(duration: 0.3) : nil, value: written)
        } else {
            content.mask(alignment: .leading) {
                Rectangle()
                    .scaleEffect(x: written ? 1 : 0, anchor: .leading)
                    .animation(written ? .timingCurve(0.45, 0, 0.2, 1, duration: 0.42) : nil, value: written)
            }
        }
    }
}

/// Part of a meeting's page settling in, top to bottom, when it opens: each
/// block rises a few points out of a soft blur, a beat after the one above.
/// Only opacity with Reduce Motion.
private struct SettleIn: ViewModifier {
    let index: Int
    let settled: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let moving = !settled && !reduceMotion
        content
            .opacity(settled ? 1 : 0)
            .offset(y: moving ? 10 : 0)
            .blur(radius: moving ? 2 : 0)
            .animation(settled ? .spring(duration: 0.4, bounce: 0).delay(0.04 + Double(index) * 0.055) : nil,
                       value: settled)
    }
}

private extension View {
    func settleIn(_ index: Int, _ settled: Bool) -> some View { modifier(SettleIn(index: index, settled: settled)) }
}

extension BriefingCard where Actions == EmptyView {
    init(lead: String = EarlVoice.inShort, text: String, query: String = "", onEdit: ((String) -> Void)? = nil) {
        self.init(lead: lead, text: text, query: query, onEdit: onEdit) { EmptyView() }
    }
}

/// A meeting that didn't finish: what happened, what's safe, one way forward.
/// Plain words, no jokes.
struct FailedCard: View {
    @EnvironmentObject private var state: AppState
    let meeting: Meeting

    private var transcribed: Bool { !meeting.turns.isEmpty }

    private var safe: String? {
        switch (meeting.hasAudio, transcribed) {
        case (true, true): "Your recording and transcript are safe."
        case (true, false): "Your recording is safe."
        case (false, true): "Your transcript is safe."
        case (false, false): nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Label(meeting.isUnreadable ? "I couldn't open this one."
                      : transcribed ? "I couldn't write the notes for this one." : "I couldn't transcribe this one.",
                      systemImage: "exclamationmark.triangle")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Paper.error)
                Text(meeting.info.error ?? "Something went wrong while processing.")
                    .font(.paperBody)
                    .foregroundStyle(Paper.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let safe {
                    Text(safe).font(.paperBody).foregroundStyle(Paper.ink)
                }
            }
            if meeting.isUnreadable {
                // D-4: a newer Earl wrote this. Only look at it or remove it; Earl never writes to it.
                HStack(spacing: 10) {
                    Button("Show in Finder") { state.reveal(meeting.id) }
                        .buttonStyle(.paperPrimary)
                    Button("Delete…", role: .destructive) { state.delete(meeting.id) }
                        .buttonStyle(.paperSecondary)
                }
            } else {
            HStack(spacing: 10) {
                Button("Try again") { state.retry(meeting.id) }
                    .buttonStyle(.paperPrimary)
                    .disabled(state.isBusy(meeting.id))
                if meeting.files.contains(where: { $0.name == "whisper.log" }) {
                    Button("Show log") { state.open(meeting.id, file: "whisper.log") }
                        .buttonStyle(.paperSecondary)
                }
            }
            }
            if !meeting.isUnreadable {
            HStack(spacing: 16) {
                step(done: meeting.hasAudio || meeting.info.duration > 0,
                     "Recorded \(meeting.durationText)")
                step(done: transcribed, "Transcribed")
                if transcribed {
                    step(done: false, "Notes")
                } else {
                    // Not reached: neither done nor failed.
                    Label("Notes", systemImage: "minus").foregroundStyle(Paper.inkMuted)
                }
            }
            .font(.system(size: 14))
            }
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Paper.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Paper.hairline))
    }

    private func step(done: Bool, _ text: String) -> some View {
        Label(text, systemImage: done ? "checkmark" : "xmark")
            .foregroundStyle(done ? Paper.ok : Paper.error)
    }
}

// MARK: - Decided, open, to-dos

/// Decided and Still open on the left, your to-dos and everyone else's on the
/// right. Two items per group; the rest behind "› N more".
struct NotesColumns: View {
    @EnvironmentObject private var state: AppState
    let meeting: Meeting
    let notes: FrontPageNotes
    let query: String
    let wide: Bool
    @Binding var expanded: Bool
    var interactive = true
    var onPlay: ((Turn) -> Void)?

    static let preview = 2

    static func split(_ todos: [ActionItem], userName: String?) -> (mine: [ActionItem], others: [ActionItem]) {
        let mine = todos.filter { ActionItems.isMine(owner: $0.owner, userName: userName) }
        let others = todos.filter { !ActionItems.isMine(owner: $0.owner, userName: userName) }
        return (mine, others)
    }

    /// Whether any group has more than it shows collapsed (then its "› N more"
    /// line leads to the full summary).
    static func overflows(_ notes: FrontPageNotes, userName: String?) -> Bool {
        let (mine, others) = split(notes.todos, userName: userName)
        return [notes.decisions.count, notes.open.count, notes.points.count, notes.answered.count,
                mine.filter { !$0.done }.count,
                others.filter { !$0.done }.count].contains { $0 > preview }
    }

    var body: some View {
        let words = PageWords(language: meeting.info.language)
        let (mine, others) = Self.split(notes.todos, userName: Prefs.userName)
        let kind = meeting.info.notesKind.flatMap(MeetingKind.init(rawValue:)) ?? .general // K-1
        let left = !notes.decisions.isEmpty || !notes.open.isEmpty || !notes.points.isEmpty || !notes.answered.isEmpty
        let right = !mine.isEmpty || !others.isEmpty
        let leftColumn = VStack(alignment: .leading, spacing: 22) {
            if !notes.points.isEmpty { // K-1
                group(words.points(kind), count: nil) { bullets(notes.points, marked: 1) }
            }
            if !notes.decisions.isEmpty {
                group(words.decided, count: nil) {
                    bullets(notes.decisions, marked: 1)
                }
            }
            if !notes.open.isEmpty {
                group(words.stillOpen, count: nil) { bullets(notes.open, marked: 0) }
            }
            if !notes.answered.isEmpty { // K-1
                group(words.answered, count: nil) { bullets(notes.answered, marked: 0) }
            }
        }
        let rightColumn = VStack(alignment: .leading, spacing: 22) {
            if !mine.isEmpty {
                group(kind.isListening ? words.forYou : words.yourTodos, count: nil) { tickets(mine, mine: true) }
            }
            if !others.isEmpty {
                group(words.everyoneElse, count: others.filter { !$0.done }.count) { tickets(others, mine: false) }
            }
        }
        // Wide, the columns keep their places even when one is empty: your
        // to-dos are always on the right, on every page.
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

    private func group(_ title: String, count: Int?, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.paperTitle).foregroundStyle(Paper.ink)
                if let count, count > 0 {
                    Text("\(count)").font(.system(size: 13)).foregroundStyle(Paper.inkMuted)
                }
            }
            content()
        }
    }

    /// `marked`: how many of the first bullets get the highlighter (at most two a page).
    @ViewBuilder
    private func bullets(_ items: [String], marked: Int) -> some View {
        let shown = expanded ? items : Array(items.prefix(Self.preview))
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(shown.enumerated()), id: \.offset) { i, text in
                EditableBullet(meetingID: meeting.id, raw: text, display: PageText.attributed(text, query: query), // E-1
                               marked: i < min(marked, 2), enabled: interactive)
            }
            more(items.count - shown.count)
        }
    }

    @ViewBuilder
    private func tickets(_ items: [ActionItem], mine: Bool) -> some View {
        // Open items first; ticked ones only in the full summary.
        let open = items.filter { !$0.done }
        let shown = expanded ? open + items.filter(\.done) : Array(open.prefix(Self.preview))
        VStack(alignment: .leading, spacing: 8) {
            ForEach(shown) { item in
                TodoTicket(meeting: meeting, item: item, mine: mine, query: query, interactive: interactive,
                           onPlay: onPlay)
            }
            if shown.isEmpty && !expanded {
                Text("All done.").font(.system(size: 14)).foregroundStyle(Paper.inkMuted)
            }
            more(expanded ? 0 : open.count - shown.count)
        }
    }

    @ViewBuilder
    private func more(_ hidden: Int) -> some View {
        if hidden > 0 && interactive {
            MoreLine(text: "\(hidden) more · Full summary") { withAnimation(.easeOut(duration: 0.2)) { expanded = true } }
        }
    }
}

struct PageBullet: View {
    let text: AttributedString
    var marked = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Text("•").font(.paperBody).foregroundStyle(Paper.inkMuted)
            Group {
                if marked {
                    Text(text).textRenderer(MarkerRenderer(color: Paper.marker))
                } else {
                    Text(text)
                }
            }
            .font(.paperBody)
            .lineSpacing(3)
            .foregroundStyle(Paper.ink)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A to-do as a ticket. Yours: a checkbox and a dashed border. Everyone
/// else's: the owner's face and name first. On hover: "▶ 14:10 · Reminders".
struct TodoTicket: View {
    @EnvironmentObject private var state: AppState
    let meeting: Meeting
    let item: ActionItem
    let mine: Bool
    var query = ""
    var interactive = true
    var onPlay: ((Turn) -> Void)?

    @State private var hovering = false
    @State private var editing = false // E-1

    var body: some View {
        let owner = item.owner.map { FrontPageMatch.speaker(for: $0, in: meeting.speakers) } ?? nil
        let source = FrontPageMatch.sourceTurn(for: item.text, in: meeting.turns)
        Ticket(mine: mine) {
            if mine {
                Button { state.toggleTodo(item) } label: { TicketBox(checked: item.done) }
                    .buttonStyle(.plain)
                    .disabled(!interactive)
                    .help(item.done ? "Mark as not done" : "Mark as done")
            } else if let owner {
                SpeakerAvatar.badge(SpeakerFaces.look(for: owner.sampleTurn, in: meeting.speakers), size: 20)
            }
            if editing { // E-1
                TodoEditor(meeting: meeting, item: item, mine: mine) { editing = false }
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                label(ownerName: owner.flatMap(\.name).map(AttendeeName.firstName) ?? item.owner.map(AttendeeName.firstName))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { if interactive && !state.isBusy(meeting.id) { editing = true } }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if hovering && interactive && !editing {
                TicketActions(reminders: state.reminders, meeting: meeting, item: item, mine: mine, source: onPlay == nil ? nil : source,
                              onPlay: onPlay, onEdit: { editing = true })
                    .offset(x: -10, y: 12)
                    .transition(.opacity)
            }
        }
        .zIndex(hovering ? 1 : 0)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private func label(ownerName: String?) -> some View {
        var text = PageText.attributed(item.text, query: query)
        if !mine, let ownerName {
            var name = AttributedString(ownerName + " · ")
            name.font = .system(size: 15, weight: .semibold)
            text = name + text
        }
        return Text(text)
            .lineSpacing(2)
            .strikethrough(item.done, color: Paper.inkMuted)
            .foregroundStyle(item.done ? Paper.inkMuted : Paper.ink)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The small pill a ticket shows on hover.
private struct TicketActions: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var reminders: RemindersSync
    let meeting: Meeting
    let item: ActionItem
    let mine: Bool
    let source: Turn?
    var onPlay: ((Turn) -> Void)?
    var onEdit: (() -> Void)? // E-1

    var body: some View {
        let sent = reminders.sent.contains(item.key)
        HStack(spacing: 8) {
            if let source, let onPlay {
                Button { onPlay(source) } label: {
                    Label(Meeting.timestamp(source.start), systemImage: "play.fill").labelStyle(TightLabel())
                }
                .help("Play from where it was said")
                dot
            }
            if !item.done {
                Button(sent ? "In Reminders" : "Reminders") {
                    Task { await reminders.send([item], meetings: state.meetings) }
                }
                .disabled(sent)
                .help(sent ? "Already in the Earl list in Reminders" : "Send to the Earl list in Reminders")
            }
            if !mine {
                dot
                Button(item.done ? "Not done" : "Done") { state.toggleTodo(item) }
            }
            if let onEdit { // E-1
                if !item.done || !mine { dot } // else the play button's dot comes first, or nothing does
                Button(action: onEdit) { Image(systemName: "pencil").font(.system(size: 13, weight: .medium)) }
                    .help("Edit")
                    .accessibilityLabel("Edit")
            }
        }
        .buttonStyle(.plain)
        .font(.paperLabel)
        .foregroundStyle(Paper.ink)
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .background(Paper.card, in: Capsule())
        .overlay(Capsule().strokeBorder(Paper.hairline))
        .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
    }

    private var dot: some View { Text("·").foregroundStyle(Paper.inkMuted) }
}

/// Icon and title close together.
struct TightLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.system(size: 13, weight: .bold)).imageScale(.small).accessibilityHidden(true)
            configuration.title.monospacedDigit()
        }
    }
}

// MARK: - Full summary

/// Everything: all summary bullets, other sections, and the meeting's details
/// (calendar or invite, how it was processed, files).
struct FullSummary: View {
    let meeting: Meeting
    let notes: FrontPageNotes
    let query: String
    @Binding var expanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if !notes.summary.isEmpty {
                section("Summary", notes.summary)
            }
            ForEach(Array(notes.other.enumerated()), id: \.offset) { _, s in
                if !s.bullets.isEmpty { section(s.title, s.bullets) }
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("Details").font(.paperTitle).foregroundStyle(Paper.ink)
                MeetingDetailsTab(meeting: meeting)
            }
            MoreLine(text: "Show less") { withAnimation(.easeOut(duration: 0.2)) { expanded = false } }
        }
        .padding(.top, 22)
    }

    private func section(_ title: String, _ bullets: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.paperTitle).foregroundStyle(Paper.ink)
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(bullets.enumerated()), id: \.offset) { _, b in
                    EditableBullet(meetingID: meeting.id, raw: b, display: PageText.attributed(b, query: query)) // E-1
                }
            }
        }
    }
}
