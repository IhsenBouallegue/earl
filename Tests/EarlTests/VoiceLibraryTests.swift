import Foundation
import Testing
@testable import Earl

/// R3-3: the voice library's rules, on plain values and a temporary file.
struct VoiceLibraryTests {
    /// A unit vector along axis `i`, nudged towards axis `j` by `tilt`.
    static func print(_ i: Int, tilt: Float = 0, towards j: Int = 0, dims: Int = 8) -> [Float] {
        var v = [Float](repeating: 0, count: dims)
        v[i] = 1
        v[j] += tilt
        return v
    }

    static func speaker(_ id: String, _ embedding: [Float], name: String? = nil, source: Speaker.NameSource? = nil,
                        seconds: Double = 60, track: String = "Them") -> Speaker {
        Speaker(id: id, track: track, name: name, nameSource: name == nil ? nil : source, embedding: embedding,
                seconds: seconds)
    }

    // MARK: Similarity and assignment

    @Test func cosineSimilarity() {
        #expect(abs(SpeakerEdit.cosine([1, 0], [1, 0]) - 1) < 1e-6)
        #expect(abs(SpeakerEdit.cosine([1, 0], [0, 1])) < 1e-6)
        #expect(abs(SpeakerEdit.cosine([1, 1], [2, 2]) - 1) < 1e-6)
        #expect(SpeakerEdit.cosine([1, 0], [1, 0, 0]) == 0) // different sizes never match
        #expect(SpeakerEdit.cosine([], []) == 0)
    }

    @Test func similarityIsTheBestSample() {
        let voice = Voice(name: "Sarah", samples: [Self.print(0), Self.print(1)])
        #expect(abs(VoiceLibrary.similarity(Self.print(1), to: voice) - 1) < 1e-6)
        #expect(VoiceLibrary.similarity(Self.print(2), to: voice) == 0)
        #expect(VoiceLibrary.similarity(Self.print(0), to: Voice(name: "Empty")) == 0)
    }

    @Test func greedyOneToOne() {
        let a = UUID(), b = UUID()
        let pairs = [
            VoiceLibrary.Match(speakerID: "S1", voiceID: a, score: 0.90),
            VoiceLibrary.Match(speakerID: "S2", voiceID: a, score: 0.95), // S2 wins Sarah
            VoiceLibrary.Match(speakerID: "S1", voiceID: b, score: 0.80), // so S1 gets Tom
            VoiceLibrary.Match(speakerID: "S2", voiceID: b, score: 0.85), // S2 is taken
        ]
        let out = VoiceLibrary.assign(pairs)
        #expect(out.count == 2)
        #expect(out.contains(VoiceLibrary.Match(speakerID: "S2", voiceID: a, score: 0.95)))
        #expect(out.contains(VoiceLibrary.Match(speakerID: "S1", voiceID: b, score: 0.80)))
    }

    @Test func eachVoiceOncePerMeeting() {
        var lib = VoiceLibrary()
        lib.learn(Self.print(0), name: "Sarah", source: "A/S1")
        // Two voices that both sound like Sarah (one person split in two): only the closer one is named.
        let speakers = [Self.speaker("S1", Self.print(0, tilt: 0.3, towards: 1)), Self.speaker("S2", Self.print(0))]
        let matches = lib.matches(for: speakers, attendees: [])
        #expect(matches.map(\.speakerID) == ["S2"])
    }

    // MARK: Thresholds

    @Test func attendeesLowerTheThreshold() {
        let sarah = Voice(name: "Sarah", email: "sarah@example.com", samples: [Self.print(0)])
        #expect(VoiceLibrary.threshold(for: sarah, attendees: []) == VoiceLibrary.strictThreshold)
        #expect(VoiceLibrary.attendeeThreshold < VoiceLibrary.strictThreshold)
        let byName = [Attendee(name: "Sarah Miller", email: nil, isMe: false)]
        #expect(VoiceLibrary.threshold(for: sarah, attendees: byName) == VoiceLibrary.attendeeThreshold)
        let byEmail = [Attendee(name: "S. M.", email: "SARAH@example.com", isMe: false)]
        #expect(VoiceLibrary.threshold(for: sarah, attendees: byEmail) == VoiceLibrary.attendeeThreshold)
        let other = [Attendee(name: "Sarah Jones", email: nil, isMe: false)]
        #expect(VoiceLibrary.threshold(for: Voice(name: "Sarah Miller"), attendees: other) == VoiceLibrary.strictThreshold)
        let you = [Attendee(name: "Sarah", email: nil, isMe: true)]
        #expect(VoiceLibrary.threshold(for: sarah, attendees: you) == VoiceLibrary.strictThreshold)
    }

