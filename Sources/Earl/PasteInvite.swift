import SwiftUI

// R3-4: some meetings live on calendars this Mac can't see (a Microsoft
// calendar inside Citrix, say). The user pastes the invite text instead, and
// Earl reads the title and attendees from it locally, without an LLM. The
// result lands in the same `MeetingInfo` fields a linked calendar event uses,
// so name suggestions, name guessing and the summary context pick it up.

// MARK: - Parser

enum InviteParser {
    /// Reads a subject and the invited people from pasted invite text.
    /// `userName` marks the attendee that is you.
    static func parse(_ text: String, userName: String? = nil) -> (title: String?, attendees: [Attendee]) {
        let lines = normalized(text).components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let hasPeopleHeader = lines.contains { header($0)?.kind == .people }

        var title: String?
        var chunks: [String] = []
        if hasPeopleHeader {
            // A structured invite (Outlook, forwarded mail): only header fields
            // and what comes before them are people. The body is free text.
            var inPeople = false
            var seenHeader = false
            var firstLine = true
            for line in lines {
                defer { if !line.isEmpty { firstLine = false } }
                if line.isEmpty || isSeparator(line) { inPeople = false; continue }
                if let h = header(line) {
                    seenHeader = true
                    inPeople = false
                    switch h.kind {
                    case .title: if title == nil { title = cleanTitle(h.value) }
                    case .people: chunks.append(h.value); inPeople = true
                    case .other: break
                    }
                } else if inPeople, let last = chunks.last,
                          line.contains("@") || line.contains(";") || last.hasSuffix(";") || last.hasSuffix(",") {
                    // Long lists wrap onto the next line.
                    chunks[chunks.count - 1] += " " + line
                } else if !seenHeader {
                    if line.contains("@") {
                        chunks.append(line) // Outlook's reading pane puts the organizer here.
                    } else if firstLine, title == nil {
                        title = cleanTitle(line) // …and the subject above it.
                    }
                }
            }
        } else {
            // A plain list: one or more names per line. Skip the Teams join block.
            var inBlock = false
            for line in lines where !line.isEmpty {
                if isSeparator(line) { inBlock.toggle(); continue }
                if inBlock || isBoilerplate(line) { continue }
                if let h = header(line) {
                    if h.kind == .title, title == nil { title = cleanTitle(h.value) }
                    continue
                }
                chunks.append(line)
            }
        }

        var people: [Person] = []
        for chunk in chunks {
            for segment in chunk.split(separator: ";") {
                for person in entries(in: String(segment)) { merge(person, into: &people) }
            }
        }
        let meKey = userName.map(key)
        let attendees = people.map { Attendee(name: $0.name, email: $0.email, isMe: meKey != nil && key($0.name) == meKey) }
        return (title, attendees)
    }

    // MARK: Lines

    enum Kind: Equatable { case title, people, other }

    private static let labels: [String: Kind] = {
        var map: [String: Kind] = [:]
        for l in ["subject", "betreff", "title", "titel", "thema", "topic", "invitation", "einladung",
                  "updated invitation", "aktualisierte einladung"] { map[l] = .title }
        for l in ["required", "erforderlich", "optional", "to", "an", "cc", "bcc", "from", "von",
                  "organizer", "organiser", "organisator", "attendees", "teilnehmer", "teilnehmende",
                  "participants", "invitees", "guests", "gäste", "eingeladen",
                  "required attendees", "optional attendees", "erforderliche teilnehmer", "optionale teilnehmer"] {
            map[l] = .people
        }
        for l in ["when", "wann", "where", "ort", "location", "date", "datum", "time", "zeit", "sent", "gesendet",
                  "start", "beginn", "end", "ende", "importance", "wichtigkeit", "priorität", "attachments",
                  "anlagen", "anhänge", "recurrence", "serienmuster", "wiederholung", "room", "raum",
                  "resources", "ressourcen", "status", "categories", "kategorien", "meeting id", "besprechungs-id",
                  "passcode", "kenncode", "time zone", "zeitzone", "show as", "anzeigen als", "reminder",
                  "erinnerung"] {
            map[l] = .other
        }
        return map
    }()

