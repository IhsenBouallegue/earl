import Foundation
import Testing
@testable import Earl

/// R2-7 evaluation: meeting notes from T-1 synthetic scripts, through the real
/// summarizer on the local LLM. The scripts hand out action items with known
/// owners ("Tom, can you write the release notes?" "Sure, I'll do that."), so
/// the notes can be scored for recall (expected action items found), owner
/// accuracy (found items with the right owner) and language.
///
///     EARL_EVAL_NOTES=1 EARL_EVAL_LLM_MODEL=google/gemma-4-e4b ./test.sh --filter NotesEvalTests
///
/// Optional: `EARL_EVAL_NOTES_PROMPTS` (default "old,new"),
/// `EARL_EVAL_NOTES_PRESETS` (default "realistic,german"),
/// `EARL_EVAL_NOTES_SEEDS` (default 1,2,3), `EARL_EVAL_NOTES_MINUTES` (default 6),
/// `EARL_EVAL_NOTES_REASONING=off` (thinking off), `EARL_EVAL_NOTES_DUMP`
/// (a folder for the transcripts and answers), `EARL_EVAL_NOTES_REUSE` (score the
/// answers saved there instead of asking again), `EARL_EVAL_LLM_URL`
/// (http://localhost:11434/v1 evaluates Ollama, with its derived model),
/// `EARL_EVAL_LLM_CONTEXT` (the context of a llama-server started by hand with
/// `-c`, so the meeting isn't split as if the server had 4k).
/// The transcripts are the script lines as spoken, so this measures the
/// notes model alone, not Whisper or the speaker separation.
@Suite(.serialized)
struct NotesEvalTests {
    static let env = ProcessInfo.processInfo.environment
    static let enabled = env["EARL_EVAL_NOTES"] != nil
    static func list(_ key: String, _ fallback: String) -> [String] {
        (env[key] ?? fallback).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// The notes prompt before R2-7, for comparison.
    static let oldSystem = """
        You are a meeting assistant. You write concise, accurate meeting notes in Markdown. \
        In transcripts, "Me" is the user and "Them" is everyone else on the call (possibly several people). \
        Labels like "Speaker 2" are distinct people whose names aren't known; refer to them by these labels. \
        Write in the same language as the transcript. Never invent facts that are not in the transcript.
        """

    static func prompt(_ name: String) -> NotesPrompt {
        name == "old" ? NotesPrompt(system: oldSystem, perspective: false, languageRule: false) : NotesPrompt()
    }

    // MARK: Cases

    enum Direction: String, CaseIterable {
        case meAsksThem = "Me asks Them", themAsksMe = "Them asks Me", themAsksThem = "Them asks Them"
    }

    struct Expected {
        var owner: Int
        /// Everyone the task was given to (usually just `owner`).
        var owners: Set<Int>
        var direction: Direction
        var task: String
        var keywords: [String]
    }

    struct Case {
        var preset: String
        var seed: UInt64
        var meeting: Meeting
        var names: [String]
        var me: Int
        var expected: [Expected]
        var language: String
    }

    /// English words for the German pool's tasks, so notes in the wrong
    /// language can still be matched (and their owners scored).
    static let translations: [String: String] = [
        "die Release Notes zu schreiben": "release notes",
        "das Wartungsfenster an die Kunden zu kommunizieren": "maintenance window customers communicate announce",
        "den Interview Leitfaden anzupassen": "interview guide guideline",
        "eine Liste der ungenutzten Lizenzen zu machen": "unused licenses list",
        "den Bericht zu entwerfen": "report draft",
        "die Schwellenwerte mit dem Infrastruktur Team durchzugehen": "thresholds infrastructure",
        "den Link zum Workshop Chat schicken": "link",
        "die Budgetzahlen schicken": "budget numbers figures",
        "die aktualisierten Folien schicken": "slides",
        "einen Besprechungsraum für das Review buchen": "meeting room book",
        "das Design Team zum Review einladen": "invite",
    ]

    static let stopwords: Set<String> = [
        "with", "them", "that", "this", "from", "their", "take", "item", "action", "eine", "einen", "der", "die",
        "das", "den", "dem", "machen", "mit", "and", "the", "for", "send", "schicken", "zum", "review", "für",
    ]

    static func keywords(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter }.map(String.init).filter { $0.count >= 4 && !stopwords.contains($0) }
    }

