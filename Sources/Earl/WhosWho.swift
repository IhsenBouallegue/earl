import SwiftUI

// W-1: who's who. V-1 found that in meetings where nobody was ever confirmed,
// most of the words come from "Speaker N": voice memory works, it just never
// gets fed, because naming hides in the cast row's click menu. So under the
// cast Earl asks once, quietly, about the voices he couldn't place, and a
// name given here spreads to other meetings by voice (VoicePropagation).

enum WhosWho {
    /// Unnamed voices with less talk than this aren't worth a question.
    static let minSeconds = 30.0
    /// K-1: at a town hall or a talk.
    static let minListeningSeconds = 180.0
    /// K-1: with more invited than this, a name nobody said near the voice
    /// and the series never heard is a blind guess: don't offer it.
    static let blindGuessInvites = 12
    /// At most this many rows, the longest talkers first.
    static let maxRows = 4
    /// Name chips per unnamed voice, before "Someone else…".
    static let maxSuggestions = 4
    /// The longest a played sample of a voice runs.
    static let clipSeconds = 8.0

    struct Ask: Identifiable, Equatable {
        enum Kind: Equatable {
            /// Earl's guess, shown "Sarah?".
            case guess(String)
            case unnamed
        }

        var speakerID: String
        var kind: Kind
        var seconds: Double

        var id: String { speakerID }
        var isGuess: Bool { if case .guess = kind { true } else { false } }
    }

    // MARK: Who to ask about

    /// The voices the card asks about: guessed names, and unnamed voices
    /// with enough talk, never you. Nothing while the meeting is busy or not
    /// done, or after "Not now".
    static func asks(for meeting: Meeting, busy: Bool = false) -> [Ask] {
        guard !busy, meeting.info.status == .done, meeting.info.whosWhoDismissed != true, !meeting.turns.isEmpty
        else { return [] }
        let spoke = Set(meeting.turns.compactMap(\.speakerID))
        // K-1: at a town hall or talk the speakers matter, not one question from the floor.
        let listening = meeting.info.notesKind.flatMap(MeetingKind.init(rawValue:))?.isListening == true
        let least = listening ? minListeningSeconds : minSeconds
        let asks: [Ask] = meeting.speakers.compactMap { s in
            guard spoke.contains(s.id), !Speaker.isYou(s, in: meeting.speakers) else { return nil }
            if s.isGuess, let name = s.name { return Ask(speakerID: s.id, kind: .guess(name), seconds: s.seconds) }
            guard (s.name ?? "").isEmpty, s.seconds >= least else { return nil }
            return Ask(speakerID: s.id, kind: .unnamed, seconds: s.seconds)
        }
        return Array(asks.sorted { $0.seconds != $1.seconds ? $0.seconds > $1.seconds : $0.speakerID < $1.speakerID }
            .prefix(maxRows))
    }

    // MARK: Earl's words

    private static let numbers = ["no", "one", "two", "three", "four", "five", "six"]

    static func count(_ n: Int) -> String { numbers.indices.contains(n) ? numbers[n] : "\(n)" }

    /// "Is this Sarah?" for one guess, "I didn't catch three voices." when
    /// none has a name, "Two voices I'm not sure of." otherwise.
    static func lead(for asks: [Ask]) -> String {
        if asks.count == 1, case .guess(let name) = asks[0].kind { return EarlVoice.isThis(name) }
        let noun = asks.count == 1 ? "voice" : "voices"
        if !asks.contains(where: \.isGuess) { return "I didn't catch \(count(asks.count)) \(noun)." }
        let n = count(asks.count)
        return n.prefix(1).uppercased() + n.dropFirst() + " \(noun) I'm not sure of."
    }

    /// The "Meeting notes ready" body: the title, and Earl's question when
    /// the page will ask one.
    static func notificationBody(for meeting: Meeting) -> String {
        let asks = asks(for: meeting)
        guard !asks.isEmpty else { return meeting.info.title }
        let noun = asks.count == 1 ? "voice" : "voices"
        return meeting.info.title + "\nEarl has a question about \(count(asks.count)) \(noun)."
    }

    /// "43 s", "4 min".
    static func talkTime(_ seconds: Double) -> String {
        seconds < 60 ? "\(Int(seconds.rounded())) s" : "\(Int((seconds / 60).rounded())) min"
    }

    // MARK: Suggestions

