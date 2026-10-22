import Foundation
import Testing
@testable import Earl

/// S-3: Ask Earl's retrieval, context, citations and question detection, on
/// a made-up library. The live test asks LM Studio and only runs with
///
///     EARL_LIVE_LLM=1 ./test.sh --filter AskEarlLiveTests
///
/// (optional EARL_LIVE_LLM_MODEL / EARL_LIVE_LLM_URL; the default is the notes
/// model set in Earl).
struct AskEarlTests {
    static func turn(_ start: Double, _ speaker: String, _ id: String?, _ text: String) -> Turn {
        Turn(start: start, end: start + 8, speaker: speaker, text: text, speakerID: id)
    }

    static func meeting(_ id: String, day: Int, title: String, calendar: String? = nil, turns: [Turn],
                        speakers: [Speaker] = [], summary: String = "") -> Meeting {
        var info = MeetingInfo(title: title, titleIsDefault: false,
                               startedAt: Date(timeIntervalSince1970: 1_790_000_000 + Double(day) * 86_400),
                               duration: (turns.last?.end ?? 0) + 30, status: .done)
        info.calendarTitle = calendar
        info.calendarEventID = calendar.map { "E-\($0)" }
        return Meeting(id: id, folder: URL(fileURLWithPath: "/nonexistent/earl-ask/\(id)"), info: info, turns: turns,
                       summary: summary, files: [], speakers: speakers)
    }

    /// Three dailies (German) and a planning call (English), all invented.
    static let library: [Meeting] = {
        let matthias = [Speaker(id: "S1", track: "Them", name: "Matthias Brandt", nameSource: .confirmed, embedding: [],
                               seconds: 60)]
        let daily1 = meeting("d1", day: 1, title: "Daily", calendar: "Daily Alpenblick", turns: [
            turn(5, "Them", "S1", "Guten Morgen. Heute geht es um das Wartungsfenster für das Patching am Samstag."),
            turn(20, "Me", nil, "Das Wartungsfenster passt uns von zehn bis zwölf Uhr."),
            turn(35, "Them", "S1", "Dann buche ich die Freigabe beim Betrieb bis Donnerstag."),
            turn(50, "Me", nil, "Super, danke. Sonst noch etwas?"),
        ] + (0..<10).map { turn(70 + Double($0) * 10, "Them", "S1", "Kleiner Punkt \($0) zur Dokumentation der Server.") },
            speakers: matthias, summary: "## Summary\n- Wartungsfenster für Samstag besprochen.")
        let daily2 = meeting("d2", day: 2, title: "Daily", calendar: "Daily Alpenblick", turns: [
            turn(4, "Them", "S1", "Die Lizenzen für November sind bestellt."),
            turn(18, "Me", nil, "Ich schicke Dominik das Angebot bis Freitag."),
        ], speakers: matthias, summary: "## Summary\n- Lizenzen bestellt.\n\n## Action items\n- [ ] Me: Angebot an Dominik")
        let planning = meeting("p1", day: 3, title: "Release planning", turns: [
            turn(10, "Them", nil, "Let's talk about the onboarding release date."),
            turn(25, "Me", nil, "I propose we ship onboarding on October sixth to twenty percent of users."),
            turn(40, "Them", nil, "Agreed. Marketing needs the announcement copy a week before."),
            turn(55, "Them", nil, "The billing migration is postponed until January."),
        ], summary: "## Summary\n- Release date for onboarding.\n\n## Decisions\n- Ship on October 6.")
        return [planning, daily2, daily1]
    }()

    // MARK: Words

    @Test func termsDropStopwordsAndStem() {
        #expect(AskText.terms("What did Matthias say about the patching window?") == ["matthia", "patch", "window"])
        #expect(AskText.terms("Wann haben wir das Wartungsfenster festgelegt?") == ["wartungsfenst", "festgelegt"])
        #expect(AskText.stem("lizenzen") == "lizenz")
        #expect(AskText.stem("days") == "day")
        #expect(AskText.stem("es") == "es") // too short to strip
    }

    // MARK: Chunks

