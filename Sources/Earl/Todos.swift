import AppKit
import EventKit
import SwiftUI

// R3-2: one to-do list across meetings. summary.md stays the source of truth:
// ticking an item rewrites "- [ ]" to "- [x]" on its line. Ticks survive
// Summarize Again through todos-done.json, and items can be sent to Reminders
// (mapping in reminders.json), whose completions flow back.

// MARK: - Parsing

/// One checkbox line in a meeting's summary.
struct ActionItem: Identifiable, Hashable {
    let meetingID: String
    /// Index of the line in summary.md (split on "\n").
    let line: Int
    let owner: String?
    let text: String
    var done: Bool

    var id: String { "\(meetingID)#\(line)" }
    /// Stable across edits that keep the task's words, and across renamed owners
    /// (R2-3 can turn "Speaker 2" into "Sarah"): the Reminders mapping key.
    var key: String { ActionItems.key(meetingID: meetingID, text: text) }
}

enum ActionItems {
    /// All checkbox lines, in any section and at any indent.
    static func parse(_ summary: String, meetingID: String) -> [ActionItem] {
        summary.components(separatedBy: "\n").enumerated().compactMap { index, line in
            parseLine(line, meetingID: meetingID, index: index)
        }
    }

    static func parseLine(_ line: String, meetingID: String, index: Int) -> ActionItem? {
        guard let (done, rest) = checkbox(line) else { return nil }
        let (owner, text) = splitOwner(rest)
        guard !text.isEmpty else { return nil }
        return ActionItem(meetingID: meetingID, line: index, owner: owner, text: text, done: done)
    }

    /// "- [ ] rest" → (false, "rest"); also "* [x]", "+ [X]" and "1. [ ]".
    private static func checkbox(_ line: String) -> (Bool, String)? {
        var s = Substring(line.trimmingCharacters(in: .whitespacesAndNewlines))
        if let first = s.first, "-*+".contains(first) {
            s = s.dropFirst()
        } else if let dot = s.firstIndex(of: "."), dot > s.startIndex, s[..<dot].allSatisfy(\.isNumber) {
            s = s[s.index(after: dot)...]
        } else {
            return nil
        }
        guard s.first == " " else { return nil }
        s = s.drop { $0 == " " }
        guard s.count >= 3, s.hasPrefix("["), s.dropFirst(2).first == "]" else { return nil }
        let mark = s.dropFirst().first!
        guard mark == " " || mark == "x" || mark == "X" else { return nil }
        return (mark != " ", s.dropFirst(3).trimmingCharacters(in: .whitespaces))
    }