    /// `preset` is a T-1 preset, or "requests" / "requests-de" (see `Requests`).
    static func makeCase(preset: String, seed: UInt64, minutes: Double) -> Case {
        let names: [String]
        let lines: [SyntheticScript.Line]
        let language: String
        if let requests = Requests.script(preset) {
            (names, lines, language) = requests
        } else {
            let p = SyntheticMeeting.Preset(rawValue: preset) ?? .realistic
            let config = SyntheticMeeting.Config(p)
            names = config.remote.map(\.name) + [config.me.name]
            var h: UInt64 = seed
            for b in preset.utf8 { h = (h &* 31) &+ UInt64(b) }
            var rng = SeededRNG(seed: h)
            lines = SyntheticScript.build(pool: config.pool, names: names, seconds: minutes * 60, rng: &rng)
            language = p == .german ? "de" : "en"
        }
        let me = names.count - 1

        var turns: [Turn] = []
        var talk = [Double](repeating: 0, count: names.count)
        var t = 2.0
        for line in lines {
            let seconds = Double(line.text.split(separator: " ").count) / 3.2
            turns.append(Turn(start: t, end: t + seconds, speaker: line.speaker == me ? "Me" : "Them", text: line.text,
                              speakerID: line.speaker == me ? nil : "S\(line.speaker + 1)"))
            talk[line.speaker] += seconds
            t += seconds + 0.6
        }
        // Remote voices are separated but not named, as after R2-2 without R2-3.
        let speakers = (0..<me).map {
            Speaker(id: "S\($0 + 1)", track: "Them", name: nil, embedding: [], seconds: talk[$0])
        }
        var info = MeetingInfo(title: "Eval", titleIsDefault: true, startedAt: Date(), duration: t, status: .done)
        info.language = language
        info.attendees = names.enumerated().map { Attendee(name: $0.element, email: nil, isMe: $0.offset == me) }
        let meeting = Meeting(id: "eval", folder: FileManager.default.temporaryDirectory, info: info, turns: turns,
                              summary: "", files: [], speakers: speakers)

        // Longer meetings go round the topics again and hand out the same task
        // to someone else; notes list it once. Score each task once, and
        // accept anyone it was given to.
        var expected: [Expected] = []
        for a in lines.compactMap(\.action) {
            if let i = expected.firstIndex(where: { $0.task == a.task }) {
                expected[i].owners.insert(a.owner)
                continue
            }
            expected.append(Expected(owner: a.owner, owners: [a.owner],
                                     direction: a.asker == me ? .meAsksThem : a.owner == me ? .themAsksMe : .themAsksThem,
                                     task: a.task, keywords: keywords(a.task + " " + (translations[a.task] ?? ""))))
        }
        return Case(preset: preset, seed: seed, meeting: meeting, names: names, me: me, expected: expected, language: language)
    }

    // MARK: Scoring

    struct Item { var owner: String; var task: String }

