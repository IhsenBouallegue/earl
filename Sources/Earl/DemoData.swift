import Foundation

// U-0: made-up meetings for the UI snapshots. Written as normal meeting
// folders, so the real loading code reads them. Every name and company here
// is invented.

struct DemoData {
    let store: MeetingStore
    let now: Date

    /// IDs of the meetings the screens select.
    struct IDs {
        var productSync = ""
        var failed = ""
        var standup = "" // S-1
        var townHall = "" // K-1
    }

    static let me = Attendee(name: "Alex Morgan", email: "alex@example.com", isMe: true)

    /// Today at `hour:minute`, or earlier today when that's still to come.
    private func today(_ hour: Int, _ minute: Int, before offset: TimeInterval) -> Date {
        let cal = Calendar.current
        let wanted = cal.date(bySettingHour: hour, minute: minute, second: 0, of: now) ?? now
        let latest = now.addingTimeInterval(-offset)
        return wanted < latest ? wanted : cal.date(bySetting: .second, value: 0, of: latest) ?? latest
    }

    private func daysAgo(_ days: Int, _ hour: Int, _ minute: Int) -> Date {
        let cal = Calendar.current
        let day = cal.date(byAdding: .day, value: -days, to: now) ?? now
        return cal.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
    }

    // MARK: - The library

    /// The meetings every screen shows, over several days.
    func writeLibrary() throws -> IDs {
        var ids = IDs()
        ids.productSync = try productSync()
        ids.standup = try standup()
        try earlierStandups() // S-1
        try hiringCall()
        ids.failed = try failedMeeting()
        let customer = try customerCall()
        try oneOnOne()
        try roadmapReview()
        try seriesMeetings() // S-2
        try askHistory(productSync: ids.productSync, customer: customer) // S-3
        ids.townHall = try townHall() // K-1
        return ids
    }

    // MARK: - Series (S-2)

    /// The series key of the demo's next event (the brief) and of the
    /// product sync (the series page and the masthead link).
    static let pricingSeries = "pricing workshop"
    static let productSyncSeries = "product sync"

    /// Earlier "Pricing workshop" meetings, so the next event has a brief, and
    /// earlier product syncs, so today's is 4 of 4.
    private func seriesMeetings() throws {
        let pricing = [Self.me,
                       Attendee(name: "Priya Raman", email: "priya@example.com", isMe: false),
                       Attendee(name: "Jordan Lee", email: "jordan@example.com", isMe: false),
                       Attendee(name: "Sam Okafor", email: "sam@example.com", isMe: false)]
        let voices = [
            Speaker(id: "S1", track: "Them", name: "Priya Raman", nameSource: .confirmed, embedding: [], seconds: 340,
                    avatar: AvatarLook.Accessory.glasses.rawValue),
            Speaker(id: "S2", track: "Them", name: "Jordan Lee", nameSource: .confirmed, embedding: [], seconds: 210),
            Speaker(id: "S3", track: "Them", name: "Sam Okafor", nameSource: .confirmed, embedding: [], seconds: 120),
        ]
        let talk = [turn(4, 20, "Them", "S1", "Let's pick up where we left off on the Team plan."),
                    turn(21, 40, "Them", "S2", "I have the churn numbers for the smaller plans."),
                    turn(41, 52, "Them", "S3", "And I looked at what the others charge per seat."),
                    turn(53, 60, "Me", nil, "Good, let's go through them.")]
        _ = try write(title: "Pricing workshop", start: daysAgo(16, 10, 0), minutes: 52, language: "en", turns: talk,
                      speakers: voices, summary: """
                        ## Summary
                        - First workshop on pricing for the new Team plan.

                        ## Action items
                        - [x] Jordan: Export the current plan mix
                        - [x] Me: Collect the pricing pages of five competitors
                        """, attendees: pricing, callApp: ("Zoom", "us.zoom.xos"), summarySeconds: 40, keepAudio: false,
                      headline: "The Team plan gets its own pricing workshop")
        _ = try write(title: "Pricing workshop", start: daysAgo(9, 10, 0), minutes: 47, language: "en", turns: talk,
                      speakers: voices, summary: """
                        ## Summary
                        - Discounts can't be set without finance.

                        ## Action items
                        - [ ] Me: Send the competitor comparison to Priya
                        - [ ] Priya: Book a call with finance about discounts
                        - [x] Sam: Share the per-seat prices of the three closest competitors
                        """, attendees: pricing, callApp: ("Zoom", "us.zoom.xos"), summarySeconds: 38, keepAudio: false,
                      headline: "Discounts wait for finance")
        _ = try write(title: "Pricing workshop", start: daysAgo(2, 10, 0), minutes: 44, language: "en", turns: talk,
                      speakers: voices, summary: """
                        ## Summary
                        - The Team plan narrowed to three price points.
                        - Annual billing gets a discount; the size is still open.

                        ## Decisions
                        - Three price points for the Team plan, per seat.

                        ## Action items
                        - [ ] Alex: Draft the copy for the three Team plan price points
                        - [ ] Me: Send the competitor comparison to Priya
                        - [ ] Jordan: Pull churn by plan for the last two quarters

                        ## Open questions
                        - Do existing customers keep their price, and for how long?
                        - Is annual billing 15 % or 20 % off?
                        """, attendees: pricing, callApp: ("Zoom", "us.zoom.xos"), summarySeconds: 45, keepAudio: false,
                      headline: "The Team plan narrows to three price points")

        let sync = [Self.me, Attendee(name: "Priya Raman", email: "priya@example.com", isMe: false),
                    Attendee(name: "Tom Becker", email: "tom@example.com", isMe: false)]
        let syncTalk = [turn(3, 18, "Them", nil, "Quick sync on onboarding this week."),
                        turn(19, 30, "Me", nil, "The beta is running; numbers next week.")]
        for (days, headline) in [(21, "The onboarding beta starts with fifty teams"),
                                 (14, "Beta sign-ups beat the goal by a third"),
                                 (7, "The permissions step is where people drop off")] {
            _ = try write(title: "Product sync", start: daysAgo(days, 9, 30), minutes: 30, language: "en",
                          turns: syncTalk, speakers: [], summary: """
                            ## Summary
                            - \(headline).
                            """, attendees: sync, callApp: ("Zoom", "us.zoom.xos"), summarySeconds: 20,
                          keepAudio: false, headline: headline)
        }
    }