    /// Splits "Sarah: task" on the first ": ". "[Sarah]:" and "**Sarah**:" are
    /// owners too. Long lead-ins ("Before Friday, check the following: …")
    /// aren't names, so they stay part of the task.
    static func splitOwner(_ s: String) -> (owner: String?, text: String) {
        guard let range = s.range(of: ": ") else { return (nil, s) }
        var owner = String(s[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        owner = owner.replacingOccurrences(of: "**", with: "")
        if owner.hasPrefix("[") && owner.hasSuffix("]") { owner = String(owner.dropFirst().dropLast()) }
        owner = owner.trimmingCharacters(in: .whitespaces)
        let text = String(s[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        let words = owner.split(separator: " ").count
        guard !owner.isEmpty, owner.count <= 40, words <= 4, !text.isEmpty else { return (nil, s) }
        return (owner, text)
    }

    // MARK: Keys and matching

    /// Lowercased, without diacritics, punctuation or extra spaces.
    static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "ß", with: "ss")
        let kept = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(kept).split(separator: " ").joined(separator: " ")
    }

    /// FNV-1a over the meeting ID and the normalized text: stable across launches,
    /// unlike `hashValue`.
    static func key(meetingID: String, text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in "\(meetingID)\n\(normalize(text))".utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }

    /// The owner is you: "Me" (or "Ich" in German notes), your name from
    /// Settings, or its first name. Case and accents don't matter.
    static func isMine(owner: String?, userName: String?) -> Bool {
        guard let owner else { return false }
        let o = normalize(owner)
        if ["me", "ich", "moi"].contains(o) || o.hasSuffix(" me") { return true } // "Ahsan (Me)"
        let user = normalize(userName ?? "")
        guard let userName, !user.isEmpty else { return false }
        return o == user || o == normalize(AttendeeName.firstName(userName))
    }

    /// 0...1: how alike two tasks read, by shared words or by spelling.
    static func similarity(_ a: String, _ b: String) -> Double {
        let na = normalize(a), nb = normalize(b)
        if na == nb { return 1 }
        if na.isEmpty || nb.isEmpty { return 0 }
        let wa = Set(na.split(separator: " ")), wb = Set(nb.split(separator: " "))
        let dice = 2 * Double(wa.intersection(wb).count) / Double(wa.count + wb.count)
        let chars = 1 - Double(levenshtein(Array(na), Array(nb))) / Double(max(na.count, nb.count))
        return max(dice, chars)
    }

    static let sameTaskThreshold = 0.8

    private static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        var previous = Array(0...b.count)
        for (i, ca) in a.enumerated() {
            var current = [i + 1]
            for (j, cb) in b.enumerated() {
                current.append(min(previous[j + 1] + 1, current[j] + 1, previous[j] + (ca == cb ? 0 : 1)))
            }
            previous = current
        }
        return previous[b.count]
    }

    // MARK: Editing

    /// The summary with that item ticked or unticked, rewriting only its line.
    /// If the line no longer holds the item (the summary changed underneath),
    /// the item is found again by key. nil when it's gone.
    static func setting(_ item: ActionItem, done: Bool, in summary: String) -> String? {
        var lines = summary.components(separatedBy: "\n")
        var index = item.line
        if !(lines.indices.contains(index)
             && parseLine(lines[index], meetingID: item.meetingID, index: index)?.key == item.key) {
            guard let found = parse(summary, meetingID: item.meetingID).first(where: { $0.key == item.key })
            else { return nil }
            index = found.line
        }
        lines[index] = setMark(lines[index], done: done)
        return lines.joined(separator: "\n")
    }

    /// Rewrites the first "[ ]"/"[x]" on a checkbox line, keeping the rest.
    static func setMark(_ line: String, done: Bool) -> String {
        guard let r = line.range(of: #"\[[ xX]\]"#, options: .regularExpression) else { return line }
        return line.replacingCharacters(in: r, with: done ? "[x]" : "[ ]")
    }

    // MARK: Keeping ticks across Summarize Again

    struct DoneRecord: Codable, Hashable {
        var key: String
        var text: String
    }

    /// Ticks open items in a new summary that closely match a previously done
    /// one. Each record ticks at most one item.
    static func carryOver(_ records: [DoneRecord], into summary: String, meetingID: String) -> String {
        guard !records.isEmpty else { return summary }
        var lines = summary.components(separatedBy: "\n")
        var unused = records
        for item in parse(summary, meetingID: meetingID) where !item.done {
            let best = unused.indices
                .map { ($0, unused[$0].key == item.key ? 1 : similarity(unused[$0].text, item.text)) }
                .max { $0.1 < $1.1 }
            guard let (i, score) = best, score >= sameTaskThreshold else { continue }
            lines[item.line] = setMark(lines[item.line], done: true)
            unused.remove(at: i)
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Files in the meeting folder

enum TodoFiles {
    static let doneFile = "todos-done.json"
    static let remindersFile = "reminders.json"

    static func loadDone(in folder: URL) -> [ActionItems.DoneRecord] {
        read([ActionItems.DoneRecord].self, folder.appendingPathComponent(doneFile)) ?? []
    }

    static func saveDone(_ records: [ActionItems.DoneRecord], in folder: URL) {
        write(records, folder.appendingPathComponent(doneFile))
    }

    /// Item key → Reminders `calendarItemIdentifier`.
    static func loadReminders(in folder: URL) -> [String: String] {
        read([String: String].self, folder.appendingPathComponent(remindersFile)) ?? [:]
    }

    static func saveReminders(_ map: [String: String], in folder: URL) {
        write(map, folder.appendingPathComponent(remindersFile))
    }

    /// Remembers a tick, or forgets it (and anything reading the same) on untick.
    static func record(_ item: ActionItem, done: Bool, in folder: URL) {
        var records = loadDone(in: folder).filter {
            $0.key != item.key && ActionItems.similarity($0.text, item.text) < ActionItems.sameTaskThreshold
        }
        if done { records.append(.init(key: item.key, text: item.text)) }
        saveDone(records, in: folder)
    }

    /// Called with a freshly written summary, before it's saved: re-ticks what
    /// was done in the old one (summary.md on disk, and todos-done.json).
    static func keepingTicks(_ newSummary: String, in folder: URL) -> String {
        let id = folder.lastPathComponent
        let old = (try? String(contentsOf: folder.appendingPathComponent("summary.md"), encoding: .utf8)) ?? ""
        var records = loadDone(in: folder)
        for item in ActionItems.parse(old, meetingID: id) where item.done && !records.contains(where: { $0.key == item.key }) {
            records.append(.init(key: item.key, text: item.text))
        }
        if !records.isEmpty { saveDone(records, in: folder) }
        return ActionItems.carryOver(records, into: newSummary, meetingID: id)
    }

    private static func read<T: Decodable>(_ type: T.Type, _ url: URL) -> T? {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    private static func write<T: Encodable>(_ value: T, _ url: URL) {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? e.encode(value).write(to: url, options: .atomic)
    }
}

// MARK: - Links into Earl

/// `earl://meeting/<id>`, used in reminders' notes.
enum EarlLink {
    static func url(meetingID: String) -> URL {
        URL(string: "earl://meeting/\(meetingID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? meetingID)")!
    }

    static func meetingID(from url: URL) -> String? {
        guard url.scheme?.lowercased() == "earl", url.host?.lowercased() == "meeting" else { return nil }
        let id = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return id.isEmpty || id.contains("/") || id.hasPrefix(".") ? nil : id
    }

    /// Set once the app can show a meeting. A link that arrives earlier (Earl
    /// launched by the link) waits for it.
    @MainActor static var handler: ((String) -> Void)? {
        didSet { if let id = pending, let handler { pending = nil; handler(id) } }
    }
    @MainActor private static var pending: String?

    @MainActor static func open(_ url: URL) {
        guard let id = meetingID(from: url) else { return }
        if let handler { handler(id) } else { pending = id }
    }
}

// MARK: - App state

extension AppState {
    func toggleTodo(meetingID: String, line: Int) {
        guard let item = actionItems.first(where: { $0.meetingID == meetingID && $0.line == line }) else { return }
        setDone(item, !item.done)
    }

    func toggleTodo(_ item: ActionItem) { setDone(item, !item.done) }

    /// Rewrites the item's line in summary.md, then transcript.md.
    func setDone(_ item: ActionItem, _ done: Bool) {
        let folder = Prefs.storageURL.appendingPathComponent(item.meetingID)
        let file = folder.appendingPathComponent("summary.md")
        guard let summary = try? String(contentsOf: file, encoding: .utf8),
              let updated = ActionItems.setting(item, done: done, in: summary) else { reload(); return }
        if updated != summary { try? store.saveSummary(updated, in: folder) }
        TodoFiles.record(item, done: done, in: folder)
        reload()
        if let m = meeting(item.meetingID) { store.saveMarkdown(m) }
    }

    /// Items whose reminder was completed are marked done here.
    func refreshReminders(force: Bool = false) {
        Task {
            for item in await reminders.completedItems(in: actionItems.filter { !$0.done }, force: force) {
                setDone(item, true)
            }
        }
    }
}

// MARK: - Reminders

/// Sends action items to a Reminders list named "Earl". Asks for access only
/// when you send something.
@MainActor
final class RemindersSync: ObservableObject {
    static let listName = "Earl"

    /// Keys of items that have a reminder (per reminders.json).
    @Published private(set) var sent: Set<String> = []
    @Published var error: String?

    private lazy var store = EKEventStore()
    private var lastRefresh: Date?

    var isAllowed: Bool { EKEventStore.authorizationStatus(for: .reminder) == .fullAccess }

    func loadSent(meetings: [Meeting]) {
        sent = Set(meetings.flatMap { TodoFiles.loadReminders(in: $0.folder).keys })
    }

    /// Adds a reminder for each item that doesn't have one yet. Returns how many were added.
    @discardableResult
    func send(_ items: [ActionItem], meetings: [Meeting]) async -> Int {
        do {
            var allowed = isAllowed
            if !allowed { allowed = try await store.requestFullAccessToReminders() }
            guard allowed else {
                error = "Earl isn't allowed to use Reminders. Turn it on in System Settings, under Privacy & Security › Reminders."
                return 0
            }
            let list = try earlList()
            var added = 0
            for (meetingID, group) in Dictionary(grouping: items, by: \.meetingID) {
                guard let meeting = meetings.first(where: { $0.id == meetingID }) else { continue }
                var map = TodoFiles.loadReminders(in: meeting.folder)
                for item in group {
                    if let existing = map[item.key], store.calendarItem(withIdentifier: existing) != nil { continue }
                    let reminder = EKReminder(eventStore: store)
                    reminder.calendar = list
                    reminder.title = Self.title(for: item)
                    reminder.notes = Self.notes(for: meeting)
                    reminder.url = EarlLink.url(meetingID: meeting.id)
                    try store.save(reminder, commit: false)
                    map[item.key] = reminder.calendarItemIdentifier
                    added += 1
                }
                try store.commit()
                TodoFiles.saveReminders(map, in: meeting.folder)
            }
            loadSent(meetings: meetings)
            return added
        } catch {
            self.error = "Couldn't add to Reminders: \(error.localizedDescription)"
            loadSent(meetings: meetings)
            return 0
        }
    }

    /// Open items whose reminder is completed. Runs at most once a minute and
    /// never asks for access.
    func completedItems(in open: [ActionItem], force: Bool = false) async -> [ActionItem] {
        if !force, let last = lastRefresh, Date().timeIntervalSince(last) < 60 { return [] }
        lastRefresh = Date()
        guard isAllowed else { return [] }
        var maps: [String: [String: String]] = [:]
        var done: [ActionItem] = []
        for item in open {
            let folder = Prefs.storageURL.appendingPathComponent(item.meetingID)
            if maps[item.meetingID] == nil { maps[item.meetingID] = TodoFiles.loadReminders(in: folder) }
            guard let id = maps[item.meetingID]?[item.key],
                  let reminder = store.calendarItem(withIdentifier: id) as? EKReminder,
                  reminder.isCompleted else { continue }
            done.append(item)
        }
        return done
    }

    private func earlList() throws -> EKCalendar {
        if let list = store.calendars(for: .reminder).first(where: { $0.title == Self.listName }) { return list }
        let list = EKCalendar(for: .reminder, eventStore: store)
        list.title = Self.listName
        guard let source = store.defaultCalendarForNewReminders()?.source
                ?? store.sources.first(where: { $0.sourceType == .local || $0.sourceType == .calDAV })
        else { throw PipelineError.message("No Reminders account to add the \"Earl\" list to.") }
        list.source = source
        try store.saveCalendar(list, commit: true)
        return list
    }

    /// Your own items read as the task; others keep their owner.
    nonisolated static func title(for item: ActionItem, userName: String? = Prefs.userName) -> String {
        guard let owner = item.owner, !ActionItems.isMine(owner: owner, userName: userName) else { return item.text }
        return "\(owner): \(item.text)"
    }

    nonisolated static func notes(for meeting: Meeting) -> String {
        "From “\(meeting.info.title)”, \(meeting.info.startedAt.formatted(date: .abbreviated, time: .shortened))\n"
            + EarlLink.url(meetingID: meeting.id).absoluteString
    }
}

// MARK: - Sidebar row

/// U-3: "To-dos" with a red count of your open items.
struct TodosSidebarRow: View {
    let count: Int
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "checklist")
                    .font(.system(size: 14))
                    .foregroundStyle(Paper.inkMuted)
                    .frame(width: 18)
                Text("To-dos")
                    .font(.paperChat)
                    .foregroundStyle(Paper.ink)
                Spacer(minLength: 0)
                if count > 0 {
                    Text("\(count)")
                        .contentTransition(.numericText(value: Double(count)))
                        .font(.system(size: 13, weight: .bold).monospacedDigit())
                        .foregroundStyle(Paper.onColor)
                        .padding(.horizontal, 8)
                        .frame(minWidth: 24, minHeight: 20)
                        .background(Paper.live, in: Capsule())
                        .accessibilityLabel("\(count) open")
                }
            }
            .modifier(SidebarRowBackground(selected: selected))
        }
        .buttonStyle(.plain)
        .animation(.snappy(duration: 0.2), value: count)
        .help("Your to-dos from every meeting")
    }
}

// MARK: - Page

struct TodosView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var reminders: RemindersSync
    @AppStorage(Prefs.Key.userName, store: Prefs.defaults) private var userName = ""

    private var myOpen: [ActionItem] {
        state.actionItems.filter { !$0.done && ActionItems.isMine(owner: $0.owner, userName: userName) }
    }

    var body: some View {
        TodoList(items: state.actionItems, meetings: state.meetings,
                 userName: userName.isEmpty ? nil : userName, sent: reminders.sent,
                 onToggle: { state.toggleTodo($0) },
                 onOpen: { state.selection = .meeting($0) },
                 onSend: { item in Task { await reminders.send([item], meetings: state.meetings) } },
                 onSendMine: { Task { await reminders.send(myOpen, meetings: state.meetings) } },
                 onSetName: { state.selection = .engine })
            .navigationTitle("")
            .onAppear {
                reminders.loadSent(meetings: state.meetings)
                state.refreshReminders()
            }
            .alert("Reminders", isPresented: Binding(get: { reminders.error != nil },
                                                     set: { if !$0 { reminders.error = nil } })) {
                Button("Open System Settings") { state.openPrivacySettings("Privacy_Reminders") }
                Button("OK", role: .cancel) {}
            } message: {
                Text(reminders.error ?? "")
            }
    }
}

/// The page's look, without app state (rendered in tests). U-3: a masthead and
/// a Georgia title, then Yours as tickets, Everyone else with the owner's face
/// first, each grouped by meeting; done items fold into "› N done".
struct TodoList: View {
    let items: [ActionItem]
    let meetings: [Meeting]
    var userName: String?
    var sent: Set<String> = []
    var showDone = false
    var onToggle: (ActionItem) -> Void = { _ in }
    var onOpen: (String) -> Void = { _ in }
    var onSend: (ActionItem) -> Void = { _ in }
    var onSendMine: () -> Void = {}
    var onSetName: () -> Void = {}

