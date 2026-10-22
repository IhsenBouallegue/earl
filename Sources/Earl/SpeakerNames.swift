import SwiftUI

// R2-3: names for the voices R2-2 found. You name them by clicking a chip or a
// badge; before that, the local LLM makes a first guess from how people
// address each other ("Tom, can you…").

extension Prefs.Key {
    static let guessSpeakerNames = "guessSpeakerNames"
}

extension Prefs {
    static var guessSpeakerNames: Bool {
        UserDefaults.standard.object(forKey: Key.guessSpeakerNames) as? Bool ?? true
    }
}

extension Speaker {
    /// A turn standing for this speaker, so the per-turn naming rules apply.
    var sampleTurn: Turn { Turn(start: 0, end: 0, speaker: track, text: "", speakerID: id) }

    var isGuess: Bool { nameSource == .guessed && !(name ?? "").isEmpty }

    /// Whether this voice is you: the main voice on the microphone.
    static func isYou(_ speaker: Speaker, in speakers: [Speaker]) -> Bool {
        isMe(speaker.sampleTurn, in: speakers)
    }

    /// The name on a badge or chip: a guess gets a "?", and its evidence as the tooltip.
    static func badge(for turn: Turn, in speakers: [Speaker]) -> (name: String, help: String?) {
        let name = displayName(for: turn, in: speakers)
        guard let speaker = speakers.first(where: { $0.id == turn.speakerID }) else { return (name, nil) }
        if speaker.isRecognised { return (name, speaker.recognisedHelp) } // R3-3
        guard speaker.isGuess else { return (name, nil) }
        return (name + "?", "Guessed: " + (speaker.evidence ?? "from the conversation"))
    }
}

// MARK: - Editing

/// Renaming and merging, on plain values so they can be tested.
enum SpeakerEdit {
    static func rename(_ speakers: [Speaker], id: String, to name: String?, source: Speaker.NameSource?,
                       evidence: String? = nil) -> [Speaker] {
        speakers.map { s in
            guard s.id == id else { return s }
            var s = s
            let name = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            s.name = name.isEmpty ? nil : name
            s.nameSource = name.isEmpty ? nil : source
            s.evidence = name.isEmpty ? nil : evidence
            return s
        }
    }

    /// Makes `from` part of `into`: its turns take `into`'s ID, talk time adds
    /// up, the voice prints are averaged by talk time, and consecutive turns of
    /// the merged speaker join up. `into` keeps its name, or takes `from`'s.
    static func merge(turns: [Turn], speakers: [Speaker], from: String, into: String) -> (turns: [Turn], speakers: [Speaker]) {
        guard from != into, let a = speakers.first(where: { $0.id == from }),
              let bi = speakers.firstIndex(where: { $0.id == into }) else { return (turns, speakers) }
        var b = speakers[bi]
        b.embedding = weightedMean(b.embedding, b.seconds, a.embedding, a.seconds)
        b.seconds += a.seconds
        if (b.name ?? "").isEmpty, let name = a.name, !name.isEmpty {
            b.name = name
            b.nameSource = a.nameSource
            b.evidence = a.evidence
        }
        var merged = speakers
        merged[bi] = b
        merged.removeAll { $0.id == from }

        let renamed = turns.map { t -> Turn in
            var t = t
            if t.speakerID == from { t.speakerID = into }
            return t
        }
        return (join(renamed, speakerID: into), merged)
    }

    /// Joins consecutive turns of one speaker, by the same rules as `Transcriber.buildTurns`.
    static func join(_ turns: [Turn], speakerID: String) -> [Turn] {
        var out: [Turn] = []
        for turn in turns.sorted(by: { $0.start < $1.start }) {
            if var last = out.last, last.speakerID == speakerID, turn.speakerID == speakerID, last.speaker == turn.speaker,
               turn.start - last.end < 4, last.text.count + turn.text.count < 1200 {
                last.text += " " + turn.text
                last.end = max(last.end, turn.end)
                out[out.count - 1] = last
            } else {
                out.append(turn)
            }
        }
        return out
    }

    static func weightedMean(_ a: [Float], _ wa: Double, _ b: [Float], _ wb: Double) -> [Float] {
        guard !b.isEmpty, b.count == a.count else { return a.isEmpty ? b : a }
        let total = max(wa + wb, 1e-9)
        return zip(a, b).map { Float((Double($0) * wa + Double($1) * wb) / total) }
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in a.indices {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        return na > 0 && nb > 0 ? dot / (na.squareRoot() * nb.squareRoot()) : 0
    }

    /// Transcribe Again on the same audio gives near-identical voice prints.
    /// Even the same person diarized from two different halves of a call
    /// scores 0.90 and up, while different people stay at 0.59 and below
    /// (synthetic meetings, see SpeakerNamesEvalTests), so 0.75 sits between.
    static let carryOverThreshold: Float = 0.75

    /// Transcribe Again makes new speakers. Gives each the confirmed name of
    /// the old speaker with the most similar voice print on the same track,
    /// one to one, when they are similar enough.
    static func carryOver(from old: [Speaker], to new: [Speaker], threshold: Float = carryOverThreshold) -> [Speaker] {
        let named = old.filter { $0.nameSource == .confirmed && !($0.name ?? "").isEmpty && !$0.embedding.isEmpty }
        var pairs: [(new: Int, old: Int, score: Float)] = []
        for (i, n) in new.enumerated() where !n.embedding.isEmpty {
            for (j, o) in named.enumerated() where o.track == n.track {
                let score = cosine(n.embedding, o.embedding)
                if score >= threshold { pairs.append((i, j, score)) }
            }
        }
        var out = new
        var usedNew = Set<Int>(), usedOld = Set<Int>()
        for pair in pairs.sorted(by: { $0.score > $1.score }) where !usedNew.contains(pair.new) && !usedOld.contains(pair.old) {
            usedNew.insert(pair.new)
            usedOld.insert(pair.old)
            out[pair.new].name = named[pair.old].name
            out[pair.new].nameSource = .confirmed
            out[pair.new].evidence = nil
        }
        return out
    }
}

// MARK: - Guessing names

/// Asks the local LLM who is who, from how people address each other.
struct SpeakerNameGuesser {
    struct Guess: Hashable {
        var name: String
        var evidence: String
    }

