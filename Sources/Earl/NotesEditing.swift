import SwiftUI

// E-1: correcting the notes by hand. Double-click a line on the front page
// (or its pencil, on hover) and it becomes a field in the same font. Return
// saves by rewriting that one line of summary.md, Escape cancels, an empty
// line is removed (with Undo). Edits mark nothing stale.

// MARK: - Lines

enum NotesEdit {
    /// A notes line cut into what stays and what you edit: the indent, bullet
    /// and checkbox ("- [ ] "), the owner as written ("**Sarah**: "), and
    /// the text.
    struct Parts: Equatable {
        var lead: String
        var owner: String?
        /// The owner exactly as written, with its ": ".
        var ownerRaw: String
        var text: String

        var line: String { lead + ownerRaw + text }
    }

    static func parts(_ line: String) -> Parts {
        let chars = Array(line)
        var i = 0
        while i < chars.count, chars[i] == " " || chars[i] == "\t" { i += 1 }
        var isBullet = false
        if i < chars.count, "-*+•".contains(chars[i]), i + 1 < chars.count, chars[i + 1] == " " {
            i += 1
            isBullet = true
        } else {
            var j = i
            while j < chars.count, chars[j].isNumber { j += 1 }
            if j > i, j + 1 < chars.count, chars[j] == ".", chars[j + 1] == " " {
                i = j + 1
                isBullet = true
            }
        }
        guard isBullet else { return Parts(lead: String(chars[..<i]), owner: nil, ownerRaw: "", text: String(chars[i...])) }
        while i < chars.count, chars[i] == " " { i += 1 }
        var isCheckbox = false
        if i + 2 < chars.count, chars[i] == "[", " xX".contains(chars[i + 1]), chars[i + 2] == "]" {
            i += 3
            while i < chars.count, chars[i] == " " { i += 1 }
            isCheckbox = true
        }
        let lead = String(chars[..<i])
        let rest = String(chars[i...])
        // Only to-dos have owners; a plain bullet's "Note: …" is part of its text.
        guard isCheckbox, let colon = rest.range(of: ": ") else { return Parts(lead: lead, owner: nil, ownerRaw: "", text: rest) }
        let split = ActionItems.splitOwner(rest)
        guard let owner = split.owner else { return Parts(lead: lead, owner: nil, ownerRaw: "", text: rest) }
        let rawEnd = rest[colon.upperBound...].prefix { $0 == " " }.endIndex
        return Parts(lead: lead, owner: owner, ownerRaw: String(rest[..<rawEnd]), text: split.text)
    }

    /// The index of the line that reads `text` as a plain bullet (not a
    /// heading or a to-do). `hint` wins when it still reads so; otherwise the
    /// first such line, since the notes may have changed underneath.
    static func lineIndex(of text: String, in summary: String, hint: Int? = nil) -> Int? {
        let lines = summary.components(separatedBy: "\n")
        func reads(_ i: Int) -> Bool {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"),
                  ActionItems.parseLine(lines[i], meetingID: "", index: i) == nil else { return false }
            return FrontPageNotes.bulletText(line) == text
        }
        if let hint, lines.indices.contains(hint), reads(hint) { return hint }
        return lines.indices.first(where: reads)
    }

    /// The line of a to-do, checked by key like ticking does.
    static func lineIndex(of item: ActionItem, in summary: String) -> Int? {
        let lines = summary.components(separatedBy: "\n")
        if lines.indices.contains(item.line),
           ActionItems.parseLine(lines[item.line], meetingID: item.meetingID, index: item.line)?.key == item.key {
            return item.line
        }
        return ActionItems.parse(summary, meetingID: item.meetingID).first { $0.key == item.key }?.line
    }

    /// The summary with line `index`'s text replaced, keeping its bullet,
    /// checkbox and owner. Empty text removes the line.
    static func replacingText(ofLine index: Int, in summary: String, with text: String) -> String {
        var lines = summary.components(separatedBy: "\n")
        guard lines.indices.contains(index) else { return summary }
        let text = oneLine(text)
        if text.isEmpty {
            lines.remove(at: index)
        } else {
            var p = parts(lines[index])
            p.text = text
            lines[index] = p.line
        }
        return lines.joined(separator: "\n")
    }

