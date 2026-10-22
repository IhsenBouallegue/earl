import Foundation

// R2-2: the voices found on a track, how whisper's segments are matched to
// them, and how a turn's speaker is named everywhere.

/// One voice found in a meeting, as saved in `speakers.json`. R2-3 and R3-3
/// fill in the name.
struct Speaker: Codable, Hashable, Identifiable {
    enum NameSource: String, Codable { case guessed, voice, confirmed }

    /// "S1", "S2", … numbered by first appearance in the meeting.
    var id: String
    /// "Them" or "Me": the track the voice was found on.
    var track: String
    var name: String?
    var nameSource: NameSource?
    var embedding: [Float]
    /// Talk time in seconds.
    var seconds: Double
    /// R2-5: the accessory this voice wore on the live stage (`AvatarLook.Accessory`).
    var avatar: String?
    /// R2-3: why the name was guessed, e.g. a quote from the transcript.
    var evidence: String?

    /// The N of "Speaker N".
    var number: Int { Int(id.dropFirst()) ?? 0 }

    /// The name shown for `turn`: the speaker's name, else "Speaker N", else
    /// the track ("Them" or "Me"). A track with a single voice keeps its track
    /// name, and so does the main voice on the microphone, which is you.
    static func displayName(for turn: Turn, in speakers: [Speaker]) -> String {
        guard let id = turn.speakerID, let speaker = speakers.first(where: { $0.id == id }) else { return turn.speaker }
        if let name = speaker.name, !name.isEmpty { return name }
        let sameTrack = speakers.filter { $0.track == speaker.track }
        if sameTrack.count < 2 { return turn.speaker }
        if turn.isMe, isMainVoice(speaker, among: sameTrack) { return "Me" }
        return "Speaker \(speaker.number)"
    }

    /// Whether `turn` is you: the microphone track, and not someone else in the room.
    static func isMe(_ turn: Turn, in speakers: [Speaker]) -> Bool {
        guard turn.isMe else { return false }
        guard let id = turn.speakerID, let speaker = speakers.first(where: { $0.id == id }) else { return true }
        let sameTrack = speakers.filter { $0.track == speaker.track }
        return sameTrack.count < 2 || isMainVoice(speaker, among: sameTrack)
    }

    private static func isMainVoice(_ speaker: Speaker, among sameTrack: [Speaker]) -> Bool {
        sameTrack.max { $0.seconds < $1.seconds }?.id == speaker.id
    }
}

extension Meeting {
    /// The label for a turn in views and exports (see `Speaker.displayName`).
    func displayName(for turn: Turn) -> String {
        Speaker.displayName(for: turn, in: speakers)
    }
}

extension MeetingStore {
    private static let speakersFile = "speakers.json"

    func loadSpeakers(in folder: URL) -> [Speaker] { Self.readSpeakers(in: folder) }

    static func readSpeakers(in folder: URL) -> [Speaker] {
        (try? Data(contentsOf: folder.appendingPathComponent(speakersFile)))
            .flatMap { try? JSONDecoder().decode([Speaker].self, from: $0) } ?? []
    }

    /// Writes `speakers.json`, or removes it when no voices were separated.
    /// P-1: with `textOnly`, voice fingerprints are never written.
    func saveSpeakers(_ speakers: [Speaker], in folder: URL, textOnly: Bool = Prefs.textOnly) throws {
        guard Self.canWrite(folder: folder) else { throw UnreadableFolder() }
        let url = folder.appendingPathComponent(Self.speakersFile)
        guard !speakers.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let kept = textOnly ? Privacy.withoutVoiceprints(speakers) : speakers
        try encoder.encode(kept).write(to: url, options: .atomic)
    }
}

// MARK: - Matching whisper segments to voices

/// A word with its time, from whisper's word-level output. The text keeps
/// whisper's leading space, so words join back without guessing.
struct TimedWord: Hashable {
    var text: String
    var start: Double
    var end: Double
}

/// A whisper segment on a diarized track, with its words so it can be split.
struct Phrase: Hashable {
    var turn: Turn
    var words: [TimedWord]
}

enum SpeakerAssignment {
    /// Both voices must cover at least this long of a segment before it's split.
    static let minSplitSeconds = 1.5
    /// A segment outside any voice takes the nearest one within this distance.
    static let maxGapSeconds = 2.0

    /// Gives each segment the voice covering most of its time, splitting
    /// segments on word timestamps where two voices each cover at least 1.5 s,
    /// then smooths voices across whisper's phrase breaks mid-sentence (see
    /// `smoothChains`). Returns the turns with the voice index (nil when no
    /// voice is near).
    static func assign(_ phrases: [Phrase], to diarization: Diarization) -> [(turn: Turn, speaker: Int?)] {
        var out: [(turn: Turn, speaker: Int?)] = []
        for phrase in phrases {
            let cover = coverage(phrase.turn.start, phrase.turn.end, diarization)
            let major = cover.filter { $0.value >= minSplitSeconds }
            guard major.count >= 2, phrase.words.count >= 2 else {
                let best = cover.max { $0.value < $1.value }?.key
                out.append((phrase.turn, best ?? nearest(phrase.turn.start, phrase.turn.end, diarization)))
                continue
            }
            out += split(phrase, diarization)
        }
        return smoothChains(out)
    }

