import Foundation
import Testing
@testable import Earl

/// R2-4 evaluation on T-1's synthetic meetings: the `speakers` preset has the
/// call's echo on the mic (-18 dB, 60-120 ms, reverb) and double talk; the
/// `realistic` preset has no echo, to check the gate then changes nothing.
/// Runs Whisper, so it only runs when asked (tools/eval-echo.sh):
///
///     EARL_ECHO_EVAL=1 ./test.sh --filter EchoEvalTests
///
/// Optional: `EARL_ECHO_SEEDS` (default "1,2,3"), `EARL_SYNTH_MINUTES` (5),
/// `EARL_ECHO_NO_WHISPER=1` for the frame-level numbers only,
/// `EARL_ECHO_VERBOSE=1` to print leftover echo and lost words.
@Suite(.serialized)
struct EchoEvalTests {
    static let env = ProcessInfo.processInfo.environment
    static let enabled = env["EARL_ECHO_EVAL"] == "1"
    static let longRun = env["EARL_ECHO_LONG"] == "1"

    private var seeds: [UInt64] {
        (Self.env["EARL_ECHO_SEEDS"] ?? "1,2,3").split(separator: ",").compactMap { UInt64($0) }
    }
    private var minutes: Double { Double(Self.env["EARL_SYNTH_MINUTES"] ?? "") ?? 5 }
    private var whisper: Bool { Self.env["EARL_ECHO_NO_WHISPER"] != "1" }