    /// "Erforderlich: Müller, Sarah; …" → (.people, "Müller, Sarah; …").
    static func header(_ line: String) -> (kind: Kind, value: String)? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let label = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
        guard let kind = labels[label] else { return nil }
        return (kind, line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
    }

    private static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
    }

    /// The underscore rules around a Teams join block.
    private static func isSeparator(_ line: String) -> Bool {
        line.count >= 5 && line.allSatisfy { "_-=–—".contains($0) }
    }

    private static func isBoilerplate(_ line: String) -> Bool {
        let l = line.lowercased()
        return l.contains("http") || l.contains("microsoft teams") || l.contains("teams meeting")
            || l.contains("teams-besprechung")
    }

    private static let titlePrefixes = ["wg:", "aw:", "fw:", "fwd:", "re:", "einladung:", "invitation:",
                                        "updated invitation:", "aktualisierte einladung:", "accepted:",
                                        "angenommen:", "tentative:", "mit vorbehalt angenommen:",
                                        "canceled:", "cancelled:", "abgesagt:"]

    static func cleanTitle(_ raw: String) -> String? {
        var t = raw.trimmingCharacters(in: .whitespaces)
        var stripped = true
        while stripped {
            stripped = false
            for p in titlePrefixes where t.lowercased().hasPrefix(p) {
                t = String(t.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)
                stripped = true
            }
        }
        // Google: "Sprint Planning @ Mon 22 Sep 2025 10:00 – 11:00 (CEST) (sarah@x.com)".
        if let at = t.range(of: " @ "), t[at.upperBound...].contains(where: \.isNumber) {
            t = String(t[..<at.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        guard !t.isEmpty, t.count <= 200, !t.contains("@") else { return nil }
        return t
    }

    // MARK: People

    struct Person: Equatable {
        var name: String
        var email: String?
        /// The name came from the address ("Sarah Mueller"), so a written one wins.
        var derived: Bool
    }

    private static let angled = try! NSRegularExpression(pattern: #"<\s*(?:mailto:)?([^<>\s@]+@[^<>\s]+)\s*>"#,
                                                          options: .caseInsensitive)
    private static let bare = try! NSRegularExpression(pattern: #"(?:mailto:)?([A-Za-z0-9._%+'-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,})"#)

    /// The people in one ';'-separated piece of a list.
    static func entries(in segment: String) -> [Person] {
        let ns = segment as NSString
        let matches = angled.matches(in: segment, range: NSRange(location: 0, length: ns.length))
        if !matches.isEmpty {
            // "Müller, Sarah <sarah@example.de>, Tom Weber <tom@example.de>"
            var out: [Person] = []
            var cursor = 0
            for m in matches {
                let name = ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
                if let p = person(name: name, email: ns.substring(with: m.range(at: 1))) { out.append(p) }
                cursor = m.range.location + m.range.length
            }
            out += names(in: ns.substring(from: cursor))
            return out
        }

        let emails = bare.matches(in: segment, range: NSRange(location: 0, length: ns.length))
        if !emails.isEmpty {
            // "sarah@example.de, tom@example.de" or "Sarah Müller sarah@example.de" or "sarah@example.de (Sarah Müller)".
            var rest = segment
            for m in emails.reversed() {
                rest = (rest as NSString).replacingCharacters(in: m.range, with: ",")
            }
            let addresses = emails.map { ns.substring(with: $0.range(at: 1)) }
            let leftover = rest.replacingOccurrences(of: "(", with: " ").replacingOccurrences(of: ")", with: " ")
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if addresses.count == 1, leftover.count == 1, let p = person(name: leftover[0], email: addresses[0]) {
                return [p]
            }
            return addresses.compactMap { person(name: "", email: $0) } + leftover.compactMap { person(name: $0, email: nil) }
        }

        return names(in: segment)
    }

    /// Names without addresses. Commas are either "Last, First" or a list.
    private static func names(in text: String) -> [Person] {
        let text = withoutAsides(text)
        let parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if parts.count == 2, parts[1].split(separator: " ").count == 1 {
            return person(name: text, email: nil).map { [$0] } ?? []
        }
        return parts.compactMap { person(name: $0, email: nil) }
    }

    /// A person from a written name and/or an address. `nil` for rooms,
    /// resources, and anything that doesn't read as a name.
    static func person(name raw: String, email rawEmail: String?) -> Person? {
        let email = rawEmail.map { $0.replacingOccurrences(of: "mailto:", with: "", options: [.caseInsensitive, .anchored]) }
        if let email, isResource(email: email) { return nil }
        let written = cleanName(raw)
        if !written.isEmpty {
            // A written name that isn't a person ("Raum 3.14", "FRA-T1-Room") means
            // the whole entry isn't one; don't fall back to the address.
            guard isName(written) else { return nil }
            return Person(name: written, email: email, derived: false)
        }
        guard let email, let derived = AttendeeName.fromEmail(email), isName(derived) else { return nil }
        return Person(name: derived, email: email, derived: true)
    }

    /// "'Müller, Sarah (Example GmbH)'" → "Sarah Müller".
    static func cleanName(_ raw: String) -> String {
        var s = withoutAsides(raw)
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:\"'“”„‘’«»"))
        s = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if s.filter({ $0 == "," }).count == 1 { s = AttendeeName.unflipped(s) }
        return s
    }

    /// Drops "(Example AG, Team 3)" and "[extern]": organisations and tags, not names.
    private static func withoutAsides(_ s: String) -> String {
        s.replacingOccurrences(of: #"\([^)]*\)|\[[^\]]*\]"#, with: " ", options: .regularExpression)
    }

    /// Words that never appear in a person's name, so lines holding them are
    /// boilerplate, roles or greetings.
    private static let notNameWords: Set<String> = [
        "teams", "microsoft", "besprechung", "meeting", "join", "click", "klicken", "hier", "here",
        "teilnehmen", "optionen", "options", "passcode", "kenncode", "id", "einwahl", "dial", "call",
        "anruf", "conference", "konferenz", "online", "zoom", "webex", "agenda", "tagesordnung",
        "organizer", "organisator", "organiser", "presenter", "referent", "referentin", "attendee",
        "teilnehmer", "guest", "gast", "extern", "external", "required", "optional", "erforderlich",
        "hallo", "hello", "hi", "team", "zusammen", "liebe", "lieber", "dear", "all", "bitte", "please",
        "danke", "thanks", "gruß", "grüße", "regards", "und", "and", "the", "die", "das", "mit", "with",
        "für", "for", "noreply", "calendar", "kalender", "accepted", "declined", "tentative",
        "zugesagt", "abgesagt", "none", "keine",
    ]

    static func isName(_ s: String) -> Bool {
        guard s.count <= 60, s.contains(where: \.isLetter), !s.contains(where: \.isNumber),
              !s.contains(where: { ":/@?!=#<>|\\*&+".contains($0) }) else { return false }
        let words = s.split(separator: " ")
        guard (1...5).contains(words.count),
              words.first?.first?.isUppercase == true, words.last?.first?.isUppercase == true else { return false }
        let tokens = s.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        return !tokens.contains { notNameWords.contains($0) || isRoomWord($0) }
    }

    private static func isRoomWord(_ t: String) -> Bool {
        ["room", "rooms", "raum", "räume", "resource", "ressource", "saal"].contains(t)
            || (t.count > 6 && (t.hasSuffix("raum") || t.hasSuffix("room") || t.hasSuffix("saal")))
    }

    private static func isResource(email: String) -> Bool {
        // By word, so "lisa.graumann@" stays a person.
        let local = email.lowercased().split(separator: "@").first.map(String.init) ?? ""
        if ["noreply", "no-reply", "donotreply"].contains(where: local.contains) { return true }
        return local.split(whereSeparator: { !$0.isLetter }).contains { isRoomWord(String($0)) }
    }

    // MARK: Duplicates

    /// Compares names across spellings: "Sarah Müller" = "sarah mueller".
    static func key(_ name: String) -> String {
        var s = name.lowercased()
        for (a, b) in [("ä", "ae"), ("ö", "oe"), ("ü", "ue"), ("ß", "ss")] { s = s.replacingOccurrences(of: a, with: b) }
        s = s.folding(options: .diacriticInsensitive, locale: nil)
        return s.split(whereSeparator: { !$0.isLetter }).joined(separator: " ")
    }

    private static func merge(_ p: Person, into people: inout [Person]) {
        let i = people.firstIndex { q in
            if let a = p.email, let b = q.email, a.lowercased() == b.lowercased() { return true }
            return key(p.name) == key(q.name)
        }
        guard let i else { people.append(p); return }
        if people[i].email == nil { people[i].email = p.email }
        if people[i].derived && !p.derived {
            people[i].name = p.name
            people[i].derived = false
        }
    }
}

// MARK: - Saving

extension MeetingInfo {
    /// Title or attendees without a calendar event behind them: pasted by the user.
    var hasPastedInvite: Bool {
        calendarEventID == nil && (calendarTitle != nil || !(attendees ?? []).isEmpty)
    }
}

extension AppState {
    /// Stores a pasted invite where a linked calendar event would go.
    func applyInvite(_ id: String, title: String?, attendees: [Attendee]) {
        guard var m = store.load(Prefs.storageURL.appendingPathComponent(id)) else { return }
        let title = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let newTitle = title?.isEmpty == false ? title : nil
        if let newTitle, m.info.titleIsDefault || m.info.title == m.info.calendarTitle {
            m.info.title = newTitle
            m.info.titleIsDefault = false
        }
        // A pasted invite replaces a linked event; the rest of the event no longer applies.
        m.info.calendarEventID = nil
        m.info.calendarStart = nil
        m.info.calendarEnd = nil
        m.info.organizer = nil
        m.info.meetingURL = nil
        m.info.calendarTitle = newTitle
        m.info.attendees = attendees.isEmpty ? nil : attendees
        // E-1: attendees don't change notes already written, so nothing is marked stale.
        try? store.save(m.info, in: m.folder)
        if m.info.status != .recording { store.saveMarkdown(m) }
        reload()
    }
}

// MARK: - Views

/// Paste the invite text, check what Earl found, apply.
struct PasteInviteSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let meeting: Meeting

    @State private var text = ""
    @State private var title = ""
    @State private var titleEdited = false
    @State private var attendees: [Attendee] = []
    @State private var skipped: Set<Attendee> = []
    @State private var applied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if applied { summarizeOffer } else { form }
        }
        .padding(20)
        .frame(width: 500)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Paste Invite").font(.headline)
                Text("Paste the subject, the attendee list or the whole invite. Earl reads it on this Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            TextEditor(text: $text)
                .font(.callout)
                .scrollContentBackground(.hidden)
                .frame(height: 120)
                .surface(padding: 8, radius: 10)
                .onChange(of: text) { _, new in parse(new) }

            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { preview }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                Button("Apply") { apply() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosen.isEmpty && title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Title", text: Binding(get: { title }, set: { title = $0; titleEdited = true }),
                      prompt: Text("No subject found"))
                .textFieldStyle(.roundedBorder)
            if attendees.isEmpty {
                Text("No names found yet. Earl looks for names, addresses and lines like \u{201C}Required:\u{201D}.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("\(chosen.count) of \(attendees.count) people")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(attendees, id: \.self) { a in
                            Toggle(isOn: binding(for: a)) {
                                HStack(spacing: 6) {
                                    Text(a.name)
                                    if a.isMe { Text("You").font(.caption).foregroundStyle(Theme.accent) }
                                    if let email = a.email {
                                        Text(email).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 200)
            }
        }
    }

    private var summarizeOffer: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Invite added").font(.headline)
                Text("The notes were written without these names. Summarize again with them?")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Not Now") { dismiss() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                Button("Summarize Again with These Names") {
                    state.resummarize(meeting.id)
                    dismiss()
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(state.isBusy(meeting.id))
            }
        }
    }

    private var chosen: [Attendee] { attendees.filter { !skipped.contains($0) } }

    private func binding(for a: Attendee) -> Binding<Bool> {
        Binding(get: { !skipped.contains(a) },
                set: { on in if on { skipped.remove(a) } else { skipped.insert(a) } })
    }

    private func parse(_ text: String) {
        let parsed = InviteParser.parse(text, userName: Prefs.userName)
        attendees = parsed.attendees
        skipped = skipped.intersection(parsed.attendees)
        if !titleEdited { title = parsed.title ?? "" }
    }

    private func apply() {
        state.applyInvite(meeting.id, title: title, attendees: chosen)
        if !meeting.summary.isEmpty && !meeting.turns.isEmpty {
            applied = true
        } else {
            dismiss()
        }
    }
}
