import SwiftUI

// W-1: name a voice once, everywhere. When you confirm a name and voice
// memory is on, the voice just learned is looked for in other meetings: the
// same series first, then anything from the last 60 days. Unnamed or guessed
// voices that pass the same test as recognition (`VoiceLibrary.threshold`)
// take the name, as "by voice", and their notes are patched like a rename.

enum VoicePropagation {
    /// Meetings outside the series are only searched this far back.
    static let windowDays = 60.0

    /// One voice named in another meeting.
    struct Change: Equatable {
        var meetingID: String
        var speakerID: String
        var name: String
        var score: Float
        /// "3 meetings", as recognition writes it.
        var evidence: String?
    }

    /// What one meeting looked like before and after, for Undo.
    struct Undo: Equatable {
        var meetingID: String
        var speakersBefore: [Speaker]
        var speakersAfter: [Speaker]
        var summaryBefore: String
        var summaryAfter: String
        var infoBefore: MeetingInfo
        var infoAfter: MeetingInfo
    }

    // MARK: Planning

    /// Names an edit confirmed (new or changed), on call voices.
    static func newlyConfirmed(before: [Speaker], after: [Speaker]) -> [String] {
        after.compactMap { s in
            guard s.track == "Them", s.nameSource == .confirmed, let name = s.name, !name.isEmpty else { return nil }
            let old = before.first { $0.id == s.id }
            if old?.nameSource == .confirmed, old?.name == name { return nil }
            return name
        }
    }

    /// Where to look: finished meetings other than the source, not busy, the
    /// source's series first (any age), then the rest of the last 60 days,
    /// newest first.
    static func targets(sourceID: String, in meetings: [Meeting], skip: Set<String>, now: Date = Date()) -> [Meeting] {
        let eligible = meetings.filter {
            $0.id != sourceID && !skip.contains($0.id) && $0.info.status == .done && !$0.speakers.isEmpty
        }.sorted { $0.info.startedAt > $1.info.startedAt }
        let key = meetings.first { $0.id == sourceID }.flatMap { MeetingSeries.key(for: $0) }
        let series = key.map { k in eligible.filter { MeetingSeries.key(for: $0) == k } } ?? []
        let ids = Set(series.map(\.id))
        let since = now.addingTimeInterval(-windowDays * 86400)
        return series + eligible.filter { !ids.contains($0.id) && $0.info.startedAt >= since }
    }

    /// The speaker in `speakers` that sounds like `voice`, if any: an unnamed
    /// or guessed call voice (never a confirmed or voice-named one) that
    /// clears recognition's threshold, the most alike first. Nothing when
    /// another voice in the meeting already has the name (V-1).
    static func match(_ voice: Voice, speakers: [Speaker], attendees: [Attendee]) -> (speakerID: String, score: Float)? {
        let threshold = VoiceLibrary.threshold(for: voice, attendees: attendees)
        let best = speakers
            .filter {
                $0.track == "Them" && (($0.name ?? "").isEmpty || $0.nameSource == .guessed) && !$0.embedding.isEmpty
                    && $0.seconds >= VoiceLibrary.minMatchSeconds
            }
            .map { (speakerID: $0.id, score: VoiceLibrary.similarity($0.embedding, to: voice)) }
            .filter { $0.score >= threshold }
            .max { $0.score < $1.score }
        guard let best else { return nil }
        // Its own guess doesn't count against it; anyone else's name does.
        let others = SpeakerEdit.rename(speakers, id: best.speakerID, to: nil, source: nil)
        let resolved = NameCollisions.resolve(
            speakers: others, guesses: [(.voice, [best.speakerID: .init(name: voice.name, evidence: "")])])
        return resolved.kept[best.speakerID] == nil ? nil : best
    }