    var summarizer = Self.namesSummarizer()
    /// R2-7: off by default. On a synthetic meeting (Bonsai 27B, one seed),
    /// thinking took 199–307 s and named all 4 voices; without it the answer
    /// took 16 s and named 1–2, with no wrong names either way. A missed
    /// name is fixed with one click; minutes of fans are not.
    var reasoning = false

    /// The notes model, or the one chosen for name guessing (R2-7).
    static func namesSummarizer() -> Summarizer {
        var s = Summarizer()
        s.model = Prefs.nameModel
        s.reasoning = Prefs.notesThinking(s.model) // size the load as the notes will
        return s
    }

    private static let system = """
        You work out the names of the speakers in a meeting transcript. You answer with JSON only. \
        You only name a speaker when the transcript clearly shows it, and answer null otherwise.
        """

    /// Guesses for the unnamed voices (other than you), after the guard rules.
    func guess(meeting: Meeting, attendees: [Attendee], userName: String?) async throws -> [String: Guess] {
        guard !Self.candidates(in: meeting).isEmpty else { return [:] }
        let answer = try await ask(meeting: meeting, attendees: attendees, userName: userName)
        return Self.interpret(answer, meeting: meeting, attendees: attendees, userName: userName)
    }

    /// The model's raw answer. `candidates` (Q-3) restricts who's asked
    /// about, e.g. to the voices `AddressedNames` didn't already name;
    /// defaults to every unnamed voice.
    func ask(meeting: Meeting, attendees: [Attendee], userName: String?, candidates: [Speaker]? = nil) async throws -> String {
        let candidates = candidates ?? Self.candidates(in: meeting)
        guard !candidates.isEmpty else { return "{}" }
        // R2-7: load the model as the summary will need it, so one load serves both.
        let transcriptChars = meeting.turns.reduce(0) { $0 + $1.text.count + 20 }
        let prepared = await summarizer.prepare(transcriptChars: transcriptChars, onEvent: nil)
        let context: Int?
        if let prepared { context = prepared.context } else {
            context = await Summarizer.modelInfo(baseURL: summarizer.baseURL, id: summarizer.model)?.loadedContextLength
        }
        // ~3 characters per token, with room for the answer (and reasoning, if on).
        let limit = max(6000, ((context ?? 4096) - (reasoning ? 6000 : 2500)) * 3)
        let prompt = Self.prompt(meeting: meeting, candidates: candidates, attendees: attendees,
                                 userName: userName, limit: limit)
        // Q-3: a short, valid JSON schema instead of hoping the model's
        // reasoning ends before maxTokens. 600 tokens is generous for a
        // 160-character evidence quote and a 40-character name per candidate.
        return try await summarizer.answer(system: Self.system, prompt: prompt,
                                           maxTokens: reasoning ? 12000 : 600, reasoning: reasoning,
                                           schema: Self.schema(for: candidates.map(\.id)))
    }

    /// The names schema (Q-3): one required key per candidate, each `null`
    /// or `{evidence, name}`, evidence first so the model quotes before it
    /// names.
    static func schema(for candidateIDs: [String]) -> Summarizer.AnswerSchema {
        let guess: [String: Any] = [
            "type": "object",
            "properties": [
                "evidence": ["type": "string", "maxLength": 160],
                "name": ["type": "string", "maxLength": 40],
            ],
            "required": ["evidence", "name"],
            "additionalProperties": false,
        ]
        var properties: [String: Any] = [:]
        for id in candidateIDs { properties[id] = ["anyOf": [["type": "null"], guess]] }
        return Summarizer.AnswerSchema(name: "speaker_names", schema: [
            "type": "object",
            "properties": properties,
            "required": candidateIDs,
            "additionalProperties": false,
        ])
    }

    /// The model's answer, parsed and put through the guard rules.
    static func interpret(_ answer: String, meeting: Meeting, attendees: [Attendee], userName: String?,
                          corroborate: Bool = true, candidates: [Speaker]? = nil) -> [String: Guess] {
        explain(answer, meeting: meeting, attendees: attendees, userName: userName, corroborate: corroborate,
               candidates: candidates)
            .compactMapValues { outcome in
                if case .kept(_, let g) = outcome { return g }
                return nil
            }
    }

    /// What happened to one candidate's guess, for `guessSpeakerNames`' log:
    /// the model didn't name them, its guess survived, or its guess was
    /// dropped and why.
    enum Outcome: Equatable {
        case noGuess
        case kept(raw: String, guess: Guess)
        case dropped(raw: String, reason: String)
    }

