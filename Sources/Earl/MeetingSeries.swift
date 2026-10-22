import Foundation

// S-0: meetings that belong together. A daily, a weekly, a jour fixe: the same
// calendar meeting recorded again and again. Earl uses the series to carry
// context from one meeting to the next (S-1), brief you before the next one
// (S-2) and answer questions across it (S-3).
//
// The key is the calendar title, cleaned up, because recurring events keep
// their title while some calendars give single occurrences or re-sent invites
// new IDs (seen with two "Freitagsrunde" events). Meetings without a calendar
// title, or with a default title, form no series: summarizer titles differ
// every time and would group unrelated calls.

enum MeetingSeries {
    /// Prefixes calendars add to cancelled or forwarded events.
    static let noisePrefixes = ["abgesagt:", "abgesagt -", "canceled:", "cancelled:", "fw:", "fwd:", "wg:", "aw:", "re:",
                                "updated invitation:", "invitation:", "einladung:", "aktualisiert:"]

    /// The series key for a calendar title, or nil when there's nothing to go on.
    static func key(title: String?) -> String? {
        guard var t = title?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        var stripped = true
        while stripped {
            stripped = false
            for p in noisePrefixes where t.hasPrefix(p) {
                t = String(t.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)
                stripped = true
            }
        }
        // Collapse punctuation and spacing so "Guild WF – Weekly" and
        // "Guild WF - Weekly" meet.
        let words = t.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        guard !words.isEmpty else { return nil }
        return words.joined(separator: " ")
    }

    /// The series key of a recorded meeting: its calendar title, else a title
    /// you set yourself on a meeting that has a calendar link.
    static func key(for info: MeetingInfo) -> String? {
        if let k = key(title: info.calendarTitle) { return k }
        return info.calendarEventID == nil ? nil : key(title: info.title)
    }

    static func key(for meeting: Meeting) -> String? { key(for: meeting.info) }

    /// Earlier meetings of the same series, newest first. Only finished ones
    /// with notes or a transcript count.
    static func earlier(than meeting: Meeting, in meetings: [Meeting], limit: Int = .max) -> [Meeting] {
        guard let k = key(for: meeting) else { return [] }
        return Array(meetings
            .filter { $0.id != meeting.id && $0.info.startedAt < meeting.info.startedAt && key(for: $0) == k && $0.hasContent }
            .sorted { $0.info.startedAt > $1.info.startedAt }
            .prefix(limit))
    }

    /// Past meetings of the series an upcoming event belongs to, newest first.
    static func past(forEventTitle title: String, in meetings: [Meeting], before date: Date = .distantFuture,
                     limit: Int = .max) -> [Meeting] {
        guard let k = key(title: title) else { return [] }
        return Array(meetings
            .filter { $0.info.startedAt < date && key(for: $0) == k && $0.hasContent }
            .sorted { $0.info.startedAt > $1.info.startedAt }
            .prefix(limit))
    }

    /// All meetings of a meeting's series, itself included, newest first.
    static func members(of meeting: Meeting, in meetings: [Meeting]) -> [Meeting] {
        guard let k = key(for: meeting) else { return [meeting] }
        return meetings.filter { key(for: $0) == k }.sorted { $0.info.startedAt > $1.info.startedAt }
    }

    /// Series with at least two meetings, keyed by series key, each newest first.
    static func groups(_ meetings: [Meeting]) -> [String: [Meeting]] {
        Dictionary(grouping: meetings.filter { key(for: $0) != nil }) { key(for: $0)! }
            .filter { $0.value.count >= 2 }
            .mapValues { $0.sorted { $0.info.startedAt > $1.info.startedAt } }
    }

    /// The name to show for a series: the most recent calendar title, without
    /// "Abgesagt:" and friends.
    static func displayName(_ members: [Meeting]) -> String {
        let title = members.first?.info.calendarTitle ?? members.first?.info.title ?? ""
        var t = title.trimmingCharacters(in: .whitespaces)
        var stripped = true
        while stripped {
            stripped = false
            for p in noisePrefixes where t.lowercased().hasPrefix(p) {
                t = String(t.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)
                stripped = true
            }
        }
        return t
    }
}

extension Meeting {
    /// Done, with notes or a transcript to learn from.
    var hasContent: Bool { info.status == .done && (!summary.isEmpty || !turns.isEmpty) }
}