    @Test(.enabled(if: enabled)) func echoGateOnSyntheticMeetings() throws {
        let whisperPath = Prefs.defaultWhisperPath, model = Prefs.defaultWhisperModel
        if whisper {
            try #require(FileManager.default.isExecutableFile(atPath: whisperPath))
            try #require(FileManager.default.fileExists(atPath: model))
        }
        var rows: [String] = []
        var totals = [String: (echo: Int, lost: Int)]()
        for preset in [SyntheticMeeting.Preset.speakers, .realistic] {
            for seed in seeds {
                let meeting = try Self.meeting(preset, seed: seed, minutes: minutes)
                let started = Date()
                let (result, analyzed) = try EchoFilter.cleanAndAnalyze(mic: meeting.mic, system: meeting.system)
                let took = Date().timeIntervalSince(started)
                defer { if let r = result { try? FileManager.default.removeItem(at: r.cleaned) } }
                let analysis = try #require(analyzed)

                // Frame-level: how much of your speech and of the echo alone got muted.
                let frames = frameStats(meeting.truth, analysis)
                if Self.env["EARL_ECHO_VERBOSE"] == "1" {
                    // How well "heard you" separates you from echo the gate kept.
                    let me = meeting.truth.utterances.filter { $0.track == "Me" }
                    var inside = (all: 0, heard: 0), outside = (all: 0, heard: 0)
                    for (i, l) in analysis.labels.enumerated() where l == .you || l == .both {
                        let t = Double(i) / 100
                        if me.contains(where: { $0.start <= t && t <= $0.end }) {
                            inside.all += 1; if analysis.heardYou[i] { inside.heard += 1 }
                        } else if !me.contains(where: { $0.start - 0.3 <= t && t <= $0.end + 0.3 }) {
                            outside.all += 1; if analysis.heardYou[i] { outside.heard += 1 }
                        }
                    }
                    print("  you/both frames in your speech: \(inside.all), heard you \(inside.heard); "
                          + "elsewhere: \(outside.all), heard you \(outside.heard)")
                    for u in meeting.truth.utterances where u.track == "Me" {
                        let r = Int(u.start * 100)..<min(analysis.mute.count, Int(u.end * 100))
                        let muted = r.filter { analysis.mute[$0] }.count
                        let labels = r.map { "sEyb".map(String.init)[Int(analysis.labels[$0].rawValue)] }.joined()
                        if muted > 0 || u.kind == .interjection {
                            print(String(format: "  %.2f-%.2f muted %d frames %@: %@", u.start, u.end, muted, u.text, labels))
                        }
                    }
                }
                var row = String(format: "| %@ | %d | %@ | %.0f ms (true %.0f) | corr %.2f | %.1f s | %.1f %% | %.1f %% | %.2f s |",
                                 preset.rawValue, seed, analysis.detected ? "yes" : "no", analysis.delayMs,
                                 meeting.truth.echo.first?.delayMs ?? 0, analysis.correlation,
                                 result?.removedSeconds ?? 0, frames.echoMuted * 100, frames.youMuted * 100, took)

                if whisper {
                    // Optionally the names in Whisper's prompt, as R2-1 does with the calendar's attendees.
                    let prompt: String? = Self.env["EARL_ECHO_PROMPT"] == "1"
                        ? WhisperPrompt.build(extraNames: meeting.truth.speakers.map(\.name), vocabulary: []) : nil
                    let tag = prompt == nil ? "" : "-prompt"
                    let them = try transcribe(meeting.system, "Them", cache: "whisper-Them\(tag)", prompt: prompt, in: meeting.folder)
                    let rawMe = try transcribe(meeting.mic, "Me", cache: "whisper-Me\(tag)", prompt: prompt, in: meeting.folder)
                    let cleanMe = try result.map {
                        try transcribe($0.cleaned, "Me", cache: nil, prompt: prompt, in: meeting.folder)
                    } ?? rawMe
                    let spans = result?.youSpans
                    if Self.env["EARL_ECHO_VERBOSE"] == "1" {
                        let kept = EchoFilter.dropEchoedSegments(them + cleanMe, youSpans: spans)
                        for seg in cleanMe where !kept.contains(seg) {
                            print(String(format: "  text filter dropped Me %.2f-%.2f %@", seg.start, seg.end, seg.text))
                        }
                    }
                    let variants: [(String, [Turn])] = [
                        ("raw", them + rawMe),
                        ("old text filter", Self.legacyFilter(them + rawMe)),
                        ("new text filter", EchoFilter.dropEchoedSegments(them + rawMe, youSpans: nil)),
                        ("gate", them + cleanMe),
                        ("gate + text", EchoFilter.dropEchoedSegments(them + cleanMe, youSpans: spans)),
                    ]
                    for (name, segments) in variants {
                        let s = SyntheticScore.score(truth: meeting.truth, segments: SyntheticScore.segments(from: segments))
                        row += " \(s.echoWordsAsMe) / \(s.lostWords(track: "Me")) |"
                        let key = "\(preset.rawValue) \(name)"
                        totals[key] = ((totals[key]?.echo ?? 0) + s.echoWordsAsMe, (totals[key]?.lost ?? 0) + s.lostWords(track: "Me"))
                        if Self.env["EARL_ECHO_VERBOSE"] == "1", name == "raw" || name == "gate + text" {
                            let meID = meeting.truth.speakers.first { $0.track == "Me" }?.id ?? "?"
                            print("[\(preset.rawValue) seed \(seed) \(name)] your lost words:")
                            print(s.lostExamples.filter { $0.contains(" \(meID) ") }.joined(separator: "\n"))
                            if name != "raw" {
                                // The segments the echo words sit in: scoring without them lowers the count.
                                for seg in segments where seg.speaker == "Me" {
                                    let without = SyntheticScore.score(truth: meeting.truth,
                                                                       segments: SyntheticScore.segments(from: segments.filter { $0 != seg }))
                                    if without.echoWordsAsMe < s.echoWordsAsMe {
                                        print(String(format: "  echo words in Me %.1f-%.1f %@", seg.start, seg.end, seg.text))
                                    }
                                }
                            }
                        }
                    }
                    let meWords = meeting.truth.utterances.filter { $0.track == "Me" }
                        .reduce(0) { $0 + SyntheticScore.normalize($1.text).count }
                    row += " \(meWords) |"
                }
                rows.append(row)
                print(row)
            }
        }
        print("""

        Echo words on Me / your words lost, per variant:
        | preset | seed | echo found | delay | | removed | echo-only muted | your speech muted | gate took \
        | raw | old text filter | new text filter | gate | gate + text | your words |
        |---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
        """)
        rows.forEach { print($0) }
        for (key, v) in totals.sorted(by: { $0.key < $1.key }) { print("total \(key): \(v.echo) echo words, \(v.lost) of your words lost") }
    }

