import Foundation
import Testing
@testable import Earl

/// Full synthetic meetings (T-1). These call `say`, `afconvert` and, for the
/// baseline, Whisper, so they only run when asked:
///
/// - `EARL_SYNTH=1 ./test.sh --filter SyntheticMeetingTests` generates every
///   preset twice and checks determinism, timing and levels.
/// - `EARL_SYNTH_WHISPER=1` also runs Whisper on each preset and prints the
///   baseline scores.
/// - `tools/make-test-meeting.sh` sets `EARL_SYNTH_OUT` and runs `writeMeetingFolder`.
///
/// Optional: `EARL_SYNTH_PRESET` (comma list), `EARL_SYNTH_SEED`, `EARL_SYNTH_MINUTES`.
struct SyntheticMeetingTests {
    private static let env = ProcessInfo.processInfo.environment
    static let enabled = env["EARL_SYNTH"] == "1"
    static let whisper = env["EARL_SYNTH_WHISPER"] == "1"
    static let out = env["EARL_SYNTH_OUT"]

    private var seed: UInt64 { UInt64(Self.env["EARL_SYNTH_SEED"] ?? "") ?? 1 }
    private var minutes: Double { Double(Self.env["EARL_SYNTH_MINUTES"] ?? "") ?? 5 }
    private var presets: [SyntheticMeeting.Preset] {
        guard let list = Self.env["EARL_SYNTH_PRESET"] else { return SyntheticMeeting.Preset.allCases }
        return list.split(separator: ",").compactMap { SyntheticMeeting.Preset(rawValue: String($0)) }
    }

    private func tempFolder(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("earl-synth").appendingPathComponent(name)
    }

    /// Used by tools/make-test-meeting.sh.
    @Test(.enabled(if: out != nil)) func writeMeetingFolder() throws {
        let preset = try #require(presets.first, "Unknown preset \(Self.env["EARL_SYNTH_PRESET"] ?? "")")
        let started = Date()
        let meeting = try SyntheticMeeting.make(preset: preset, seed: seed, minutes: minutes,
                                                in: URL(fileURLWithPath: Self.out!))
        print(String(format: "Wrote %@ (%.0f s of audio) in %.1f s", meeting.folder.path, meeting.truth.duration,
                     Date().timeIntervalSince(started)))
    }