    /// The summary with the to-do on line `index` given to `owner`.
    static func settingOwner(ofLine index: Int, in summary: String, to owner: String) -> String {
        var lines = summary.components(separatedBy: "\n")
        guard lines.indices.contains(index) else { return summary }
        var p = parts(lines[index])
        let owner = oneLine(owner)
        guard p.lead.contains("["), p.owner != owner else { return summary }
        p.ownerRaw = owner.isEmpty ? "" : owner + ": "
        lines[index] = p.line
        return lines.joined(separator: "\n")
    }

    /// Earl's briefing is up to three summary bullets read as one paragraph.
    /// The edited paragraph goes into the first of them and the others go,
    /// so the briefing reads as you wrote it.
    static func replacingBriefing(_ bullets: [String], in summary: String, with text: String) -> String {
        var indices: [Int] = []
        var lines = summary.components(separatedBy: "\n")
        for bullet in bullets {
            // Each bullet at its own line, even when two read the same.
            let rest = lines.indices.filter { !indices.contains($0) }
            guard let i = rest.first(where: { lineIndex(of: bullet, in: lines[$0], hint: 0) == 0 }) else { continue }
            indices.append(i)
        }
        guard let first = indices.first else { return summary }
        let text = oneLine(text)
        var gone = Array(indices.dropFirst())
        if text.isEmpty { gone = indices } else {
            var p = parts(lines[first])
            p.text = text
            lines[first] = p.line
        }
        for i in gone.sorted(by: >) { lines.remove(at: i) }
        return lines.joined(separator: "\n")
    }

    /// Notes lines are single lines: a pasted newline becomes a space.
    static func oneLine(_ s: String) -> String {
        s.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// The people a to-do can be given to: everyone in the cast but you, by
    /// the label the notes use for them.
    static func owners(in meeting: Meeting) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for member in CastMember.cast(turns: meeting.turns, speakers: meeting.speakers) where !member.isYou {
            let speaker = meeting.speakers.first { $0.id == member.speakerID }
            let name = speaker.flatMap { NotesPatch.label($0, in: meeting.speakers) } ?? CastRow.name(member)
            if seen.insert(name).inserted { out.append(name) }
        }
        return out
    }

    /// How a to-do of yours is written: your name from Settings, else "Me".
    static func yourOwnerLabel(userName: String?) -> String {
        let name = userName?.trimmingCharacters(in: .whitespaces) ?? ""
        return name.isEmpty ? "Me" : name
    }
}

// MARK: - Undo

/// "Line removed · Undo" for five seconds after a line was emptied.
@MainActor
final class NotesUndo: ObservableObject {
    static let shared = NotesUndo()

    struct Removal: Equatable {
        let id = UUID()
        let meetingID: String
        let before: String
        let after: String
    }

    @Published private(set) var removal: Removal?

    func offer(_ removal: Removal) {
        withAnimation(.easeOut(duration: 0.2)) { self.removal = removal }
        let id = removal.id
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            if self.removal?.id == id { self.dismiss() }
        }
    }

    func dismiss() {
        withAnimation(.easeOut(duration: 0.2)) { removal = nil }
    }
}

// MARK: - App state

extension AppState {
    /// Saves edited notes the way ticking a to-do does: summary.md, the
    /// to-do files, then transcript.md.
    private func saveNotes(_ meetingID: String, from old: String, to new: String,
                           moved: [(old: ActionItem, new: ActionItem)] = []) {
        guard new != old, !isBusy(meetingID) else { return }
        let folder = Prefs.storageURL.appendingPathComponent(meetingID)
        do {
            try store.saveSummary(new, in: folder)
        } catch {
            NSLog("Earl: couldn't save the notes: \(error)")
            return
        }
        TodoFiles.rekey(moved, in: folder)
        reload()
        if let m = meeting(meetingID) { store.saveMarkdown(m) }
        if !moved.isEmpty { reminders.loadSent(meetings: meetings) }
    }

    private func currentSummary(_ meetingID: String) -> String? {
        try? String(contentsOf: Prefs.storageURL.appendingPathComponent(meetingID).appendingPathComponent("summary.md"),
                    encoding: .utf8)
    }