    /// `interpret`, but keeping the raw guess and the reason for every drop,
    /// so "Guessed names: none" doesn't have to mean the model found nothing
    /// (R2-3's log used to throw the raw guesses away).
    static func explain(_ answer: String, meeting: Meeting, attendees: [Attendee], userName: String?,
                        corroborate: Bool = true, candidates: [Speaker]? = nil) -> [String: Outcome] {
        let ids = (candidates ?? Self.candidates(in: meeting)).map(\.id)
        let parsed = parse(answer, validIDs: Set(ids))
        let acceptedOutcomes = acceptDetailed(parsed, speakers: meeting.speakers, attendees: attendees, userName: userName,
                                              transcript: meeting.turns.map(\.text).joined(separator: "\n"))
        var out: [String: Outcome] = [:]
        for id in ids {
            guard let raw = parsed[id] else { out[id] = .noGuess; continue }
            switch acceptedOutcomes[id] {
            case .kept(let g): out[id] = .kept(raw: raw.name, guess: g)
            case .dropped(let reason): out[id] = .dropped(raw: raw.name, reason: reason)
            case nil: out[id] = .dropped(raw: raw.name, reason: "not accepted")
            }
        }
        guard corroborate else { return out }
        let acceptedGuesses = Dictionary(uniqueKeysWithValues: out.compactMap { id, outcome -> (String, Guess)? in
            if case .kept(_, let g) = outcome { return (id, g) }
            return nil
        })
        let survivors = corroborated(acceptedGuesses, turns: meeting.turns, candidates: ids)
        for id in ids {
            guard case .kept(let raw, _) = out[id], survivors[id] == nil else { continue }
            out[id] = .dropped(raw: raw, reason: "not backed up next to \(id)'s turns")
        }
        return out
    }

    /// The `Name guesses:` log line: every candidate, the model's raw guess
    /// (or "null"), and whether it was kept or why it was dropped.
    static func logLine(_ outcomes: [String: Outcome]) -> String {
        guard !outcomes.isEmpty else { return "none" }
        return outcomes.sorted { $0.key < $1.key }.map { id, outcome in
            switch outcome {
            case .noGuess: return "\(id) = null"
            case .kept(let raw, let guess): return "\(id) = \(raw) (kept: \(guess.name))"
            case .dropped(let raw, let reason): return "\(id) = \(raw) (dropped: \(reason))"
            }
        }.joined(separator: ", ")
    }

    // MARK: Combined (Q-3)

    /// `guessSpeakerNames` and the replay tool's result: names from direct
    /// address, then the model for whatever's left.
    struct CombinedResult {
        /// Decided by `AddressedNames`, no LLM.
        var addressed: [String: Guess]
        /// The candidates the model was (or would be) asked about, i.e. the
        /// ones `addressed` didn't name.
        var remaining: [Speaker]
        /// nil when there was nothing left to ask, or the request failed.
        var modelAnswer: String?
        var modelOutcomes: [String: Outcome]
        var modelError: String?
        /// V-1: addressed guesses dropped because a confirmed or recognised
        /// voice already has that name; those speakers go to the model.
        var addressedDropped: [String: NameCollisions.Drop] = [:]

        /// The names to apply, one per person across every source
        /// (confirmed > voice > addressed > model), and what lost (V-1).
        func final(speakers: [Speaker]) -> (guesses: [String: Guess], dropped: [String: NameCollisions.Drop]) {
            let model = modelOutcomes.compactMapValues { outcome -> Guess? in
                if case .kept(_, let g) = outcome { return g }
                return nil
            }
            let resolved = NameCollisions.resolve(speakers: speakers,
                                                  guesses: [(.addressed, addressed), (.model, model)])
            return (resolved.kept, addressedDropped.merging(resolved.dropped) { _, later in later })
        }
    }

    /// Runs `AddressedNames` first, then asks the model only about
    /// candidates it didn't name (skipping the request entirely when none
    /// are left). The model sees the addressed names already applied, so it
    /// won't give the same name to a voice `AddressedNames` already named.
    static func combinedGuess(meeting: Meeting, attendees: [Attendee], userName: String?,
                              guesser: SpeakerNameGuesser) async -> CombinedResult {
        let candidates = Self.candidates(in: meeting)
        let found = AddressedNames.guesses(turns: meeting.turns, candidates: candidates.map(\.id),
                                           attendees: attendees, userName: userName)
        // V-1: AddressedNames only knows the unnamed voices, so it can hand
        // out a name voice memory (or you) already gave someone else.
        let (addressed, addressedDropped) = NameCollisions.resolve(speakers: meeting.speakers,
                                                                   guesses: [(.addressed, found)])
        var working = meeting
        working.speakers = apply(addressed, to: meeting.speakers)
        let remaining = Self.candidates(in: working)
        guard !remaining.isEmpty else {
            return CombinedResult(addressed: addressed, remaining: [], modelAnswer: nil, modelOutcomes: [:], modelError: nil,
                                  addressedDropped: addressedDropped)
        }
        do {
            let answer = try await guesser.ask(meeting: working, attendees: attendees, userName: userName, candidates: remaining)
            let outcomes = explain(answer, meeting: working, attendees: attendees, userName: userName, candidates: remaining)
            return CombinedResult(addressed: addressed, remaining: remaining, modelAnswer: answer,
                                  modelOutcomes: outcomes, modelError: nil, addressedDropped: addressedDropped)
        } catch {
            return CombinedResult(addressed: addressed, remaining: remaining, modelAnswer: nil, modelOutcomes: [:],
                                  modelError: error.localizedDescription, addressedDropped: addressedDropped)
        }
    }

    /// The `Addressed:` log line, in the same style as `logLine`.
    static func addressedLogLine(_ addressed: [String: Guess]) -> String {
        guard !addressed.isEmpty else { return "none" }
        return addressed.sorted { $0.key < $1.key }.map { id, guess in
            "\(id) = \(guess.name) (\"\(guess.evidence)\")"
        }.joined(separator: ", ")
    }