    /// Every change the newly learned `voices` call for in `meetings`.
    static func plan(voices: [Voice], sourceID: String, in meetings: [Meeting], skip: Set<String>,
                     now: Date = Date()) -> [Change] {
        var changes: [Change] = []
        for meeting in targets(sourceID: sourceID, in: meetings, skip: skip, now: now) {
            var speakers = meeting.speakers
            for voice in voices {
                guard let hit = match(voice, speakers: speakers, attendees: meeting.info.attendees ?? []) else { continue }
                let evidence = voice.meetings == 1 ? "1 meeting" : "\(voice.meetings) meetings"
                speakers = SpeakerEdit.rename(speakers, id: hit.speakerID, to: voice.name, source: .voice, evidence: evidence)
                changes.append(Change(meetingID: meeting.id, speakerID: hit.speakerID, name: voice.name, score: hit.score,
                                      evidence: evidence))
            }
        }
        return changes
    }

    // MARK: Applying

    /// Saves the changes, meeting by meeting, from what's on disk now:
    /// speakers.json, the notes patched by `NotesPatch`, transcript.md, and a
    /// line in whisper.log. Returns what Undo needs.
    static func apply(_ changes: [Change], sourceID: String, store: MeetingStore) -> [Undo] {
        var undos: [Undo] = []
        var order: [String] = []
        for c in changes where !order.contains(c.meetingID) { order.append(c.meetingID) }
        for id in order {
            guard var meeting = store.load(store.root.appendingPathComponent(id)), meeting.info.status == .done else { continue }
            let before = (turns: meeting.turns, speakers: meeting.speakers)
            var applied: [Change] = []
            for c in changes where c.meetingID == id {
                // Named meanwhile (you, or recognition): leave it.
                guard let s = meeting.speakers.first(where: { $0.id == c.speakerID }),
                      (s.name ?? "").isEmpty || s.nameSource == .guessed else { continue }
                meeting.speakers = SpeakerEdit.rename(meeting.speakers, id: c.speakerID, to: c.name, source: .voice,
                                                      evidence: c.evidence)
                applied.append(c)
            }
            guard !applied.isEmpty else { continue }
            do {
                let saved = try NotesPatch.saveSpeakerEdit(meeting, before: before, mergedInto: [:], store: store)
                store.saveMarkdown(saved)
                LogFile(meeting.folder.appendingPathComponent("whisper.log"))
                    .write("Named by voice from \(sourceID): " + applied.map {
                        "\($0.speakerID) = \($0.name) (\(String(format: "%.2f", $0.score)))"
                    }.joined(separator: ", "))
                undos.append(Undo(meetingID: id, speakersBefore: before.speakers, speakersAfter: saved.speakers,
                                  summaryBefore: meeting.summary, summaryAfter: saved.summary,
                                  infoBefore: meeting.info, infoAfter: saved.info))
            } catch {
                NSLog("Earl: couldn't name voices in \(id): \(error)")
            }
        }
        return undos
    }

    /// Puts the meetings back as they were, keeping anything changed since:
    /// a speaker renamed again stays, and so do notes edited in the meantime.
    static func undo(_ undos: [Undo], store: MeetingStore) {
        for u in undos {
            guard var meeting = store.load(store.root.appendingPathComponent(u.meetingID)) else { continue }
            var speakers = meeting.speakers
            for (i, s) in speakers.enumerated() {
                guard let after = u.speakersAfter.first(where: { $0.id == s.id }), s == after,
                      let old = u.speakersBefore.first(where: { $0.id == s.id }), old != after else { continue }
                speakers[i] = old
            }
            do {
                if speakers != meeting.speakers { try store.saveSpeakers(speakers, in: meeting.folder) }
                meeting.speakers = speakers
                if meeting.summary == u.summaryAfter, u.summaryBefore != u.summaryAfter {
                    try store.saveSummary(u.summaryBefore, in: meeting.folder)
                    TodoFiles.rekey(old: u.summaryAfter, new: u.summaryBefore, in: meeting.folder)
                    meeting.summary = u.summaryBefore
                }
                var info = meeting.info
                if info.title == u.infoAfter.title { info.title = u.infoBefore.title }
                if info.headline == u.infoAfter.headline { info.headline = u.infoBefore.headline }
                if info != meeting.info {
                    try store.save(info, in: meeting.folder)
                    meeting.info = info
                }
                store.saveMarkdown(meeting)
            } catch {
                NSLog("Earl: couldn't undo names in \(u.meetingID): \(error)")
            }
        }
    }