    /// The "## Action items" bullets as (owner, task).
    static func actionItems(_ markdown: String) -> [Item] {
        var inSection = false
        var items: [Item] = []
        for raw in markdown.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") { inSection = line.lowercased().contains("action"); continue }
            guard inSection, line.hasPrefix("-") || line.hasPrefix("*") else { continue }
            var text = line.drop { "-* ".contains($0) }
            if text.hasPrefix("[ ]") || text.hasPrefix("[x]") { text = text.dropFirst(3) }
            let clean = text.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
            if let colon = clean.firstIndex(of: ":") {
                items.append(Item(owner: String(clean[..<colon]), task: String(clean[clean.index(after: colon)...])))
            } else {
                items.append(Item(owner: "", task: clean))
            }
        }
        return items
    }

    /// Everyone the owner text names: first names, "Speaker N", "Me"/"Ich".
    static func people(in owner: String, _ c: Case) -> Set<Int> {
        let words = Set(owner.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
        var found = Set<Int>()
        for (i, name) in c.names.enumerated() where words.contains(name.lowercased()) { found.insert(i) }
        if words.contains("me") || words.contains("ich") { found.insert(c.me) }
        let lower = owner.lowercased()
        for i in 0..<c.me where lower.contains("speaker \(i + 1)") || lower.contains("sprecher \(i + 1)") { found.insert(i) }
        return found
    }

    struct Score {
        var expected = 0, found = 0, rightOwner = 0, extra = 0
        var byDirection: [Direction: (found: Int, right: Int, expected: Int)] = [:]
        var languageRight = 0, runs = 0
        var seconds = 0.0, thinkingChars = 0, tokensPerSecond: [Double] = []

        mutating func add(_ o: Score) {
            expected += o.expected; found += o.found; rightOwner += o.rightOwner; extra += o.extra
            languageRight += o.languageRight; runs += o.runs; seconds += o.seconds
            thinkingChars += o.thinkingChars; tokensPerSecond += o.tokensPerSecond
            for (d, v) in o.byDirection {
                let x = byDirection[d] ?? (0, 0, 0)
                byDirection[d] = (x.found + v.found, x.right + v.right, x.expected + v.expected)
            }
        }

        var line: String {
            let dirs = Direction.allCases.compactMap { d in
                byDirection[d].map { "\(d.rawValue) \($0.right)/\($0.found) of \($0.expected)" }
            }.joined(separator: "; ")
            let speed = tokensPerSecond.isEmpty ? "–" : String(format: "%.0f", tokensPerSecond.reduce(0, +) / Double(tokensPerSecond.count))
            return "owner \(DiarizationEvalTests.pct(rightOwner, found)), recall \(DiarizationEvalTests.pct(found, expected)), "
                + "extra \(extra), language \(languageRight)/\(runs), \(String(format: "%.0f", seconds / Double(max(1, runs)))) s per run, "
                + "\(speed) tok/s, thinking \(thinkingChars / max(1, runs)) chars per run · \(dirs)"
        }
    }

    static func score(_ markdown: String, _ c: Case) -> (Score, [String]) {
        var s = Score()
        s.expected = c.expected.count
        s.runs = 1
        if detectLanguage(markdown) == c.language { s.languageRight = 1 }
        let items = actionItems(markdown)
        // Best keyword overlap first, one-to-one.
        var pairs: [(item: Int, exp: Int, score: Int)] = []
        for (i, item) in items.enumerated() {
            let text = item.task.lowercased()
            for (e, exp) in c.expected.enumerated() {
                let hits = exp.keywords.filter { text.contains($0.prefix(5)) }.count
                if hits > 0 { pairs.append((i, e, hits)) }
            }
        }
        var usedItems = Set<Int>(), usedExp = Set<Int>()
        var log: [String] = []
        for p in pairs.sorted(by: { $0.score > $1.score }) where !usedItems.contains(p.item) && !usedExp.contains(p.exp) {
            usedItems.insert(p.item); usedExp.insert(p.exp)
            let exp = c.expected[p.exp]
            let named = people(in: items[p.item].owner, c)
            let right = !named.isEmpty && named.isSubset(of: exp.owners)
            s.found += 1
            if right { s.rightOwner += 1 }
            var d = s.byDirection[exp.direction] ?? (0, 0, 0)
            d.found += 1; if right { d.right += 1 }
            s.byDirection[exp.direction] = d
            log.append("\(right ? "right" : "WRONG") \(exp.direction.rawValue): \"\(items[p.item].owner)\" for \(c.names[exp.owner]) · \(exp.task)")
        }
        for exp in c.expected {
            var d = s.byDirection[exp.direction] ?? (0, 0, 0)
            d.expected += 1
            s.byDirection[exp.direction] = d
        }
        for (e, exp) in c.expected.enumerated() where !usedExp.contains(e) {
            log.append("missed \(exp.direction.rawValue): \(c.names[exp.owner]) · \(exp.task)")
        }
        s.extra = items.count - usedItems.count
        return (s, log)
    }

    /// "de" or "en", by common words in the notes.
    static func detectLanguage(_ text: String) -> String {
        let words = text.lowercased().split { !$0.isLetter }.map(String.init)
        let de: Set<String> = ["der", "die", "das", "und", "ist", "wir", "mit", "für", "nicht", "bis", "wird", "zu", "den", "ein", "eine", "werden", "soll"]
        let en: Set<String> = ["the", "and", "is", "we", "with", "for", "not", "by", "will", "to", "of", "a", "be", "should", "was"]
        return words.filter(de.contains).count > words.filter(en.contains).count ? "de" : "en"
    }

    // MARK: Run

    @Test(.enabled(if: enabled, "Set EARL_EVAL_NOTES to evaluate the notes"))
    func notes() async throws {
        try await DiarizationEvalTests.offMain { try await Self.run() }
    }

    static func run() async throws {
        var summarizer = Summarizer()
        summarizer.baseURL = env["EARL_EVAL_LLM_URL"] ?? Prefs.defaultLLMURL
        summarizer.model = env["EARL_EVAL_LLM_MODEL"] ?? Prefs.defaultLLMModel
        if summarizer.baseURL.contains(":11434") { summarizer.backend = .ollama(model: summarizer.model) } // D-3
        if let context = env["EARL_EVAL_LLM_CONTEXT"].flatMap(Int.init) { // D-3: llama-server started by hand
            summarizer.backend = .custom(url: summarizer.baseURL)
            summarizer.fixedContext = context
        }
        summarizer.vocabulary = []
        summarizer.reasoning = env["EARL_EVAL_NOTES_REASONING"] != "off"
        let minutes = Double(env["EARL_EVAL_NOTES_MINUTES"] ?? "") ?? 6
        let seeds = list("EARL_EVAL_NOTES_SEEDS", "1,2,3").compactMap { UInt64($0) }
        let presets = list("EARL_EVAL_NOTES_PRESETS", "realistic,german,requests,requests-de")
        let tag = "\(summarizer.model) reasoning \(summarizer.reasoning ? "default" : "off")"

        var totals: [String: Score] = [:]
        for preset in presets {
            for seed in seeds {
                let c = makeCase(preset: preset, seed: seed, minutes: minutes)
                let counts = Direction.allCases.map { d in "\(c.expected.filter { $0.direction == d }.count) \(d.rawValue)" }
                print("[notes] \(preset) seed \(seed): \(c.meeting.turns.count) turns, \(c.meeting.transcriptText.count) chars, "
                      + "\(c.expected.count) action items (\(counts.joined(separator: ", ")))")
                for name in list("EARL_EVAL_NOTES_PROMPTS", "old,new") {
                    var s = summarizer
                    s.prompt = prompt(name)
                    s.prompt.language = name == "old" ? nil : NotesLanguage.resolve(setting: "auto", detected: c.meeting.info.language)
                    let dump = env["EARL_EVAL_NOTES_DUMP"]
                    let base = dump.map { "\($0)/\(summarizer.model.replacingOccurrences(of: "/", with: "_"))-\(summarizer.reasoning ? "r" : "nr")-\(preset)-\(seed)-\(name)" }
                    var score: Score, log: [String]
                    if env["EARL_EVAL_NOTES_REUSE"] != nil, let base, let saved = try? String(contentsOfFile: base + ".md", encoding: .utf8) {
                        // Re-score a saved answer, e.g. after changing the scoring.
                        (score, log) = Self.score(Summarizer.parse(Summarizer.visible(saved).text).markdown, c)
                    } else {
                        let started = Date()
                        var thinking = 0
                        let result = try await s.summarize(c.meeting.transcriptText, context: SummaryContext(c.meeting.info)) { event in
                            if case .progress(_, let chars, _, _) = event { thinking = chars }
                        }
                        (score, log) = Self.score(result.markdown, c)
                        score.seconds = Date().timeIntervalSince(started)
                        score.thinkingChars = thinking
                        if let tps = result.tokensPerSecond { score.tokensPerSecond = [tps] }
                        if let dump, let base {
                            try? c.meeting.transcriptText.write(toFile: "\(dump)/transcript-\(preset)-\(seed).txt", atomically: true, encoding: .utf8)
                            try? ("TITLE: \(result.title ?? "")\n\n" + result.markdown).write(toFile: base + ".md", atomically: true, encoding: .utf8)
                        }
                    }
                    totals["\(preset), \(name) prompt", default: Score()].add(score)
                    totals["all, \(name) prompt", default: Score()].add(score)
                    print("[notes] \(tag) · \(preset) seed \(seed) · \(name) prompt: \(score.line)")
                    for l in log { print("[notes]   \(l)") }
                }
            }
        }
        for (key, s) in totals.sorted(by: { $0.key < $1.key }) { print("[notes] TOTAL \(tag) · \(key): \(s.line)") }
    }
}