    @Test func chunksOverlapAndKeepIDsTimesAndNames() {
        let daily1 = Self.library[2]
        let chunks = AskChunk.chunks(of: daily1)
        #expect(chunks.count == 2) // 14 turns: 0–7, then 6–13
        #expect(chunks.allSatisfy { $0.meetingID == "d1" })
        #expect(chunks[0].start == 5)
        #expect(chunks[0].speakers == ["Matthias Brandt", "Me"])
        #expect(chunks[0].text.hasPrefix("[00:05] Matthias Brandt: Guten Morgen."))
        // The second window starts two turns before the first one ended.
        let firstLines = chunks[0].text.components(separatedBy: "\n")
        let secondLines = chunks[1].text.components(separatedBy: "\n")
        #expect(Array(firstLines.suffix(AskChunk.overlap)) == Array(secondLines.prefix(AskChunk.overlap)))
        #expect(firstLines.count == AskChunk.maxTurns)
    }

    @Test func chunksStayUnderTheCharacterLimit() {
        let long = String(repeating: "word ", count: 100) // 500 characters a turn
        let m = Self.meeting("x", day: 1, title: "Long", turns: (0..<6).map { Self.turn(Double($0) * 10, "Me", nil, long) })
        let chunks = AskChunk.chunks(of: m)
        #expect(chunks.allSatisfy { $0.text.count <= AskChunk.maxChars + 600 })
        #expect(chunks.first?.text.components(separatedBy: "\n").count == 2)
        // Every turn is in some chunk, and the last chunk ends with the last turn.
        #expect(chunks.last?.text.hasSuffix(long) == true)
    }

    @Test func indexCachesAndInvalidates() {
        let index = AskIndex()
        var m = Self.library[0]
        let first = index.chunks(of: m)
        #expect(index.chunks(of: m) == first)
        m.turns.append(Self.turn(70, "Me", nil, "One more thing about the pricing page."))
        #expect(index.chunks(of: m).last?.text.contains("pricing page") == true)
    }

    // MARK: Ranking

    @Test func englishQueryFindsTheRightChunk() {
        let chunks = Self.library.flatMap { AskChunk.chunks(of: $0) }
        let ranked = AskRank.rank("When is the billing migration?", chunks: chunks)
        #expect(ranked.first?.chunk.meetingID == "p1")
        #expect(ranked.first?.chunk.text.contains("billing migration") == true)
        #expect(ranked.first!.score > 0)
    }

    @Test func germanQueryFindsTheRightChunk() {
        let chunks = Self.library.flatMap { AskChunk.chunks(of: $0) }
        let ranked = AskRank.rank("Wann ist das Wartungsfenster?", chunks: chunks)
        #expect(ranked.first?.chunk.meetingID == "d1")
        #expect(ranked.first?.chunk.start == 5)
        let lizenz = AskRank.rank("Welche Lizenzen wurden bestellt?", chunks: chunks)
        #expect(lizenz.first?.chunk.meetingID == "d2")
    }

    @Test func speakerNameInTheQuestionAddsABonus() {
        let chunks = Self.library.flatMap { AskChunk.chunks(of: $0) }
        let ranked = AskRank.rank("What did Matthias say?", chunks: chunks)
        #expect(["d1", "d2"].contains(ranked.first?.chunk.meetingID ?? ""))
        #expect(ranked.first!.score >= AskRank.speakerBonus)
        #expect(ranked.last!.score == 0) // the planning call has no Matthias
    }

    // MARK: Context

    @Test func meetingScopeSendsTheWholeTranscriptWhenItFits() {
        let r = AskContext.request(question: "When do we ship?", scope: .meeting("p1"), meetings: Self.library)
        #expect(r.material.contains("Ship on October 6."))
        #expect(r.material.contains("[00:55]"))
        #expect(r.meetings.keys.sorted() == ["p1"])
        #expect(r.user.contains("Question: When do we ship?"))
        #expect(r.user.hasPrefix("Today is "))
        #expect(r.system.contains("[[<meeting id>@<mm:ss>]]"))
    }