    private func productSync() throws -> String {
        let start = today(9, 30, before: 2 * 3600)
        let attendees = [Self.me,
                         Attendee(name: "Priya Raman", email: "priya@example.com", isMe: false),
                         Attendee(name: "Sarah Chen", email: "sarah@example.com", isMe: false),
                         Attendee(name: "Tom Becker", email: "tom@example.com", isMe: false),
                         Attendee(name: "Jordan Lee", email: "jordan@example.com", isMe: false)]
        let turns = [
            turn(12, 26, "Them", "S1", "Okay, let's start. The goal today is to decide whether the new onboarding goes out with the October release."),
            turn(27, 41, "Me", nil, "Sounds good. I put the beta numbers in the doc. The short version is that the permissions step got a lot better."),
            turn(42, 63, "Them", "S1", "It did. Drop-off on that step went from thirty-one percent to eighteen. That's the biggest change we've seen all year."),
            turn(64, 88, "Them", "S2", "The one thing that still bothers me is the empty state. Three of the five people in the last test thought something had gone wrong."),
            turn(89, 101, "Them", "S3", "Thanks, Sarah. Is that a copy problem or a design problem?"),
            turn(102, 121, "Them", "S2", "Both, I think. The illustration looks like an error, and the text says \"nothing here\" instead of telling you what to do next."),
            turn(122, 140, "Me", nil, "Then let's fix it before we ship. I can have final copy by Wednesday if that works for translation."),
            turn(141, 163, "Them", "S3", "Wednesday works. German and French take about a week, so anything after that pushes us past the sixth."),
            turn(164, 178, "Them", "S4", "Do we need a separate flow for team admins, or is that a later release?"),
            turn(179, 198, "Them", "S1", "Later, I'd say. Let's ship the three-step flow to twenty percent of new users on October sixth and keep the old one behind a setting."),
            turn(199, 210, "Me", nil, "Agreed. I'll also book a usability session with two beta customers before then."),
            turn(211, 226, "Them", "S1", "Great. I've already shared the funnel dashboard, so everyone can watch the numbers once it's live."),
            turn(227, 236, "Them", "S4", "I'll write up the admin question so we don't lose it."),
            turn(237, 246, "Me", nil, "Perfect. Thanks, everyone."),
        ]
        let speakers = [
            Speaker(id: "S1", track: "Them", name: "Priya Raman", nameSource: .confirmed, embedding: [], seconds: 71,
                    avatar: AvatarLook.Accessory.glasses.rawValue),
            Speaker(id: "S2", track: "Them", name: "Sarah", nameSource: .guessed, embedding: [], seconds: 43,
                    avatar: AvatarLook.Accessory.bowTie.rawValue, evidence: "Tom says “Thanks, Sarah” at 01:29"),
            Speaker(id: "S3", track: "Them", name: "Tom Becker", nameSource: .voice, embedding: [], seconds: 34,
                    avatar: AvatarLook.Accessory.beanie.rawValue),
            // W-1: long enough for who's who to ask about, with Sarah's guess.
            Speaker(id: "S4", track: "Them", embedding: [], seconds: 48),
        ]
        let summary = """
            ## Summary
            - The team reviewed the new three-step onboarding ahead of the October release.
            - In the beta, drop-off on the permissions step fell from 31 % to 18 %.
            - Sarah found that the empty state still reads as an error to new users.
            - Translation needs the final copy by Wednesday to keep the October 6 date.

            ## Decisions
            - Ship the new onboarding to 20 % of new users on October 6.
            - Keep the old flow behind a setting for one release.

            ## Action items
            - [ ] Alex: Send the final onboarding copy to Tom by Wednesday
            - [ ] Me: Book a usability session with two beta customers
            - [x] Priya: Share the funnel dashboard with the team
            - [ ] Sarah: Redesign the empty state so it doesn't look like an error
            - [ ] Tom: Confirm translation timing for German and French

            ## Open questions
            - Do team admins need a separate onboarding flow?
            """
        return try write(title: "Product sync: onboarding revamp", start: start, minutes: 38, language: "en",
                         turns: turns, speakers: speakers, summary: summary, attendees: attendees,
                         callApp: ("Zoom", "us.zoom.xos"), summarySeconds: 74, eventID: "demo-product-sync",
                         headline: "Onboarding ships to 20 % on October 6", calendarTitle: "Product sync") // S-2
    }