    /// Q-2: whisper breaks a phrase at every ~1 s pause, and each phrase took
    /// its own majority voice, so a sentence split across such a pause could
    /// get two different voices even though it's one person talking. Links
    /// neighbouring phrase-turns into a "sentence chain" when the gap between
    /// them is under 1 s, the first doesn't end a sentence (`.`, `?`, `!`) and
    /// the second doesn't start one (whisper capitalises a new sentence, so a
    /// continuation starting lowercase is the tell). In a chain with more than
    /// one voice, gives every turn the voice spoken longest in the chain
    /// (ties go to the first turn's voice). `nil` voices are left alone, both
    /// as members of a chain and when picking the winner. This also covers
    /// `split`'s own breaks: on a real meeting the diarizer flipped voices
    /// every few words through one person's opening sentence.
    static func smoothChains(_ assigned: [(turn: Turn, speaker: Int?)])
        -> [(turn: Turn, speaker: Int?)] {
        guard assigned.count > 1 else { return assigned }
        var chains: [[Int]] = [[0]]
        for i in 1..<assigned.count {
            if linksSentence(assigned[i - 1].turn, assigned[i].turn) {
                chains[chains.count - 1].append(i)
            } else {
                chains.append([i])
            }
        }
        var out = assigned
        for chain in chains where chain.count > 1 {
            var durations: [Int: Double] = [:]
            for i in chain {
                guard let voice = assigned[i].speaker else { continue }
                durations[voice, default: 0] += max(assigned[i].turn.end - assigned[i].turn.start, 0)
            }
            guard durations.count > 1 else { continue } // one voice (or none): nothing to smooth
            let maxDuration = durations.values.max()!
            let winner = chain.compactMap { assigned[$0].speaker }.first { durations[$0] == maxDuration } ?? durations.keys.first!
            for i in chain where assigned[i].speaker != nil {
                out[i].speaker = winner
            }
        }
        return out
    }

    /// Whether `next` reads as `prev`'s sentence continuing, close enough in
    /// time that it's the same breath.
    private static func linksSentence(_ prev: Turn, _ next: Turn) -> Bool {
        guard next.start - prev.end < 1 else { return false }
        guard let last = prev.text.last(where: { !$0.isWhitespace }), !".?!".contains(last) else { return false }
        guard let first = next.text.first(where: { !$0.isWhitespace }) else { return false }
        return first.isLowercase
    }

    /// Seconds of [start, end] covered by each voice.
    static func coverage(_ start: Double, _ end: Double, _ d: Diarization) -> [Int: Double] {
        var cover: [Int: Double] = [:]
        for seg in d.segments {
            let overlap = min(end, seg.end) - max(start, seg.start)
            if overlap > 0 { cover[seg.speaker, default: 0] += overlap }
        }
        return cover
    }

    private static func nearest(_ start: Double, _ end: Double, _ d: Diarization) -> Int? {
        let gaps = d.segments.map { seg in (seg.speaker, max(seg.start - end, start - seg.end, 0)) }
        guard let best = gaps.min(by: { $0.1 < $1.1 }), best.1 <= maxGapSeconds else { return nil }
        return best.0
    }

    /// Splits a phrase into runs of words by voice. Runs shorter than a second
    /// are folded into their neighbour, so one misplaced word doesn't become a turn.
    private static func split(_ phrase: Phrase, _ d: Diarization) -> [(turn: Turn, speaker: Int?)] {
        var runs: [(speaker: Int?, words: [TimedWord])] = []
        for word in phrase.words {
            let cover = coverage(word.start, word.end, d)
            let speaker = cover.max { $0.value < $1.value }?.key ?? nearest(word.start, word.end, d)
            if let last = runs.last, last.speaker == speaker {
                runs[runs.count - 1].words.append(word)
            } else {
                runs.append((speaker, [word]))
            }
        }
        func duration(_ words: [TimedWord]) -> Double { (words.last?.end ?? 0) - (words.first?.start ?? 0) }
        while runs.count > 1, let i = runs.indices.min(by: { duration(runs[$0].words) < duration(runs[$1].words) }),
              duration(runs[i].words) < 1 {
            let words = runs.remove(at: i).words
            if i > 0 {
                runs[i - 1].words += words
            } else {
                runs[0].words.insert(contentsOf: words, at: 0)
            }
            // Neighbours with the same voice become one run.
            var merged: [(speaker: Int?, words: [TimedWord])] = []
            for run in runs {
                if let last = merged.last, last.speaker == run.speaker {
                    merged[merged.count - 1].words += run.words
                } else {
                    merged.append(run)
                }
            }
            runs = merged
        }
        return runs.map { run in
            var turn = phrase.turn
            turn.start = run.words.first?.start ?? turn.start
            turn.end = run.words.last?.end ?? turn.end
            turn.text = run.words.map(\.text).joined().trimmingCharacters(in: .whitespaces)
            return (turn, run.speaker)
        }
    }

    /// Numbers the voices "S1", "S2", … by first appearance in `turns`, whose
    /// `speakerID` holds a temporary key per track and voice. Voices that
    /// never appear in a turn are dropped.
    static func number(_ turns: [Turn], voices: [String: (track: String, embedding: [Float], seconds: Double)])
        -> (turns: [Turn], speakers: [Speaker]) {
        var ids: [String: String] = [:]
        var speakers: [Speaker] = []
        let turns = turns.map { turn -> Turn in
            guard let key = turn.speakerID, let voice = voices[key] else {
                var t = turn
                t.speakerID = nil
                return t
            }
            if ids[key] == nil {
                let id = "S\(speakers.count + 1)"
                ids[key] = id
                speakers.append(Speaker(id: id, track: voice.track, embedding: voice.embedding, seconds: voice.seconds))
            }
            var t = turn
            t.speakerID = ids[key]
            return t
        }
        return (turns, speakers)
    }
}
