import SwiftUI

// R2-7: reliable, better meeting notes. The prompt, the check that an answer
// is usable, the notes language and model settings, and speed from real runs.

// MARK: - Prompt

/// Everything the notes model is told, in one place so it can be measured
/// (see NotesEvalTests).
struct NotesPrompt {
    var system = Self.standardSystem
    /// Say whose view the transcript is from, and that the person who agreed
    /// to a task owns it, not the one who asked. Small models get this backwards.
    var perspective = true
    /// Put the language rule in the user message, right before the format:
    /// small models ignore it in the system prompt.
    var languageRule = true
    /// ISO code of the notes language; nil means the transcript's language.
    var language: String?
    /// Who "Me" is.
    var userName: String?
    /// S-1: earlier meetings of the series (`SeriesContext.text`), put before the transcript.
    var seriesContext: String?
    /// S-1: the shape of the notes.
    var kind = MeetingKind.general

    static let standardSystem = """
        You are a meeting assistant. You write concise, accurate meeting notes in Markdown. \
        In transcripts, "Me" is the user and "Them" is everyone else on the call (possibly several people). \
        Labels like "Speaker 2" are distinct people whose names aren't known; refer to them by these labels. \
        The people invited to the meeting may not all have spoken, and not everyone who spoke was invited: \
        give a "Speaker N" a name only when the transcript's own lines show who it is, never by matching \
        them to an invitee by elimination or role. Otherwise keep the label, including for action item owners. \
        Never invent facts that are not in the transcript.
        """

    var perspectiveLine: String {
        let me = userName.map { "\($0) ('Me')" } ?? "the user ('Me')"
        return """
            The transcript is from the point of view of \(me). When someone asks another person to do \
            something, the action item belongs to the person who agreed to do it, not the one who asked. \
            Only list action items someone clearly agreed to or was clearly assigned.
            """
    }

    var languageLine: String {
        guard let language else { return "Write the notes in the same language as the transcript." }
        return "Write the notes in \(NotesLanguage.englishName(language))."
    }

    /// Notes on one part of a long meeting.
    func part(_ index: Int, of count: Int, intro: String, chunk: String) -> String {
        var rules = ""
        if perspective { rules += perspectiveLine + "\n\n" }
        if languageRule { rules += languageLine + " " }
        // S-1: the earlier meetings, so the parts keep what was said about them.
        let earlier = seriesBlock.isEmpty ? ""
            : seriesBlock + "Also note anything said today about these earlier to-dos and questions.\n\n"
        return """
            \(intro)\(earlier)This is part \(index) of \(count) of a meeting transcript. \
            \(partAsk)

            \(chunk)

            \(rules)Output only the bullets.
            """
    }

    /// The final notes, from the transcript or the notes on its parts.
    func final(intro: String, material: String) -> String {
        var out = intro + seriesBlock + material + "\n\n" // S-1: earlier meetings before today's
        if perspective { out += perspectiveLine + "\n\n" }
        if kind == .oneOnOne { out += oneOnOneLine + "\n\n" } // S-1
        if let kindLine { out += kindLine + "\n\n" } // K-1
        if languageRule { out += languageLine + " Keep the headings in English, exactly as shown.\n\n" }
        out += """
            Write the meeting notes in exactly this format:

            TITLE: <a short title for the meeting, at most 6 words>
            HEADLINE: <what happened, one sentence, at most 12 words>


            """
        out += summarySection + sinceSection // S-1
        out += sections // K-1
        out += "\n\nLeave out any section that would be empty (except \(summaryHeading))."
        // Said again after the English template, which otherwise pulls models
        // with thinking off into English (Bonsai 27B: 0 of 3 German notes without it).
        if languageRule {
            let language = language.map(NotesLanguage.englishName) ?? "the language of the transcript"
            out += "\n\nWrite the title, the headline and every bullet point in \(language). Only the headings stay in English."
        }
        return out
    }
}

// MARK: - Remembering and shaping (S-1)

extension NotesPrompt {
    /// Small models copy context into the notes.
    static let noCopyRule = "Never copy earlier items into today's notes unless they were discussed again today."