    /// The real Transcriber on a copy of a synthetic meeting folder, on
    /// speakers (gate runs) and on headphones (gate skipped). Speaker
    /// separation is off so the speaker model isn't needed.
    @Test(.enabled(if: enabled && Self.env["EARL_ECHO_NO_WHISPER"] != "1")) @MainActor func transcriberRunsTheGate() async throws {
        let meeting = try Self.meeting(.speakers, seed: seeds.first ?? 1, minutes: minutes)
        let fm = FileManager.default
        for usedSpeakers in [nil, true, false] as [Bool?] {
            let folder = fm.temporaryDirectory.appendingPathComponent("earl-echo-eval/pipeline-\(UUID().uuidString)")
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: folder) }
            for name in ["mic-16k.wav", "system-16k.wav"] {
                try fm.copyItem(at: meeting.folder.appendingPathComponent(name), to: folder.appendingPathComponent(name))
            }
            let micBefore = try Data(contentsOf: folder.appendingPathComponent("mic-16k.wav"))
            let leftovers = { Set((try? fm.contentsOfDirectory(atPath: fm.temporaryDirectory.path)) ?? []).filter { $0.hasPrefix("earl-mic-clean-") } }
            let cleanBefore = leftovers()

            var transcriber = Transcriber()
            transcriber.whisperPath = Prefs.defaultWhisperPath
            transcriber.modelPath = Prefs.defaultWhisperModel
            transcriber.language = "auto"
            transcriber.prompt = nil
            transcriber.diarizer = nil
            transcriber.diarizeMic = false
            transcriber.usedSpeakers = usedSpeakers
            let statuses = StatusLog()
            let started = Date()
            let output = try await transcriber.transcribe(folder: folder) { event in
                if case .removingEcho = event { statuses.removing = true }
            }
            let took = Date().timeIntervalSince(started)