    // MARK: Corroboration

    /// Small models happily fill in every attendee by elimination or by role
    /// ("S4 gives technical updates, so S4 is Megan"). Keeps only guesses the
    /// transcript backs up next to that speaker's own turns (see `support`),
    /// and only when no other unnamed voice is backed up more for that name.
    /// On three synthetic meetings with attendees, this took precision from
    /// 83 % (10 of 12) to 100 % (10 of 10), dropping only the two wrong guesses.
    static func corroborated(_ guesses: [String: Guess], turns: [Turn], candidates: [String]) -> [String: Guess] {
        guesses.filter { id, guess in
            let first = String(guess.name.split(separator: " ").first ?? "")
            let mine = support(for: id, name: first, turns: turns)
            guard mine > 0 else { return false }
            return !candidates.contains { $0 != id && support(for: $0, name: first, turns: turns) > mine }
        }
    }

    /// How often `name` is said right next to a turn of speaker `id`: near the
    /// end of someone else's turn just before ("…Tom, can you?"), near the
    /// start of someone else's turn just after ("Thanks Tom"), or in their own
    /// introduction ("I'm Tom"). Tolerates short forms and whisper's near-miss
    /// spellings via `NameMatch`, so "Isa" and "Mathias" count too.
    static func support(for id: String, name: String, turns: [Turn]) -> Int {
        func words(_ text: String, first n: Int) -> String { text.split(separator: " ").prefix(n).joined(separator: " ") }
        func words(_ text: String, last n: Int) -> String { text.split(separator: " ").suffix(n).joined(separator: " ") }
        func other(_ i: Int) -> Bool { turns.indices.contains(i) && turns[i].speakerID != id }
        var count = 0
        for (i, turn) in turns.enumerated() where turn.speakerID == id {
            // Q-3: widened from the last 10 words, so a name several
            // sentences before the end of a long turn ("…René, you're going
            // to have some additional information…") still counts.
            if other(i - 1), mentions(name, in: words(turns[i - 1].text, last: 25)) { count += 1 }
            if other(i + 1), mentions(name, in: words(turns[i + 1].text, first: 6)) { count += 1 }
            if introduces(name, in: turn.text) { count += 1 }
        }
        return count
    }

    /// Whether any word of `text` could be `name` (see `NameMatch`). Only
    /// capitalised words count, as in `appears`, unless the text has no
    /// capitals at all: otherwise "the" would be a short form of Theodore and
    /// "mir" of Miriam.
    static func mentions(_ name: String, in text: String) -> Bool {
        let anyCapital = text.contains { $0.isUppercase }
        return text.split { !$0.isLetter }.contains { word in
            (!anyCapital || word.first?.isUppercase == true) && NameMatch.matches(spoken: String(word), name: name)
        }
    }

    /// A self-introduction naming `name`: "I'm Tom", "this is Tom", or the
    /// German equivalents ("ich bin", "hier ist", "hier spricht", "mein Name
    /// ist", "ich heiße"), which the English-only pattern used to miss.
    private static let introPattern = try! NSRegularExpression(
        pattern: #"(?i:i'm|i am|this is|my name is|it's|ich bin|hier ist|hier spricht|mein name ist|ich hei(?:ß|ss)e)\s+(\S+)"#)

    static func introduces(_ name: String, in text: String) -> Bool {
        selfIntroducedNames(in: text).contains { mentions(name, in: $0) }
    }

    /// The capitalised words right after a self-introduction pattern ("I'm
    /// Tom", "ich bin Tom"), whoever they are. Q-3: `AddressedNames` uses
    /// this to vote for the speaker's own turn without checking one name at
    /// a time, as `introduces` does.
    static func selfIntroducedNames(in text: String) -> [String] {
        let ns = text as NSString
        var out: [String] = []
        for match in introPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let word = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:"))
            // "Ich bin mir sicher" isn't Miriam: the name must be capitalised
            // (unless the whole line is lowercase, see `mentions`).
            guard word.first?.isUppercase == true || !text.contains(where: \.isUppercase) else { continue }
            out.append(word)
        }
        return out
    }

    /// Unnamed voices that aren't you.
    static func candidates(in meeting: Meeting) -> [Speaker] {
        meeting.speakers.filter { ($0.name ?? "").isEmpty && !Speaker.isYou($0, in: meeting.speakers) }
    }

