import Foundation

// E-1: renaming a speaker patches the notes in place. Since Q-3 the notes keep
// unbacked labels ("Speaker 2"), so a new name is a text substitution, not a
// reason to run the notes model again.

enum NotesPatch {
    /// One substitution: every whole-word `labels` occurrence becomes `name`.
    struct Rename: Equatable {
        var labels: [String]
        var name: String
    }

    /// The notes, headline and title with every whole-word occurrence of
    /// `labels` replaced by `name`. Unchanged text when nothing matched.
    static func rename(summary: String, headline: String?, title: String, from labels: [String], to name: String)
        -> (summary: String, headline: String?, title: String) {
        (replacing(labels, with: name, in: summary),
         headline.map { replacing(labels, with: name, in: $0) },
         replacing(labels, with: name, in: title))
    }

    /// Replaces whole-word, case-sensitive occurrences of `labels` with `name`.
    /// "Speaker 2" doesn't match in "Speaker 21"; a German genitive "s"
    /// ("Sarahs") stays after the new name ("Toms"), and so does an English
    /// "'s". Where the text already reads `name` (renaming "Sarah" to
    /// "Sarah Chen"), it's left alone.
    static func replacing(_ labels: [String], with name: String, in text: String) -> String {
        let candidates = labels.filter { !$0.isEmpty && $0 != name }.sorted { $0.count > $1.count }.map(Array.init)
        guard !candidates.isEmpty, !text.isEmpty else { return text }
        let chars = Array(text)
        let nameChars = Array(name)
        var out: [Character] = []
        out.reserveCapacity(chars.count)
        var changed = false
        var i = 0
        scan: while i < chars.count {
            if startsWord(chars, at: i) {
                if let end = wordMatch(chars, at: i, nameChars) {
                    out += chars[i..<end]
                    i = end
                    continue scan
                }
                for label in candidates {
                    if let end = wordMatch(chars, at: i, label) {
                        out += nameChars
                        i = end
                        changed = true
                        continue scan
                    }
                }
            }
            out.append(chars[i])
            i += 1
        }
        return changed ? String(out) : text
    }

    private static func isWord(_ c: Character) -> Bool { c.isLetter || c.isNumber }

    private static func startsWord(_ chars: [Character], at i: Int) -> Bool {
        i == 0 || !isWord(chars[i - 1])
    }

    private static func endsWord(_ chars: [Character], at i: Int) -> Bool {
        i >= chars.count || !isWord(chars[i])
    }

    /// Where `word` ends when it stands at `i` as a whole word, also before a
    /// genitive "s" (which isn't consumed, so it stays in the text).
    private static func wordMatch(_ chars: [Character], at i: Int, _ word: [Character]) -> Int? {
        let end = i + word.count
        guard !word.isEmpty, end <= chars.count, Array(chars[i..<end]) == word else { return nil }
        if endsWord(chars, at: end) { return end }
        if chars[end] == "s", endsWord(chars, at: end + 1) { return end }
        return nil
    }

    // MARK: - From a speaker edit

    /// The label a speaker has in the notes: its name, else "Speaker N".
    /// nil for you, whom the notes call "Me" or by your name, which no
    /// speaker edit changes.
    static func label(_ speaker: Speaker, in speakers: [Speaker]) -> String? {
        if let name = speaker.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty { return name }
        if Speaker.isYou(speaker, in: speakers) { return nil }
        return "Speaker \(speaker.number)"
    }

    /// The substitutions a speaker edit calls for: each speaker whose label
    /// changed (or which was merged into another) has its old label replaced
    /// by the new one. A full name's first name is replaced too when only
    /// that person has it among the meeting's speakers and attendees, by the
    /// new first name when the new label is a full name. Full names come
    /// first, so "Sarah Becker" isn't half-replaced by the "Sarah" rule.
    static func renames(before: [Speaker], after: [Speaker], mergedInto: [String: String] = [:],
                        attendees: [Attendee] = []) -> [Rename] {
        var full: [Rename] = [], first: [Rename] = []
        func add(_ rename: Rename, to list: inout [Rename]) {
            if let i = list.firstIndex(where: { $0.name == rename.name }) {
                for l in rename.labels where !list[i].labels.contains(l) { list[i].labels.append(l) }
            } else {
                list.append(rename)
            }
        }
        for old in before {
            let targetID = mergedInto[old.id] ?? old.id
            guard let new = after.first(where: { $0.id == targetID }),
                  let oldLabel = label(old, in: before), let newLabel = label(new, in: after),
                  oldLabel != newLabel else { continue }
            // Two voices with the same name (a wrong guess next to the real
            // person): the text can't say which is which, so don't touch it.
            let shared = before.contains { $0.id != old.id && label($0, in: before) == oldLabel }
            if shared && mergedInto[old.id] == nil { continue }
            add(Rename(labels: [oldLabel], name: newLabel), to: &full)
            if let oldFirst = uniqueFirstName(oldLabel, among: before.filter { $0.id != old.id }, attendees: attendees) {
                let newFirst = uniqueFirstName(newLabel, among: after.filter { $0.id != new.id }, attendees: attendees)
                let target = newFirst ?? newLabel
                if oldFirst != target { add(Rename(labels: [oldFirst], name: target), to: &first) }
            }
        }
        return full + first
    }

