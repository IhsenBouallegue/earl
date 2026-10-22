import SwiftUI

// S-1: "Since last time" on the front page, under Earl's briefing: what moved
// on the earlier meeting's to-dos and questions. A quiet list; items the notes
// call done get a check, and the title links back to that meeting.

struct SinceLastTime: View {
    @EnvironmentObject private var state: AppState
    let meeting: Meeting
    let items: [String]
    var query = ""
    var interactive = true

    @State private var hovering = false

    var body: some View {
        // English like the rest of the page's headings, whatever the notes' language.
        let german = false
        let previous = SeriesContext.previous(of: meeting, in: state.meetings)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(german ? "Seit dem letzten Mal" : "Since last time")
                    .font(.paperTitle)
                    .foregroundStyle(Paper.ink)
                Spacer(minLength: 12)
                if let previous {
                    Button { state.selection = .meeting(previous.id) } label: {
                        Text(Self.fromText(previous.info.startedAt, german: german))
                            .font(.paperLabel)
                            .foregroundStyle(hovering ? Paper.ink : Paper.inkMuted)
                            .underline(hovering)
                    }
                    .buttonStyle(.plain)
                    .disabled(!interactive)
                    .onHover { hovering = $0 }
                    .help("Open the meeting of \(SeriesContext.day(previous.info.startedAt))")
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, text in
                    row(text)
                }
            }
        }
    }

    private func row(_ text: String) -> some View {
        // E-1: editable like every other bullet on the page.
        EditableLine(text: text, enabled: interactive && !state.isBusy(meeting.id), marker: "•",
                     onSave: { state.editNoteLine(meetingID: meeting.id, original: text, to: $0) }) {
            rowContent(text)
        }
    }

    private func rowContent(_ text: String) -> some View {
        let done = Self.isDone(text)
        return HStack(alignment: .firstTextBaseline, spacing: 9) {
            Group {
                if done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Paper.ok)
                        .accessibilityLabel("Done")
                } else {
                    Text("•").font(.paperBody).foregroundStyle(Paper.inkMuted)
                }
            }
            .frame(width: 13, alignment: .leading)
            Text(PageText.attributed(text, query: query))
                .font(.paperBody)
                .lineSpacing(3)
                .foregroundStyle(Paper.ink)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    /// "from Tue, Oct 6", or "vom Di., 6. Okt." for German notes.
    static func fromText(_ date: Date, german: Bool) -> String {
        guard german else { return "from " + SeriesContext.day(date) }
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "EEE, d. MMM"
        return "vom " + f.string(from: date)
    }

    /// The notes say this one is done ("Done: sent the patch list", "Patch
    /// list sent (erledigt)"), and not "not done yet".
    static func isDone(_ text: String) -> Bool {
        let words = text.lowercased().split { !$0.isLetter && $0 != "-" }.map(String.init)
        let doneWords: Set<String> = ["done", "erledigt", "completed", "abgeschlossen"]
        // "not done", "not yet done", "noch nicht erledigt"
        let negations: Set<String> = ["not", "nicht", "yet", "never", "nie"]
        return words.indices.contains { i in
            doneWords.contains(words[i]) && (i == 0 || !negations.contains(words[i - 1]))
        }
    }
}