    /// S-1: the daily is a series, so its notes say what moved since yesterday.
    static let standupTeam = [me, Attendee(name: "Nina Park", email: "nina@example.com", isMe: false),
                              Attendee(name: "Sam Okafor", email: "sam@example.com", isMe: false)]

    private func standup() throws -> String {
        let start = today(8, 45, before: 4 * 3600)
        let turns = [
            turn(3, 14, "Me", nil, "Morning. I sent the pricing page review last night, today it's the onboarding copy."),
            turn(15, 29, "Them", nil, "I'm on the export bug. It only happens with very long meeting titles, so I have a fix in review."),
            turn(30, 38, "Me", nil, "Nice. Anything blocking anyone? No? Great, short one then."),
        ]
        let summary = """
            ## Round the table
            - Alex: pricing page review sent; on the onboarding copy today.
            - Nina: fix for the export bug with long titles is in review.
            - Sam: no blockers; still waiting on the staging database.

            ## Since last time
            - Done: Alex sent the pricing page review to Priya.
            - The export bug fix moved from investigation to review.
            - Staging database access for Sam is still open.

            ## Action items
            - [ ] Me: Finish the onboarding copy today
            """
        return try write(title: "Daily standup", start: start, minutes: 9, language: "en", turns: turns, speakers: [],
                         summary: summary, attendees: Self.standupTeam, callApp: ("Slack", "com.tinyspeck.slackmacgap"),
                         summarySeconds: 12, eventID: "demo-daily",
                         headline: "Nobody is blocked, and the export fix is in review", kind: .standup)
    }