    /// Without it, gemma-4-e4b left the section out 2 of 3 times (SeriesNotesEvalTests).
    /// qwen3.8-27b on a real weekly marked a to-do done "implicitly, as nobody
    /// raised it as a blocker" and explained itself in brackets: done must be
    /// said, never inferred, and items nobody mentioned stay out.
    static let sinceRule = """
        When today's transcript mentions an earlier to-do or question, say what happened to it under \
        "## Since last time": "- Done: <the to-do, in a few words>" only when someone says today that it is \
        finished, else "- <the to-do or question, in a few words>: <what moved>". Never conclude that something \
        is done because nobody mentioned it or it wasn't raised as a problem. Leave out earlier items nobody \
        talked about today. One short line per item, no explanations in brackets.
        """

    /// The earlier meetings and the rule that keeps them out of today's notes.
    var seriesBlock: String {
        guard let seriesContext, !seriesContext.isEmpty else { return "" }
        return seriesContext + "\n\n" + Self.noCopyRule + " " + Self.sinceRule + "\n\n"
    }

    /// Stand-ups go round the table instead of summarising.
    var summaryHeading: String { kind == .standup ? "Round the table" : "Summary" }

    var summarySection: String {
        switch kind {
        case .standup: "## Round the table\n- Name: what they're on, any blocker (one bullet per person who spoke)\n\n"
        case .townHall: "## Summary\n<3-5 bullet points: the main messages>\n\n" // K-1
        case .talk: "## Summary\n<3-5 bullet points: what was presented and its main argument>\n\n" // K-1
        default: "## Summary\n<3-6 bullet points covering what the meeting was about>\n\n"
        }
    }

    /// Only with earlier meetings to compare against.
    var sinceSection: String {
        guard !seriesBlock.isEmpty else { return "" }
        return """
            ## Since last time
            <bullet points: what moved on the earlier open to-dos and questions that came up today; \
            start a bullet with "Done:" only if today's transcript says that to-do is finished. Plain bullets, \
            no checkboxes. Leave out this section if nothing earlier came up.>


            """
    }

    var oneOnOneLine: String {
        let me = userName.map { "\($0) ('Me')" } ?? "the user ('Me')"
        return "This is a one-to-one. Write the summary from the point of view of \(me): what they learned and what they owe."
    }
}

// MARK: - The shape of the notes (K-1)

extension NotesPrompt {
    /// Who "Me" is in an owner: the name, so the to-do reads as yours.
    private var meOwner: String { userName ?? "Me" }

    /// What a part of a long meeting should collect.
    var partAsk: String {
        let what = switch kind {
        case .townHall:
            "the main messages, announcements (news, changes, dates, numbers), anything the audience was asked to do, and questions asked with the answers given"
        case .talk:
            "the main points, ideas, facts and recommendations worth remembering, anything the audience was asked to do, and questions asked with the answers given"
        default:
            "topics discussed, key points, decisions, action items (with who owns them) and open questions"
        }
        return "Extract detailed bullet-point notes: \(what)."
    }

    /// Listening kinds: real Q&A only, and "For you" only for real asks. On a
    /// real all-hands qwen3.8-27b put security advice ("check the URL") and
    /// "no questions from the audience" in; on a demo, "ask the team if you
    /// have questions".
    static let listeningRule = """
        "For you" is for concrete things to do, ideally with a date (vote by the 18th, fill in the survey): \
        general advice, good practice and invitations like "reach out if you have questions" are not to-dos; \
        put advice worth keeping with the other points, and leave out "For you" if nothing concrete was asked. \
        Under "Questions asked", only questions someone actually asked; leave the section out if there were none.
        """

    /// Said again in the template, where small models look.
    static let forYouHint = "a concrete thing the audience was asked to do, with any date (never advice or \"reach out if you have questions\"; no such thing, no section)"
    static let questionsHint = "- question → the answer given, on one line (only questions someone asked; none asked, no section)"

    /// What kind of meeting it was, and what that means for the notes.
    var kindLine: String? {
        switch kind {
        case .townHall:
            return """
                This was a town hall: leaders or organisers informed a large audience. An audience decides nothing, \
                so there are no decisions. Announcements are news, changes, dates and numbers that were shared. \
                Under "For you", list only what the audience or \(meOwner) was asked to do; the speakers' own \
                to-dos are not the audience's. \(Self.listeningRule)
                """
        case .talk:
            return """
                This was a talk or demo: one or two people presented to listeners, \(meOwner) among them. Nothing \
                was decided by the listeners. Key points are what's worth remembering: ideas, facts, \
                recommendations, numbers. The presenters' own to-dos (their slides, their follow-ups) are not \
                \(meOwner)'s: under "For you", list only what the audience was asked to do or what \(meOwner) \
                offered to do. \(Self.listeningRule)
                """
        case .general, .standup:
            return """
                Decisions are only what the people in this meeting agreed or decided together today; what someone \
                presented, explained or announced is not a decision.
                """
        case .oneOnOne:
            return nil
        }
    }

