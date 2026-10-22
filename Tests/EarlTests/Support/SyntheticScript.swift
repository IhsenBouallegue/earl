import Foundation

/// The words of a synthetic meeting (T-1): a seeded walk through a pool of
/// topics, so longer meetings don't loop and every line is known.
/// `{to}` is replaced by the name of the person being addressed.
enum SyntheticScript {
    struct Line {
        var speaker: Int
        var text: String
        /// R2-7: the action item handed out on this line, if any.
        var action: ActionItem? = nil
    }

    /// Who asked whom to do what (R2-7's notes evaluation). The owner is the
    /// person asked, who agrees in the next line.
    struct ActionItem: Equatable {
        var asker: Int
        var owner: Int
        var task: String
    }

    struct Topic {
        var title: String
        var statements: [String]
        var decision: String
        var action: String
    }

    struct Pool {
        var openings: [String]
        var greetings: [String]
        var intros: [String]
        var reactions: [String]
        var questions: [String]
        var decisions: [String]
        var asks: [String]
        var replies: [String]
        var closings: [String]
        var byes: [String]
        var interjections: [String]
        var crosstalk: [String]
        var topics: [Topic]
    }

    /// Builds lines for about `seconds` of speech. Participant 0 chairs.
    /// `names` has one entry per participant (remote speakers, then you).
    static func build(pool: Pool, names: [String], seconds: Double, rng: inout SeededRNG) -> [Line] {
        var lines: [Line] = []
        var estimate = 0.0
        let count = names.count

        func say(_ speaker: Int, _ template: String, to: Int? = nil, fill: [String: String] = [:]) {
            var text = template
            let target = to ?? other(than: speaker)
            text = text.replacingOccurrences(of: "{to}", with: names[target])
            for (k, v) in fill { text = text.replacingOccurrences(of: "{\(k)}", with: v) }
            lines.append(Line(speaker: speaker, text: text))
            // About 3.2 words a second plus a pause, measured on the say voices.
            estimate += Double(text.split(separator: " ").count) / 3.2 + 0.6
        }
        func other(than a: Int, _ b: Int? = nil) -> Int {
            var x = rng.int(0...(count - 1))
            while x == a || x == b { x = rng.int(0...(count - 1)) }
            return x
        }

        say(0, rng.pick(pool.openings))
        let greeter = other(than: 0)
        say(greeter, rng.pick(pool.greetings), to: 0)

        var topics = rng.shuffle(pool.topics)
        var used: [String: Set<Int>] = [:]
        var t = 0
        let closingCost = 12.0
        while estimate < seconds - closingCost {
            if t == topics.count { topics = rng.shuffle(pool.topics); t = 0 }
            let topic = topics[t]; t += 1
            func statement() -> String {
                var seen = used[topic.title] ?? []
                if seen.count == topic.statements.count { seen = [] }
                var i = rng.int(0...(topic.statements.count - 1))
                while seen.contains(i) { i = (i + 1) % topic.statements.count }
                seen.insert(i)
                used[topic.title] = seen
                return topic.statements[i]
            }

            let chair = lines.last?.speaker == 0 ? other(than: 0) : 0
            let owner = other(than: chair)
            say(chair, rng.pick(pool.intros), to: owner, fill: ["topic": topic.title])
            say(owner, statement() + " " + statement())
            var last = owner
            for _ in 0..<rng.int(2...4) {
                let next = other(than: last)
                if rng.chance(0.35) {
                    // Ask someone by name; they answer.
                    let asked = other(than: next)
                    say(next, rng.pick(pool.questions), to: asked)
                    say(asked, statement())
                    last = asked
                } else if rng.chance(0.4) {
                    say(next, rng.pick(pool.reactions) + " " + statement(), to: last)
                    last = next
                } else {
                    say(next, statement())
                    last = next
                }
            }
            // Whoever sums up also hands out the action item, in one turn.
            let decider = other(than: last)
            let assignee = other(than: decider)
            let ask = rng.pick(pool.asks).replacingOccurrences(of: "{action}", with: topic.action)
            say(decider, rng.pick(pool.decisions) + " " + topic.decision + " " + ask, to: assignee)
            lines[lines.count - 1].action = ActionItem(asker: decider, owner: assignee, task: topic.action)
            say(assignee, rng.pick(pool.replies), to: decider)
        }
        let closer = lines.last?.speaker == 0 ? other(than: 0) : 0
        say(closer, rng.pick(pool.closings))
        say(other(than: closer), rng.pick(pool.byes), to: closer)
        return lines
    }