    private func removed(_ meetingID: String, before: String, after: String) {
        NotesUndo.shared.offer(.init(meetingID: meetingID, before: before, after: after))
    }

    /// A plain bullet (Decided, Still open, the summary, other sections).
    func editNoteLine(meetingID: String, original: String, to text: String) {
        guard let summary = currentSummary(meetingID),
              let index = NotesEdit.lineIndex(of: original, in: summary) else { return }
        let updated = NotesEdit.replacingText(ofLine: index, in: summary, with: text)
        saveNotes(meetingID, from: summary, to: updated)
        if NotesEdit.oneLine(text).isEmpty && updated != summary { removed(meetingID, before: summary, after: updated) }
    }

    /// A to-do's words; its owner and tick stay.
    func editTodo(_ item: ActionItem, to text: String) {
        guard let summary = currentSummary(item.meetingID),
              let index = NotesEdit.lineIndex(of: item, in: summary) else { return }
        let updated = NotesEdit.replacingText(ofLine: index, in: summary, with: text)
        if NotesEdit.oneLine(text).isEmpty {
            saveNotes(item.meetingID, from: summary, to: updated)
            if updated != summary { removed(item.meetingID, before: summary, after: updated) }
            return
        }
        let new = ActionItems.parseLine(updated.components(separatedBy: "\n")[index], meetingID: item.meetingID, index: index)
        saveNotes(item.meetingID, from: summary, to: updated, moved: new.map { [(item, $0)] } ?? [])
    }

    func setTodoOwner(_ item: ActionItem, to owner: String) {
        guard let summary = currentSummary(item.meetingID),
              let index = NotesEdit.lineIndex(of: item, in: summary) else { return }
        saveNotes(item.meetingID, from: summary, to: NotesEdit.settingOwner(ofLine: index, in: summary, to: owner))
    }

    /// Earl's "In short" paragraph, made of the first summary bullets.
    func editBriefing(meetingID: String, bullets: [String], to text: String) {
        guard let summary = currentSummary(meetingID) else { return }
        let updated = NotesEdit.replacingBriefing(bullets, in: summary, with: text)
        saveNotes(meetingID, from: summary, to: updated)
        if NotesEdit.oneLine(text).isEmpty && updated != summary { removed(meetingID, before: summary, after: updated) }
    }

    /// The front page's headline. Empty puts the meeting's title back in its place.
    func editHeadline(meetingID: String, to text: String) {
        let folder = Prefs.storageURL.appendingPathComponent(meetingID)
        guard !isBusy(meetingID), var m = store.load(folder) else { return }
        let text = NotesEdit.oneLine(text)
        let headline: String? = text.isEmpty ? nil : text
        guard headline != m.info.headline else { return }
        m.info.headline = headline
        try? store.save(m.info, in: folder)
        reload()
    }

    /// Puts back the notes from before a line was removed, unless they changed since.
    func undoRemoval(_ removal: NotesUndo.Removal) {
        NotesUndo.shared.dismiss()
        guard currentSummary(removal.meetingID) == removal.after else { return }
        saveNotes(removal.meetingID, from: removal.after, to: removal.before)
    }
}

// MARK: - Views

/// The pencil at the end of an editable line, shown while the pointer is on it.
struct EditPencil: View {
    /// What it takes beside a line. Lines lend it from the margin
    /// (`pencilGutter`), so their text wraps the same with or without it.
    static let width: CGFloat = 22

    let visible: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "pencil")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Paper.inkMuted)
                .frame(width: Self.width - 4, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
        .help("Edit")
        .accessibilityLabel("Edit")
    }
}

/// A line in edit: a plain field in the line's own font over a hairline,
/// and a quiet hint under it. Return saves, Escape cancels, clicking
/// elsewhere saves (like the title).
struct NoteField: View {
    let original: String
    var font: Font = .paperBody
    var lineSpacing: CGFloat = 3
    var hint = "Return saves · Esc cancels"
    /// The new text, or nil when cancelled.
    let onDone: (String?) -> Void