    @Test(.enabled(if: enabled)) func presetsAreDeterministicAndAligned() throws {
        for preset in presets {
            let a = tempFolder("\(preset.rawValue)-seed\(seed)")
            let b = tempFolder("\(preset.rawValue)-seed\(seed)-again")
            let started = Date()
            let first = try SyntheticMeeting.make(preset: preset, seed: seed, minutes: minutes, in: a)
            let took = Date().timeIntervalSince(started)
            let second = try SyntheticMeeting.make(preset: preset, seed: seed, minutes: minutes, in: b)
            defer { try? FileManager.default.removeItem(at: b) }

            for name in ["system-16k.wav", "mic-16k.wav", "mix.wav", "truth.json", "README.txt"] {
                let x = try Data(contentsOf: a.appendingPathComponent(name))
                let y = try Data(contentsOf: b.appendingPathComponent(name))
                #expect(x == y, "\(preset) \(name) differs between runs")
            }
            #expect(first.truth == second.truth)
            #expect(try SyntheticTruth.load(first.truthURL) == first.truth)

            let t = first.truth
            let system = try SynthDSP.readAudio(first.system)
            let mic = try SynthDSP.readAudio(first.mic)
            let mix = try SynthDSP.readAudio(first.mix)
            #expect(abs(Double(system.count) / 16000 - t.duration) < 0.01)
            #expect(system.count == mic.count && mic.count == mix.count)
            let mixDb = SynthDSP.decibels(SynthDSP.rms(mix))
            #expect(abs(mixDb + 20) < 3, "\(preset) mix at \(mixDb) dBFS")
            #expect(SynthDSP.peak(mix) < 0.999)

            // Nobody overlaps themselves.
            for sp in t.speakers {
                let own = t.utterances.filter { $0.speaker == sp.id }
                #expect(zip(own, own.dropFirst()).allSatisfy { $0.end <= $1.start }, "\(preset) \(sp.name) talks over themselves")
            }

            // Every preset has the obstacles it promises.
            let kinds = Dictionary(grouping: t.utterances, by: \.kind).mapValues(\.count)
            let remote = t.speakers.filter { $0.track == "Them" }.count
            switch preset {
            case .clean:
                #expect(remote == 3 && t.overlaps.isEmpty && kinds[.interjection] == nil)
            case .realistic:
                #expect(remote == 4 && (3...6).contains(kinds[.interjection] ?? 0))
                #expect(t.degradations.codec != nil && t.degradations.bitrate == 24000)
            case .hard:
                #expect(remote == 5 && kinds[.crosstalk] == 2)
                #expect(t.speakers.contains { $0.voice == "Samantha" } && t.speakers.contains { $0.voice == "Karen" })
                let crosstalk = t.overlaps.filter { o in
                    t.utterances.contains { $0.kind == .crosstalk && $0.start <= o.start && o.end <= $0.end }
                }
                let longest = crosstalk.map { $0.end - $0.start }.max() ?? 0
                #expect(longest >= 2.9, "crosstalk overlap only \(longest) s")
                #expect((0.005...0.035).contains(t.degradations.packetLoss ?? 0))
            case .speakers:
                #expect(remote == 3 && !t.echo.isEmpty)
            case .german:
                #expect(t.speakers.allSatisfy { $0.voice == "Anna" || $0.voice.contains("German") })
            case .mixed:
                #expect(remote == 3 && t.speakers.contains { $0.voice == "Daniel" })
            case .backchannel:
                // The quiet one (C) says only short things, mostly over others.
                let quiet = t.utterances.filter { $0.speaker == "C" }
                #expect(remote == 3 && quiet.count >= 10)
                #expect(quiet.allSatisfy { $0.end - $0.start < 3 })
                #expect(quiet.filter { $0.kind == .interjection }.count > quiet.count / 2)
            }

            // The truth is where the audio is: speech onsets within 50 ms of
            // the truth for lines that start after a gap on their track.
            let onsets = onsetErrors(t, track: "Them", audio: system)
                + (t.echo.isEmpty ? onsetErrors(t, track: "Me", audio: mic) : [])
            let sorted = onsets.map(abs).sorted()
            let p90 = sorted.isEmpty ? 1 : sorted[Int(Double(sorted.count - 1) * 0.9)]
            #expect(sorted.count >= 10)
            #expect(p90 <= 0.05, "\(preset) onset p90 \(p90) s")

            // Speech inside utterances is well above the gaps between them.
            let (inside, gap) = speechAndGapLevels(t, track: "Them", audio: system)
            #expect(inside - gap > 12, "\(preset) speech \(inside) dB vs gaps \(gap) dB")

            print(String(format: "[%@] %.0f s audio in %.1f s; %d utterances, %d overlaps; mix %.1f dBFS, "
                         + "speech-gap %.1f dB; onset error median %.0f ms, p90 %.0f ms, max %.0f ms (n=%d)",
                         preset.rawValue, t.duration, took, t.utterances.count, t.overlaps.count, mixDb, inside - gap,
                         sorted[sorted.count / 2] * 1000, p90 * 1000, (sorted.last ?? 0) * 1000, sorted.count))
            print(spectrumSummary(preset.rawValue, system))
        }
    }

    /// Runs today's Whisper (no speaker separation) on each preset and prints
    /// what the scoring helper measures, as a baseline for later features.
    @Test(.enabled(if: whisper)) func whisperBaseline() async throws {
        let whisperPath = Prefs.defaultWhisperPath, model = Prefs.defaultWhisperModel
        try #require(FileManager.default.isExecutableFile(atPath: whisperPath))
        try #require(FileManager.default.fileExists(atPath: model))
        var rows: [String] = []
        for preset in presets {
            let folder = tempFolder("\(preset.rawValue)-seed\(seed)")
            let meeting = try SyntheticMeeting.make(preset: preset, seed: seed, minutes: minutes, in: folder)
            var segments: [Turn] = []
            for (file, speaker) in [(meeting.system, "Them"), (meeting.mic, "Me")] {
                let base = folder.appendingPathComponent("whisper-\(speaker)")
                var args = ["-m", model, "-f", file.path, "-l", "auto", "-oj", "-of", base.path, "-np", "-t", "8"]
                if FileManager.default.fileExists(atPath: Prefs.vadModel) { args += ["--vad", "-vm", Prefs.vadModel] }
                try SynthDSP.run(whisperPath, args)
                segments += try Transcriber.parse(base.appendingPathExtension("json"), speaker: speaker).turns
            }
            let raw = SyntheticScore.score(truth: meeting.truth, segments: SyntheticScore.segments(from: segments))
            print("[\(preset.rawValue)] Whisper, no separation, raw segments:\n\(raw)\n")
            if Self.env["EARL_SYNTH_VERBOSE"] == "1" { print(raw.lostExamples.joined(separator: "\n")) }
            var row = String(format: "| %@ | %.1f %% | %.1f %% | %.1f %% | %.1f %% | %.1f %% | %d/%d/%d |",
                             preset.rawValue, raw.lostShare * 100, raw.lostInCrosstalkShare * 100,
                             raw.lostInOverlapShare * 100, raw.lostElsewhereShare * 100, raw.speakerAccuracy * 100,
                             raw.interjectionsRightSpeaker, raw.interjectionsWrongSpeaker, raw.interjectionsLost)
            if !meeting.truth.echo.isEmpty {
                // What survives Earl's own echo filter.
                // buildTurns merges what it keeps, so find the surviving raw
                // "Me" segments by their text and score those.
                let keptMe = Transcriber.buildTurns(from: segments).filter { $0.speaker == "Me" }.map(\.text)
                let filtered = segments.filter { s in s.speaker == "Them" || keptMe.contains { $0.contains(s.text) } }
                let after = SyntheticScore.score(truth: meeting.truth, segments: SyntheticScore.segments(from: filtered))
                print("[\(preset.rawValue)] after Earl's echo filter:\n\(after)\n")
                row += " \(raw.echoWordsAsMe) echo words on Me, \(after.echoWordsAsMe) after Earl's echo filter"
                    + String(format: " (your words lost: %d before, %d after) |",
                             raw.lostWords(track: "Me"), after.lostWords(track: "Me"))
            } else {
                row += " – |"
            }
            rows.append(row)
        }
        print("| preset | words lost | in crosstalk | in overlaps | elsewhere | right speaker | interjections right/wrong/lost | echo |")
        print("|---|---|---|---|---|---|---|---|")
        rows.forEach { print($0) }
    }