            #expect(try Data(contentsOf: folder.appendingPathComponent("mic-16k.wav")) == micBefore, "mic-16k.wav changed")
            #expect(leftovers() == cleanBefore, "cleaned copy left behind")
            let s = SyntheticScore.score(truth: meeting.truth, segments: SyntheticScore.segments(from: output.turns))
            print(String(format: "Transcriber, usedSpeakers %@: echo removed %@ s, %d echo words on Me, %d of your words lost, took %.0f s",
                         usedSpeakers.map { "\($0)" } ?? "nil", output.echoRemovedSeconds.map { String(format: "%.0f", $0) } ?? "–",
                         s.echoWordsAsMe, s.lostWords(track: "Me"), took))
            if usedSpeakers == false {
                #expect(output.echoRemovedSeconds == nil && !statuses.removing)
            } else {
                #expect((output.echoRemovedSeconds ?? 0) > 60 && statuses.removing)
                #expect(s.echoWordsAsMe <= 5)
            }
        }
    }

    @MainActor final class StatusLog { var removing = false }

    /// Times the gate on an hour of audio: 12 x 5 minutes of the speakers preset.
    @Test(.enabled(if: enabled && longRun)) func echoGateOnAnHour() throws {
        let one = try Self.meeting(.speakers, seed: 1, minutes: 5)
        let mic = try SynthDSP.readAudio(one.mic), system = try SynthDSP.readAudio(one.system)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("earl-echo-eval/hour")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let micURL = folder.appendingPathComponent("mic-16k.wav"), sysURL = folder.appendingPathComponent("system-16k.wav")
        try SynthDSP.writeWAV(Array([[Float]](repeating: mic, count: 12).joined()), to: micURL)
        try SynthDSP.writeWAV(Array([[Float]](repeating: system, count: 12).joined()), to: sysURL)
        let started = Date()
        let result = try #require(try EchoFilter.clean(mic: micURL, system: sysURL))
        let took = Date().timeIntervalSince(started)
        try? FileManager.default.removeItem(at: result.cleaned)
        print(String(format: "An hour of audio: echo gate took %.1f s, removed %.0f s", took, result.removedSeconds))
    }

    // MARK: - Helpers

    static func meeting(_ preset: SyntheticMeeting.Preset, seed: UInt64, minutes: Double) throws -> SyntheticMeeting {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("earl-echo-eval/\(preset.rawValue)-seed\(seed)-\(minutes)m")
        // Generating takes a while; the same preset and seed give the same files.
        let truthURL = folder.appendingPathComponent("truth.json")
        if let truth = try? SyntheticTruth.load(truthURL),
           FileManager.default.fileExists(atPath: folder.appendingPathComponent("mic-16k.wav").path) {
            return SyntheticMeeting(folder: folder, truth: truth)
        }
        return try SyntheticMeeting.make(preset: preset, seed: seed, minutes: minutes, in: folder)
    }

    /// Whisper as Earl runs it on a track without speaker separation.
    private func transcribe(_ audio: URL, _ speaker: String, cache: String?, prompt: String?, in folder: URL) throws -> [Turn] {
        let base = folder.appendingPathComponent(cache ?? "whisper-\(speaker)-clean")
        let json = base.appendingPathExtension("json")
        if cache == nil || !FileManager.default.fileExists(atPath: json.path) {
            var args = ["-m", Prefs.defaultWhisperModel, "-f", audio.path, "-l", "auto", "-oj", "-of", base.path, "-np", "-t", "8"]
            if FileManager.default.fileExists(atPath: Prefs.vadModel) { args += ["--vad", "-vm", Prefs.vadModel] }
            if let prompt { args += ["--prompt", prompt] }
            _ = try SynthDSP.run(Prefs.defaultWhisperPath, args)
        }
        return try Transcriber.parse(json, speaker: speaker, promptWords: WhisperPrompt.words(in: prompt)).turns
    }

    /// Share of echo-only time muted, and of your speech muted, by frame.
    private func frameStats(_ truth: SyntheticTruth, _ a: EchoFilter.Analysis) -> (echoMuted: Double, youMuted: Double) {
        let me = truth.utterances.filter { $0.track == "Me" }
        func inMe(_ t: Double, pad: Double) -> Bool { me.contains { $0.start - pad <= t && t <= $0.end + pad } }
        var echo = 0, echoMuted = 0, you = 0, youMuted = 0
        for (i, muted) in a.mute.enumerated() {
            let t = Double(i) * EchoFilter.frameSeconds
            if inMe(t, pad: 0) {
                you += 1
                if muted { youMuted += 1 }
            } else if !inMe(t, pad: 0.3), truth.echo.contains(where: { $0.start <= t && t <= $0.end - 0.15 }) {
                echo += 1
                if muted { echoMuted += 1 }
            }
        }
        return (echo == 0 ? 0 : Double(echoMuted) / Double(echo), you == 0 ? 0 : Double(youMuted) / Double(you))
    }

    /// Earl's text filter before R2-4, for comparison.
    static func legacyFilter(_ segments: [Turn]) -> [Turn] {
        func words(_ s: String) -> Set<String> {
            Set(s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
        }
        func isEcho(_ a: String, _ b: String) -> Bool {
            let wa = words(a), wb = words(b)
            guard !wa.isEmpty, !wb.isEmpty else { return false }
            if min(wa.count, wb.count) < 3 { return wa == wb }
            return Double(wa.intersection(wb).count) / Double(min(wa.count, wb.count)) >= 0.6
        }
        let them = segments.filter { $0.speaker == "Them" }
        return segments.filter { seg in
            guard seg.speaker == "Me" else { return true }
            return !them.contains { other in
                seg.start < other.end + 1.5 && other.start < seg.end + 1.5 && isEcho(seg.text, other.text)
            }
        }
    }
}