    // MARK: - English

    static let english = Pool(
        openings: [
            "Okay, let's get started. Thanks everyone for joining.",
            "Alright, I think we have everyone. Let's kick off.",
            "Good morning everyone. We have a full agenda, so let's dive in.",
        ],
        greetings: [
            "Morning {to}, good to see everyone.",
            "Hi {to}, hi all.",
            "Hey everyone. Thanks for setting this up, {to}.",
        ],
        intros: [
            "Next up is {topic}. {to}, can you give us an update?",
            "Let's talk about {topic}. {to}, where are we on that?",
            "Moving on to {topic}. {to}, do you want to start?",
            "Okay, {topic}. {to}, what's the latest?",
        ],
        reactions: [
            "Thanks {to}, that helps.",
            "Good point, {to}.",
            "I agree with {to} on that.",
            "Right, and building on what {to} said,",
            "I'm not so sure, {to}.",
        ],
        questions: [
            "{to}, what do you think?",
            "{to}, does that work for your team?",
            "{to}, is that realistic?",
            "What's the risk there, {to}?",
        ],
        decisions: [
            "Okay, so we agree.",
            "Let's decide then.",
            "So the decision is:",
            "Fine, let's go with this.",
        ],
        asks: [
            "{to}, can you {action}?",
            "{to}, could you take the action item to {action}?",
            "Thanks. {to}, would you {action}?",
        ],
        replies: [
            "Sure, I'll do that by Friday.",
            "Yes, I can take that. I'll have it done by Thursday.",
            "Okay, I'll get that done this week.",
            "No problem, {to}, I'll send it by tomorrow.",
        ],
        closings: [
            "Great, I think that's everything for today. Thanks everyone.",
            "Okay, that's all we had. Thanks {to}, and thanks everyone.",
            "Alright, let's wrap up here. Talk to you all next week.",
        ],
        byes: ["Thanks {to}, bye everyone.", "Thanks all, see you.", "Bye, have a good one."],
        interjections: ["Yeah.", "Right.", "Mm-hm.", "Sorry, go on.", "Okay.", "Exactly.", "Sure.", "True."],
        crosstalk: [
            "But hold on, we already agreed on this with the whole team last week.",
            "Wait, I thought the budget for that was already approved in March.",
            "Sorry, I really have to jump in here because the numbers look different to me.",
            "No, no, the customer asked for the opposite in the last review meeting.",
            "Actually I think the design team is still waiting for our answer on that one.",
            "Hang on, that would break the integration with the billing service completely.",
        ],
        topics: [
            Topic(title: "the release plan", statements: [
                "The release candidate is ready, and we fixed the last two blocking bugs yesterday.",
                "QA still needs two more days for the regression tests on Windows.",
                "I'd like to ship on Friday, but only if the crash rate stays below one percent.",
                "The feature flag for the new editor is off by default, so the risk is small.",
                "We should write the release notes before Thursday so support can read them.",
                "Last time we shipped on a Friday, nobody was around to handle the rollback.",
            ], decision: "we ship the release on Monday morning, not Friday.",
               action: "write the release notes and share them with support"),
            Topic(title: "the hiring pipeline", statements: [
                "We have three candidates in the final round for the backend role.",
                "The take-home exercise takes most people more than six hours, which is too long.",
                "Two of our best candidates dropped out because the process took four weeks.",
                "I think we can merge the technical interview and the architecture interview.",
                "The recruiter says the market for senior designers is very tight right now.",
                "We should give feedback to every candidate within two days.",
            ], decision: "we shorten the take-home exercise to two hours.",
               action: "update the interview guide and tell the recruiters"),
            Topic(title: "the customer escalation", statements: [
                "The customer reported data loss after the last sync, and they are very upset.",
                "We traced it to a race condition when two devices edit the same record.",
                "The fix is small, but we need to backfill about four hundred accounts.",
                "Their contract renewal is next month, so we have to handle this carefully.",
                "I spoke with their account manager this morning, and they want a written report.",
                "We should offer them a call with our engineering lead this week.",
            ], decision: "we send the customer a written incident report by Wednesday.",
               action: "draft the incident report and review it with legal"),
            Topic(title: "the budget for next quarter", statements: [
                "Our cloud costs went up by eighteen percent, mostly because of storage.",
                "Finance wants every team to cut five percent from next quarter's budget.",
                "We can save a lot by moving old backups to cold storage.",
                "The conference budget is already spent, so travel is on hold until July.",
                "I'd rather cut tools we don't use than cut the training budget.",
                "We are paying for forty seats in the design tool, but only twenty people use it.",
            ], decision: "we move old backups to cold storage and cancel unused licenses.",
               action: "list the licenses we can cancel"),
            Topic(title: "the mobile app redesign", statements: [
                "The new navigation tested well, and task completion went up by twelve percent.",
                "Older users struggled to find the settings in the new layout.",
                "The dark mode colors still fail the contrast check in two places.",
                "Engineering estimates six weeks for the full redesign.",
                "We could ship the new navigation first and the visual refresh later.",
                "Android and iOS should launch at the same time this time.",
            ], decision: "we ship the new navigation first and the visual refresh in the next release.",
               action: "fix the contrast issues and send new mockups"),
            Topic(title: "the on-call rotation", statements: [
                "We had eleven pages last week, and seven of them were false alarms.",
                "The disk space alert fires every night during the backup job.",
                "People are tired, and two engineers asked to leave the rotation.",
                "We should raise the alert thresholds and add a runbook for each alert.",
                "The weekend shifts should be paid extra, like the other teams do.",
                "I can pair with new people on their first on-call week.",
            ], decision: "we tune the noisy alerts before anyone else joins the rotation.",
               action: "review the alert thresholds with the infrastructure team"),
            Topic(title: "the data migration", statements: [
                "The migration script processed ninety percent of the records in the test run.",
                "The remaining ten percent have broken date formats from the old system.",
                "We need a maintenance window of about three hours.",
                "Sunday night is the quietest time for our European customers.",
                "We should keep the old database read only for at least a month.",
                "I'm worried about the reporting jobs that still read from the old tables.",
            ], decision: "we run the migration on Sunday night with a three hour window.",
               action: "announce the maintenance window to customers"),
            Topic(title: "the security audit", statements: [
                "The auditors found no critical issues, but there are five medium findings.",
                "Most of the findings are about old accounts that still have admin rights.",
                "We need to rotate the API keys that were shared in the old wiki.",
                "The penetration test is scheduled for the second week of next month.",
                "Two factor authentication should be mandatory for everyone by the end of the month.",
                "We still don't have a clear owner for the vendor security reviews.",
            ], decision: "two factor authentication becomes mandatory by the end of the month.",
               action: "remove the old admin accounts and rotate the keys"),
            Topic(title: "the marketing launch", statements: [
                "The landing page is ready, but the video is still in editing.",
                "We booked three podcasts and one newsletter for the launch week.",
                "The press release needs a quote from the CEO before we can send it.",
                "Paid ads performed badly last time, so I'd put the money into partnerships.",
                "Sign ups from the waitlist are already at four thousand.",
                "We need screenshots of the final version, not the beta.",
            ], decision: "we launch on the fourteenth and skip the paid ads.",
               action: "get the CEO quote for the press release"),
            Topic(title: "the office move", statements: [
                "The new office will be ready in six weeks, maybe seven.",
                "There are fewer meeting rooms, so we need a booking system.",
                "Some people asked for quiet desks away from the kitchen.",
                "Parking is limited, and the company will pay for public transport instead.",
                "The movers need a list of everything we are taking with us.",
                "We should use the move to throw out the old monitors and chairs.",
            ], decision: "everyone packs their desk by the end of next month.",
               action: "send the packing list to the movers"),
            Topic(title: "the analytics dashboard", statements: [
                "The weekly active users chart has been wrong since the tracking change.",
                "Sales wants a revenue view by region, not just by product.",
                "The dashboard takes almost a minute to load, which nobody likes.",
                "We could precompute the heavy queries every night.",
                "I'd like one number that everyone agrees on for retention.",
                "Half of the charts on the dashboard haven't been opened in three months.",
            ], decision: "we remove the unused charts and precompute the heavy queries.",
               action: "fix the active users chart"),
            Topic(title: "the partner integration", statements: [
                "The partner's API changed without notice, and our sync broke on Tuesday.",
                "They promised a sandbox environment, but we still don't have access.",
                "About two hundred shared customers are affected by the broken sync.",
                "We should add monitoring so we notice these changes within an hour.",
                "Their team is in Singapore, so meetings are hard to schedule.",
                "The contract says they must announce breaking changes thirty days in advance.",
            ], decision: "we escalate the missing sandbox to their management.",
               action: "set up monitoring for the partner sync"),
            Topic(title: "the documentation", statements: [
                "Half of the support tickets are questions the docs should answer.",
                "The getting started guide still shows the old pricing page.",
                "Nobody owns the API reference, so it's always out of date.",
                "We could generate the reference from the code comments.",
                "Customers love the video tutorials, but they're expensive to update.",
                "Search on the docs site doesn't find anything with a typo.",
            ], decision: "we generate the API reference from the code from now on.",
               action: "update the getting started guide"),
            Topic(title: "the team offsite", statements: [
                "The offsite is planned for the last week of September.",
                "The hotel near the lake has space for thirty people.",
                "Last year's agenda was too packed, and people wanted more free time.",
                "We should plan one day for strategy and one day for fun.",
                "A few people can't travel, so we need a good video setup.",
                "The budget covers travel and two nights, but not the dinner.",
            ], decision: "we book the hotel by the lake for two nights.",
               action: "collect dietary requirements and book the hotel"),
        ]
    )

