import SwiftUI

// K-1: what kind of meeting the notes were written for, on the masthead's
// right beside the page's other controls, in quiet words. Picking another kind rewrites the notes in its
// shape, and the series' next meetings follow it.

struct NotesKindMenu: View {
    @EnvironmentObject private var state: AppState
    let meeting: Meeting

    private var current: MeetingKind? { meeting.info.notesKind.flatMap(MeetingKind.init(rawValue:)) }

    /// Notes written before K-1 for what looks like a town hall or a talk:
    /// Earl suggests it, and rewrites only when asked.
    private var suggestion: MeetingKind? {
        guard current == nil, let kind = MeetingKind.decide(meeting, in: state.meetings), kind.isListening else { return nil }
        return kind
    }

    private var labelText: String {
        if let current { return current.label }
        if let suggestion { return "Looks like a \(suggestion.label.lowercased())" }
        return "Kind of meeting"
    }

    /// "Earl will write the next Daily this way.", or nil outside a series.
    private var seriesLine: String? {
        let members = MeetingSeries.members(of: meeting, in: state.meetings)
        guard members.count > 1 else { return nil }
        return "Earl will write the next \(MeetingSeries.displayName(members)) this way."
    }

    var body: some View {
        Menu {
            Section("Write these notes as") {
                ForEach(MeetingKind.allCases, id: \.self) { kind in
                    Button {
                        if kind != current { state.rewriteNotes(meeting.id, as: kind) }
                    } label: {
                        if kind == current { Image(systemName: "checkmark") }
                        Text(kind.label)
                        Text(kind.explanation)
                    }
                }
            }
            if let seriesLine {
                Divider()
                Text(seriesLine)
            }
        } label: {
            Text("\(labelText) \(Image(systemName: "chevron.down"))")
                .font(.system(size: 13))
                .foregroundStyle(suggestion == nil ? Paper.inkMuted : Paper.ink)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(state.isBusy(meeting.id) || meeting.turns.isEmpty)
        .help(current.map { "Notes written for a \($0.label.lowercased()). Choose another kind to rewrite them." }
              ?? suggestion.map { "These notes were written for a working meeting. Choose \"\($0.label)\" to rewrite them to fit." }
              ?? "Choose what kind of meeting this was, and Earl rewrites the notes to fit")
        .accessibilityLabel("Kind of meeting: \(current?.label ?? "not set")")
    }
}