    /// The sections after the summary (and "Since last time").
    var sections: String {
        switch kind {
        case .townHall:
            return """
                ## Announcements
                <bullet points: what was announced, with dates and numbers>

                ## For you
                - [ ] \(meOwner): \(Self.forYouHint)

                ## Questions asked
                \(Self.questionsHint)
                """
        case .talk:
            return """
                ## Key points
                <bullet points: ideas, facts and recommendations worth remembering>

                ## Questions asked
                \(Self.questionsHint)

                ## For you
                - [ ] \(meOwner): \(Self.forYouHint)
                """
        default:
            return """
                ## Decisions
                <bullet points>

                ## Action items
                - [ ] Name: task (write the owner's name plainly, without brackets)

                ## Open questions
                <bullet points>
                """
        }
    }
}

// MARK: - Tidying a listening kind's notes (K-1)

enum NotesTidy {
    /// "Reach out if you have questions" isn't a to-do. qwen3.8-27b kept one
    /// in "For you" on a real demo even with the rule in the template.
    static let invitations = ["if you have questions", "if you have any questions", "any questions", "reach out",
                              "feel free", "if needed", "bei bedarf", "bei fragen", "bei weiteren fragen",
                              "falls fragen", "wenn fragen", "melden, falls", "jederzeit"]

    static func isInvitation(_ task: String) -> Bool {
        let t = task.lowercased()
        return invitations.contains { t.contains($0) }
    }