    @State private var doneOpen: Bool?

    private func isMine(_ item: ActionItem) -> Bool { ActionItems.isMine(owner: item.owner, userName: userName) }

    private var mine: [ActionItem] { items.filter { !$0.done && isMine($0) } }
    private var others: [ActionItem] { items.filter { !$0.done && !isMine($0) } }
    private var done: [ActionItem] { items.filter(\.done) }

    /// Meetings newest first (as `meetings` is sorted), items in summary order.
    private func groups(_ items: [ActionItem]) -> [(meeting: Meeting, items: [ActionItem])] {
        let byMeeting = Dictionary(grouping: items, by: \.meetingID)
        return meetings.compactMap { m in byMeeting[m.id].map { (m, $0.sorted { $0.line < $1.line }) } }
    }

    var body: some View {
        VStack(spacing: 0) {
            Masthead(text: "To-dos") {
                if !mine.isEmpty {
                    let allSent = mine.allSatisfy { sent.contains($0.key) }
                    Button(allSent ? "Yours are in Reminders" : "Send yours to Reminders", action: onSendMine)
                        .buttonStyle(.plain)
                        .font(.paperLabel)
                        .foregroundStyle(Paper.inkMuted)
                        .disabled(allSent)
                        .help("Adds each of your open to-dos to the \"Earl\" list in Reminders, once")
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(headline)
                        .font(.paperHeadline)
                        .foregroundStyle(Paper.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(subtitle)
                        .font(PageGrid.sublineFont)
                        .foregroundStyle(Paper.inkMuted)
                        .padding(.top, PageGrid.subline)
                    if userName == nil { nameHint.padding(.top, 22) }

                    if items.isEmpty {
                        empty.padding(.top, 30)
                    } else {
                        section("Your to-dos", mine, emptyText: "Nothing on your plate. Suspicious.", mine: true)
                            .padding(.top, 30)
                        section("Everyone else", others, emptyText: "Nobody owes anybody anything.", mine: false)
                            .padding(.top, 30)
                        if !done.isEmpty { doneSection.padding(.top, 26) }
                    }
                }
                .frame(maxWidth: 680, alignment: .leading)
                .padding(.horizontal, Paper.Space.pageX)
                .padding(.top, PageGrid.top)
                .padding(.bottom, PageGrid.bottom)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .paperBackground()
    }

    private var headline: String {
        switch mine.count {
        case 0: "Nothing is yours right now."
        case 1: "One to-do is yours."
        default: "\(mine.count) to-dos are yours."
        }
    }

    private var subtitle: String {
        let open = mine.count + others.count
        if open == 0 { return "To-dos from your meetings land here." }
        return open == 1 ? "1 open across your meetings." : "\(open) open across your meetings."
    }

    private var nameHint: some View {
        HStack(spacing: 12) {
            Text("To-dos for “Me” count as yours. Add your name so Earl knows the rest.")
                .font(.paperBody)
                .foregroundStyle(Paper.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Set your name", action: onSetName).buttonStyle(.paperSecondary)
        }
        .paperCard(padding: 12)
    }

    private func section(_ title: String, _ items: [ActionItem], emptyText: String, mine: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.paperTitle).foregroundStyle(Paper.ink)
                // Yours are counted in the headline; say it once.
                if !items.isEmpty && !mine {
                    Text("\(items.count)").font(.paperLabel).foregroundStyle(Paper.inkMuted)
                }
            }
            if items.isEmpty {
                Text(emptyText)
                    .font(.paperBody)
                    .foregroundStyle(Paper.inkMuted)
                    .padding(.top, 8)
            } else {
                ForEach(groups(items), id: \.meeting.id) { group in
                    meetingGroup(group.meeting, group.items, mine: mine)
                }
            }
        }
    }

    private func meetingGroup(_ meeting: Meeting, _ items: [ActionItem], mine: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TodoMeetingLink(meeting: meeting) { onOpen(meeting.id) }
            ForEach(items) { item in
                TodosPageTicket(item: item, mine: mine, owner: mine ? nil : owner(item, in: meeting),
                           sent: sent.contains(item.key), onToggle: { onToggle(item) }, onSend: { onSend(item) })
            }
        }
        .padding(.top, 14)
    }