/// Hand-written requests where the words point the wrong way ("send *me*
/// the slides", "I need the numbers from you"), like the real meeting in which
/// a 4B model gave "share the chat link" to the person who asked for it.
enum Requests {
    typealias L = SyntheticScript.Line
    typealias A = SyntheticScript.ActionItem

    /// Participants are two remote people (0, 1), then you (2).
    static func script(_ preset: String) -> (names: [String], lines: [L], language: String)? {
        switch preset {
        case "requests":
            return (["Sarah", "Tom", "Alex"], [
                L(speaker: 2, text: "Okay, let's get started. I only have the three open points from last week."),
                L(speaker: 0, text: "Sounds good. The customer workshop went well, by the way. They liked the new dashboard."),
                L(speaker: 2, text: "Great to hear. Sarah, could you share the link to the workshop chat with me after the call?",
                  action: A(asker: 2, owner: 0, task: "share the link to the workshop chat")),
                L(speaker: 0, text: "Sure, I'll send it to you right after this."),
                L(speaker: 1, text: "On the budget side, we are still waiting for the final numbers from finance."),
                L(speaker: 2, text: "Tom, I need those budget numbers from you for my report on Friday.",
                  action: A(asker: 2, owner: 1, task: "send the budget numbers")),
                L(speaker: 1, text: "Okay, I'll put them together and email them to you by Thursday."),
                L(speaker: 0, text: "Alex, can you send me the updated slides before the steering meeting?",
                  action: A(asker: 0, owner: 2, task: "send the updated slides")),
                L(speaker: 2, text: "Yes, I'll send them tomorrow morning."),
                L(speaker: 1, text: "Could you book a meeting room for the review next week, Alex? My calendar is a mess.",
                  action: A(asker: 1, owner: 2, task: "book a meeting room for the review")),
                L(speaker: 2, text: "Sure, I'll book it today."),
                L(speaker: 2, text: "And can someone invite the design team to that review?",
                  action: A(asker: 2, owner: 0, task: "invite the design team to the review")),
                L(speaker: 0, text: "I'll do it, I have their list anyway."),
                L(speaker: 1, text: "Great. That's all from me. Thanks everyone."),
                L(speaker: 2, text: "Thanks, bye."),
            ], "en")
        case "requests-de":
            return (["Katrin", "Markus", "Jan"], [
                L(speaker: 2, text: "Okay, lasst uns anfangen. Ich habe nur die drei offenen Punkte von letzter Woche."),
                L(speaker: 0, text: "Passt. Der Kundenworkshop lief übrigens gut, das neue Dashboard kam super an."),
                L(speaker: 2, text: "Schön zu hören. Katrin, kannst du mir nach dem Call den Link zum Workshop Chat schicken?",
                  action: A(asker: 2, owner: 0, task: "den Link zum Workshop Chat schicken")),
                L(speaker: 0, text: "Klar, schicke ich dir direkt danach."),
                L(speaker: 1, text: "Beim Budget warten wir noch auf die finalen Zahlen von der Finanzabteilung."),
                L(speaker: 2, text: "Markus, ich brauche die Budgetzahlen von dir für meinen Bericht am Freitag.",
                  action: A(asker: 2, owner: 1, task: "die Budgetzahlen schicken")),
                L(speaker: 1, text: "Okay, ich stelle sie zusammen und schicke sie dir bis Donnerstag."),
                L(speaker: 0, text: "Jan, schickst du mir bitte die aktualisierten Folien vor dem Steering Meeting?",
                  action: A(asker: 0, owner: 2, task: "die aktualisierten Folien schicken")),
                L(speaker: 2, text: "Ja, mache ich morgen früh."),
                L(speaker: 1, text: "Kannst du einen Besprechungsraum für das Review nächste Woche buchen, Jan? Mein Kalender ist voll.",
                  action: A(asker: 1, owner: 2, task: "einen Besprechungsraum für das Review buchen")),
                L(speaker: 2, text: "Klar, buche ich heute noch."),
                L(speaker: 2, text: "Und kann jemand das Design Team zum Review einladen?",
                  action: A(asker: 2, owner: 0, task: "das Design Team zum Review einladen")),
                L(speaker: 0, text: "Mache ich, ich habe die Liste sowieso."),
                L(speaker: 1, text: "Super. Das war's von mir. Danke euch."),
                L(speaker: 2, text: "Danke, tschüss."),
            ], "de")
        default:
            return nil
        }
    }
}