    // MARK: - German (with some English, as in many real meetings)

    static let german = Pool(
        openings: [
            "Okay, lasst uns anfangen. Danke, dass ihr alle da seid.",
            "Hallo zusammen, ich glaube, wir sind vollständig. Let's get started.",
        ],
        greetings: ["Hallo {to}, hallo zusammen.", "Morgen {to}, danke fürs Organisieren."],
        intros: [
            "Als Nächstes: {topic}. {to}, kannst du kurz den Stand erzählen?",
            "Dann zum Thema {topic}. {to}, wie sieht es aus?",
            "Okay, Thema {topic}. {to}, magst du anfangen?",
        ],
        reactions: [
            "Danke {to}, das hilft.",
            "Guter Punkt, {to}.",
            "Da stimme ich {to} zu.",
            "Good point, {to}.",
        ],
        questions: [
            "{to}, was meinst du dazu?",
            "{to}, passt das für dein Team?",
            "{to}, ist das realistisch?",
            "{to}, what do you think?",
        ],
        decisions: ["Okay, dann machen wir das so.", "Also, die Entscheidung ist:", "Gut, dann halten wir fest:"],
        asks: [
            "{to}, kannst du {action}?",
            "{to}, übernimmst du es, {action}?",
        ],
        replies: [
            "Ja, mache ich bis Freitag.",
            "Klar, ich kümmere mich darum.",
            "Okay, sure, I'll do it this week.",
        ],
        closings: [
            "Super, das war alles für heute. Danke euch allen.",
            "Okay, dann machen wir hier Schluss. Danke {to} und danke an alle.",
        ],
        byes: ["Danke {to}, tschüss zusammen.", "Bis nächste Woche, ciao.", "Thanks, bye."],
        interjections: ["Ja.", "Genau.", "Okay.", "Stimmt.", "Mhm.", "Sorry, mach weiter."],
        crosstalk: [
            "Moment mal, das haben wir doch letzte Woche schon mit dem ganzen Team besprochen.",
            "Warte, ich dachte, das Budget dafür wurde im März schon freigegeben.",
            "Sorry, da muss ich kurz einhaken, die Zahlen sehen bei mir ganz anders aus.",
        ],
        topics: [
            Topic(title: "Release", statements: [
                "Der Release Candidate ist fertig, und die letzten zwei Blocker sind behoben.",
                "Die Tester brauchen noch zwei Tage für die Regressionstests.",
                "Ich würde gerne am Freitag releasen, aber nur, wenn die Crash Rate niedrig bleibt.",
                "The feature flag is off by default, so the risk is small.",
                "Die Release Notes sollten bis Donnerstag fertig sein.",
            ], decision: "wir releasen am Montag und nicht am Freitag.",
               action: "die Release Notes zu schreiben"),
            Topic(title: "Datenmigration", statements: [
                "Das Skript hat im Testlauf neunzig Prozent der Datensätze migriert.",
                "Der Rest hat kaputte Datumsformate aus dem alten System.",
                "Wir brauchen ein Wartungsfenster von etwa drei Stunden.",
                "Sonntagnacht ist für unsere Kunden die ruhigste Zeit.",
                "The old database should stay read only for a month.",
            ], decision: "die Migration läuft am Sonntagabend.",
               action: "das Wartungsfenster an die Kunden zu kommunizieren"),
            Topic(title: "Recruiting", statements: [
                "Wir haben drei Kandidaten in der letzten Runde für die Backend Stelle.",
                "Die Probeaufgabe dauert für die meisten mehr als sechs Stunden.",
                "Zwei gute Kandidaten sind abgesprungen, weil der Prozess zu lange gedauert hat.",
                "We could merge the two technical interviews into one.",
                "Jeder Kandidat sollte innerhalb von zwei Tagen Feedback bekommen.",
            ], decision: "die Probeaufgabe wird auf zwei Stunden gekürzt.",
               action: "den Interview Leitfaden anzupassen"),
            Topic(title: "Budget", statements: [
                "Die Cloud Kosten sind um achtzehn Prozent gestiegen, vor allem wegen Speicher.",
                "Die Finanzabteilung will, dass jedes Team fünf Prozent einspart.",
                "Alte Backups könnten wir in günstigeren Speicher verschieben.",
                "We pay for forty licenses, but only twenty people use the tool.",
                "Beim Weiterbildungsbudget würde ich lieber nicht sparen.",
            ], decision: "wir kündigen ungenutzte Lizenzen.",
               action: "eine Liste der ungenutzten Lizenzen zu machen"),
            Topic(title: "Kundeneskalation", statements: [
                "Der Kunde hat nach dem letzten Sync Datenverlust gemeldet.",
                "Die Ursache ist eine Race Condition, wenn zwei Geräte gleichzeitig speichern.",
                "Der Fix ist klein, aber wir müssen etwa vierhundert Konten korrigieren.",
                "Their contract renewal is next month, so we need to be careful.",
                "Der Kunde möchte einen schriftlichen Bericht.",
            ], decision: "der Kunde bekommt bis Mittwoch einen schriftlichen Bericht.",
               action: "den Bericht zu entwerfen"),
            Topic(title: "Bereitschaftsdienst", statements: [
                "Letzte Woche gab es elf Alarme, und sieben davon waren Fehlalarme.",
                "Der Speicherplatz Alarm geht jede Nacht während des Backups los.",
                "Zwei Kollegen wollen aus der Rotation raus, weil sie müde sind.",
                "We should add a runbook for every alert.",
                "Die Wochenenddienste sollten extra bezahlt werden.",
            ], decision: "wir passen die Schwellenwerte der Alarme an.",
               action: "die Schwellenwerte mit dem Infrastruktur Team durchzugehen"),
        ]
    )
}