    private var isDoneOpen: Bool { doneOpen ?? showDone }

    private var doneSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) { doneOpen = !isDoneOpen }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .rotationEffect(.degrees(isDoneOpen ? 90 : 0))
                    Text("\(done.count) done")
                }
                .font(.paperLabel)
                .foregroundStyle(Paper.inkMuted)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isDoneOpen ? "Hide done to-dos" : "Show done to-dos")
            if isDoneOpen {
                ForEach(groups(done), id: \.meeting.id) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        TodoMeetingLink(meeting: group.meeting) { onOpen(group.meeting.id) }
                        ForEach(group.items) { item in
                            let mine = isMine(item)
                            TodosPageTicket(item: item, mine: mine, owner: mine ? nil : owner(item, in: group.meeting),
                                       sent: sent.contains(item.key), onToggle: { onToggle(item) }, onSend: {})
                        }
                    }
                    .padding(.top, 14)
                }
            }
        }
    }

    private var empty: some View {
        HStack(alignment: .top, spacing: 12) {
            EarlAvatar(size: 32)
            EarlLine(lead: EarlVoice.nothingYet,
                     text: "When a meeting ends, the to-dos from its notes land here, yours first.")
        }
    }

    /// The owner's name and face. A name that matches a voice in the meeting
    /// wears that voice's face, so the colour agrees with the meeting page;
    /// anyone else gets the guest face.
    private func owner(_ item: ActionItem, in meeting: Meeting) -> TodoOwner? {
        guard let name = item.owner else { return nil }
        let look = TodoOwner.look(for: name, in: meeting.speakers) ?? .voice(3)
        return TodoOwner(name: name, look: look)
    }
}