    /// Names for an unnamed voice, best first: people invited or named
    /// before in the series whom no voice in this meeting has yet, and never
    /// you. First those whose name is said next to this voice's turns
    /// (`SpeakerNameGuesser.support`), then those named in earlier meetings of
    /// the series (most recent first), then the rest alphabetically.
    /// `earlier`: the series' earlier meetings, newest first.
    static func suggestions(for speakerID: String, in meeting: Meeting, earlier: [Meeting], userName: String?,
                            limit: Int = maxSuggestions) -> [String] {
        let attendees = meeting.info.attendees ?? []
        let yours = ([userName] + attendees.filter(\.isMe).map(\.name)).compactMap { $0 }.filter { !$0.isEmpty }
        let taken = meeting.speakers.compactMap(\.name).filter { !$0.isEmpty }
        func free(_ name: String) -> Bool {
            !yours.contains { NameCollisions.samePerson($0, name) } && !taken.contains { NameCollisions.samePerson($0, name) }
        }
        var names: [String] = []
        func add(_ name: String) {
            let name = name.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, free(name), !names.contains(where: { NameCollisions.samePerson($0, name) }) else { return }
            names.append(name)
        }
        for a in attendees where !a.isMe { add(a.name) }
        // When was each person last named in the series (0 = the latest meeting).
        var lastSeen: [String: Int] = [:]
        for (i, m) in earlier.enumerated() {
            for s in m.speakers where s.nameSource == .confirmed || s.nameSource == .voice {
                guard let name = s.name, !name.isEmpty else { continue }
                add(name)
                if let match = names.first(where: { NameCollisions.samePerson($0, name) }), lastSeen[match] == nil {
                    lastSeen[match] = i
                }
            }
        }
        let support = Dictionary(uniqueKeysWithValues: names.map { name in
            (name, SpeakerNameGuesser.support(for: speakerID, name: AttendeeName.firstName(name), turns: meeting.turns))
        })
        let ranked = names.sorted { a, b in
            let (sa, sb) = (support[a] ?? 0, support[b] ?? 0)
            if sa != sb { return sa > sb }
            switch (lastSeen[a], lastSeen[b]) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
            }
        }
        let blind = attendees.count > blindGuessInvites
        return Array(ranked.filter { !blind || (support[$0] ?? 0) > 0 || lastSeen[$0] != nil }.prefix(limit))
    }

    /// The full name to confirm a guess as: the attendee it stands for
    /// ("Sarah" → "Sarah Chen"), else the guess.
    static func confirmedName(for guess: String, attendees: [Attendee]) -> String {
        attendees.first { a in
            !a.isMe && (a.name.caseInsensitiveCompare(guess) == .orderedSame
                        || AttendeeName.firstName(a.name).caseInsensitiveCompare(guess) == .orderedSame)
        }?.name ?? guess
    }

    // MARK: Hearing a voice

    /// What to play for a voice: its longest turn nobody talks over (another
    /// turn overlapping it would muddle the sample), from its start, for at
    /// most `clipSeconds`. Falls back to its longest turn of all.
    static func clip(for speakerID: String, in turns: [Turn]) -> (turn: Turn, seconds: Double)? {
        let own = turns.filter { $0.speakerID == speakerID && $0.end > $0.start }
        func clean(_ t: Turn) -> Bool {
            !turns.contains { o in
                (o.speakerID != t.speakerID || o.speaker != t.speaker) && o.start < t.end && t.start < o.end
            }
        }
        let longest: ([Turn]) -> Turn? = { $0.max { ($0.end - $0.start, $1.start) < ($1.end - $1.start, $0.start) } }
        guard let turn = longest(own.filter(clean)) ?? longest(own) else { return nil }
        return (turn, min(clipSeconds, turn.end - turn.start))
    }
}

// MARK: - App state

extension AppState {
    /// "Not now": the card stays away for this meeting.
    func dismissWhosWho(_ meetingID: String) {
        let folder = Prefs.storageURL.appendingPathComponent(meetingID)
        guard !isBusy(meetingID), var m = store.load(folder) else { return }
        m.info.whosWhoDismissed = true
        try? store.save(m.info, in: folder)
        reload()
    }
}

// MARK: - The card

/// Under the cast: a quiet paper card with Earl's question and one row per
/// voice: its face, a sample to hear, and names to pick. Rows fold away as
/// they're answered; the last one leaves Earl's thanks for a moment.
struct WhosWhoCard: View {
    @EnvironmentObject private var state: AppState
    let meeting: Meeting
    var interactive = true
    /// Plays `seconds` of a turn; nil without audio.
    var onClip: ((Turn, Double) -> Void)?