    static func prompt(meeting: Meeting, candidates: [Speaker], attendees: [Attendee], userName: String?,
                       limit: Int) -> String {
        let ids = Set(candidates.map(\.id))
        let lines: [(start: Double, text: String)] = meeting.turns.map { turn in
            let label: String
            if let id = turn.speakerID, ids.contains(id) {
                label = id
            } else if Speaker.isMe(turn, in: meeting.speakers) {
                label = "Me"
            } else {
                label = meeting.displayName(for: turn)
            }
            return (turn.start, "\(label): \(turn.text)")
        }
        let me = userName ?? attendees.first(where: \.isMe)?.name
        let names = attendees.map(\.name) + (me.map { [$0] } ?? [])
        let transcript = compact(lines, names: names, limit: limit)
        let list = candidates.map(\.id).joined(separator: ", ")
        let others = attendees.filter { !$0.isMe }.map(\.name)
        var intro = others.isEmpty
            ? "The names of the participants are not known in advance.\n"
            : "Invited to the meeting: \(others.joined(separator: ", ")).\n"
        intro += me.map { "\"Me\" is the user, \($0). Nobody else is \($0).\n" } ?? "\"Me\" is the user.\n"
        // Q-3: evidence first, so the model quotes before it names — and the
        // example shows that order too.
        let example = candidates.prefix(2).enumerated().map { i, s in
            i == 0 ? "\"\(s.id)\": {\"evidence\": \"…\", \"name\": \"…\"}" : "\"\(s.id)\": null"
        }.joined(separator: ", ")
        return """
            \(intro)Each line of the transcript starts with who is speaking. \(list) are different people \
            whose names are not known yet.

            Transcript:
            \(transcript)

            For each of \(list), give their name if the transcript makes it clear. A name may be a short \
            form or a misspelling of an invited name ("Isa" for Isabelle, "Mathias" for Matthias) — give the \
            name as it was said, not the invited spelling. What someone does or talks about is never \
            evidence of who they are — only their name being said is. Good evidence:
            - someone is addressed by name and that speaker answers on the next line ("Tom, can you take this?" then S2: "Sure." means S2 is Tom);
            - someone is thanked or greeted by name right after they spoke;
            - a speaker introduces themselves ("I'm Tom", "this is Tom").
            People say the names of others, not their own: a name a speaker says is almost never that speaker's name.
            Answer null for a speaker when the evidence is missing, weak or contradictory. Never give one name to two speakers.

            Quote the evidence first, then give the name it points to, for example \
            {"evidence": "Tom, can you take this?", "name": "Tom"}. Answer with only this JSON object, \
            one key per speaker:
            {\(example)}
            """
    }

    /// Fits the transcript into `limit` characters. When it doesn't fit, keeps
    /// the turns around mentions of names (the one before, for thanks; the one
    /// after, for answers), then the first and last few minutes.
    static func compact(_ lines: [(start: Double, text: String)], names: [String], limit: Int,
                        edgeSeconds: Double = 180) -> String {
        let all = lines.map(\.text).joined(separator: "\n")
        guard all.count > limit, !lines.isEmpty else { return all }
        let words = Set(names.flatMap { $0.split(separator: " ").map(String.init) }.filter { $0.count > 1 })
            .union(addressedNames(in: all))
        var order: [Int] = []
        // Lines are "label: text"; look for names in the text only.
        let texts = lines.map { $0.text.split(separator: ":", maxSplits: 1).last.map(String.init) ?? $0.text }
        for (i, text) in texts.enumerated() where words.contains(where: { appears($0, in: text) }) {
            order += [i - 1, i, i + 1].filter { lines.indices.contains($0) }
        }
        let first = lines[0].start, last = lines[lines.count - 1].start
        order += lines.indices.filter { lines[$0].start - first < edgeSeconds }
        order += lines.indices.reversed().filter { last - lines[$0].start < edgeSeconds }

        var keep = Set<Int>(), used = 0
        for i in order where !keep.contains(i) {
            let cost = lines[i].text.count + 1
            if used + cost > limit { continue }
            keep.insert(i)
            used += cost
        }
        var out: [String] = []
        var previous: Int?
        for i in keep.sorted() {
            if let p = previous, i > p + 1 { out.append("…") } else if previous == nil, i > 0 { out.append("…") }
            out.append(lines[i].text)
            previous = i
        }
        return out.joined(separator: "\n")
    }

    private static let notNames: Set<String> = [
        "Okay", "Ok", "So", "Yes", "Yeah", "No", "Well", "Right", "Sure", "Thanks", "Thank", "Great", "Alright",
        "Sorry", "Actually", "Hi", "Hey", "And", "But", "I", "Then", "Fine", "Good", "Also", "Oh", "Hello", "Morning",
        "Bye", "Wait", "Please", "Now", "Look", "Listen", "Guys", "Everyone", "All", "Team", "Folks",
    ]

    /// Capitalized words used to address someone ("thanks Tom", "Tom, can you…",
    /// "…, Tom?"), for finding mentions when there's no attendee list.
    static func addressedNames(in text: String) -> Set<String> {
        let patterns = [
            #"\b(?:[Tt]hanks|[Tt]hank you|[Hh]i|[Hh]ey|[Mm]orning|[Bb]ye|[Oo]ver to you)[, ]+([A-Z][a-z]+)\b"#,
            #"(?:^|(?<=[.?!:,]\s))([A-Z][a-z]+),"#,
            #",\s*([A-Z][a-z]+)[.?!]"#,
        ]
        var out = Set<String>()
        let ns = text as NSString
        for p in patterns {
            let regex = try! NSRegularExpression(pattern: p, options: [.anchorsMatchLines])
            for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                out.insert(ns.substring(with: m.range(at: 1)))
            }
        }
        return out.subtracting(notNames)
    }

