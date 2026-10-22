import SwiftUI

// R1-3: a custom vocabulary that biases Whisper (and the summary model)
// towards the right spellings of names, products and acronyms.
// Q-1: the prompt reads as a sentence (Whisper copies a bare list as speaker
// labels), and attendees are cleaned up before they reach it.

extension Prefs.Key {
    static let vocabulary = "vocabulary"
}

extension Prefs {
    /// The vocabulary as typed in Settings: one term per line (commas work too).
    static var vocabulary: String { UserDefaults.standard.string(forKey: Key.vocabulary) ?? "" }
    static var vocabularyTerms: [String] { WhisperPrompt.terms(from: vocabulary) }
}

/// Builds Whisper's initial prompt from the vocabulary, and recognises when
/// Whisper parrots that prompt back instead of transcribing.
enum WhisperPrompt {
    /// whisper.cpp allows at most n_text_ctx/2 = 224 prompt tokens. Stay well
    /// under that, estimating ~3.5 characters per token.
    static let maxTokens = 180
    static let maxCharacters = Int(Double(maxTokens) * 3.5)

    /// Splits on newlines and commas, trims, and drops empty entries and
    /// case-insensitive duplicates (the first spelling wins).
    static func terms(from text: String) -> [String] {
        unique(text.components(separatedBy: CharacterSet(charactersIn: ",\n\r"))
            .map { $0.trimmingCharacters(in: .whitespaces) })
    }

    /// The prompt for the current vocabulary plus `extraNames` (e.g. meeting
    /// attendees), vocabulary first. `nil` when there's nothing to say.
    /// Q-1: a plain sentence ("Alex Weber, Sam Kowalski and Jo Brandt talk
    /// about Skyfield and Acme.") instead of "Glossary: A, B, C." — Whisper
    /// tended to copy that bare list as speaker labels ("Alex Weber:") at
    /// the start of sentences once it appeared.
    static func build(extraNames: [String] = [], vocabulary: [String] = Prefs.vocabularyTerms) -> String? {
        let terms = buildTerms(extraNames: extraNames, vocabulary: vocabulary)
        return terms.isEmpty ? nil : sentence(for: terms)
    }

    /// The exact terms `build` used for its prompt, without re-parsing the
    /// sentence: saved as `MeetingInfo.vocabularyTerms` and turned into
    /// `promptWords` for echo detection and label stripping (Q-1).
    static func buildTerms(extraNames: [String] = [], vocabulary: [String] = Prefs.vocabularyTerms) -> [String] {
        fitting(unique(vocabulary + extraNames.map { $0.trimmingCharacters(in: .whitespaces) }))
    }

    /// The leading terms that fit in the prompt; the rest are dropped.
    static func fitting(_ terms: [String]) -> [String] {
        var kept: [String] = []
        for term in terms {
            guard sentence(for: kept + [term]).count <= maxCharacters else { break }
            kept.append(term)
        }
        return kept
    }

    /// A natural sentence for `terms`: people first ("who"), then other terms
    /// ("what they're talking about"), so it reads like something someone
    /// might actually say instead of a list Whisper is tempted to echo as
    /// formatting.
    private static func sentence(for terms: [String]) -> String {
        let people = terms.filter(isPersonName)
        let topics = terms.filter { !isPersonName($0) }
        switch (people.isEmpty, topics.isEmpty) {
        case (true, true):
            return ""
        case (false, true):
            return "\(list(people)) \(people.count == 1 ? "is" : "are") in this meeting."
        case (true, false):
            return "This meeting is about \(list(topics))."
        case (false, false):
            return "\(list(people)) \(people.count == 1 ? "talks" : "talk") about \(list(topics))."
        }
    }

    /// "A", "A and B", or "A, B and C".
    private static func list(_ items: [String]) -> String {
        guard let last = items.last else { return "" }
        guard items.count > 1 else { return last }
        return items.dropLast().joined(separator: ", ") + " and " + last
    }

    /// A term that reads like "First Last": more than one word, each starting
    /// with an uppercase letter, no digits. A rough heuristic, not a real
    /// name parser, but enough to tell "Sarah Müller" from "Skyfield" or the
    /// all-caps acronym "OKR".
    private static func isPersonName(_ term: String) -> Bool {
        let words = term.split(separator: " ").filter { !$0.isEmpty }
        guard words.count > 1 else { return false }
        return words.allSatisfy { word in
            guard let first = word.first, first.isUppercase else { return false }
            return !word.contains(where: \.isNumber)
        }
    }