    @State private var thanking = false
    @State private var askingConsent = false
    @State private var naming: String?
    @State private var hovering: String?
    @State private var open = false
    @FocusState private var focus: String?

    var body: some View {
        let asks = interactive ? WhosWho.asks(for: meeting, busy: state.isBusy(meeting.id)) : []
        VStack(alignment: .leading, spacing: 0) {
            if askingConsent {
                VoiceConsentPrompt(meetingID: meeting.id) { consentAnswered(asks) }
                    .modifier(QuietCard())
                    .padding(.bottom, 26)
            } else if !asks.isEmpty {
                // One quiet line until you reach for it: the news leads, the question waits.
                Group {
                    if open { card(asks) } else { line(asks) }
                }
                .padding(.bottom, open ? 26 : 22)
                .transition(.opacity)
            } else if thanking {
                EarlLine(lead: "Thank you.", leadSize: 18)
                    .padding(.bottom, 14)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.25), value: asks.map(\.id))
        .animation(.easeOut(duration: 0.25), value: thanking)
        .onChange(of: asks.isEmpty) { wasEmpty, isEmpty in
            guard isEmpty, !wasEmpty, !askingConsent else { return }
            thank()
        }
    }

    private func thank() {
        // "Not now" or a busy meeting empties the card too, without an answer.
        guard meeting.info.whosWhoDismissed != true, !state.isBusy(meeting.id) else { return }
        thanking = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            thanking = false
        }
    }

    /// "Two voices I'm not sure of.  Name them ›   Not now"
    private func line(_ asks: [WhosWho.Ask]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) { open = true }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(WhosWho.lead(for: asks))
                        .font(.earlVoice(size: 17))
                        .foregroundStyle(Paper.ink)
                    Text("\(asks.count == 1 ? "Name it" : "Name them") \(Image(systemName: "chevron.right"))")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Paper.ink)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Hear each voice and say who it is")
            Spacer(minLength: 8)
            Button("Not now") { state.dismissWhosWho(meeting.id) }
                .buttonStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Paper.inkMuted)
                .help("Don't ask about this meeting again")
        }
    }

    private func card(_ asks: [WhosWho.Ask]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                EarlLine(lead: WhosWho.lead(for: asks), leadSize: 17)
                Spacer(minLength: 8)
                Button("Not now") { state.dismissWhosWho(meeting.id) }
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(Paper.inkMuted)
                    .help("Don't ask about this meeting again")
            }
            VStack(alignment: .leading, spacing: 10) {
                ForEach(asks) { ask in
                    row(ask)
                        .transition(.asymmetric(insertion: .opacity,
                                                removal: .opacity.combined(with: .move(edge: .top))))
                }
            }
        }
        .modifier(QuietCard())
    }

    // MARK: Rows

    private func row(_ ask: WhosWho.Ask) -> some View {
        let look = SpeakerFaces.look(for: Turn(start: 0, end: 0, speaker: "Them", text: "", speakerID: ask.speakerID),
                                     in: meeting.speakers)
        let voice = VoicePalette.voice(for: look)
        let label: String = switch ask.kind {
        case .guess(let name): name + "?"
        case .unnamed: Self.unnamedLabel(ask.speakerID, in: meeting)
        }
        return HStack(alignment: .center, spacing: 12) {
            SpeakerAvatar.badge(look, size: 26, unconfirmed: ask.isGuess)
            VStack(alignment: .leading, spacing: 0) {
                Text(label)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(voice.text)
                    .lineLimit(1)
                Text(WhosWho.talkTime(ask.seconds))
                    .font(.system(size: 13))
                    .foregroundStyle(Paper.inkMuted)
                    .monospacedDigit()
            }
            .frame(width: 112, alignment: .leading)
            playButton(ask, label: label)
            FlowLayout(spacing: 8, lineSpacing: 6) { chips(ask) }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 ? ask.id : (hovering == ask.id ? nil : hovering) }
        .help(ask.isGuess ? meeting.speakers.first { $0.id == ask.speakerID }?.evidence.map { "Earl heard: \($0)" } ?? "" : "")
    }

    /// "Speaker 4", even when it's the only voice on the call (where the
    /// transcript says "Them").
    static func unnamedLabel(_ id: String, in meeting: Meeting) -> String {
        let display = Speaker.displayName(for: Turn(start: 0, end: 0, speaker: "Them", text: "", speakerID: id),
                                          in: meeting.speakers)
        return display.hasPrefix("Speaker ") ? display : "Speaker \(Int(id.dropFirst()) ?? 1)"
    }

    @ViewBuilder
    private func playButton(_ ask: WhosWho.Ask, label: String) -> some View {
        if let onClip, let clip = WhosWho.clip(for: ask.speakerID, in: meeting.turns) {
            Button { onClip(clip.turn, clip.seconds) } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Paper.ink)
                    .frame(width: 30, height: 30)
                    .background(Paper.card, in: Circle())
                    .overlay(Circle().strokeBorder(Paper.hairline))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Hear \(label.hasSuffix("?") ? String(label.dropLast()) : label) at \(Meeting.timestamp(clip.turn.start))")
            .accessibilityLabel("Hear \(label)")
        }
    }

    @ViewBuilder
    private func chips(_ ask: WhosWho.Ask) -> some View {
        switch ask.kind {
        case .guess(let name):
            let full = WhosWho.confirmedName(for: name, attendees: meeting.info.attendees ?? [])
            NameChip(title: "Yes, \(name)", strong: true, focus: $focus, key: "\(ask.id)/yes") {
                if full != name {
                    pick(ask.speakerID) { state.renameSpeaker(meetingID: meeting.id, speakerID: ask.speakerID, name: full) }
                } else {
                    pick(ask.speakerID) { state.confirmSpeaker(meetingID: meeting.id, speakerID: ask.speakerID) }
                }
            }
            .help(full != name ? "\(full), from the invite" : "")
            NameChip(title: "No", focus: $focus, key: "\(ask.id)/no") {
                state.clearSpeakerName(meetingID: meeting.id, speakerID: ask.speakerID)
            }
        case .unnamed:
            let earlier = MeetingSeries.earlier(than: meeting, in: state.meetings, limit: 10)
            let names = WhosWho.suggestions(for: ask.speakerID, in: meeting, earlier: earlier, userName: Prefs.userName)
            ForEach(names, id: \.self) { name in
                NameChip(title: name, focus: $focus, key: "\(ask.id)/\(name)") {
                    pick(ask.speakerID) { state.renameSpeaker(meetingID: meeting.id, speakerID: ask.speakerID, name: name) }
                }
            }
            NameChip(title: "Someone else…", muted: true, focus: $focus, key: "\(ask.id)/else") { naming = ask.speakerID }
                .popover(isPresented: Binding(get: { naming == ask.speakerID }, set: { if !$0 { naming = nil } }),
                         arrowEdge: .bottom) {
                    SpeakerNamePopover(meeting: meeting, speakerID: ask.speakerID) { naming = nil }
                }
        }
    }

    /// Names a voice, then asks once about remembering voices (R3-3), since
    /// that's what lets the name spread.
    private func pick(_ speakerID: String, _ rename: () -> Void) {
        let ask = VoiceConsentPrompt.shouldAsk
        rename()
        if ask { askingConsent = true }
    }

    private func consentAnswered(_ asks: [WhosWho.Ask]) {
        askingConsent = false
        // Remembering just started: what you confirmed here can spread now.
        if Prefs.rememberVoices { state.propagateVoices(meetingID: meeting.id) }
        if asks.isEmpty { thank() }
    }
}

