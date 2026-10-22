import Foundation
import Testing
@testable import Earl

/// R3-3 calibration: voice prints from synthetic meetings (T-1), diarization
/// only (no whisper, no LLM), to choose the voice-memory thresholds.
///
///     EARL_EVAL_VOICES=1 EARL_EVAL_MODELS=<copy of the speaker models> ./test.sh --filter VoiceMemoryEvalTests
///
/// Per seed, four `realistic` meetings with pinned voices:
/// - `enroll`: Sarah, Tom, Megan and Lisa, whose prints go into the library;
/// - `later`: Megan, Sarah and Tom again (other lines, other seed) with a stranger;
/// - `shifted`: all four with pitch ±6 % or speed ±15 %;
/// - `strangers`: four other `say` voices, Karen (whom R2-2 confuses with
///   Samantha) in each.
///
/// Optional: `EARL_EVAL_VOICES_SEEDS` (default 1,2,3), `EARL_EVAL_VOICES_MINUTES`
/// (default 4), `EARL_EVAL_VOICES_CACHE` (keeps meetings and voice prints, so
/// reruns only redo the arithmetic).
@Suite(.serialized)
struct VoiceMemoryEvalTests {
    typealias V = SyntheticMeeting.Voice
    static let env = ProcessInfo.processInfo.environment
    static let enabled = env["EARL_EVAL_VOICES"] != nil && DiarizationEvalTests.modelsDir != nil
    static let seeds = (env["EARL_EVAL_VOICES_SEEDS"] ?? "1,2,3").split(separator: ",").compactMap { UInt64($0) }
    static let minutes = Double(env["EARL_EVAL_VOICES_MINUTES"] ?? "") ?? 4

    static let sarah = V(voice: "Samantha", name: "Sarah"), tom = V(voice: "Daniel", name: "Tom")
    static let megan = V(voice: "Moira", name: "Megan"), lisa = V(voice: "Tessa", name: "Lisa")
    static let karen = V(voice: "Karen", name: "Kate")
    static let strangers: [[V]] = [
        [karen, V(voice: "Fred", name: "Frank"), V(voice: "Aman", name: "Arjun"), V(voice: "Kathy", name: "Claire")],
        [karen, V(voice: "Ralph", name: "Ralph"), V(voice: "Flo (English (US))", name: "Flora"),
         V(voice: "Shelley (English (UK))", name: "Shelley")],
        [karen, V(voice: "Rocko (English (US))", name: "Rocco"), V(voice: "Sandy (English (UK))", name: "Sandy"),
         V(voice: "Grandpa (English (UK))", name: "Walter")],
    ]

    enum Kind: String, CaseIterable, Codable { case enroll, later, shifted, strangers }

    static func remote(_ kind: Kind, seed: UInt64) -> [V] {
        switch kind {
        case .enroll: return [sarah, tom, megan, lisa]
        case .later: return [megan, sarah, tom, strangers[Int(seed - 1) % 3][3]]
        case .shifted:
            var s = sarah, t = tom, m = megan, l = lisa
            s.pitch = 1.06; t.pitch = 0.94; m.rateScale = 1.15; l.rateScale = 0.85
            return [s, t, m, l]
        case .strangers: return strangers[Int(seed - 1) % 3]
        }
    }

    /// One voice R2-2 found, with the person it belongs to.
    struct Found: Codable {
        var meeting: String
        var kind: Kind
        var id: String
        var person: String?
        var seconds: Double
        var embedding: [Float]
    }

    @Test(.enabled(if: enabled, "Set EARL_EVAL_VOICES and EARL_EVAL_MODELS to calibrate voice memory"))
    func calibrate() async throws {
        try await DiarizationEvalTests.offMain { try await Self.run() }
    }