    /// S-1: the two dailies before today's.
    private func earlierStandups() throws {
        let yesterday = """
            ## Round the table
            - Alex: reviewing the pricing page.
            - Nina: digging into the export bug with long titles.
            - Sam: blocked on access to the staging database.

            ## Action items
            - [x] Me: Send the pricing page review to Priya
            - [ ] Nina: Find the cause of the export bug
            - [ ] Sam: Ask IT for staging database access

            ## Open questions
            - Does the export bug affect older meetings too?
            """
        try write(title: "Daily standup", start: daysAgo(1, 8, 45), minutes: 11, language: "en", turns: [], speakers: [],
                  summary: yesterday, attendees: Self.standupTeam, callApp: ("Slack", "com.tinyspeck.slackmacgap"),
                  summarySeconds: 14, eventID: "demo-daily", keepAudio: false,
                  headline: "Sam is blocked on staging access")
        let before = """
            ## Round the table
            - Alex: wrapping up the October roadmap page.
            - Nina: release notes for 2.4.

            ## Action items
            - [x] Nina: Publish the 2.4 release notes
            """
        try write(title: "Daily standup", start: daysAgo(2, 8, 45), minutes: 8, language: "en", turns: [], speakers: [],
                  summary: before, attendees: Self.standupTeam, callApp: ("Slack", "com.tinyspeck.slackmacgap"),
                  summarySeconds: 10, eventID: "demo-daily", keepAudio: false,
                  headline: "Release notes for 2.4 go out today")
    }

    // MARK: - A town hall (K-1)

    /// A company all-hands you listened to: announcements, what's asked of
    /// you, the Q&A. No decisions, nobody else's to-dos.
    private func townHall() throws -> String {
        let invited = [Self.me] + (1...47).map { Attendee(name: "Colleague \($0)", email: "c\($0)@example.com", isMe: false) }
        let voices = [
            Speaker(id: "S1", track: "Them", name: "Dana Whitfield", nameSource: .confirmed, embedding: [], seconds: 1150,
                    avatar: AvatarLook.Accessory.glasses.rawValue),
            Speaker(id: "S2", track: "Them", name: "Marco Bellini", nameSource: .confirmed, embedding: [], seconds: 640),
            Speaker(id: "S3", track: "Them", name: "Ruth Adebayo", nameSource: .voice, embedding: [], seconds: 420),
            Speaker(id: "S4", track: "Them", name: nil, nameSource: nil, embedding: [], seconds: 95),
        ]
        let turns = [
            turn(5, 40, "Them", "S1", "Good morning everyone, thanks for joining. Three things today: the quarter, the new office, and the engagement survey."),
            turn(41, 90, "Them", "S1", "Revenue came in at 112 percent of plan, mostly from the Team plan."),
            turn(600, 660, "Them", "S2", "The Lisbon office opens on March 3rd. Desks can be booked from February."),
            turn(1200, 1260, "Them", "S3", "The engagement survey is open until Friday the 24th. Please take ten minutes for it."),
            turn(1500, 1530, "Them", "S4", "Will remote Fridays stay as they are?"),
            turn(1531, 1570, "Them", "S1", "Yes, nothing changes there this year."),
        ]
        let summary = """
            ## Summary
            - The quarter closed at 112 % of plan, carried by the Team plan.
            - The Lisbon office opens on March 3rd.
            - Everyone is asked to fill in the engagement survey by Friday.

            ## Announcements
            - Revenue reached 112 % of plan; the Team plan grew fastest.
            - The Lisbon office opens on March 3rd; desks can be booked from February.
            - Two new hires join the support team next month.
            - The holiday party is on December 12th.

            ## For you
            - [ ] Alex: Fill in the engagement survey by Friday the 24th
            - [ ] Alex: Book a Lisbon desk from February, if you'll travel

            ## Questions asked
            - Will remote Fridays stay? → Yes, unchanged this year.
            - Is there a travel budget for Lisbon? → Teams get one trip per quarter.
            """
        return try write(title: "Company all-hands", start: daysAgo(3, 16, 0), minutes: 48, language: "en", turns: turns,
                         speakers: voices, summary: summary, attendees: invited,
                         callApp: ("Zoom", "us.zoom.xos"), summarySeconds: 96,
                         headline: "A strong quarter, and Lisbon opens in March", kind: .townHall)
    }