/// Who a to-do belongs to, as shown on someone else's ticket.
struct TodoOwner: Equatable {
    var name: String
    var look: AvatarLook

    /// Matches the owner against the meeting's speakers by full name, first
    /// name, or "Speaker N".
    static func look(for owner: String, in speakers: [Speaker]) -> AvatarLook? {
        let o = ActionItems.normalize(owner)
        guard !o.isEmpty else { return nil }
        let match = speakers.first { s in
            guard let name = s.name, !name.isEmpty else { return false }
            let full = ActionItems.normalize(name)
            return full == o || ActionItems.normalize(AttendeeName.firstName(name)) == o
        } ?? speakers.first { o == "speaker \($0.number)" }
        guard let match else { return nil }
        return SpeakerFaces.looks(for: speakers)[match.id]
    }
}

/// The meeting a group of to-dos came from: a quiet link.
private struct TodoMeetingLink: View {
    let meeting: Meeting
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(meeting.info.title).lineLimit(1)
                Text("· \(SidebarDay.label(for: meeting.info.startedAt).lowercasedDay), \(meeting.info.startedAt.formatted(date: .omitted, time: .shortened))")
                    .lineLimit(1)
                    .layoutPriority(1)
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold))
                    .opacity(hovering ? 1 : 0)
            }
            .font(.paperLabel)
            .foregroundStyle(hovering ? Paper.ink : Paper.inkMuted)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Open the meeting")
    }
}