    static func run() async throws {
        let cache = env["EARL_EVAL_VOICES_CACHE"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        let root = cache ?? FileManager.default.temporaryDirectory.appendingPathComponent("earl-voices-\(UUID().uuidString)")
        defer { if cache == nil { try? FileManager.default.removeItem(at: root) } }
        let started = Date()
        var diarizeSeconds = 0.0, meetings = 0
        var found: [Found] = []
        for seed in seeds {
            for kind in Kind.allCases {
                let r = try await voices(kind, seed: seed, in: root)
                found += r.found
                diarizeSeconds += r.seconds
                meetings += r.seconds > 0 ? 1 : 0
            }
        }
        print("[voices] \(meetings) meetings diarized in \(fmt(diarizeSeconds)) s; \(fmt(Date().timeIntervalSince(started))) s in total")
        analyse(found)
    }

    // MARK: - Meetings

    static func voices(_ kind: Kind, seed: UInt64, in root: URL) async throws -> (found: [Found], seconds: Double) {
        let name = "\(kind.rawValue)-seed\(seed)-\(DiarizationEvalTests.fmt(minutes))min"
        let folder = root.appendingPathComponent(name, isDirectory: true)
        let json = folder.appendingPathComponent("voices.json")
        if let data = try? Data(contentsOf: json), let cached = try? JSONDecoder().decode([Found].self, from: data) {
            return (cached, 0)
        }
        // Seeds differ per kind, so no two meetings share their lines.
        let offset: UInt64 = [.enroll: 0, .later: 100, .shifted: 200, .strangers: 300][kind]!
        let meeting = try SyntheticMeeting.make(preset: .realistic, seed: seed + offset, minutes: minutes,
                                                remote: remote(kind, seed: seed), in: folder)
        let diarizer = try await DiarizationEvalTests.diarizer()
        let t0 = Date()
        let d = try await diarizer.run(audio: meeting.system)
        let seconds = Date().timeIntervalSince(t0)
        let remote = meeting.truth.utterances.filter { $0.track == "Them" }
        let out = d.speakers.map { s -> Found in
            // The person whose lines this voice covers most, if at least half.
            var cover: [String: Double] = [:], total = 0.0
            for seg in d.segments where seg.speaker == s.index {
                for u in remote {
                    let o = min(seg.end, u.end) - max(seg.start, u.start)
                    if o > 0 { cover[u.speaker, default: 0] += o; total += o }
                }
            }
            let owner = cover.max { $0.value < $1.value }.flatMap { $0.value >= total / 2 ? $0.key : nil }
            return Found(meeting: name, kind: kind, id: "S\(s.index + 1)",
                         person: owner.flatMap { meeting.truth.speaker($0)?.name }, seconds: s.seconds,
                         embedding: s.embedding)
        }
        try JSONEncoder().encode(out).write(to: json)
        for f in ["system-16k.wav", "mic-16k.wav", "mix.wav"] { try? FileManager.default.removeItem(at: folder.appendingPathComponent(f)) }
        print("[voices] \(name): \(out.count) voices in \(fmt(seconds)) s: "
              + out.map { "\($0.id)=\($0.person ?? "?") \(Int($0.seconds)) s" }.joined(separator: ", "))
        return (out, seconds)
    }

    // MARK: - Analysis

    static func speakers(_ found: [Found]) -> [Speaker] {
        found.map { Speaker(id: $0.id, track: "Them", embedding: $0.embedding, seconds: $0.seconds) }
    }

    static func analyse(_ found: [Found]) {
        let enroll = found.filter { $0.kind == .enroll && $0.person != nil && $0.seconds >= VoiceLibrary.minLearnSeconds }
        let tests = found.filter { $0.kind != .enroll }
        let known = Set(enroll.compactMap(\.person))

        // 1. Raw pairs: every test voice against every enrolled print.
        var genuine: [Kind: [Float]] = [:], impostor: [String: [Float]] = [:]
        var short: (genuine: [Float], impostor: [Float]) = ([], [])
        for t in tests {
            for e in enroll {
                let s = SpeakerEdit.cosine(t.embedding, e.embedding)
                let same = t.person == e.person && t.person != nil
                if t.seconds < VoiceLibrary.minMatchSeconds {
                    if same { short.genuine.append(s) } else { short.impostor.append(s) }
                    continue
                }
                if same {
                    genuine[t.kind, default: []].append(s)
                } else {
                    let label = t.person == "Kate" && e.person == "Sarah" ? "Karen vs Samantha"
                        : known.contains(t.person ?? "") ? "known, other person" : "stranger"
                    impostor[label, default: []].append(s)
                }
            }
        }
        print("[voices] single prints, test voices ≥ \(Int(VoiceLibrary.minMatchSeconds)) s:")
        for (k, xs) in genuine.sorted(by: { $0.key.rawValue < $1.key.rawValue }) { print("[voices]   same person, \(k.rawValue): \(stats(xs))") }
        for (k, xs) in impostor.sorted(by: { $0.key < $1.key }) { print("[voices]   different, \(k): \(stats(xs))") }
        print("[voices]   voices under \(Int(VoiceLibrary.minMatchSeconds)) s: same \(stats(short.genuine)), different \(stats(short.impostor))")

        // 2. Libraries as Earl would hold them, max over samples vs centroid.
        let bySeed = Dictionary(grouping: enroll, by: \.meeting)
        var libraries: [(label: String, library: VoiceLibrary)] = bySeed.keys.sorted().map { key in
            ("1 meeting (\(key))", library(bySeed[key]!))
        }
        libraries.append(("\(bySeed.count) meetings", library(enroll)))
        let testMeetings = Dictionary(grouping: tests, by: \.meeting)
        for scoring in ["max", "centroid"] {
            var g: [Float] = [], i: [Float] = []
            for (_, lib) in libraries where lib.voices.first?.samples.count ?? 0 > 1 {
                for t in tests where t.seconds >= VoiceLibrary.minMatchSeconds {
                    for v in lib.voices {
                        let s = scoring == "max" ? VoiceLibrary.similarity(t.embedding, to: v)
                            : SpeakerEdit.cosine(t.embedding, centroid(v.samples))
                        if v.name == t.person { g.append(s) } else { i.append(s) }
                    }
                }
            }
            print("[voices] \(bySeed.count)-sample library, \(scoring): same \(stats(g)), different \(stats(i))")
        }

        // 3. Threshold sweep, as Earl assigns (greedy, one to one), with no attendees.
        print("[voices] sweep, no attendees (true = right name / voices of known people; false = wrong names / voices named):")
        for th in stride(from: Float(0.5), through: 0.9, by: 0.05) {
            let r = simulate(libraries, testMeetings, strict: th, invited: th, attendees: { _ in [] })
            print("[voices]   \(String(format: "%.2f", th)): \(r.line)")
        }

        // 4. The chosen thresholds, with attendee lists.
        let chosen = (VoiceLibrary.strictThreshold, VoiceLibrary.attendeeThreshold)
        print("[voices] chosen: strict \(chosen.0), attendee \(chosen.1)")
        let cases: [(String, ([Found]) -> [Attendee])] = [
            ("no attendees", { _ in [] }),
            ("attendees = the people there", { fs in Set(fs.compactMap(\.person)).map { Attendee(name: $0, email: nil, isMe: false) } }),
            ("attendees = everyone in the library, present or not", { fs in
                Set(fs.compactMap(\.person)).union(known).map { Attendee(name: $0, email: nil, isMe: false) } }),
        ]
        for (label, attendees) in cases {
            let r = simulate(libraries, testMeetings, strict: chosen.0, invited: chosen.1, attendees: attendees)
            print("[voices]   \(label): \(r.line)")
            for (k, line) in r.byKind.sorted(by: { $0.key < $1.key }) { print("[voices]     \(k): \(line)") }
            if label == "no attendees" { #expect(r.wrong == 0) }
        }
    }

    static func library(_ prints: [Found]) -> VoiceLibrary {
        var lib = VoiceLibrary()
        for p in prints { lib.learn(p.embedding, name: p.person!, source: "\(p.meeting)/\(p.id)") }
        return lib
    }

    static func centroid(_ xs: [[Float]]) -> [Float] {
        guard let n = xs.first?.count else { return [] }
        return (0..<n).map { k in xs.reduce(0) { $0 + $1[k] } / Float(xs.count) }
    }

    struct Outcome {
        var right = 0, eligible = 0, wrong = 0, named = 0, strangersNamed = 0, strangers = 0
        var byKind: [String: String] = [:]
        var line: String {
            "true \(DiarizationEvalTests.pct(right, eligible)) (\(right)/\(eligible)), "
                + "false \(DiarizationEvalTests.pct(wrong, named)) (\(wrong)/\(named)), strangers named \(strangersNamed)/\(strangers)"
        }
    }

    static func simulate(_ libraries: [(label: String, library: VoiceLibrary)], _ meetings: [String: [Found]],
                         strict: Float, invited: Float, attendees: ([Found]) -> [Attendee]) -> Outcome {
        var total = Outcome()
        var kinds: [Kind: Outcome] = [:]
        for (_, lib) in libraries {
            let names = Set(lib.voices.map(\.name))
            for (_, fs) in meetings {
                let matches = lib.matches(for: speakers(fs), attendees: attendees(fs), strict: strict, invited: invited)
                let byID = Dictionary(uniqueKeysWithValues: matches.map { ($0.speakerID, $0) })
                var o = Outcome()
                // Known people count once per meeting: their largest voice.
                var seen = Set<String>()
                for f in fs.sorted(by: { $0.seconds > $1.seconds }) where f.seconds >= VoiceLibrary.minMatchSeconds {
                    let name = byID[f.id].flatMap { m in lib.voices.first { $0.id == m.voiceID }?.name }
                    let isKnown = f.person.map(names.contains) ?? false
                    if isKnown, seen.insert(f.person!).inserted {
                        o.eligible += 1
                        if name == f.person { o.right += 1 }
                    }
                    if !isKnown { o.strangers += 1 }
                    if let name {
                        o.named += 1
                        if name != f.person { o.wrong += 1 }
                        if !isKnown { o.strangersNamed += 1 }
                    }
                }
                let kind = fs[0].kind
                kinds[kind, default: Outcome()].add(o)
                total.add(o)
            }
        }
        for (k, o) in kinds { total.byKind[k.rawValue] = o.line }
        return total
    }

    static func stats(_ xs: [Float]) -> String {
        guard !xs.isEmpty else { return "–" }
        let s = xs.sorted()
        func q(_ p: Double) -> String { String(format: "%.2f", s[min(s.count - 1, Int(p * Double(s.count - 1)))]) }
        return "n \(s.count), min \(q(0)) p5 \(q(0.05)) median \(q(0.5)) p95 \(q(0.95)) max \(q(1))"
    }

    static func fmt(_ x: Double) -> String { DiarizationEvalTests.fmt(x) }
}

extension VoiceMemoryEvalTests.Outcome {
    mutating func add(_ o: Self) {
        right += o.right; eligible += o.eligible; wrong += o.wrong; named += o.named
        strangersNamed += o.strangersNamed; strangers += o.strangers
    }
}