    @Test func meetingScopeFallsBackToTopChunksWhenTooLong() {
        let r = AskContext.request(question: "Wartungsfenster", scope: .meeting("d1"), meetings: Self.library,
                                   budget: 1000)
        #expect(r.material.count <= 1000)
        #expect(r.material.contains("Wartungsfenster für das Patching"))
        #expect(!r.material.contains("Kleiner Punkt 9"))
    }

    @Test func seriesScopeHasEveryMembersNotesNewestFirst() {
        let r = AskContext.request(question: "Was hat Matthias gebucht?", scope: .series("daily alpenblick"),
                                   meetings: Self.library)
        let d2 = r.material.range(of: "Meeting d2")!, d1 = r.material.range(of: "Meeting d1")!
        #expect(d2.lowerBound < d1.lowerBound)
        #expect(r.material.contains("Lizenzen bestellt."))
        #expect(r.material.contains("Freigabe beim Betrieb"))
        #expect(!r.material.contains("onboarding"))
        #expect(Set(r.meetings.keys) == ["d1", "d2"])
        #expect(r.material.count <= AskContext.budget)
    }

    @Test func allScopeListsMeetingsAndStaysInBudget() {
        let many = (0..<80).map { i in
            Self.meeting("m\(i)", day: i, title: "Call \(i)",
                         turns: (0..<30).map { Self.turn(Double($0) * 10, "Them", nil, "Filler sentence \($0) about nothing much at all.") })
        } + Self.library
        let r = AskContext.request(question: "billing migration", scope: .all, meetings: many)
        #expect(r.material.count <= AskContext.budget)
        let listed = r.material.components(separatedBy: "\n").filter { $0.hasPrefix("- ") }
        #expect(listed.count == AskContext.listLimit)
        #expect(r.material.contains("The billing migration is postponed"))
        #expect(r.foundAnything)
    }

    // MARK: Citations

    @Test func citationsParseAndInventedOnesAreDropped() {
        let raw = """
            We ship on October 6. [[p1@00:25]] Matthias books it. [[d1@00:35]] \
            Made up. [[2026-01-01_000000@00:10]] Too late. [[p1@59:00]] Short form. [[@00:40]]
            """
        let parsed = AskCitations.parse(raw, limits: ["p1": 85, "d1": 200], current: "p1") { id, s in "\(id) \(Int(s))" }
        #expect(parsed.citations.map(\.meetingID) == ["p1", "d1", "p1"])
        #expect(parsed.citations.map(\.seconds) == [25, 35, 40])
        #expect(parsed.citations[0].label == "p1 25")
        #expect(!parsed.text.contains("2026-01-01"))
        #expect(!parsed.text.contains("59:00"))
        #expect(parsed.text.contains("Made up. Too late."))
        #expect(parsed.text.contains("Short form. [[p1@00:40]]"))
        #expect(!parsed.notFound)
    }

    @Test func noneMarkerAndHalfWrittenMarkers() {
        let none = AskCitations.parse("[[none]] The records don't mention a budget.", limits: [:], current: nil) { _, _ in "" }
        #expect(none.notFound)
        #expect(none.text == "The records don't mention a budget.")
        let streaming = AskCitations.parse("We ship Monday. [[p1@00:", limits: ["p1": 85], current: nil) { _, _ in "" }
        #expect(streaming.text == "We ship Monday.")
        #expect(AskCitations.seconds("1:02:05") == 3725)
        #expect(AskCitations.seconds("14:10") == 850)
    }

    @Test func answerTextRendersChipsAndCopiesLabels() {
        let c = Citation(meetingID: "p1", seconds: 25, label: "Tue 9:41")
        let text = "- **Ship** on October 6. [[p1@00:25]]\n- Drop this [[p1@00:99]]\n\nA paragraph\nthat wraps."
        let blocks = AnswerText.blocks(text)
        #expect(blocks.count == 3)
        #expect(blocks[2] == .paragraph("A paragraph that wraps."))
        let attributed = AnswerText.attributed("We ship. [[p1@00:25]]", citations: [c], currentMeetingID: nil)
        #expect(String(attributed.characters).contains("Tue\u{00A0}9:41"))
        #expect(attributed.runs.contains { $0.link?.absoluteString == "earl-cite://0" })
        #expect(AnswerText.plain("We ship. [[p1@00:25]]", citations: [c]) == "We ship. (Tue 9:41)")
    }

