import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Earl

struct TodosTests {
    static let summary = """
        ## Summary
        - The team reviewed the launch plan.
        - [ ] Not an action item section, but still a checkbox

        ## Decisions
        - Ship on Friday: agreed by everyone

        ## Action items
        - [ ] Sarah: Send the updated deck to the client
        - [x] Me: Book the room for Thursday
        - [ ] Update the changelog
          - [ ] Speaker 2: Check the numbers: revenue and churn
        * [X] [Tom]: Draft the press release
        - [ ] **Ahsan Lefèvre**: Review the contract
        - [ ] Before Friday, the team should check the following items: logs and alerts

        ## Open questions
        - Who owns the budget?
        """

    var items: [ActionItem] { ActionItems.parse(Self.summary, meetingID: "m1") }

    // MARK: Parser

    @Test func findsEveryCheckboxLine() {
        #expect(items.count == 8)
        #expect(items.map(\.line) == [2, 8, 9, 10, 11, 12, 13, 14])
        #expect(items.allSatisfy { $0.meetingID == "m1" })
    }

    @Test func ownerOrNoOwner() {
        #expect(items[1].owner == "Sarah")
        #expect(items[1].text == "Send the updated deck to the client")
        #expect(items[3].owner == nil)
        #expect(items[3].text == "Update the changelog")
        // Splits on the first ": " only.
        #expect(items[4].owner == "Speaker 2")
        #expect(items[4].text == "Check the numbers: revenue and churn")
        #expect(items[5].owner == "Tom")
        #expect(items[6].owner == "Ahsan Lefèvre")
        // A long lead-in isn't a name.
        #expect(items[7].owner == nil)
        #expect(items[7].text.hasPrefix("Before Friday"))
    }

    @Test func doneMarks() {
        #expect(items.map(\.done) == [false, false, true, false, false, true, false, false])
    }

    @Test func ignoresPlainBulletsAndLinks() {
        let text = "- plain\n- [link](x): y\n-[ ] no space\n- [?] odd\n1. [ ] Me: numbered"
        let parsed = ActionItems.parse(text, meetingID: "m")
        #expect(parsed.count == 1)
        #expect(parsed.first?.owner == "Me")
    }

    @Test func keyIsStableAndIgnoresOwnerAndPunctuation() {
        let a = ActionItems.key(meetingID: "m1", text: "Send the deck.")
        #expect(a == ActionItems.key(meetingID: "m1", text: "send the  DECK"))
        #expect(a != ActionItems.key(meetingID: "m2", text: "Send the deck."))
        #expect(a.count == 16)
        let renamed = ActionItems.parse("- [ ] Sarah: Send the deck.", meetingID: "m1")[0]
        #expect(renamed.key == a)
    }

    // MARK: Toggling

    @Test func togglesExactlyThatLine() throws {
        let item = items[1]
        let out = try #require(ActionItems.setting(item, done: true, in: Self.summary))
        let before = Self.summary.components(separatedBy: "\n")
        let after = out.components(separatedBy: "\n")
        #expect(after[8] == "- [x] Sarah: Send the updated deck to the client")
        #expect(zip(before, after).enumerated().filter { $0.element.0 != $0.element.1 }.map(\.offset) == [8])
        // And back, keeping indentation and bullet style.
        let indented = items[4]
        let ticked = try #require(ActionItems.setting(indented, done: true, in: Self.summary))
        #expect(ticked.components(separatedBy: "\n")[11] == "  - [x] Speaker 2: Check the numbers: revenue and churn")
        let tom = items[5]
        let unticked = try #require(ActionItems.setting(tom, done: false, in: Self.summary))
        #expect(unticked.components(separatedBy: "\n")[12] == "* [ ] [Tom]: Draft the press release")
    }

    @Test func findsTheItemAgainWhenLinesMoved() throws {
        let item = items[1] // line 8
        let shifted = "# New heading\n\n" + Self.summary
        let out = try #require(ActionItems.setting(item, done: true, in: shifted))
        #expect(out.components(separatedBy: "\n")[10] == "- [x] Sarah: Send the updated deck to the client")
        #expect(out.components(separatedBy: "\n")[8] == Self.summary.components(separatedBy: "\n")[6])
        // Gone entirely: nothing to do.
        #expect(ActionItems.setting(item, done: true, in: "## Action items\n- [ ] Tom: Other") == nil)
    }