    private func hiringCall() throws {
        let start = daysAgo(1, 15, 0)
        let attendees = [Self.me, Attendee(name: "Jamie Ortiz", email: "jamie.ortiz@example.org", isMe: false)]
        let turns = [
            turn(8, 25, "Me", nil, "Thanks for making the time, Jamie. Could you start by telling me about the app you shipped last year?"),
            turn(26, 58, "Them", nil, "Sure. It was an offline-first field app for inspectors. The hard part was syncing when people had no signal for hours."),
            turn(59, 72, "Me", nil, "How did you handle conflicts when two people edited the same inspection?"),
            turn(73, 110, "Them", nil, "We kept every change as an event and merged on the server. Most conflicts turned out to be the same edit made twice."),
        ]
        let summary = """
            ## Summary
            - Interview with Jamie Ortiz for the senior iOS role.
            - Jamie built an offline-first field app and explained event-based sync well.
            - Strong on architecture; less experience with SwiftUI at scale.

            ## Decisions
            - Move Jamie to the take-home exercise.

            ## Action items
            - [ ] Me: Send the take-home exercise to Jamie by Friday
            - [ ] Jamie: Share availability for the final round
            """
        _ = try write(title: "Hiring call: senior iOS engineer", start: start, minutes: 46, language: "en",
                      turns: turns, speakers: [], summary: summary, attendees: attendees,
                      callApp: ("Teams", "com.microsoft.teams2"), summarySeconds: 51,
                      headline: "Jamie moves on to the take-home exercise")
    }

    private func failedMeeting() throws -> String {
        let start = daysAgo(1, 11, 20)
        var meeting = try store.create(startedAt: start, microphone: "MacBook Pro Microphone")
        meeting.info.duration = 27 * 60
        meeting.info.status = .failed
        meeting.info.error = "whisper-cli failed (exit code 3). The model file may be damaged: download it again under the hood."
        try store.save(meeting.info, in: meeting.folder)
        audio(in: meeting.folder, minutes: 27, raw: true)
        return meeting.id
    }

    @discardableResult
    private func customerCall() throws -> String {
        let start = daysAgo(3, 14, 0)
        let attendees = [Self.me,
                         Attendee(name: "Markus Wagner", email: "m.wagner@example.de", isMe: false),
                         Attendee(name: "Julia Brandt", email: "j.brandt@example.de", isMe: false)]
        let turns = [
            turn(5, 20, "Them", "S1", "Guten Tag zusammen. Wir wollten heute über den Lieferplan für das vierte Quartal sprechen."),
            turn(21, 38, "Me", nil, "Sehr gern. Wir können die ersten Lizenzen Anfang Oktober bereitstellen, den Rest im November."),
            turn(39, 61, "Them", "S2", "Für uns wäre wichtig, dass die Schulung vor dem Rollout stattfindet, sonst haben wir zu viele Rückfragen."),
            turn(62, 75, "Me", nil, "Das passt. Ich schicke Ihnen bis Freitag ein Angebot für die zusätzlichen Lizenzen und zwei Schulungstermine."),
        ]
        let speakers = [
            Speaker(id: "S1", track: "Them", name: "Markus Wagner", nameSource: .confirmed, embedding: [], seconds: 38),
            Speaker(id: "S2", track: "Them", name: "Julia Brandt", nameSource: .confirmed, embedding: [], seconds: 29),
        ]
        let summary = """
            ## Summary
            - Abstimmung des Lieferplans für das vierte Quartal mit Alpenblick Logistik.
            - Die ersten Lizenzen kommen Anfang Oktober, der Rest im November.
            - Die Schulung soll vor dem Rollout stattfinden.

            ## Decisions
            - Rollout in zwei Stufen, Schulung vorher.

            ## Action items
            - [ ] Ich: Angebot für die zusätzlichen Lizenzen bis Freitag schicken
            - [ ] Markus Wagner: Lieferadressen für November bestätigen
            - [ ] Julia Brandt: Zwei Schulungstermine intern abstimmen
            """
        return try write(title: "Kundengespräch: Lieferplan Q4", start: start, minutes: 41, language: "de",
                      turns: turns, speakers: speakers, summary: summary, attendees: attendees,
                      callApp: ("Teams", "com.microsoft.teams2"), summarySeconds: 63,
                      // U-2: long, to check that the headline wraps to three lines at most.
                      headline: "Lieferadressen für November müssen bis Freitag bestätigt werden, sonst verschiebt sich der Rollout")
    }