    @Test func attendeeBonusDecidesInBetween() {
        var lib = VoiceLibrary()
        lib.learn(Self.print(0), name: "Sarah", source: "A/S1")
        // Between the two thresholds.
        let target = (VoiceLibrary.strictThreshold + VoiceLibrary.attendeeThreshold) / 2
        let tilt = (1 / (target * target) - 1).squareRoot()
        let s = Self.speaker("S1", Self.print(0, tilt: tilt, towards: 1))
        #expect(abs(VoiceLibrary.similarity(s.embedding, to: lib.voices[0]) - target) < 1e-4)
        #expect(lib.matches(for: [s], attendees: []).isEmpty)
        let invited = [Attendee(name: "Sarah", email: nil, isMe: false)]
        #expect(lib.matches(for: [s], attendees: invited).count == 1)
    }

    @Test func matchesOnlyUnnamedLongEnoughCallVoices() {
        var lib = VoiceLibrary()
        lib.learn(Self.print(0), name: "Sarah", source: "A/S1")
        lib.learn(Self.print(1), name: "Tom", source: "A/S2")
        lib.learn(Self.print(2), name: "Megan", source: "A/S3")
        let speakers = [
            Self.speaker("S1", Self.print(0), seconds: 5),                                  // too short
            Self.speaker("S2", Self.print(1), name: "Tom", source: .confirmed),            // already named
            Self.speaker("S3", Self.print(2), track: "Me"),                                // your side
            Self.speaker("S4", Self.print(3)),                                             // a stranger
        ]
        #expect(lib.matches(for: speakers, attendees: []).isEmpty)
        // A name carried over to another voice isn't given twice.
        let carried = [Self.speaker("S1", Self.print(4), name: "Sarah", source: .confirmed), Self.speaker("S2", Self.print(0))]
        #expect(lib.matches(for: carried, attendees: []).isEmpty)
    }

    // MARK: Learning

    @Test func sampleCapKeepsTheNewest() {
        var lib = VoiceLibrary()
        for k in 0..<(VoiceLibrary.maxSamples + 3) {
            lib.learn(Self.print(k % 8, tilt: Float(k), towards: (k + 1) % 8), name: "Sarah", source: "M\(k)/S1")
        }
        let v = lib.voices[0]
        #expect(lib.voices.count == 1)
        #expect(v.samples.count == VoiceLibrary.maxSamples)
        #expect(v.sources.first == "M3/S1")
        #expect(v.sources.last == "M12/S1")
        #expect(v.meetings == VoiceLibrary.maxSamples + 3)
    }

    @Test func sameSpeakerReplacesItsSample() {
        var lib = VoiceLibrary()
        lib.learn(Self.print(0), name: "Sarah", source: "A/S1")
        lib.learn(Self.print(1), name: "sarah", source: "A/S1")
        lib.learn(Self.print(2), name: "Sarah", source: "A/S3") // same meeting, another split of her voice
        #expect(lib.voices.count == 1)
        #expect(lib.voices[0].samples == [Self.print(1), Self.print(2)])
        #expect(lib.voices[0].meetings == 1)
    }

    @Test func learnsOnlyConfirmedLongCallVoices() {
        var lib = VoiceLibrary()
        let after = [
            Self.speaker("S1", Self.print(0), name: "Sarah", source: .confirmed),
            Self.speaker("S2", Self.print(1), name: "Tom", source: .guessed),
            Self.speaker("S3", Self.print(2), name: "Megan", source: .voice),
            Self.speaker("S4", Self.print(3), name: "Lisa", source: .confirmed, seconds: 12),
            Self.speaker("S5", Self.print(4), name: "Bob", source: .confirmed, track: "Me"),
        ]
        lib.update(meetingID: "A", before: [], after: after,
                   attendees: [Attendee(name: "Sarah Miller", email: "sarah@example.com", isMe: false)])
        #expect(lib.voices.map(\.name) == ["Sarah"])
        #expect(lib.voices[0].email == "sarah@example.com")
        #expect(lib.voices[0].sources == ["A/S1"])
    }

    @Test func correctingANameMovesTheSample() {
        var lib = VoiceLibrary()
        lib.learn(Self.print(0), name: "Sarah", source: "B/S1") // from an earlier meeting
        let before = [Self.speaker("S2", Self.print(1), name: "Sarah", source: .confirmed)]
        lib.update(meetingID: "A", before: [], after: before, attendees: [])
        #expect(lib.voices[0].samples.count == 2)
        #expect(lib.voices[0].meetings == 2)

        let after = SpeakerEdit.rename(before, id: "S2", to: "Kate", source: .confirmed)
        lib.update(meetingID: "A", before: before, after: after, attendees: [])
        #expect(lib.voices.first { $0.name == "Sarah" }?.samples == [Self.print(0)])
        #expect(lib.voices.first { $0.name == "Sarah" }?.meetings == 1)
        #expect(lib.voices.first { $0.name == "Kate" }?.samples == [Self.print(1)])

        // Clearing the name takes the sample back; a voice left empty goes.
        let cleared = SpeakerEdit.rename(after, id: "S2", to: nil, source: nil)
        lib.update(meetingID: "A", before: after, after: cleared, attendees: [])
        #expect(lib.voices.map(\.name) == ["Sarah"])
    }