    private static func unique(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        return terms.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    // MARK: - Attendees (Q-1)

    /// Group addresses aren't people: dropped before they reach the prompt.
    /// Checked against the name and, when present, the email's local part.
    private static let groupNamePrefixes = ["distribution", "shared", "dl ", "team "]
    private static let groupNameSubstrings = [" - org", " - "]
    private static let groupEmailPrefixes = ["dl_", "dl-", "u_", "shared.", "team.", "all.", "distribution"]

    /// Suffixes meaning "not an employee", stripped before the name is used.
    private static let externalSuffixes = [" -Extern", " (Extern)", " (extern)", " (External)", " [EXT]"]

    /// Domains that don't identify a company, so no company term is added for them.
    private static let webmailLabels: Set<String> = [
        "gmail", "googlemail", "outlook", "hotmail", "live", "icloud", "me", "proton", "protonmail",
        "gmx", "web", "yahoo",
    ]

    /// Names to give Whisper so it spells attendees right (Q-1): mailing
    /// lists and other group addresses dropped, "-Extern"-style suffixes
    /// stripped, duplicates merged, and the company name added once (unless
    /// the vocabulary already spells it).
    static func attendeeTerms(_ attendees: [Attendee], vocabulary: [String] = Prefs.vocabularyTerms) -> [String] {
        var terms = cleanedAttendeeNames(attendees)
        if let company = companyName(from: attendees, vocabulary: vocabulary) { terms.append(company) }
        return terms
    }

    /// Attendee names cleaned the same way as `attendeeTerms` (group
    /// addresses dropped, "-Extern"-style suffixes stripped, duplicates
    /// merged), but without the company name term. Q-3: used for the notes
    /// prompt's participant list, so "Sam Kowalski -Extern" reads as "Sam
    /// Kowalski" instead of a second, near-duplicate name.
    static func cleanedAttendeeNames(_ attendees: [Attendee]) -> [String] {
        unique(attendees.filter { !isGroupAddress($0) }.map(cleanAttendeeName))
    }

    static func isGroupAddress(_ attendee: Attendee) -> Bool {
        let name = attendee.name.lowercased()
        if groupNamePrefixes.contains(where: name.hasPrefix) { return true }
        if groupNameSubstrings.contains(where: name.contains) { return true }
        guard let email = attendee.email?.lowercased(), let local = email.split(separator: "@").first else { return false }
        return groupEmailPrefixes.contains { local.hasPrefix($0) }
    }

    static func cleanAttendeeName(_ attendee: Attendee) -> String {
        var name = attendee.name
        for suffix in externalSuffixes where name.hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
            break
        }
        return name.trimmingCharacters(in: .whitespaces)
    }

    /// The most common attendee email domain's second-level label,
    /// capitalised ("acme-labs.de" → "Acme-labs"). `nil` when there's no
    /// domain to go on, it's a webmail domain, or the vocabulary already
    /// spells the company (the user's own spelling wins).
    static func companyName(from attendees: [Attendee], vocabulary: [String]) -> String? {
        guard let domain = commonestDomain(of: attendees), let label = secondLevelLabel(of: domain),
              !webmailLabels.contains(label.lowercased()) else { return nil }
        let name = label.prefix(1).uppercased() + label.dropFirst()
        guard !vocabulary.contains(where: { normalize($0) == normalize(name) }) else { return nil }
        return name
    }

    private static func commonestDomain(of attendees: [Attendee]) -> String? {
        let domains = attendees.compactMap { $0.email?.lowercased().split(separator: "@").last }.map(String.init)
        guard !domains.isEmpty else { return nil }
        var counts: [String: Int] = [:]
        for d in domains { counts[d, default: 0] += 1 }
        let best = counts.values.max() ?? 0
        // First occurrence wins a tie, so the result is deterministic.
        return domains.first { counts[$0] == best }
    }

    private static func secondLevelLabel(of domain: String) -> String? {
        let parts = domain.split(separator: ".")
        guard let label = parts.count >= 2 ? parts[parts.count - 2] : parts.first, !label.isEmpty else { return nil }
        return String(label)
    }