    static func containsWord(_ text: String, _ word: String, caseSensitive: Bool = true) -> Bool {
        let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: word) + "(?![\\p{L}\\p{N}])"
        return text.range(of: pattern, options: caseSensitive ? [.regularExpression] : [.regularExpression, .caseInsensitive]) != nil
    }

    // MARK: Parsing and guarding

    /// Reads the model's JSON answer, tolerating reasoning, code fences and
    /// text around it. Keeps only the speaker IDs asked about.
    static func parse(_ answer: String, validIDs: Set<String>) -> [String: Guess] {
        var text = answer
        while let open = text.range(of: "<think>") {
            if let close = text.range(of: "</think>", range: open.upperBound..<text.endIndex) {
                text.removeSubrange(open.lowerBound..<close.upperBound)
            } else {
                text.removeSubrange(open.lowerBound..<text.endIndex)
            }
        }
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let object = try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: Any]
        else { return [:] }
        var out: [String: Guess] = [:]
        for (key, value) in object {
            guard let id = normalizedID(key), validIDs.contains(id) else { continue }
            var name: String?
            var evidence = ""
            if let dict = value as? [String: Any] {
                name = dict["name"] as? String
                evidence = (dict["evidence"] as? String) ?? ""
            } else if let string = value as? String {
                name = string
            }
            guard let name = name?.trimmingCharacters(in: CharacterSet(charactersIn: " \"'.,:;!?\n")),
                  !name.isEmpty, !noGuessStrings.contains(name.lowercased()) else { continue }
            out[id] = Guess(name: name, evidence: evidence.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return out
    }

    /// Q-3: strings the model sometimes gives instead of a JSON `null`.
    private static let noGuessStrings: Set<String> = ["null", "none", "unknown", "n/a", "-"]

    /// "S2", "s2", "Speaker 2" → "S2".
    private static func normalizedID(_ key: String) -> String? {
        let k = key.trimmingCharacters(in: .whitespaces).lowercased()
        let digits = k.drop { !$0.isNumber }
        guard let n = Int(digits), k.hasPrefix("s") else { return nil }
        return "S\(n)"
    }

    private static let placeholders: Set<String> = [
        "me", "them", "you", "user", "unknown", "null", "none", "n/a", "-", "speaker", "someone", "everyone",
    ]

    /// Whether a guess was kept, or dropped and why (see `acceptDetailed`).
    enum AcceptResult: Equatable {
        case kept(Guess)
        case dropped(String)
    }

    /// The guard rules: a name must be an attendee's (by `NameMatch`, so "Isa"
    /// or "Mathias" reach "Isabelle Kramer" or "Matthias Vogel") or appear
    /// verbatim in the transcript, is never yours (even by fuzzy match: "Asan"
    /// must not name someone else Ahsan), and never goes to two speakers (or
    /// to a speaker when someone already has it). Attendee names keep the
    /// calendar's spelling. "Verbatim" is case-sensitive, so "will" and "mark"
    /// don't count for Will and Mark (see `appears`).
    static func accept(_ guesses: [String: Guess], speakers: [Speaker], attendees: [Attendee], userName: String?,
                       transcript: String) -> [String: Guess] {
        acceptDetailed(guesses, speakers: speakers, attendees: attendees, userName: userName, transcript: transcript)
            .compactMapValues { result in
                if case .kept(let g) = result { return g }
                return nil
            }
    }

    /// `accept`, but keeping the reason for every drop.
    static func acceptDetailed(_ guesses: [String: Guess], speakers: [Speaker], attendees: [Attendee], userName: String?,
                               transcript: String) -> [String: AcceptResult] {
        var yourNames = Set<String>(), yourFirstNames = Set<String>()
        for name in [userName].compactMap({ $0 }) + attendees.filter(\.isMe).map(\.name) {
            yourNames.insert(name.lowercased())
            if let first = name.split(separator: " ").first { yourFirstNames.insert(String(first).lowercased()) }
        }
        let others = attendees.filter { !$0.isMe }
        let taken = Set(speakers.compactMap { $0.name?.lowercased() })

        var out: [String: AcceptResult] = [:]
        for (id, guess) in guesses {
            guard let speaker = speakers.first(where: { $0.id == id }) else { out[id] = .dropped("no such speaker"); continue }
            guard (speaker.name ?? "").isEmpty else { out[id] = .dropped("already named"); continue }
            let name = guess.name
            let lower = name.lowercased()
            let firstWord = String(name.split(separator: " ").first ?? "")
            guard name.count <= 40, !name.contains(where: \.isNumber) else { out[id] = .dropped("not a name"); continue }
            guard !placeholders.contains(lower), !lower.hasPrefix("speaker") else { out[id] = .dropped("just a placeholder"); continue }
            let isYours = yourNames.contains(lower) || yourFirstNames.contains(lower) || yourNames.contains(firstWord.lowercased())
                || yourFirstNames.contains { NameMatch.matches(spoken: firstWord, name: $0) }
            guard !isYours else { out[id] = .dropped("that's you"); continue }
            guard !taken.contains(lower) else { out[id] = .dropped("someone already has that name"); continue }

            if let attendee = others.first(where: { $0.name.lowercased() == lower }) {
                out[id] = .kept(Guess(name: attendee.name, evidence: guess.evidence))
            } else if let first = others.lazy.compactMap({ $0.name.split(separator: " ").first.map(String.init) })
                        .first(where: { $0.lowercased() == lower }) {
                out[id] = .kept(Guess(name: first, evidence: guess.evidence))
            } else {
                let fuzzy = others.filter { attendee in
                    guard let attFirst = attendee.name.split(separator: " ").first.map(String.init) else { return false }
                    return NameMatch.matches(spoken: firstWord, name: attFirst)
                }
                if fuzzy.count == 1 {
                    out[id] = .kept(Guess(name: fuzzy[0].name, evidence: guess.evidence))
                } else if appears(name, in: transcript) {
                    out[id] = .kept(guess) // several fuzzy matches, or no attendees to check against: keep it as said
                } else {
                    out[id] = .dropped(fuzzy.isEmpty ? "not an attendee and not said in the transcript"
                                                      : "matches more than one attendee")
                }
            }
        }
        // Never the same name twice: when the model gives one name to two
        // speakers, it doesn't know which, so neither gets it.
        var counts: [String: Int] = [:]
        for case .kept(let guess) in out.values { counts[guess.name.lowercased(), default: 0] += 1 }
        for id in out.keys {
            if case .kept(let guess) = out[id], counts[guess.name.lowercased()] != 1 {
                out[id] = .dropped("given to more than one speaker")
            }
        }
        return out
    }

    /// Whether `name` is said in the transcript. Case counts, except on lines
    /// without any capitals: on muffled call audio whisper sometimes writes
    /// whole lines in lowercase, names included.
    static func appears(_ name: String, in transcript: String) -> Bool {
        transcript.split(separator: "\n").contains { line in
            let line = String(line)
            return containsWord(line, name, caseSensitive: line.lowercased() != line)
        }
    }

    static func apply(_ guesses: [String: Guess], to speakers: [Speaker]) -> [Speaker] {
        guesses.reduce(speakers) { speakers, entry in
            SpeakerEdit.rename(speakers, id: entry.key, to: entry.value.name, source: .guessed,
                               evidence: entry.value.evidence.isEmpty ? nil : entry.value.evidence)
        }
    }
}