    /// "Also named Sarah in 3 other meetings".
    static func message(names: [String], meetings: Int) -> String {
        let who: String
        switch names.count {
        case 0: who = "voices"
        case 1: who = names[0]
        default: who = names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
        return "Also named \(who) in \(meetings) other \(meetings == 1 ? "meeting" : "meetings")"
    }
}

// MARK: - The toast

/// "Also named Sarah in 3 other meetings · Undo", for five seconds. Holds
/// the before-state only while it shows.
@MainActor
final class VoicePropagationToast: ObservableObject {
    static let shared = VoicePropagationToast()

    struct Offer: Equatable {
        let id = UUID()
        let sourceID: String
        let names: [String]
        let undos: [VoicePropagation.Undo]

        var text: String { VoicePropagation.message(names: names, meetings: undos.count) }
    }

    @Published private(set) var offer: Offer?

    func show(_ offer: Offer) {
        withAnimation(.easeOut(duration: 0.2)) { self.offer = offer }
        let id = offer.id
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            if self.offer?.id == id { self.dismiss() }
        }
    }

    func dismiss() {
        withAnimation(.easeOut(duration: 0.2)) { offer = nil }
    }
}

// MARK: - App state

extension AppState {
    /// After names were confirmed in `meetingID`: finds the same voices in
    /// other meetings, off the main thread, then reloads once and says so.
    /// `names` nil means every name confirmed there (just after consent).
    func propagateVoices(meetingID: String, names: [String]? = nil) {
        let library = VoiceStore.shared.library
        guard VoiceStore.shared.isEnabled(), !library.voices.isEmpty else { return }
        let wanted = names ?? (meeting(meetingID).map { VoicePropagation.newlyConfirmed(before: [], after: $0.speakers) } ?? [])
        let voices = wanted.compactMap { library.index(named: $0).map { library.voices[$0] } }
        guard !voices.isEmpty else { return }
        var skip = Set(jobs.map(\.id))
        if let recordingID { skip.insert(recordingID) }
        let meetings = self.meetings
        let store = self.store
        Task.detached(priority: .utility) {
            let changes = VoicePropagation.plan(voices: voices, sourceID: meetingID, in: meetings, skip: skip)
            guard !changes.isEmpty else { return }
            let undos = VoicePropagation.apply(changes, sourceID: meetingID, store: store)
            guard !undos.isEmpty else { return }
            await MainActor.run {
                self.reload()
                self.reminders.loadSent(meetings: self.meetings)
                var named: [String] = []
                for c in changes where undos.contains(where: { $0.meetingID == c.meetingID }) && !named.contains(c.name) {
                    named.append(c.name)
                }
                VoicePropagationToast.shared.show(.init(sourceID: meetingID, names: named, undos: undos))
            }
        }
    }

    func undoPropagation(_ offer: VoicePropagationToast.Offer) {
        VoicePropagationToast.shared.dismiss()
        let store = self.store
        let undos = offer.undos.filter { !isBusy($0.meetingID) && $0.meetingID != recordingID }
        Task.detached(priority: .userInitiated) {
            VoicePropagation.undo(undos, store: store)
            await MainActor.run {
                self.reload()
                self.reminders.loadSent(meetings: self.meetings)
            }
        }
    }
}

/// The toast at the foot of the page the name was given on.
struct VoicePropagationToastView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var toast = VoicePropagationToast.shared
    let meetingID: String

    var body: some View {
        if let offer = toast.offer, offer.sourceID == meetingID {
            HStack(spacing: 8) {
                Image(systemName: "waveform").foregroundStyle(Paper.inkMuted).accessibilityHidden(true)
                Text(offer.text).foregroundStyle(Paper.ink)
                Text("·").foregroundStyle(Paper.inkMuted)
                Button("Undo") { state.undoPropagation(offer) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Paper.ink)
                    .fontWeight(.semibold)
            }
            .font(.system(size: 14))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Paper.card, in: Capsule())
            .overlay(Capsule().strokeBorder(Paper.hairline))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }
}
