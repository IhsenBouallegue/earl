import Foundation
import Testing
@testable import Earl

/// S-1 evaluation: does the notes model, given earlier meetings of the series,
/// keep them out of today's Decisions and Action items, and say what moved?
/// Hand-written cases: the context names items today's transcript never
/// mentions (they must not be copied) and one it settles (it should show up
/// under "Since last time", done or not).
///
///     EARL_EVAL_SERIES=1 EARL_EVAL_LLM_MODEL=google/gemma-4-e4b ./test.sh --filter SeriesNotesEvalTests
///
/// Thinking is off unless `EARL_EVAL_SERIES_REASONING=on`. One call per case.
@Suite(.serialized)
struct SeriesNotesEvalTests {
    static let env = ProcessInfo.processInfo.environment

    struct Case {
        var name: String
        var kind: MeetingKind
        var context: String
        var transcript: String
        var language: String
        /// Words of earlier items not discussed today: must not be in Decisions or Action items.
        var untouched: [String]
        /// A word of the earlier item that moved today, and whether it's now done.
        var moved: String
        var movedDone: Bool
    }

    static let cases: [Case] = [
        Case(name: "daily", kind: .standup, context: """
            \(SeriesContext.heading)

            Last time (Mon, Oct 5): Tom is chasing the patch list.
            Decisions:
            - Freeze the public API on Friday.
            Open questions:
            - Who owns the QA rota?

            Open to-dos:
            - Tom: Send the patch list to the customer (set Mon, Oct 5)
            - Sarah: Book the Lisbon venue (set Mon, Oct 5)
            """, transcript: """
            [00:02] Me: Morning everyone. Quick round. Tom?
            [00:06] Tom: I sent the patch list to the customer last night, they confirmed it. Today I'm on the login timeout bug.
            [00:15] Me: Great. Sarah?
            [00:18] Sarah: I'm preparing the database migration. Can someone write the runbook for it?
            [00:24] Me: I'll write the migration runbook today.
            [00:28] Sarah: Thanks. No blockers for me.
            [00:31] Me: Nothing blocking for me either. Thanks, that's it.
            """, language: "en", untouched: ["lisbon", "venue", "freeze", "rota"], moved: "patch", movedDone: true),
        Case(name: "weekly", kind: .general, context: """
            \(SeriesContext.heading)

            Last time (Tue, Sep 29): Offsite moved, hiring plan pending.
            Decisions:
            - Move the team offsite to November.
            Open questions:
            - Do we need a second designer next year?

            Open to-dos:
            - Priya: Draft the hiring plan (set Tue, Sep 29)
            - Me: Order new laptops for the interns (set Tue, Sep 29)
            """, transcript: """
            [00:03] Them: Let's look at the budget for Q4 first. We're about ten percent under, mostly travel.
            [00:14] Me: Good. Then we can afford the conference tickets for Sam and Jordan.
            [00:21] Them: Agreed, let's book both tickets. Priya, where are we with the hiring plan?
            [00:27] Priya: Not done yet, sorry. I'll finish the hiring plan by next Wednesday.
            [00:33] Me: Fine. I'll book the two conference tickets this week.
            [00:38] Them: Great, that's all for today.
            """, language: "en", untouched: ["offsite", "laptop", "designer"], moved: "hiring", movedDone: false),
        Case(name: "daily-de", kind: .standup, context: """
            \(SeriesContext.heading)

            Last time (Mon, Oct 5): Rechnung wartet auf Klärung.
            Decisions:
            - Die Retro findet ab jetzt donnerstags statt.
            Open questions:
            - Wer übernimmt die Urlaubsvertretung im Dezember?

            Open to-dos:
            - Katrin: Rechnung an den Kunden schicken (set Mon, Oct 5)
            - Markus: Serverlizenzen verlängern (set Mon, Oct 5)
            """, transcript: """
            [00:02] Me: Guten Morgen. Kurze Runde. Katrin?
            [00:05] Katrin: Die Rechnung an den Kunden ist gestern rausgegangen. Heute kümmere ich mich um das Angebot für die Stadtwerke.
            [00:14] Me: Super. Markus?
            [00:16] Markus: Ich teste weiter den neuen Export. Kannst du mir die Testdaten schicken?
            [00:21] Me: Ja, die Testdaten schicke ich dir gleich nach dem Daily.
            [00:25] Markus: Danke, sonst keine Blocker.
            """, language: "de", untouched: ["retro", "donnerstag", "urlaub", "lizenz"], moved: "rechnung", movedDone: true),
    ]

    /// The bullets under headings whose kind is one of `kinds`.
    static func bullets(_ markdown: String, _ kinds: Set<String>) -> [String] {
        var keep = false
        var out: [String] = []
        for raw in markdown.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                let h = line.lowercased()
                keep = kinds.contains { h.contains($0) }
                continue
            }
            if keep && !line.isEmpty { out.append(line) }
        }
        return out
    }

    @Test(.enabled(if: env["EARL_EVAL_SERIES"] != nil, "Set EARL_EVAL_SERIES to evaluate notes with series context"))
    func series() async throws {
        try await DiarizationEvalTests.offMain { try await Self.run() }
    }

    static func run() async throws {
        var summarizer = Summarizer()
        summarizer.baseURL = env["EARL_EVAL_LLM_URL"] ?? Prefs.defaultLLMURL
        summarizer.model = env["EARL_EVAL_LLM_MODEL"] ?? Prefs.defaultLLMModel
        summarizer.vocabulary = []
        summarizer.reasoning = env["EARL_EVAL_SERIES_REASONING"] == "on"
        var copies = 0, movedRight = 0, shaped = 0
        for c in cases {
            var s = summarizer
            // `EARL_EVAL_SERIES_CONTEXT=off`: the same meetings without it, as a baseline.
            s.prompt.seriesContext = env["EARL_EVAL_SERIES_CONTEXT"] == "off" ? nil : c.context
            s.prompt.kind = c.kind
            s.prompt.language = c.language
            s.prompt.userName = "Alex"
            let started = Date()
            let result = try await s.summarize(c.transcript) { _ in }
            let seconds = Date().timeIntervalSince(started)
            let md = result.markdown
            let today = bullets(md, ["decision", "action", "entscheid", "aufgabe"]).joined(separator: "\n").lowercased()
            let copied = c.untouched.filter { today.contains($0) }
            let notes = FrontPageNotes.parse(md, meetingID: "eval")
            let since = notes.since.first { $0.lowercased().contains(c.moved) }
            let right = since.map { SinceLastTime.isDone($0) == c.movedDone } ?? false
            let shapeRight = c.kind != .standup || md.contains("## Round the table")
            copies += copied.count
            if right { movedRight += 1 }
            if shapeRight { shaped += 1 }
            print("[series] \(summarizer.model) · \(c.name): \(String(format: "%.0f", seconds)) s, copied \(copied), "
                  + "since \(since.map { "\"\($0)\"" } ?? "missing") \(right ? "right" : "WRONG"), shape \(shapeRight ? "ok" : "WRONG")")
            print(md.split(separator: "\n").map { "[series]   \($0)" }.joined(separator: "\n"))
        }
        print("[series] TOTAL \(summarizer.model): copied \(copies) earlier items, moved item right \(movedRight)/\(cases.count), "
              + "shape \(shaped)/\(cases.count)")
    }
}