    private static func normalize(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    // MARK: - Prompt echo and invented labels (Q-1)

    /// The lowercased words of a prompt (or, since Q-1, of the term list it
    /// was built from — the sentence's own connective words like "talk" or
    /// "about" shouldn't count).
    static func words(in prompt: String?) -> Set<String> {
        guard let prompt else { return [] }
        return Set(words(of: prompt))
    }

    /// On silence or noise Whisper sometimes outputs the prompt itself. Treat
    /// a segment as an echo when more than 80% of its words (at least two)
    /// are prompt words. A lone term is kept, since people do say single names.
    static func isEcho(_ text: String, promptWords: Set<String>) -> Bool {
        guard !promptWords.isEmpty else { return false }
        let w = words(of: text)
        guard w.count >= 2 else { return false }
        return Double(w.filter(promptWords.contains).count) / Double(w.count) > 0.8
    }

    /// Drops a run of 1–3 words ending in ":" at the start of `text`, or
    /// right after a sentence ends, when at least one of those words is a
    /// prompt word — Whisper inventing a speaker label from the prompt
    /// ("Alex Weber: Ja, genau." → "Ja, genau."). A real colon inside speech
    /// ("the plan: first we…") or a time ("10:30") has no prompt word before
    /// the colon, so it's left alone.
    static func stripInventedLabels(_ text: String, promptWords: Set<String>) -> String {
        guard !promptWords.isEmpty, text.contains(":") else { return text }
        var result = text
        let matches = labelRegex.matches(in: result, range: NSRange(result.startIndex..., in: result))
        for match in matches.reversed() {
            guard let labelRange = Range(match.range(at: 2), in: result) else { continue }
            let label = words(of: String(result[labelRange]))
            guard label.contains(where: promptWords.contains) else { continue }
            guard let leadRange = Range(match.range(at: 1), in: result),
                  let fullRange = Range(match.range, in: result) else { continue }
            result.replaceSubrange(fullRange, with: String(result[leadRange]))
        }
        return result
    }

    /// Group 1: nothing (start of text) or a sentence end and its whitespace.
    /// Group 2: 1–3 letter-only words right before the colon.
    private static let labelRegex = try! NSRegularExpression(
        pattern: #"(^|[.!?]\s+)((?:\p{L}[\p{L}'-]*\s+){0,2}\p{L}[\p{L}'-]*):\s*"#)

    private static func words(of text: String) -> [String] {
        text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    // MARK: - whisper-cli context (Q-1)

    /// whisper-cli's `-mc` caps how many context tokens it re-feeds the model
    /// per segment: the carried prompt, then whatever Whisper itself just
    /// decoded (see whisper.cpp's `n_max_text_ctx`/`prompt_past0`/
    /// `prompt_past1`). Left uncapped, there's room for both, and Whisper's
    /// own previous text ("prompt_past1") is what lets an invented label (or
    /// a decoding loop) perpetuate itself once it appears. `-mc 0` isn't the
    /// fix either: whisper.cpp only builds *any* per-segment prompt when
    /// `n_max_text_ctx > 0`, so it drops the initial prompt too (checked
    /// against the whisper.cpp source and a real whisper-cli run, see the
    /// Q-1 report). Sizing `-mc` to (about) the prompt's own token budget,
    /// together with `--carry-initial-prompt`, fills that budget with the
    /// vocabulary on every segment and leaves next to no room for Whisper's
    /// own rolling text.
    static func maxContext(for prompt: String?) -> Int {
        guard let prompt, !prompt.isEmpty else { return 0 }
        return Int((Double(prompt.count) / 3.5).rounded(.up)) + 4
    }
}

/// The Vocabulary card under the hood.
struct VocabularySettings: View {
    @AppStorage(Prefs.Key.vocabulary) private var vocabulary = ""

    var body: some View {
        let terms = WhisperPrompt.terms(from: vocabulary)
        let fitting = WhisperPrompt.fitting(terms).count

        Card(title: "Vocabulary",
             subtitle: "Earl gives these to Whisper so they're spelled right. Keep it to the words you actually hear in meetings.") {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $vocabulary)
                    .font(.settingsRow)
                    .scrollContentBackground(.hidden)
                    .frame(height: 120)
                if vocabulary.isEmpty {
                    // TextEditor has no placeholder; line this up with its text inset.
                    Text("One per line, for example:\nSkyfield\nKubernetes\nSarah Müller")
                        .font(.settingsRow)
                        .foregroundStyle(Paper.inkMuted)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
            .surface(padding: 8, radius: Theme.rowRadius)

            HStack {
                Text(countText(terms.count))
                    .foregroundStyle(Paper.inkMuted)
                Spacer()
                if fitting < terms.count {
                    StatusLabel(kind: .attention, text: "Only the first \(fitting) terms fit")
                }
            }
            .font(.settingsNote)
        }
    }

    private func countText(_ n: Int) -> String {
        switch n {
        case 0: return "No terms yet. Whisper is winging it."
        case 1: return "1 term"
        default: return "\(n) terms"
        }
    }
}