    private func oneOnOne() throws {
        let start = daysAgo(5, 10, 0)
        let attendees = [Self.me, Attendee(name: "Priya Raman", email: "priya@example.com", isMe: false)]
        let turns = [
            turn(4, 22, "Them", nil, "How are you finding the new team rhythm? Last time you said the Monday planning felt long."),
            turn(23, 44, "Me", nil, "It's better since we split it in two. I'd still like fewer status updates and more decisions in the room."),
        ]
        let summary = """
            ## Summary
            - Planning is better since it was split in two.
            - Alex wants fewer status updates and more decisions in meetings.

            ## Action items
            - [ ] Priya: Try a written status update before Monday planning
            - [x] Me: Draft the Q4 goals and share them before next week
            """
        _ = try write(title: "Weekly 1:1 with Priya", start: start, minutes: 28, language: "en", turns: turns,
                      speakers: [], summary: summary, attendees: attendees, callApp: nil, summarySeconds: 20,
                      keepAudio: false)
    }

    private func roadmapReview() throws {
        let start = daysAgo(9, 16, 0)
        let turns = [
            turn(10, 31, "Them", nil, "The main question for next quarter is whether we build the admin console or double down on onboarding."),
            turn(32, 50, "Me", nil, "Onboarding first. The data from the beta says that's where we lose people."),
        ]
        let summary = """
            ## Summary
            - Reviewed the roadmap for next quarter.
            - Onboarding comes before the admin console.

            ## Decisions
            - Onboarding is the Q4 priority; the admin console moves to Q1.

            ## Action items
            - [x] Me: Update the public roadmap page
            - [ ] Tom: Estimate the admin console for Q1
            """
        _ = try write(title: "Quarterly roadmap review", start: start, minutes: 55, language: "en", turns: turns,
                      speakers: [], summary: summary, attendees: nil, callApp: ("Zoom", "us.zoom.xos"),
                      summarySeconds: 88, keepAudio: false,
                      headline: "Onboarding comes first; the admin console waits for Q1")
    }

    /// S-3: questions asked about the product sync (in its folder) and across
    /// meetings (in Application Support), with cited moments.
    private func askHistory(productSync: String, customer: String) throws {
        guard let sync = store.load(store.root.appendingPathComponent(productSync)),
              let kunde = store.load(store.root.appendingPathComponent(customer)) else { return }
        func cite(_ m: Meeting, _ seconds: Double) -> Citation {
            Citation(meetingID: m.id, seconds: seconds, label: AskCitations.label(start: m.info.startedAt, seconds: seconds, now: now))
        }
        func marker(_ m: Meeting, _ seconds: Double) -> String { AskCitations.marker(cite(m, seconds)) }
        let owe = EarlAnswer(
            question: "What do I owe?", scope: .meeting(sync.id),
            text: """
                - The final onboarding copy, to Tom by Wednesday. \(marker(sync, 122))
                - A usability session with two beta customers before October 6. \(marker(sync, 199))
                """,
            citations: [cite(sync, 122), cite(sync, 199)], date: now.addingTimeInterval(-40 * 60))
        let when = EarlAnswer(
            question: "When did we settle on October 6?", scope: .meeting(sync.id),
            text: """
                Priya proposed it near the end: ship the three-step flow to **20 % of new users on October 6** \
                and keep the old one behind a setting. \(marker(sync, 179)) You agreed straight after. \(marker(sync, 199))

                The date rests on translation: German and French need about a week once the copy is final on \
                Wednesday. \(marker(sync, 141))
                """,
            citations: [cite(sync, 179), cite(sync, 199), cite(sync, 141)], date: now.addingTimeInterval(-6 * 60))
        try AskHistory.save([owe, when], to: AskHistory.url(for: sync))

        let dropOff = EarlAnswer(
            question: "What did Priya say about drop-off?", scope: .all,
            text: "That drop-off on the permissions step fell from **31 % to 18 %** in the beta, the biggest change "
                + "this year. \(marker(sync, 42))",
            citations: [cite(sync, 42)], date: now.addingTimeInterval(-26 * 3600))
        let rollout = EarlAnswer(
            question: "Was haben wir mit Alpenblick zum Rollout vereinbart?", scope: .all,
            text: """
                Der Rollout kommt in zwei Stufen: die ersten Lizenzen Anfang Oktober, der Rest im November. \
                \(marker(kunde, 21)) Julia Brandt war wichtig, dass die Schulung vorher stattfindet. \(marker(kunde, 39))

                - Du schickst bis Freitag ein Angebot für die zusätzlichen Lizenzen und zwei Schulungstermine. \(marker(kunde, 62))
                """,
            citations: [cite(kunde, 21), cite(kunde, 39), cite(kunde, 62)], date: now.addingTimeInterval(-50 * 60))
        let budget = EarlAnswer(
            question: "Did anyone mention the budget for Q1?", scope: .all,
            text: "The roadmap review moved the admin console to Q1, but nobody talked about a budget for it.",
            citations: [], date: now.addingTimeInterval(-20 * 60), notFound: true)
        try AskHistory.save([dropOff, rollout, budget], to: AskHistory.globalURL)
    }