    /// Drops invitation to-dos under "For you", and the heading when nothing's left.
    static func withoutInvitations(_ markdown: String) -> String {
        var lines = markdown.components(separatedBy: "\n")
        var inForYou = false
        var heading: Int?
        var kept = 0
        var drop = IndexSet()
        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                if let heading, inForYou, kept == 0 { drop.insert(heading) }
                inForYou = FrontPageNotes.kind(of: trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)) == .actions
                    && trimmed.lowercased().contains("for you")
                heading = inForYou ? i : nil
                kept = 0
                continue
            }
            guard inForYou, !trimmed.isEmpty else { continue }
            if let item = ActionItems.parseLine(line, meetingID: "", index: i), isInvitation(item.text) {
                drop.insert(i)
            } else {
                kept += 1
            }
        }
        if let heading, inForYou, kept == 0 { drop.insert(heading) }
        for i in drop.reversed() { lines.remove(at: i) }
        return lines.joined(separator: "\n").replacingOccurrences(of: "\n\n\n\n", with: "\n\n")
            .replacingOccurrences(of: "\n\n\n", with: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Checking the answer

enum NotesCheck {
    /// Usable notes: a "## Summary" heading with something under a heading.
    /// Empty answers, answers that are only a TITLE line (both seen from a
    /// model loaded with too small a context) and free text all fail.
    static func isValid(_ output: String) -> Bool {
        let body = Summarizer.parse(output).markdown
        let lines = body.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        // S-1: a stand-up's summary is "Round the table".
        guard lines.contains(where: { $0.lowercased().hasPrefix("## summary") || $0.lowercased().hasPrefix("## round the table") })
        else { return false }
        return lines.contains { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    static let emptyMessage = """
        The summary model returned nothing, twice. Check that the model is loaded in LM Studio \
        (a larger context helps), then retry.
        """
}

// MARK: - Notes language

enum NotesLanguage {
    static let automatic = "auto"
    /// "Same as the meeting", English, German.
    static let options: [(code: String, name: String)] = [
        (automatic, "Same as the meeting"), ("en", "English"), ("de", "German"),
    ]

    /// The language to ask for: the setting, else the language Whisper heard.
    static func resolve(setting: String, detected: String?) -> String? {
        if setting != automatic { return setting }
        guard let detected, detected != automatic, !detected.isEmpty else { return nil }
        return detected
    }

    static func englishName(_ code: String) -> String {
        Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
    }
}

extension Prefs.Key {
    static let notesLanguage = "notesLanguage"
    static let nameModel = "nameGuessModel"
    static let modelSpeeds = "llmModelSpeeds"
    static let thinkingModels = "llmThinkingModels"
}

extension Prefs {
    static var notesLanguage: String {
        Prefs.defaults.string(forKey: Key.notesLanguage) ?? NotesLanguage.automatic
    }
    /// The model for name guessing; empty means the notes model.
    static var nameModel: String {
        let id = Prefs.defaults.string(forKey: Key.nameModel) ?? ""
        // "Same as notes": the model Earl writes notes with (D-3: Ollama's, or the one it chose).
        return id.isEmpty ? NotesEngine.model(for: NotesEngine.current, fallback: llmModel) : id
    }
    /// Models allowed to think before writing notes. Off by default: on a
    /// 30-minute synthetic meeting, Bonsai 27B took 292 s thinking and 83 s
    /// not, with the same owners; Qwen 3.8 27B took 112 s without thinking
    /// and 9 minutes with it on a real meeting (NotesEvalTests).
    static func notesThinking(_ model: String) -> Bool {
        // D-3: the built-in note writers never think (`reasoning_effort: "none"`); that's how they were chosen.
        if BuiltInModel.all.contains(where: { $0.id == model }) { return false }
        return (Prefs.defaults.stringArray(forKey: Key.thinkingModels) ?? []).contains(model)
    }
    static func setNotesThinking(_ on: Bool, for model: String) {
        var list = Set(Prefs.defaults.stringArray(forKey: Key.thinkingModels) ?? [])
        if on { list.insert(model) } else { list.remove(model) }
        Prefs.defaults.set(list.sorted(), forKey: Key.thinkingModels)
    }
}

// MARK: - Speed from real runs

/// Tokens per second and the time per 30 minutes of meeting, from the last
/// real summary with each model, for an honest estimate in Settings.
struct ModelSpeed: Equatable {
    var tokensPerSecond: Double
    var secondsPer30Minutes: Double

    static func all() -> [String: ModelSpeed] {
        let raw = Prefs.defaults.dictionary(forKey: Prefs.Key.modelSpeeds) as? [String: [Double]] ?? [:]
        return raw.compactMapValues { $0.count == 2 ? ModelSpeed(tokensPerSecond: $0[0], secondsPer30Minutes: $0[1]) : nil }
    }

    static func record(model: String, tokensPerSecond: Double?, seconds: Double, meetingSeconds: Double) {
        // Very short meetings say little about longer ones; the fixed cost dominates.
        guard meetingSeconds >= 120 else { return }
        var raw = Prefs.defaults.dictionary(forKey: Prefs.Key.modelSpeeds) as? [String: [Double]] ?? [:]
        raw[model] = [tokensPerSecond ?? 0, seconds * 1800 / meetingSeconds]
        Prefs.defaults.set(raw, forKey: Prefs.Key.modelSpeeds)
    }

    var text: String {
        let per = "About \(Format.duration(secondsPer30Minutes)) per 30-minute meeting"
        return tokensPerSecond > 0 ? "\(per) · \(Int(tokensPerSecond)) tok/s" : per
    }
}

// MARK: - Recommendation

enum ModelAdvice {
    /// The strongest general model that fits in memory: the most parameters,
    /// then the finer quantization. A model fits when its weights take under
    /// half the memory (45 %), which leaves room for the context and other apps.
    static func recommended(_ models: [LMStudioModel], memory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> String? {
        let fitting = models.filter { m in
            guard m.isLLM, let size = m.size_bytes, m.billions != nil else { return false }
            return Double(size) <= Double(memory) * 0.45
        }
        return fitting.max { a, b in
            let key = { (m: LMStudioModel) in (m.billions ?? 0, m.quantization?.bits_per_weight ?? 0, m.size_bytes ?? 0) }
            return key(a) < key(b)
        }?.key
    }

    /// "27B · Q4_K_M · 17.7 GB"
    static func sizeText(_ m: LMStudioModel) -> String {
        [m.params_string ?? m.billions.map { "\(Int($0))B" }, m.quantization?.name,
         m.size_bytes.map { Format.bytes($0) }]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

// MARK: - Settings

/// The models in the Summaries card, with sizes, the recommendation and speed.
struct NotesModelList: View {
    let models: [LLMModel]
    /// D-3: the model in use (Ollama's or the recommended one can differ from the setting).
    var active: String?
    @AppStorage(Prefs.Key.llmModel, store: Prefs.defaults) private var llmModel = Prefs.defaultLLMModel
    @AppStorage(Prefs.Key.llmURL, store: Prefs.defaults) private var llmURL = Prefs.defaultLLMURL
    @State private var details: [String: LMStudioModel] = [:]
    @State private var recommended: String?

    var body: some View {
        let speeds = ModelSpeed.all()
        VStack(spacing: 2) {
            ForEach(models) { row($0, speed: speeds[$0.id]) }
        }
        .task(id: models.map(\.id).joined() + models.map { $0.state ?? "" }.joined()) {
            let list = await LMStudioModels.list(baseURL: llmURL) ?? []
            details = Dictionary(list.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
            recommended = ModelAdvice.recommended(list)
        }
    }

    private func row(_ model: LLMModel, speed: ModelSpeed?) -> some View {
        let selected = (active ?? llmModel) == model.id
        let info = details[model.id]
        let size = info.map(ModelAdvice.sizeText) ?? model.quantization
        let context = (info?.loadedContext ?? model.loadedContextLength).map { "loaded with \($0 / 1024)k context" }
        return ListRow(selected: selected) {
            RadioMark(selected: selected)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.id).font(.settingsRowTitle)
                    if recommended == model.id {
                        Text("Recommended for notes")
                            .font(.paperLabel)
                            .foregroundStyle(Paper.ok)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Paper.ok.opacity(0.12), in: Capsule())
                    }
                }
                Text([size, model.isLoaded ? context ?? "loaded" : nil].compactMap { $0 }.joined(separator: " · "))
                    .font(.settingsNote)
                    .foregroundStyle(Paper.inkMuted)
                Text(speed?.text ?? "Speed untested")
                    .font(.settingsNote)
                    .foregroundStyle(Paper.inkMuted)
            }
            Spacer()
        }
        .onTapGesture { llmModel = model.id }
    }
}

/// Notes language and the model for name guessing, under the model list.
struct NotesOptions: View {
    let models: [LLMModel]
    /// D-3: the model in use; the setting when nil.
    var active: String?
    @AppStorage(Prefs.Key.notesLanguage, store: Prefs.defaults) private var notesLanguage = NotesLanguage.automatic
    @AppStorage(Prefs.Key.nameModel, store: Prefs.defaults) private var nameModel = ""
    @AppStorage(Prefs.Key.llmModel, store: Prefs.defaults) private var llmModel = Prefs.defaultLLMModel
    @AppStorage(Prefs.Key.llmURL, store: Prefs.defaults) private var llmURL = Prefs.defaultLLMURL
    @State private var thinking = false
    private var model: String { active ?? llmModel }
    @State private var canThink = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if canThink {
                Toggle("Let \(model.split(separator: "/").last.map(String.init) ?? model) think before writing notes",
                       isOn: $thinking)
                    .font(.settingsRow)
                    .onChange(of: thinking) { _, on in Prefs.setNotesThinking(on, for: model) }
                Text("Thinking takes several times longer and rarely changes who does what.")
                    .font(.settingsNote)
                    .foregroundStyle(Paper.inkMuted)
            }
            HStack {
                Text("Notes language").font(.settingsRow)
                Spacer()
                Picker("Notes language", selection: $notesLanguage) {
                    ForEach(NotesLanguage.options, id: \.code) { Text($0.name).tag($0.code) }
                }
                .labelsHidden()
                .fixedSize()
            }
            HStack {
                Text("Model for name guessing").font(.settingsRow)
                Spacer()
                Picker("Model for name guessing", selection: $nameModel) {
                    Text("Same as notes").tag("")
                    ForEach(models) { Text($0.id).tag($0.id) }
                    // Keep a model that isn't listed right now selectable.
                    if !nameModel.isEmpty && !models.contains(where: { $0.id == nameModel }) {
                        Text(nameModel).tag(nameModel)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            Text("Name guessing is a short task, so a small, fast model is usually enough.")
                .font(.settingsNote)
                .foregroundStyle(Paper.inkMuted)
        }
        .task(id: model) {
            thinking = Prefs.notesThinking(model)
            canThink = await LMStudioModels.model(baseURL: llmURL, id: model)?.reasons ?? false
        }
    }
}

/// The Details tab line about the model's context, e.g. "Loaded with 32k context by Earl".
enum NotesContextText {
    static func text(_ info: MeetingInfo) -> String? {
        guard let context = info.summaryContext else { return nil }
        return "Loaded with \(context / 1024)k context" + (info.summaryContextByEarl == true ? " by Earl" : "")
    }
}