private extension String {
    /// "Today" → "today", but weekdays and dates keep their capitals.
    var lowercasedDay: String { self == "Today" || self == "Yesterday" ? lowercased() : self }
}

/// One to-do as a ticket: box, (owner face and name,) text; "Reminders" on hover.
private struct TodosPageTicket: View {
    let item: ActionItem
    let mine: Bool
    let owner: TodoOwner?
    let sent: Bool
    let onToggle: () -> Void
    let onSend: () -> Void

    @State private var hovering = false

    var body: some View {
        Ticket(mine: mine) {
            Button(action: onToggle) { TicketBox(checked: item.done) }
                .buttonStyle(.plain)
                .help(item.done ? "Mark as not done" : "Mark as done")
            if let owner {
                SpeakerAvatar.badge(owner.look, size: 20)
            }
            text
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !item.done {
                Button(sent ? "In Reminders" : "Reminders", action: onSend)
                    .buttonStyle(.plain)
                    .font(.paperLabel)
                    .foregroundStyle(Paper.inkMuted)
                    .disabled(sent)
                    .help(sent ? "Already in Reminders" : "Send to Reminders")
                    .opacity(hovering ? 1 : 0)
            }
        }
        .opacity(item.done ? 0.75 : 1)
        .onHover { hovering = $0 }
    }

    private var text: Text {
        let body = Text(item.text)
            .foregroundStyle(item.done ? Paper.inkMuted : Paper.ink)
            .strikethrough(item.done, color: Paper.inkMuted)
        guard let owner else { return body }
        let voice = VoicePalette.voice(for: owner.look)
        return Text("\(Text(owner.name).fontWeight(.semibold).foregroundStyle(voice.text)) · \(body)")
    }
}

/// A round checkbox, shared by the To-dos page and the Summary tab.
struct TodoCheckbox: View {
    let done: Bool
    var font: Font = .body
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(font)
                .foregroundStyle(done ? Theme.accent : Color.secondary)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .help(done ? "Mark as not done" : "Mark as done")
    }
}