/// The card's surface: soft paper and a hairline, quieter than the white
/// briefing card under it, so the question never outshouts the news.
private struct QuietCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Paper.paperSoft, in: RoundedRectangle(cornerRadius: Paper.Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Paper.Radius.card, style: .continuous).strokeBorder(Paper.hairline))
    }
}

/// A name to pick: a small capsule. Tab reaches it, Return or Space picks it.
private struct NameChip: View {
    let title: String
    var strong = false
    var muted = false
    var focus: FocusState<String?>.Binding
    let key: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        let focused = focus.wrappedValue == key
        Text(title)
            .font(.system(size: 14, weight: strong ? .semibold : .regular))
            .foregroundStyle(muted && !hovering ? Paper.inkMuted : Paper.ink)
            .lineLimit(1)
            .padding(.horizontal, 11)
            .padding(.vertical, 4)
            .background(Paper.card, in: Capsule())
            .overlay(Capsule().strokeBorder(focused ? Paper.ink : hovering ? Paper.inkMuted.opacity(0.6) : Paper.hairline,
                                            lineWidth: focused ? 1.5 : 1))
            .fixedSize()
            .contentShape(Capsule())
            .focusable()
            .focusEffectDisabled()
            .focused(focus, equals: key)
            .onKeyPress(.return) { action(); return .handled }
            .onKeyPress(.space) { action(); return .handled }
            .onTapGesture(perform: action)
            .onHover { hovering = $0 }
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