    // MARK: ⌘K

    @Test func questionDetection() {
        #expect(AskQuestion.isQuestion("what did Matthias say"))
        #expect(AskQuestion.isQuestion("Wann ist das Wartungsfenster"))
        #expect(AskQuestion.isQuestion("budget?"))
        #expect(AskQuestion.isQuestion("Hat Dominik geantwortet"))
        #expect(!AskQuestion.isQuestion("onboarding"))
        #expect(!AskQuestion.isQuestion("how"))
        #expect(!AskQuestion.isQuestion("whatever happened"))
        #expect(!AskQuestion.isQuestion("  "))
    }

    @Test func questionSearchFiltersByItsWords() {
        let found = AskSearch.filter(Self.library, query: "When is the billing migration?")
        #expect(found.map(\.id) == ["p1"])
        #expect(AskSearch.filter(Self.library, query: "Lizenzen").map(\.id) == ["d2"])
    }

    // MARK: History

    @Test func historyKeepsTheLastThirty() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("earl-ask-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(AskHistory.fileName)
        for i in 0..<35 {
            AskHistory.append(EarlAnswer(question: "Q\(i)", scope: .series("daily"), text: "A [[d1@00:05]]",
                                         citations: [Citation(meetingID: "d1", seconds: 5, label: "Mon 9:00")],
                                         date: Date()), to: url)
        }
        let list = AskHistory.load(url)
        #expect(list.count == AskHistory.limit)
        #expect(list.first?.question == "Q5")
        #expect(list.last?.scope == .series("daily"))
        #expect(list.last?.citations.first?.seconds == 5)
        #expect(MeetingFile(name: "questions.json", bytes: 0).description == "Questions you asked Earl")
    }
}

// MARK: - Live

/// Two questions about a synthetic transcript through LM Studio, thinking off.
struct AskEarlLiveTests {
    static let env = ProcessInfo.processInfo.environment

    @Test(.enabled(if: env["EARL_LIVE_LLM"] == "1", "Set EARL_LIVE_LLM=1 to ask LM Studio"))
    func twoQuestions() async throws {
        let app = UserDefaults(suiteName: "local.earl.app")
        var engine = AskEngine()
        engine.summarizer.model = Self.env["EARL_LIVE_LLM_MODEL"] ?? app?.string(forKey: Prefs.Key.llmModel)
            ?? Prefs.defaultLLMModel
        engine.summarizer.baseURL = Self.env["EARL_LIVE_LLM_URL"] ?? app?.string(forKey: Prefs.Key.llmURL)
            ?? Prefs.defaultLLMURL
        engine.summarizer.reasoning = false
        print("[ask] model \(engine.summarizer.model), thinking off")
        let library = AskEarlTests.library
        let questions: [(String, AskScope)] = [
            ("What did we decide about the onboarding release, and what does marketing need?", .meeting("p1")),
            ("Wann ist das Wartungsfenster und wer bucht die Freigabe?", .series("daily alpenblick")),
        ]
        for (q, scope) in questions {
            let request = AskContext.request(question: q, scope: scope, meetings: library)
            let started = Date()
            let raw = try await engine.ask(request) { _ in }
            let seconds = Date().timeIntervalSince(started)
            let parsed = AskCitations.parse(raw, limits: request.meetings, current: nil) { _, s in Meeting.timestamp(s) }
            print("[ask] Q: \(q)\n[ask] \(String(format: "%.1f", seconds)) s, \(parsed.citations.count) citations "
                  + "\(parsed.citations.map { "\($0.meetingID)@\($0.label)" })\n[ask] A: \(raw)\n")
            #expect(!parsed.text.isEmpty)
        }
    }
}