    /// The first name of a full name, when nobody else in the meeting has it.
    /// nil for single names and for "Speaker N".
    static func uniqueFirstName(_ name: String, among others: [Speaker], attendees: [Attendee]) -> String? {
        let parts = name.split(separator: " ")
        guard parts.count >= 2, !name.hasPrefix("Speaker ") else { return nil }
        let first = AttendeeName.firstName(name)
        guard !first.isEmpty, first != name else { return nil }
        let key = ActionItems.normalize(first)
        let otherNames = others.compactMap(\.name) + attendees.map(\.name).filter {
            ActionItems.normalize($0) != ActionItems.normalize(name)
        }
        let clash = otherNames.contains { ActionItems.normalize(AttendeeName.firstName($0)) == key }
        return clash ? nil : first
    }

    /// Applies the renames to a meeting's notes, headline and title. A title
    /// that came from the calendar or a pasted invite is someone else's
    /// words and stays.
    static func patched(_ meeting: Meeting, renames: [Rename]) -> Meeting {
        var m = meeting
        let keepTitle = m.info.calendarTitle != nil && m.info.title == m.info.calendarTitle
        for r in renames {
            let out = rename(summary: m.summary, headline: m.info.headline, title: m.info.title, from: r.labels, to: r.name)
            m.summary = out.summary
            m.info.headline = out.headline
            if !keepTitle { m.info.title = out.title }
        }
        return m
    }

    // MARK: - Saving

    /// Saves a speaker edit already applied to `meeting` (turns and
    /// speakers), with the notes patched to the new names. Nothing is marked
    /// stale. Returns the saved meeting.
    @discardableResult
    static func saveSpeakerEdit(_ meeting: Meeting, before: (turns: [Turn], speakers: [Speaker]),
                                mergedInto: [String: String], store: MeetingStore) throws -> Meeting {
        if meeting.turns != before.turns { try store.saveTranscript(meeting.turns, in: meeting.folder) }
        try store.saveSpeakers(meeting.speakers, in: meeting.folder)
        let renames = renames(before: before.speakers, after: meeting.speakers, mergedInto: mergedInto,
                              attendees: meeting.info.attendees ?? [])
        let patched = Self.patched(meeting, renames: renames)
        if patched.summary != meeting.summary {
            try store.saveSummary(patched.summary, in: meeting.folder)
            TodoFiles.rekey(old: meeting.summary, new: patched.summary, in: meeting.folder)
        }
        if patched.info != meeting.info { try store.save(patched.info, in: meeting.folder) }
        return patched
    }
}

// MARK: - To-do files follow the text

extension TodoFiles {
    /// When a to-do's words change in place (a rename, an edit), its tick
    /// record and its Reminders mapping move to the new key, so the item
    /// stays done and stays "In Reminders". Pairs lines by index, so both
    /// summaries must have the same lines.
    static func rekey(old: String, new: String, in folder: URL) {
        let id = folder.lastPathComponent
        let oldItems = Dictionary(ActionItems.parse(old, meetingID: id).map { ($0.line, $0) }) { a, _ in a }
        let pairs = ActionItems.parse(new, meetingID: id).compactMap { item -> (ActionItem, ActionItem)? in
            guard let was = oldItems[item.line] else { return nil }
            return (was, item)
        }
        rekey(pairs, in: folder)
    }

    static func rekey(_ pairs: [(old: ActionItem, new: ActionItem)], in folder: URL) {
        let moved = pairs.filter { $0.old.key != $0.new.key }
        guard !moved.isEmpty else { return }
        var records = loadDone(in: folder)
        var reminders = loadReminders(in: folder)
        var recordsChanged = false, remindersChanged = false
        for (old, new) in moved {
            for i in records.indices where records[i].key == old.key {
                records[i] = .init(key: new.key, text: new.text)
                recordsChanged = true
            }
            if let identifier = reminders.removeValue(forKey: old.key) {
                reminders[new.key] = identifier
                remindersChanged = true
            }
        }
        if recordsChanged { saveDone(records, in: folder) }
        if remindersChanged { saveReminders(reminders, in: folder) }
    }
}