    // MARK: - Measuring

    /// For utterances on `track` with at least 0.4 s of quiet on that track
    /// before them, how far the audible onset is from the truth's start.
    private func onsetErrors(_ t: SyntheticTruth, track: String, audio: [Float]) -> [Double] {
        let mine = t.utterances.filter { $0.track == track }
        let far = t.degradations.farSpeaker
        let block = SynthDSP.samples(0.005)
        return mine.compactMap { u -> Double? in
            guard u.speaker != far, u.end - u.start > 0.8,
                  !mine.contains(where: { $0 != u && $0.end > u.start - 0.4 && $0.start < u.start + 0.3 }) else { return nil }
            // Floor: the loudest 5 ms block of the quiet before; the onset is the
            // first block well above it and near the speech level.
            let quiet = SynthDSP.samples(u.start - 0.35)..<SynthDSP.samples(u.start - 0.05)
            let speech = SynthDSP.samples(u.start)..<SynthDSP.samples(min(u.end, u.start + 1))
            let blocks = stride(from: quiet.lowerBound, to: quiet.upperBound, by: block).map {
                SynthDSP.rms(audio, $0..<($0 + block))
            }
            let floor = blocks.max() ?? 0
            let level = SynthDSP.rms(audio, speech)
            let threshold = max(floor * 2, level * SynthDSP.linear(-20))
            var i = SynthDSP.samples(u.start - 0.3)
            while i < speech.upperBound {
                if SynthDSP.rms(audio, i..<(i + block)) > threshold { return SynthDSP.seconds(i) - u.start }
                i += block
            }
            return nil
        }
    }

    /// Average level (dB) inside utterances on `track` vs in gaps where nobody
    /// on that track talks.
    private func speechAndGapLevels(_ t: SyntheticTruth, track: String, audio: [Float]) -> (Double, Double) {
        let mine = t.utterances.filter { $0.track == track }.sorted { $0.start < $1.start }
        let inside = mine.map { SynthDSP.samples($0.start)..<SynthDSP.samples($0.end) }
        var gaps: [Range<Int>] = []
        var end = 0.0
        for u in mine {
            // Leave room for reverb tails and the next word's lead-in.
            if u.start - end > 0.6 { gaps.append(SynthDSP.samples(end + 0.25)..<SynthDSP.samples(u.start - 0.1)) }
            end = max(end, u.end)
        }
        return (SynthDSP.decibels(SynthDSP.rms(audio, over: inside)), SynthDSP.decibels(SynthDSP.rms(audio, over: gaps)))
    }

    /// Share of energy per band, to check the call sounds band-limited and
    /// noisy the way the preset says.
    private func spectrumSummary(_ name: String, _ x: [Float]) -> String {
        let total = SynthDSP.rms(x)
        let bands: [(String, [Float])] = [
            ("<150 Hz", SynthDSP.filter(x, .lowpass, 150)),
            ("150-3.4k", SynthDSP.filter(SynthDSP.filter(x, .highpass, 150), .lowpass, 3400)),
            ("3.4-7k", SynthDSP.filter(SynthDSP.filter(x, .highpass, 3400), .lowpass, 7000)),
            (">7 kHz", SynthDSP.filter(SynthDSP.filter(x, .highpass, 7000), .highpass, 7000)),
        ]
        let parts = bands.map { String(format: "%@ %.1f dB", $0.0, SynthDSP.decibels(SynthDSP.rms($0.1) / total)) }
        return "[\(name)] system spectrum relative to total: " + parts.joined(separator: ", ")
    }
}
