import Foundation
import Testing
@testable import Earl

/// Replays Ask Earl on a copy of a real meeting folder:
/// EARL_ASK_LIBRARY=<copy of the library>, EARL_ASK_ID=<meeting id>,
/// EARL_ASK_QUESTIONS="first|second" (from the shell, never committed),
/// EARL_REPROCESS_MODEL. Prints whether each answer said "the notes don't
/// say", its length and the time; EARL_ASK_SHOW=1 prints the answers too.
struct AskReplay {
    static let env = ProcessInfo.processInfo.environment

    @Test(.enabled(if: env["EARL_ASK_LIBRARY"] != nil)) func replay() async throws {
        let root = URL(fileURLWithPath: try #require(Self.env["EARL_ASK_LIBRARY"]), isDirectory: true)
        try ReprocessTool.assertSafe(root)
        let id = try #require(Self.env["EARL_ASK_ID"])
        let questions = (Self.env["EARL_ASK_QUESTIONS"] ?? "").split(separator: "|").map(String.init)
        let library = MeetingStore(root: root).loadAll()
        var engine = AskEngine()
        if let model = Self.env["EARL_REPROCESS_MODEL"] { engine.summarizer.model = model; engine.followsBackend = false }
        for q in questions {
            let request = AskContext.request(question: q, scope: .meeting(id), meetings: library)
            let started = Date()
            let raw = try await engine.ask(request) { _ in }
            let parsed = AskCitations.parse(raw, limits: request.meetings, current: id) { _, _ in "" }
            print(String(format: "[ask] task: %@ · %d chars of records · not found: %@ · %d chars · %d citations · %.0f s",
                         AskIntent.isTask(q) ? "yes" : "no", request.material.count, parsed.notFound ? "YES" : "no",
                         parsed.text.count, parsed.citations.count, Date().timeIntervalSince(started)))
            if Self.env["EARL_ASK_SHOW"] == "1" { print(parsed.text) }
        }
    }
}

struct AskIntentTests {
    @Test func tasksAndQuestions() {
        #expect(AskIntent.isTask("Gib mir eine kurze Zusammenfassung fürs Ticket"))
        #expect(AskIntent.isTask("write me a recap of what I learned"))
        #expect(AskIntent.isTask("Schreib eine Mail an Tom"))
        #expect(AskIntent.isTask("Was ist das Wichtigste?"))
        #expect(!AskIntent.isTask("Who brought up the log analysis?"))
        #expect(!AskIntent.isTask("Wann ist das Wartungsfenster?"))
    }

    @Test func tasksGetTheWholeMeetingAndAreNeverNone() {
        let s = AskContext.system
        #expect(s.contains("a summary, recap or draft of a meeting that has records is never [[none]]"))
        #expect(s.contains("never invent facts"))
        #expect(AskContext.taskBudget > AskContext.budget)
    }
}

@MainActor
struct AskNotFoundTests {
    func request(material: String, found: Bool) -> AskRequest {
        AskRequest(system: "", user: "", material: material, meetings: [:], foundAnything: found)
    }

    @Test func aDraftWithoutCitationsIsAnAnswer() {
        let plain = AskCitations.Parsed(text: "Recap…", citations: [], notFound: false)
        #expect(!AskSession.notFound(plain, request: request(material: "notes", found: false), question: "Write a recap"))
        #expect(AskSession.notFound(plain, request: request(material: "notes", found: false), question: "Who paid?"))
        #expect(AskSession.notFound(plain, request: request(material: "", found: false), question: "Write a recap"))
        let none = AskCitations.Parsed(text: "No.", citations: [], notFound: true)
        #expect(AskSession.notFound(none, request: request(material: "notes", found: true), question: "Write a recap"))
    }
}