    // MARK: - States that come and go

    /// A meeting still being transcribed, and the job that shows its progress.
    func processing() throws -> (id: String, job: Job) {
        let start = today(11, 30, before: 50 * 60)
        var meeting = try store.create(startedAt: start, microphone: "MacBook Pro Microphone")
        meeting.info.duration = 32 * 60
        meeting.info.status = .transcribing
        meeting.info.callApp = "Google Meet"
        try store.save(meeting.info, in: meeting.folder)
        audio(in: meeting.folder, minutes: 32, raw: true)

        var job = Job(id: meeting.id, kind: .full)
        job.step = .transcribing
        job.startedAt = now.addingTimeInterval(-95)
        job.status = "Transcribing the call audio"
        job.model = "Large v3 Turbo"
        job.track = "Them"
        job.trackIndex = 0
        job.trackCount = 2
        job.trackProgress = 0.62
        job.language = "en"
        job.liveTurns = [
            turn(6, 19, "Them", nil, "Can everyone hear me? Great. Let's go through the launch checklist one item at a time."),
            turn(20, 37, "Them", nil, "Support docs are done, the status page is ready, and marketing has the announcement queued for nine o'clock."),
            turn(38, 52, "Them", nil, "The only open item is the rollback plan. We need someone to own it before Thursday."),
            turn(53, 61, "Them", nil, "Legal signed off on the new terms this morning, so that's no longer blocking."),
        ]
        return (meeting.id, job)
    }

    /// A recording in progress, linked to `event`.
    func recording(event: CalendarCandidate) throws -> Meeting {
        var meeting = try store.create(startedAt: event.start.addingTimeInterval(60), microphone: "MacBook Pro Microphone")
        meeting.info.title = event.title
        meeting.info.titleIsDefault = false
        meeting.info.callApp = "Zoom"
        meeting.info.callAppBundleID = "us.zoom.xos"
        meeting.info.calendarEventID = event.id
        meeting.info.calendarTitle = event.title
        meeting.info.calendarStart = event.start
        meeting.info.calendarEnd = event.end
        meeting.info.attendees = [Self.me] + event.attendees
        meeting.info.outputDevice = "AirPods Pro"
        meeting.info.usedSpeakers = false
        try store.save(meeting.info, in: meeting.folder)
        return meeting
    }

    /// Calendar events: one running now (for the recording) and one soon.
    func events() -> (ongoing: CalendarCandidate, next: CalendarCandidate) {
        let minute = Calendar.current.date(bySetting: .second, value: 0, of: now) ?? now
        let ongoing = CalendarCandidate(
            id: "demo-design-review", title: "Design review: checkout flow",
            start: minute.addingTimeInterval(-25 * 60), end: minute.addingTimeInterval(35 * 60), isAllDay: false,
            attendeeCount: 3, myStatus: .accepted, urls: ["https://example.zoom.us/j/5550100"],
            organizer: "Sarah Chen",
            attendees: [Attendee(name: "Sarah Chen", email: "sarah@example.com", isMe: false),
                        Attendee(name: "Tom Becker", email: "tom@example.com", isMe: false),
                        Attendee(name: "Nina Park", email: "nina@example.com", isMe: false)],
            calendarName: "Work")
        let next = CalendarCandidate(
            id: "demo-pricing", title: "Pricing workshop",
            start: minute.addingTimeInterval(8 * 60 + 30), end: minute.addingTimeInterval(53 * 60 + 30), isAllDay: false,
            attendeeCount: 4, myStatus: .accepted, urls: ["https://meet.example.com/abc-defg-hij"],
            organizer: "Priya Raman",
            attendees: [Attendee(name: "Priya Raman", email: "priya@example.com", isMe: false),
                        Attendee(name: "Jordan Lee", email: "jordan@example.com", isMe: false),
                        Attendee(name: "Sam Okafor", email: "sam@example.com", isMe: false),
                        Attendee(name: "Lena Fischer", email: "lena@example.com", isMe: false)],
            calendarName: "Work")
        return (ongoing, next)
    }

