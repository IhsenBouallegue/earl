import Foundation
import Testing
@testable import Earl

/// K-1: notes that fit the meeting.
struct NotesKindTests {
    static let base = Date(timeIntervalSince1970: 1_790_000_000)

    /// `words`: per voice, "Me" or "S1"…, how many words it said.
    static func meeting(_ id: String = "m", title: String = "Weekly", minutes: Double = 40, attendees: Int = 6,
                        words: [String: Int], separated: Bool = true, day: Double = 0,
                        kind: MeetingKind? = nil, byUser: Bool? = nil) -> Meeting {
        var info = MeetingInfo(title: title, titleIsDefault: false, startedAt: base.addingTimeInterval(day * 86_400),
                               duration: minutes * 60, status: .done, calendarEventID: "E", calendarTitle: title)
        info.attendees = (0..<attendees).map { Attendee(name: "Person \($0)", email: "p\($0)@example.com", isMe: false) }
        info.speakerModel = separated ? "test" : nil
        info.notesKind = kind?.rawValue
        info.notesKindByUser = byUser
        var t = 0.0
        let turns = words.sorted { $0.key < $1.key }.map { voice, n in
            defer { t += 10 }
            return Turn(start: t, end: t + 9, speaker: voice == "Me" ? "Me" : "Them",
                        text: Array(repeating: "word", count: n).joined(separator: " "),
                        speakerID: voice == "Me" ? nil : voice)
        }
        return Meeting(id: id, folder: URL(fileURLWithPath: "/tmp/\(id)"), info: info, turns: turns,
                       summary: "## Summary\n- x", files: [])
    }

    // MARK: Deciding