// MARK: - App state

extension AppState {
    func renameSpeaker(meetingID: String, speakerID: String, name: String) {
        editSpeakers(meetingID) { _, speakers in
            // A name is one person: a voice that only had it as a guess (or
            // by voice) gives it up. A confirmed one keeps it; that's a merge
            // the user can do on purpose.
            for other in speakers where other.id != speakerID && other.nameSource != .confirmed
                && other.name?.lowercased() == name.lowercased() {
                speakers = SpeakerEdit.rename(speakers, id: other.id, to: nil, source: nil)
            }
            speakers = SpeakerEdit.rename(speakers, id: speakerID, to: name, source: .confirmed)
        }
    }

    func confirmSpeaker(meetingID: String, speakerID: String) {
        editSpeakers(meetingID) { _, speakers in
            guard let name = speakers.first(where: { $0.id == speakerID })?.name else { return }
            speakers = SpeakerEdit.rename(speakers, id: speakerID, to: name, source: .confirmed)
        }
    }

    func clearSpeakerName(meetingID: String, speakerID: String) {
        editSpeakers(meetingID) { _, speakers in
            speakers = SpeakerEdit.rename(speakers, id: speakerID, to: nil, source: nil)
        }
    }

    func mergeSpeakers(meetingID: String, from: String, into: String) {
        editSpeakers(meetingID, mergedInto: [from: into]) { turns, speakers in // E-1
            (turns, speakers) = SpeakerEdit.merge(turns: turns, speakers: speakers, from: from, into: into)
        }
    }

    /// Names you've confirmed in recent meetings, newest first, for suggestions.
    func recentSpeakerNames(limit: Int = 12) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for m in meetings {
            for s in m.speakers where s.nameSource == .confirmed {
                guard let name = s.name, seen.insert(name.lowercased()).inserted else { continue }
                out.append(name)
                if out.count == limit { return out }
            }
        }
        return out
    }

    /// Applies a change to a meeting's turns and speakers and saves them.
    /// E-1: the notes are patched to the new names in place (NotesPatch),
    /// instead of being flagged as out of date.
    private func editSpeakers(_ id: String, mergedInto: [String: String] = [:],
                              _ change: (inout [Turn], inout [Speaker]) -> Void) {
        guard !isBusy(id), var meeting = store.load(Prefs.storageURL.appendingPathComponent(id)) else { return }
        let before = (turns: meeting.turns, speakers: meeting.speakers)
        change(&meeting.turns, &meeting.speakers)
        guard meeting.turns != before.turns || meeting.speakers != before.speakers else { return }
        do {
            meeting = try NotesPatch.saveSpeakerEdit(meeting, before: before, mergedInto: mergedInto, store: store) // E-1
            // R3-3: names you set teach the voice library, if you opted in.
            VoiceStore.shared.learn(meetingID: id, before: before.speakers, after: meeting.speakers,
                                    attendees: meeting.info.attendees ?? [])
            // W-1: a confirmed name spreads to the same voice in other meetings.
            let confirmed = VoicePropagation.newlyConfirmed(before: before.speakers, after: meeting.speakers)
            if !confirmed.isEmpty { propagateVoices(meetingID: id, names: confirmed) }
        } catch {
            NSLog("Earl: couldn't save speaker names: \(error)")
        }
        store.saveMarkdown(meeting)
        reload()
        reminders.loadSent(meetings: meetings) // E-1: renamed to-dos keep their reminders
    }

    /// Runs the guesser during processing. Failures are logged, never fatal.
    func guessSpeakerNames(_ meeting: Meeting) async -> [Speaker] {
        let attendees = meeting.info.attendees ?? []
        let log = LogFile(meeting.folder.appendingPathComponent("whisper.log"))
        guard !SpeakerNameGuesser.candidates(in: meeting).isEmpty else {
            log.write("Addressed: none")
            log.write("Name guesses: none")
            log.write("Guessed names: none")
            return meeting.speakers
        }
        // Q-3: names from direct address first (no LLM), then the model for
        // whatever's left.
        let guesser = SpeakerNameGuesser()
        let result = await SpeakerNameGuesser.combinedGuess(meeting: meeting, attendees: attendees,
                                                             userName: Prefs.userName, guesser: guesser)
        log.write("Addressed: " + SpeakerNameGuesser.addressedLogLine(result.addressed))
        if let error = result.modelError {
            log.write("Guessing speaker names failed: \(error)")
        }
        // Q-2: log the model's raw guesses and why each was dropped, so
        // "Guessed names: none" doesn't hide whether the model found
        // nothing or the checks dropped everything it found.
        log.write("Name guesses: " + SpeakerNameGuesser.logLine(result.modelOutcomes))
        // V-1: one name per person across voice, address and the model.
        let (guesses, dropped) = result.final(speakers: meeting.speakers)
        log.write("Guessed names: " + NameCollisions.logLine(kept: guesses, dropped: dropped))
        return SpeakerNameGuesser.apply(guesses, to: meeting.speakers)
    }
}