    // MARK: Mine

    @Test func mineMatching() {
        #expect(ActionItems.isMine(owner: "Me", userName: nil))
        #expect(ActionItems.isMine(owner: "me", userName: "Ahsan"))
        #expect(ActionItems.isMine(owner: "Ich", userName: nil))
        #expect(ActionItems.isMine(owner: "Ahsan (Me)", userName: nil))
        #expect(ActionItems.isMine(owner: "Ahsan Lefèvre", userName: "Ahsan Lefevre"))
        #expect(ActionItems.isMine(owner: "ahsan", userName: "Ahsan Lefèvre"))
        #expect(ActionItems.isMine(owner: "Zoë", userName: "zoe Martin"))
        #expect(!ActionItems.isMine(owner: "Sarah", userName: "Ahsan"))
        #expect(!ActionItems.isMine(owner: "Ahsan", userName: nil))
        #expect(!ActionItems.isMine(owner: nil, userName: "Ahsan"))
        #expect(!ActionItems.isMine(owner: "Speaker 2", userName: "Ahsan"))
        #expect(!ActionItems.isMine(owner: "Lefevre", userName: "Ahsan Lefevre"))
    }

    // MARK: Carry-over

    @Test func carryOverTicksCloseMatches() {
        let records: [ActionItems.DoneRecord] = [
            .init(key: "x", text: "Book the room for Thursday"),
            .init(key: "y", text: "Send the updated deck to the client"),
            .init(key: "z", text: "Something that is no longer there at all"),
        ]
        let new = """
            ## Action items
            - [ ] Me: Book the room for Thursday.
            - [ ] Sarah: Send the updated slide deck to the client
            - [ ] Tom: Call the lawyer
            - [x] Tom: Already done
            """
        let out = ActionItems.carryOver(records, into: new, meetingID: "m1").components(separatedBy: "\n")
        #expect(out[1] == "- [x] Me: Book the room for Thursday.")
        #expect(out[2] == "- [x] Sarah: Send the updated slide deck to the client")
        #expect(out[3] == "- [ ] Tom: Call the lawyer")
        #expect(out[4] == "- [x] Tom: Already done")
    }

    @Test func carryOverUsesEachRecordOnce() {
        let records: [ActionItems.DoneRecord] = [.init(key: "x", text: "Send the invoice")]
        let new = "- [ ] Sarah: Send the invoice\n- [ ] Tom: Send the invoice"
        let out = ActionItems.carryOver(records, into: new, meetingID: "m1")
        #expect(out == "- [x] Sarah: Send the invoice\n- [ ] Tom: Send the invoice")
    }

    @Test func similarity() {
        #expect(ActionItems.similarity("Send the deck", "send the deck!") == 1)
        #expect(ActionItems.similarity("Präsentation an Kunden schicken", "Praesentation an Kunden schicken") >= 0.8)
        #expect(ActionItems.similarity("Send the deck", "Call the lawyer") < 0.8)
    }