    @Test func recognisedThenConfirmedLearns() {
        var lib = VoiceLibrary()
        lib.learn(Self.print(0), name: "Sarah", source: "A/S1")
        let meetingB = [Self.speaker("S1", Self.print(0, tilt: 0.1, towards: 1)), Self.speaker("S2", Self.print(5))]
        let named = lib.apply(lib.matches(for: meetingB, attendees: []), to: meetingB)
        #expect(named[0].name == "Sarah")
        #expect(named[0].nameSource == .voice)
        #expect(named[0].recognisedHelp == "Recognised by voice (Sarah, 1 meeting)")
        #expect(named[1].name == nil)
        // The guesser only sees the voice still unnamed.
        let meeting = Meeting(id: "B", folder: URL(fileURLWithPath: "/tmp"), info: MeetingInfo(title: "B", titleIsDefault: false, startedAt: Date(), duration: 60, status: .done),
                              turns: [], summary: "", files: [], speakers: named)
        #expect(SpeakerNameGuesser.candidates(in: meeting).map(\.id) == ["S2"])
        // A voice match alone isn't learned; your confirmation is.
        lib.update(meetingID: "B", before: [], after: named, attendees: [])
        #expect(lib.voices[0].samples.count == 1)
        let confirmed = SpeakerEdit.rename(named, id: "S1", to: "Sarah", source: .confirmed)
        lib.update(meetingID: "B", before: named, after: confirmed, attendees: [])
        #expect(lib.voices[0].samples.count == 2)
        #expect(lib.voices[0].meetings == 2)
    }

    // MARK: Storage

    @Test func codableRoundTrip() throws {
        let voice = Voice(name: "Sarah", email: "s@example.com", samples: [[0.25, -0.5], [1, 0]], sources: ["A/S1", "B/S2"],
                          updatedAt: Date(timeIntervalSince1970: 1_790_000_000), meetings: 2)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("earl-voices-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try VoiceStore.write([voice], to: url)
        #expect(VoiceStore.read(url) == [voice])
        // Files without `sources` still load.
        let old = #"[{"id":"\#(voice.id)","name":"Tom","samples":[[1]],"updatedAt":"2026-09-01T10:00:00Z","meetings":1}]"#
        try Data(old.utf8).write(to: url)
        #expect(VoiceStore.read(url).first?.name == "Tom")
        #expect(VoiceStore.read(url).first?.sources == [])
    }

    @MainActor @Test func storeKeepsNothingWhenOff() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("earl-voices-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("voices.json")
        let store = VoiceStore(url: url, isEnabled: { false })
        let after = [Self.speaker("S1", Self.print(0), name: "Sarah", source: .confirmed)]
        store.learn(meetingID: "A", before: [], after: after, attendees: [])
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(store.recognise([Self.speaker("S1", Self.print(0))], attendees: []).speakers[0].name == nil)
    }

    @MainActor @Test func storeLearnsDeletesAndForgets() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("earl-voices-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("voices.json")
        let store = VoiceStore(url: url, isEnabled: { true })
        store.learn(meetingID: "A", before: [], after: [
            Self.speaker("S1", Self.print(0), name: "Sarah", source: .confirmed),
            Self.speaker("S2", Self.print(1), name: "Tom", source: .confirmed),
        ], attendees: [])
        #expect(FileManager.default.fileExists(atPath: url.path))
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
        #expect(VoiceStore(url: url).voices.map(\.name) == ["Sarah", "Tom"])

        // Meeting B: Sarah again, recognised by voice.
        let b = store.recognise([Self.speaker("S1", Self.print(3)), Self.speaker("S2", Self.print(0))], attendees: [])
        #expect(b.speakers[1].name == "Sarah" && b.speakers[1].nameSource == .voice)
        #expect(b.speakers[0].name == nil)

        store.delete(store.voices.first { $0.name == "Sarah" }!.id)
        #expect(VoiceStore.read(url).map(\.name) == ["Tom"])
        #expect(store.recognise([Self.speaker("S2", Self.print(0))], attendees: []).speakers[0].name == nil)

        store.forgetAll()
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(store.voices.isEmpty)
    }

    @MainActor @Test func offByDefault() {
        // Nothing sets it in the test process, so this is the shipped default.
        #expect(Prefs.rememberVoices == false)
        #expect(VoiceStore(url: URL(fileURLWithPath: "/nonexistent/voices.json")).voices.isEmpty)
    }

    @Test func settingsDetail() {
        let voice = Voice(name: "Sarah", samples: [[1], [1], [1]], updatedAt: Date(), meetings: 2)
        #expect(VoiceSettings.detail(voice).hasPrefix("3 samples · 2 meetings · last heard"))
    }
}