/// Offline checks of the scoring itself.
struct NotesScoringTests {
    @Test func scriptsHandOutActionItemsBothWays() {
        var directions = Set<NotesEvalTests.Direction>()
        for preset in ["realistic", "german"] {
            for seed: UInt64 in [1, 2, 3] {
                let c = NotesEvalTests.makeCase(preset: preset, seed: seed, minutes: 6)
                #expect(c.expected.count >= 3)
                for e in c.expected { directions.insert(e.direction) }
            }
        }
        #expect(directions.contains(.meAsksThem))
        #expect(directions.contains(.themAsksMe))
    }

    @Test func scoresOwnersAndRecall() {
        let c = NotesEvalTests.makeCase(preset: "german", seed: 1, minutes: 6)
        let first = c.expected[0]
        let right = c.names[first.owner]
        let wrong = c.names[(first.owner + 1) % c.names.count]
        let notes = """
            ## Summary
            - Wir haben über vieles gesprochen und die Entscheidung ist klar.

            ## Action items
            - [ ] \(right): \(first.task)
            - [ ] **\(wrong)**: something nobody asked for
            """
        let (s, _) = NotesEvalTests.score(notes, c)
        #expect(s.found == 1)
        #expect(s.rightOwner == 1)
        #expect(s.extra == 1)
        #expect(s.languageRight == 1)

        let swapped = notes.replacingOccurrences(of: "- [ ] \(right):", with: "- [ ] \(wrong):")
        #expect(NotesEvalTests.score(swapped, c).0.rightOwner == 0)
        #expect(NotesEvalTests.people(in: "Ich (Jan)", c) == [c.me])
        #expect(NotesEvalTests.people(in: "Speaker 2", c) == [1])
    }
}