    @Test func keepingTicksAcrossSummarizeAgain() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("earl-todos-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // Ticked in Earl (recorded) and ticked by hand in summary.md (not recorded).
        try "- [x] Me: Book the room\n- [x] Tom: Draft the release\n- [ ] Sarah: Send the deck"
            .write(to: folder.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
        let old = ActionItems.parse(try String(contentsOf: folder.appendingPathComponent("summary.md"), encoding: .utf8),
                                    meetingID: folder.lastPathComponent)
        TodoFiles.record(old[0], done: true, in: folder)
        let new = "## Action items\n- [ ] Ahsan: Book the room\n- [ ] Tom: Draft the press release\n- [ ] Sarah: Send the deck"
        let out = TodoFiles.keepingTicks(new, in: folder)
        #expect(out == "## Action items\n- [x] Ahsan: Book the room\n- [x] Tom: Draft the press release\n- [ ] Sarah: Send the deck")
        #expect(TodoFiles.loadDone(in: folder).count == 2)
        // Unticking forgets it, so it isn't brought back.
        TodoFiles.record(old[1], done: false, in: folder)
        #expect(TodoFiles.loadDone(in: folder).map(\.text) == ["Book the room"])
    }

    // MARK: Links and Reminders text

    @Test func earlLinks() {
        let url = EarlLink.url(meetingID: "2026-09-24_100000")
        #expect(url.absoluteString == "earl://meeting/2026-09-24_100000")
        #expect(EarlLink.meetingID(from: url) == "2026-09-24_100000")
        #expect(EarlLink.meetingID(from: URL(string: "earl://meeting/")!) == nil)
        #expect(EarlLink.meetingID(from: URL(string: "earl://meeting/../x")!) == nil)
        #expect(EarlLink.meetingID(from: URL(string: "https://meeting/abc")!) == nil)
    }

    @Test func reminderTitles() {
        let mine = ActionItems.parse("- [ ] Me: Book the room", meetingID: "m")[0]
        let theirs = ActionItems.parse("- [ ] Sarah: Send the deck", meetingID: "m")[0]
        #expect(RemindersSync.title(for: mine, userName: nil) == "Book the room")
        #expect(RemindersSync.title(for: theirs, userName: nil) == "Sarah: Send the deck")
    }
}

/// Renders the To-dos page to PNGs for reviewing the look. Only runs with
/// EARL_TODOS_PNG set to an output folder:
///
///     EARL_TODOS_PNG=/tmp/earl-todos ./test.sh --filter TodosRenderTests
@MainActor
struct TodosRenderTests {
    nonisolated static let out = ProcessInfo.processInfo.environment["EARL_TODOS_PNG"]

    static func meeting(_ id: String, _ title: String, hoursAgo: Double, summary: String) -> Meeting {
        let info = MeetingInfo(title: title, titleIsDefault: false, startedAt: Date().addingTimeInterval(-hoursAgo * 3600),
                               duration: 1800, status: .done, error: nil)
        return Meeting(id: id, folder: URL(fileURLWithPath: "/tmp/\(id)"), info: info, turns: [],
                       summary: summary, files: [])
    }

    static let meetings = [
        meeting("a", "Launch plan sync", hoursAgo: 2, summary: """
            ## Action items
            - [ ] Me: Book the room for Thursday's demo
            - [ ] Sarah: Send the updated deck to the client
            - [x] Ahsan: Share the recording with the design team
            - [ ] Speaker 2: Check the churn numbers before Friday
            """),
        meeting("b", "Kundentermin Müller GmbH", hoursAgo: 26, summary: """
            ## Action items
            - [ ] Ahsan: Angebot bis Montag überarbeiten
            - [ ] Herr Müller: Vertragsentwurf an die Rechtsabteilung geben
            - [x] Tom: Protokoll verschicken
            """),
    ]

    private func page(showDone: Bool, _ scheme: ColorScheme, meetings: [Meeting]? = nil,
                      userName: String? = "Ahsan") -> some View {
        let meetings = meetings ?? Self.meetings
        let items = meetings.flatMap { ActionItems.parse($0.summary, meetingID: $0.id) }
        let sent = Set(items.dropFirst().prefix(1).map(\.key))
        return TodoList(items: items, meetings: meetings, userName: userName, sent: sent, showDone: showDone)
            .frame(width: 820, height: 620)
            .background(scheme == .dark ? Color(white: 0.12) : Color.white)
            .environment(\.colorScheme, scheme)
    }

    /// NSHostingView draws the AppKit-backed controls (the segmented picker)
    /// that ImageRenderer leaves out.
    private func save(_ view: some View, scheme: ColorScheme, to url: URL) throws {
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        host.frame = NSRect(x: 0, y: 0, width: 820, height: 620)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = host.appearance
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try #require(rep.representation(using: .png, properties: [:])).write(to: url)
    }

    @Test(.enabled(if: out != nil, "Set EARL_TODOS_PNG to render the To-dos page"))
    func renderPages() throws {
        let dir = URL(fileURLWithPath: Self.out!)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for scheme in [ColorScheme.light, .dark] {
            let name = scheme == .dark ? "dark" : "light"
            for showDone in [false, true] {
                try save(page(showDone: showDone, scheme), scheme: scheme,
                         to: dir.appendingPathComponent("todos-\(showDone ? "done-open" : "open")-\(name).png"))
            }
            try save(page(showDone: false, scheme, meetings: [], userName: nil), scheme: scheme,
                     to: dir.appendingPathComponent("todos-empty-\(name).png"))
        }
        print("[todos] wrote PNGs to \(dir.path)")
    }
}