    @Test func titleWordsDecide() {
        func kind(_ title: String) -> MeetingKind? {
            MeetingKind.decide(title: title, minutes: 45, seriesDates: [], voices: 5, attendees: 8)
        }
        #expect(kind("Q3 Town Hall") == .townHall)
        #expect(kind("All-Hands October") == .townHall)
        #expect(kind("Betriebsversammlung") == .townHall)
        #expect(kind("Product demo: exports") == .talk)
        #expect(kind("Webinar: modern testing") == .talk)
        #expect(kind("Schulung Datenschutz") == .talk)
        // Whole words only.
        #expect(kind("Demokratie-AG") == .general)
        #expect(kind("Gamma planning") == .general)
        // A demo you mostly gave yourself is a working meeting.
        let mine = MeetingKind.Talk(mine: 0.6, top: 0.3, words: 3000)
        #expect(MeetingKind.decide(title: "Demo for the client", minutes: 45, seriesDates: [], voices: 3, attendees: 4,
                                   talk: mine) == .general)
        // A short daily is a stand-up whatever else it says.
        #expect(kind("Daily demo") == .talk) // 45 minutes: no stand-up
        #expect(MeetingKind.decide(title: "Daily demo", minutes: 15, seriesDates: [], voices: 5, attendees: 8) == .standup)
    }

    @Test func listeningDecides() {
        // One voice holds the floor while you're silent: a talk.
        let webinar = Self.meeting(attendees: 90, words: ["S1": 4000, "S2": 2500, "S3": 200])
        #expect(MeetingKind.decide(webinar, in: [webinar]) == .talk)
        // Many invited, several voices, you silent: a town hall.
        let allHands = Self.meeting(attendees: 60, words: ["S1": 1500, "S2": 1400, "S3": 1300, "S4": 1200])
        #expect(MeetingKind.decide(allHands, in: [allHands]) == .townHall)
        // Few invited, several voices, you silent: only the model can tell.
        let unsure = Self.meeting(attendees: 2, words: ["S1": 1500, "S2": 1400, "S3": 1300, "Me": 50])
        #expect(MeetingKind.decide(unsure, in: [unsure]) == nil)
        #expect(MeetingKind.of(unsure, in: [unsure]) == .general)
        // You took part: a working meeting.
        let working = Self.meeting(attendees: 6, words: ["S1": 1500, "S2": 1400, "Me": 900])
        #expect(MeetingKind.decide(working, in: [working]) == .general)
        // One voice reporting to a small group is a working meeting.
        let update = Self.meeting(minutes: 15, attendees: 7, words: ["S1": 900, "S2": 500, "S3": 100])
        #expect(MeetingKind.decide(update, in: [update]) == nil)
        let update2 = Self.meeting(minutes: 15, attendees: 7, words: ["S1": 900, "S2": 500])
        #expect(MeetingKind.decide(update2, in: [update2]) == .oneOnOne || MeetingKind.decide(update2, in: [update2]) == .general)
        // Short meetings aren't judged on talk shares.
        let short = Self.meeting(minutes: 6, attendees: 90, words: ["S1": 900, "S2": 100, "S3": 100])
        #expect(MeetingKind.decide(short, in: [short]) == .general)
        // Unseparated call audio is one "voice": no talk from it alone.
        let joined = Self.meeting(attendees: 6, words: ["Them": 5000], separated: false)
        #expect(MeetingKind.decide(joined, in: [joined]) == .general)
    }

    @Test func talkShares() {
        let m = Self.meeting(words: ["S1": 600, "S2": 300, "Me": 100])
        let talk = MeetingKind.talk(in: m)
        #expect(abs(talk.mine - 0.1) < 0.001)
        #expect(abs((talk.top ?? 0) - 0.6) < 0.001)
        #expect(talk.words == 1000)
        #expect(MeetingKind.talk(in: Self.meeting(words: ["Them": 10], separated: false)).top == nil)
    }

    // MARK: Your choice, and the series

    @Test func yourChoiceWinsAndTheSeriesFollows() async {
        let webinar = ["S1": 4000, "S2": 300]
        let earlier = Self.meeting("a", title: "Freitagsrunde", attendees: 2, words: webinar, day: -7,
                                   kind: .townHall, byUser: true)
        let today = Self.meeting("b", title: "Freitagsrunde", attendees: 2, words: webinar, day: 0)
        #expect(MeetingKind.of(today, in: [earlier, today]) == .townHall)
        let resolved = await MeetingKind.resolve(today, in: [earlier, today]) { Issue.record("asked"); return nil }
        #expect(resolved.kind == .townHall && resolved.reason == "your choice for the series")

        // Your choice on this meeting wins over the series'.
        let mine = Self.meeting("c", title: "Freitagsrunde", attendees: 2, words: webinar, day: 1,
                                kind: .general, byUser: true)
        #expect(MeetingKind.of(mine, in: [earlier, today, mine]) == .general)
        // A kind the model chose isn't a choice the series follows.
        let guessed = Self.meeting("d", title: "Freitagsrunde", attendees: 2, words: webinar, day: -14,
                                   kind: .general, byUser: nil)
        #expect(MeetingKind.chosen(for: today, in: [guessed, today]) == nil)
    }

    @Test func modelAskedOnlyWhenUnsureAndOnce() async {
        let unsure = Self.meeting(attendees: 2, words: ["S1": 1500, "S2": 1400, "S3": 1300])
        var asked = 0
        let first = await MeetingKind.resolve(unsure, in: [unsure]) { asked += 1; return .townHall }
        #expect(first.kind == .townHall && first.reason == "the model" && asked == 1)
        var stored = unsure
        stored.info.notesKind = MeetingKind.townHall.rawValue
        let again = await MeetingKind.resolve(stored, in: [stored]) { asked += 1; return .talk }
        #expect(again.kind == .townHall && asked == 1)
        let failed = await MeetingKind.resolve(unsure, in: [unsure]) { nil }
        #expect(failed.kind == .general)
        let clear = Self.meeting(attendees: 6, words: ["S1": 1000, "Me": 900])
        _ = await MeetingKind.resolve(clear, in: [clear]) { asked += 1; return .talk }
        #expect(asked == 1)
    }

    @Test func theSeriesKeepsTheModelsKind() async {
        let words = ["S1": 1500, "S2": 1400, "S3": 1300]
        let earlier = Self.meeting("a", title: "Friday round", attendees: 2, words: words, day: -7, kind: .townHall)
        let today = Self.meeting("b", title: "Friday round", attendees: 2, words: words, day: 0)
        let r = await MeetingKind.resolve(today, in: [earlier, today]) { Issue.record("asked"); return .talk }
        #expect(r.kind == .townHall && r.reason == "the series, earlier")
    }

    @Test func guessParsing() {
        #expect(KindGuess.parse("TOWNHALL") == .townHall)
        #expect(KindGuess.parse("Town hall.") == .townHall)
        #expect(KindGuess.parse("talk") == .talk)
        #expect(KindGuess.parse("**WORKING**") == .general)
        #expect(KindGuess.parse("WORKING or TALK") == nil)
        #expect(KindGuess.parse("I am not sure") == nil)
        let p = KindGuess.prompt(transcript: String(repeating: "a", count: 20_000), title: "Freitagsrunde", userName: "Alex")
        #expect(p.contains("Alex ('Me') barely spoke") && p.count < 13_000)
        // Start, middle and end.
        let long = String(repeating: "a", count: 10_000) + String(repeating: "b", count: 10_000) + String(repeating: "c", count: 10_000)
        let excerpt = KindGuess.excerpt(long)
        #expect(excerpt.contains("a") && excerpt.contains("b") && excerpt.contains("c") && excerpt.count < 12_100)
        let m = Self.meeting(attendees: 40, words: ["S1": 600, "S2": 300, "S3": 100])
        #expect(KindGuess.facts(m) == "3 voices were heard, the one who spoke most said 60 % of the words, 40 people were invited.")
    }

    // MARK: The notes

    @Test func promptShapePerKind() {
        var p = NotesPrompt()
        p.userName = "Alex"
        p.kind = .townHall
        let townHall = p.final(intro: "", material: "m")
        #expect(townHall.contains("## Announcements") && townHall.contains("## For you") && townHall.contains("## Questions asked"))
        #expect(townHall.contains("- [ ] Alex: "))
        #expect(!townHall.contains("## Decisions") && !townHall.contains("## Action items"))
        #expect(p.part(1, of: 2, intro: "", chunk: "x").contains("announcements"))

        p.kind = .talk
        let talk = p.final(intro: "", material: "m")
        #expect(talk.contains("## Key points") && talk.contains("presenters' own to-dos") && talk.contains(NotesPrompt.listeningRule))
        #expect(!talk.contains("## Decisions"))
        #expect(NotesCheck.isValid("## Summary\n- About testing\n\n## Key points\n- Safety nets first"))

        p.kind = .general
        let working = p.final(intro: "", material: "m")
        #expect(working.contains("## Decisions") && working.contains("is not a decision"))
    }

    @Test func invitationsAreNotTodos() {
        let md = """
            ## Summary
            - A demo

            ## For you
            - [ ] Alex: Reach out to the team if you have questions
            - [ ] Alex: Bei Bedarf an Dominik wenden

            ## Questions asked
            - Open source? → No
            """
        let tidy = NotesTidy.withoutInvitations(md)
        #expect(!tidy.contains("For you") && !tidy.contains("Reach out") && tidy.contains("## Questions asked"))
        let kept = NotesTidy.withoutInvitations("## For you\n- [ ] Alex: Vote by the 18th\n- [ ] Alex: Feel free to ask")
        #expect(kept == "## For you\n- [ ] Alex: Vote by the 18th")
        // Only under "For you".
        let other = "## Action items\n- [ ] Pat: Reach out to legal"
        #expect(NotesTidy.withoutInvitations(other) == other)
    }

    @Test func listeningSectionsParse() {
        let notes = FrontPageNotes.parse("""
            ## Summary
            - The quarter
            ## Announcements
            - New office opens in March
            ## For you
            - [ ] Alex: Vote in the election by Oct 18
            ## Questions asked
            - Remote days? → Unchanged
            ## Key points
            - Tests before refactoring
            """, meetingID: "m")
        #expect(notes.points == ["New office opens in March", "Tests before refactoring"])
        #expect(notes.answered == ["Remote days? → Unchanged"])
        #expect(notes.todos.map(\.text) == ["Vote in the election by Oct 18"])
        #expect(notes.open.isEmpty && notes.decisions.isEmpty)
        #expect(FrontPageNotes.kind(of: "Fragen und Antworten") == .answered)
        #expect(FrontPageNotes.kind(of: "Open questions") == .open)
        #expect(NotesColumns.overflows(FrontPageNotes(points: ["a", "b", "c"]), userName: nil))
    }

    @Test func seriesContextForListeningKinds() {
        var last = Self.meeting("a", title: "Freitagsrunde", words: ["S1": 100], day: -7)
        last.summary = """
            ## Summary
            - News
            ## Decisions
            - Old style decision
            ## Action items
            - [ ] Alex: Vote
            - [ ] Pat: Finish the slides
            """
        let today = Self.meeting("b", title: "Freitagsrunde", words: ["S1": 100], day: 0)
        let working = SeriesContext.text(for: today, in: [last, today], userName: "Alex") ?? ""
        #expect(working.contains("Old style decision") && working.contains("Finish the slides"))
        let listening = SeriesContext.text(for: today, in: [last, today], userName: "Alex", listening: true) ?? ""
        #expect(!listening.contains("Old style decision") && !listening.contains("Finish the slides"))
        #expect(listening.contains("Vote"))
    }

    @Test func briefSkipsSpeakersTodosAfterATalk() {
        var last = Self.meeting("a", title: "Guild", words: ["S1": 100], day: -1, kind: .talk)
        last.summary = "## Summary\n- x\n## For you\n- [ ] Alex: Read the paper\n- [ ] Pat: Fix slide 3"
        let brief = Brief.make(event: nil, series: [last], userName: "Alex", now: Self.base)
        #expect(brief.yours.map(\.text) == ["Read the paper"])
        #expect(brief.others.isEmpty)
        last.info.notesKind = MeetingKind.general.rawValue
        #expect(Brief.make(event: nil, series: [last], userName: "Alex", now: Self.base).others.count == 1)
    }

    @Test func whosWhoAtATownHall() {
        var m = Self.meeting(attendees: 40, words: ["S1": 3000, "S2": 50])
        m.speakers = [Speaker(id: "S1", track: "Them", name: nil, nameSource: nil, embedding: [], seconds: 900),
                      Speaker(id: "S2", track: "Them", name: nil, nameSource: nil, embedding: [], seconds: 90)]
        #expect(WhosWho.asks(for: m).map(\.speakerID) == ["S1", "S2"])
        m.info.notesKind = MeetingKind.townHall.rawValue
        #expect(WhosWho.asks(for: m).map(\.speakerID) == ["S1"])
        // Forty invited and nobody named near the voice: no blind chips.
        #expect(WhosWho.suggestions(for: "S1", in: m, earlier: [], userName: nil).isEmpty)
        let small = Self.meeting(attendees: 5, words: ["S1": 3000])
        #expect(WhosWho.suggestions(for: "S1", in: small, earlier: [], userName: nil).count == 4)
    }

    @Test func pageWords() {
        let en = PageWords(language: "en"), de = PageWords(language: "de")
        #expect(en.points(.townHall) == "Announced" && en.points(.talk) == "Worth remembering")
        #expect(de.forYou == "Für dich")
        #expect(MeetingKind.allCases.count == 5 && MeetingKind.townHall.isListening && !MeetingKind.general.isListening)
    }
}
