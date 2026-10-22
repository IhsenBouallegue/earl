import SwiftUI

// P-1: one switch for people who want Earl to keep words, not voices. With
// "Keep only the text" on, a meeting's audio is deleted as soon as its
// transcript is ready, speakers.json keeps no voice fingerprints, and voice
// memory (R3-3) is off. Turning it on cleans up what earlier meetings left.

enum Privacy {
    /// `speakers` without their voice fingerprints. Names, talk time and faces stay.
    static func withoutVoiceprints(_ speakers: [Speaker]) -> [Speaker] {
        speakers.map {
            var s = $0
            s.embedding = []
            return s
        }
    }

    /// What turning the switch on deletes, for the confirmation and the sweep.
    struct Cleanup: Equatable {
        /// Transcribed meetings that still have audio.
        var audioIDs: [String] = []
        var audioBytes: Int64 = 0
        /// Meetings whose speakers still carry voice fingerprints.
        var voiceprintIDs: [String] = []
        var rememberedVoices = 0

        var isEmpty: Bool { audioIDs.isEmpty && voiceprintIDs.isEmpty && rememberedVoices == 0 }

        /// "the audio of 12 meetings (1.4 GB), voice fingerprints in 30 meetings and 4 remembered voices".
        var summary: String {
            var parts: [String] = []
            if !audioIDs.isEmpty {
                parts.append("the audio of \(Self.meetings(audioIDs.count)) (\(Format.bytes(audioBytes)))")
            }
            if !voiceprintIDs.isEmpty { parts.append("voice fingerprints in \(Self.meetings(voiceprintIDs.count))") }
            if rememberedVoices > 0 {
                parts.append(rememberedVoices == 1 ? "1 remembered voice" : "\(rememberedVoices) remembered voices")
            }
            switch parts.count {
            case 0: return ""
            case 1: return parts[0]
            default: return parts.dropLast().joined(separator: ", ") + " and " + parts.last!
            }
        }

        static func meetings(_ n: Int) -> String { n == 1 ? "1 meeting" : "\(n) meetings" }
    }

    /// Meetings that are recording or being processed are left alone; so is
    /// audio that hasn't been transcribed yet, which Retry still needs.
    static func cleanup(of meetings: [Meeting], skipping skip: Set<String>, rememberedVoices: Int) -> Cleanup {
        var c = Cleanup(rememberedVoices: rememberedVoices)
        for m in meetings where !skip.contains(m.id) {
            if m.hasAudio, !m.turns.isEmpty {
                c.audioIDs.append(m.id)
                c.audioBytes += m.audioBytes
            }
            if m.speakers.contains(where: { !$0.embedding.isEmpty }) { c.voiceprintIDs.append(m.id) }
        }
        return c
    }
}

extension AppState {
    var privacyCleanup: Privacy.Cleanup {
        var skip = Set(jobs.map(\.id))
        if let recordingID { skip.insert(recordingID) }
        return Privacy.cleanup(of: meetings, skipping: skip, rememberedVoices: VoiceStore.shared.voices.count)
    }

    /// Deletes what "Keep only the text" doesn't keep. Run when the switch is
    /// turned on, and at launch to catch audio left by a quit mid-processing.
    func applyTextOnly() {
        let c = privacyCleanup
        guard !c.isEmpty else { return }
        for id in c.audioIDs {
            if let m = meeting(id) { store.deleteAudio(in: m.folder) }
        }
        for id in c.voiceprintIDs {
            guard let m = meeting(id) else { continue }
            try? store.saveSpeakers(Privacy.withoutVoiceprints(m.speakers), in: m.folder)
        }
        if c.rememberedVoices > 0 { VoiceStore.shared.forgetAll() }
        reload()
        engine.refreshLocal(meetings: meetings)
    }
}

/// The Privacy card in Settings: the one switch, and what it means.
struct PrivacySettings: View {
    @EnvironmentObject private var state: AppState
    @AppStorage(Prefs.Key.textOnly) private var textOnly = false
    @State private var pending: Privacy.Cleanup?

    var body: some View {
        Card(title: "Privacy") {
            Toggle("Keep only the text", isOn: Binding(get: { textOnly }, set: change))
            Text(textOnly ? Self.onNote : Self.offNote)
                .font(.settingsNote)
                .foregroundStyle(Paper.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .alert("Keep only the text?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button("Delete and Turn On", role: .destructive) {
                textOnly = true
                state.applyTextOnly()
                pending = nil
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: {
            Text("Earl will delete \(pending?.summary ?? "") from this Mac. Transcripts, notes and names stay.")
        }
    }

    static let onNote = """
        Audio is deleted as soon as a meeting is transcribed, and Earl keeps no voice fingerprints. \
        Meetings can't be replayed or transcribed again, and voices aren't recognised across meetings.
        """
    static let offNote = """
        Turn on to keep transcripts and notes without anyone's voice: \
        audio goes once the transcript is ready, and no voice fingerprints are stored.
        """

    private func change(_ on: Bool) {
        guard on else {
            textOnly = false
            return
        }
        let cleanup = state.privacyCleanup
        if cleanup.isEmpty {
            textOnly = true
        } else {
            pending = cleanup
        }
    }
}