    @State private var draft = ""
    @State private var finished = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            TextField("", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(font)
                .lineSpacing(lineSpacing)
                .foregroundStyle(Paper.ink)
                .focused($focused)
                .onSubmit { finish(draft) }
                .onExitCommand { finish(nil) }
                .padding(.bottom, 3)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(focused ? Paper.inkMuted : Paper.hairline).frame(height: 1)
                }
            Text(NotesEdit.oneLine(draft).isEmpty ? "Return removes the line · Esc cancels" : hint)
                .font(.system(size: 13))
                .foregroundStyle(Paper.inkMuted)
        }
        .onAppear {
            draft = original
            focused = true
        }
        .onChange(of: focused) { _, isFocused in
            if !isFocused { finish(draft) }
        }
    }

    private func finish(_ text: String?) {
        guard !finished else { return }
        finished = true
        onDone(text.map { NotesEdit.oneLine($0) == NotesEdit.oneLine(original) ? original : $0 })
    }
}

/// Any line of the notes that can be corrected in place: double-click it,
/// or click the pencil that appears on hover.
struct EditableLine<Content: View>: View {
    let text: String
    var font: Font = .paperBody
    var enabled = true
    /// Stays before the field while editing, like a bullet's "•".
    var marker: String?
    let onSave: (String) -> Void
    @ViewBuilder var content: Content

    @State private var editing = false
    @State private var hovering = false

    var body: some View {
        if editing {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                if let marker { Text(marker).font(font).foregroundStyle(Paper.inkMuted) }
                NoteField(original: text, font: font) { new in
                    editing = false
                    if let new, new != text { onSave(new) }
                }
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                content.frame(maxWidth: .infinity, alignment: .leading)
                if enabled {
                    EditPencil(visible: hovering) { editing = true }
                }
            }
            .pencilGutter(enabled)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { if enabled { editing = true } }
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}

extension View {
    /// Lets a row with a trailing pencil reach into the margin by the
    /// pencil's width, so the row's text keeps the width it had without it.
    func pencilGutter(_ on: Bool = true) -> some View {
        padding(.trailing, on ? -EditPencil.width : 0)
    }
}

/// A bullet on the front page that can be edited.
struct EditableBullet: View {
    @EnvironmentObject private var state: AppState
    let meetingID: String
    /// The line as written in summary.md, Markdown and all.
    let raw: String
    let display: AttributedString
    var marked = false
    var enabled = true

    var body: some View {
        EditableLine(text: raw, enabled: enabled && !state.isBusy(meetingID), marker: "•",
                     onSave: { state.editNoteLine(meetingID: meetingID, original: raw, to: $0) }) {
            PageBullet(text: display, marked: marked)
        }
    }
}

/// A to-do's text and owner in edit, inside its ticket: the owner is a small
/// menu of the meeting's people and "You".
struct TodoEditor: View {
    @EnvironmentObject private var state: AppState
    let meeting: Meeting
    let item: ActionItem
    let mine: Bool
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Menu {
                Button("You") { give(NotesEdit.yourOwnerLabel(userName: Prefs.userName)) }
                Divider()
                ForEach(NotesEdit.owners(in: meeting), id: \.self) { name in
                    Button(name) { give(name) }
                }
            } label: {
                Text("\(mine ? "You" : item.owner ?? "No one yet") \(Image(systemName: "chevron.down"))")
                .font(.paperLabel)
                .foregroundStyle(Paper.inkMuted)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Who does this")
            NoteField(original: item.text) { new in
                done()
                if let new, new != item.text { state.editTodo(item, to: new) }
            }
        }
    }

    private func give(_ owner: String) {
        done()
        state.setTodoOwner(item, to: owner)
    }
}

/// "Line removed · Undo", at the foot of the front page.
struct NotesUndoToast: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var undo = NotesUndo.shared
    let meetingID: String

    var body: some View {
        if let removal = undo.removal, removal.meetingID == meetingID {
            HStack(spacing: 8) {
                Text("Line removed").foregroundStyle(Paper.ink)
                Text("·").foregroundStyle(Paper.inkMuted)
                Button("Undo") { state.undoRemoval(removal) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Paper.ink)
                    .fontWeight(.semibold)
            }
            .font(.system(size: 14))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Paper.card, in: Capsule())
            .overlay(Capsule().strokeBorder(Paper.hairline))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }
}