    /// Voices remembered across meetings, for the Speakers card.
    static let voices = [
        Voice(name: "Tom Becker", email: "tom@example.com", samples: [[0.1], [0.2], [0.3]],
              sources: ["a/S3", "b/S2", "c/S1"], updatedAt: Date().addingTimeInterval(-3 * 3600), meetings: 3),
        Voice(name: "Priya Raman", email: "priya@example.com", samples: [[0.1], [0.2]],
              sources: ["a/S1", "d/S1"], updatedAt: Date().addingTimeInterval(-5 * 86400), meetings: 2),
    ]

    // MARK: - Writing

    private func turn(_ start: Double, _ end: Double, _ speaker: String, _ id: String?, _ text: String) -> Turn {
        Turn(start: start, end: end, speaker: speaker, text: text, speakerID: id)
    }

    @discardableResult
    private func write(title: String, start: Date, minutes: Double, language: String, turns: [Turn],
                       speakers: [Speaker], summary: String, attendees: [Attendee]?,
                       callApp: (name: String, bundleID: String)?, summarySeconds: Double,
                       eventID: String? = nil, keepAudio: Bool = true, headline: String? = nil,
                       calendarTitle: String? = nil, kind: MeetingKind = .general) throws -> String {
        var meeting = try store.create(startedAt: start, microphone: "MacBook Pro Microphone")
        var info = meeting.info
        info.title = title
        info.titleIsDefault = false
        info.duration = minutes * 60
        info.status = .done
        info.language = language
        info.transcriptionModel = "Large v3 Turbo"
        info.transcriptionSeconds = minutes * 60 / 14
        info.summaryModel = "google/gemma-4-e4b"
        info.summarySeconds = summarySeconds
        info.summaryTokensPerSecond = 38
        info.summaryContext = 32768
        info.summaryContextByEarl = true
        info.headline = headline // U-2
        info.notesKind = kind.rawValue // K-1
        info.callApp = callApp?.name
        info.callAppBundleID = callApp?.bundleID
        info.outputDevice = "AirPods Pro"
        info.usedSpeakers = false
        if !speakers.isEmpty {
            info.speakerModel = Diarizer.modelName
            info.speakerCount = speakers.count
            info.diarizationSeconds = minutes * 60 / 40
        }
        if let attendees {
            info.attendees = attendees
            info.calendarEventID = eventID ?? "demo-\(meeting.id)"
            info.calendarTitle = calendarTitle ?? title // S-2
            info.calendarStart = start
            info.calendarEnd = start.addingTimeInterval(minutes * 60)
            info.organizer = attendees.first { !$0.isMe }?.name
        }
        try store.save(info, in: meeting.folder)
        try store.saveTranscript(turns, in: meeting.folder)
        try store.saveSpeakers(speakers, in: meeting.folder)
        try store.saveSummary(summary, in: meeting.folder)
        if keepAudio { audio(in: meeting.folder, minutes: minutes, raw: false) }
        meeting = store.load(meeting.folder) ?? meeting
        store.saveMarkdown(meeting)
        return meeting.id
    }

    /// Empty audio files of a realistic size. They're sparse, so they take no
    /// disk space, and nothing plays them in demo mode.
    private func audio(in folder: URL, minutes: Double, raw: Bool) {
        let perMinute16k: Int64 = 1_920_000 // 16 kHz, 16-bit mono
        let names = raw ? ["system.wav", "mic.wav"] : ["system-16k.wav", "mic-16k.wav"]
        for name in names {
            let bytes = Int64(minutes) * perMinute16k * (raw ? 3 : 1)
            DemoData.sparseFile(folder.appendingPathComponent(name), bytes: bytes)
        }
    }

    static func sparseFile(_ url: URL, bytes: Int64) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        try? handle.truncate(atOffset: UInt64(bytes))
        try? handle.close()
    }
}