// MARK: - Views

struct SpeakerNamePopover: View {
    @EnvironmentObject private var state: AppState
    let meeting: Meeting
    let speakerID: String
    var dismiss: () -> Void
    @State private var name = ""
    @FocusState private var focused: Bool
    /// R3-3: the one-time question after the first name you confirm.
    @State private var askingConsent = false

    private var speaker: Speaker? { meeting.speakers.first { $0.id == speakerID } }

    /// Attendees nobody has yet, then names from recent meetings, filtered by what's typed.
    private var suggestions: [String] {
        let used = Set(meeting.speakers.compactMap { $0.name?.lowercased() })
        let attendees = (meeting.info.attendees ?? []).filter { !$0.isMe }.map(\.name)
        var seen = used, out: [String] = []
        for n in attendees + state.recentSpeakerNames() where seen.insert(n.lowercased()).inserted {
            out.append(n)
        }
        let typed = name.trimmingCharacters(in: .whitespaces)
        let filtered = typed.isEmpty ? out : out.filter {
            $0.localizedCaseInsensitiveContains(typed) && $0.lowercased() != typed.lowercased()
        }
        return Array(filtered.prefix(6))
    }

    private var mergeTargets: [Speaker] {
        guard let speaker else { return [] }
        return meeting.speakers.filter { $0.id != speakerID && $0.track == speaker.track }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if askingConsent {
                VoiceConsentPrompt(meetingID: meeting.id, done: dismiss) // R3-3
            } else if let speaker {
                Text("Who is \(Speaker.displayName(for: speaker.sampleTurn, in: meeting.speakers))?")
                    .font(.paperTitle)
                    .foregroundStyle(Paper.ink)
                if speaker.isGuess {
                    Text("Earl's guess" + (speaker.evidence.map { ": \($0)" } ?? "."))
                        .font(.system(size: 13))
                        .foregroundStyle(Paper.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if speaker.isRecognised, let help = speaker.recognisedHelp { // R3-3
                    Label(help, systemImage: "waveform")
                        .font(.system(size: 13))
                        .foregroundStyle(Paper.inkMuted)
                }
                HStack {
                    TextField("Name", text: $name, prompt: Text("Name"))
                        .textFieldStyle(.roundedBorder)
                        .focused($focused)
                        .onSubmit(save)
                    Button("Save", action: save)
                        .buttonStyle(.paperPrimary)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || name == speaker.name
                                  || state.isBusy(meeting.id))
                }
                if !suggestions.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(suggestions, id: \.self) { suggestion in
                            Button {
                                name = suggestion
                                save()
                            } label: {
                                Text(suggestion).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(HoverRowStyle())
                        }
                    }
                }
                Divider()
                HStack {
                    if speaker.isGuess || speaker.isRecognised { // R3-3: voice matches confirm the same way
                        Button("Confirm") {
                            state.confirmSpeaker(meetingID: meeting.id, speakerID: speakerID)
                            finish()
                        }
                    }
                    if !mergeTargets.isEmpty {
                        Menu("Merge with…") {
                            ForEach(mergeTargets) { target in
                                Button(Speaker.displayName(for: target.sampleTurn, in: meeting.speakers)) {
                                    state.mergeSpeakers(meetingID: meeting.id, from: speakerID, into: target.id)
                                    dismiss()
                                }
                            }
                        }
                        .fixedSize()
                        .help("For when one person was split in two")
                    }
                    Spacer()
                    if speaker.name != nil {
                        Button("Clear Name") {
                            state.clearSpeakerName(meetingID: meeting.id, speakerID: speakerID)
                            dismiss()
                        }
                    }
                }
                .buttonStyle(.bordered)
                .disabled(state.isBusy(meeting.id))
            } else {
                Text("This speaker is gone. Probably merged.").foregroundStyle(Paper.inkMuted)
            }
        }
        .padding(16)
        .frame(width: 320)
        .onAppear {
            name = speaker?.name ?? ""
            focused = true
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        state.renameSpeaker(meetingID: meeting.id, speakerID: speakerID, name: trimmed)
        finish()
    }

    /// R3-3: after the first name you confirm, asks once about remembering voices.
    private func finish() {
        if VoiceConsentPrompt.shouldAsk { askingConsent = true } else { dismiss() }
    }
}

/// Above the briefing after names changed: the notes still use the old ones.
/// E-1: renames now patch the notes in place, so the front page no longer
/// shows this on its own; "Summarize again" stays in the More menu.
struct NamesChangedNotice: View {
    @EnvironmentObject private var state: AppState
    let meeting: Meeting

    var body: some View {
        HStack(spacing: 12) {
            Text("Names changed since the notes were written.")
                .font(.system(size: 14))
                .foregroundStyle(Paper.inkMuted)
            Spacer(minLength: 8)
            Button("Update the notes") { state.resummarize(meeting.id) }
                .buttonStyle(.paperSecondary)
                .disabled(state.isBusy(meeting.id))
        }
    }
}

/// The R2-3 line in the Speakers card.
struct GuessNamesToggle: View {
    @AppStorage(Prefs.Key.guessSpeakerNames) private var guess = true

    var body: some View {
        Toggle("Guess names from the conversation", isOn: $guess)
            .help("After transcribing, the local AI suggests names from how people address each other.")
    }
}
