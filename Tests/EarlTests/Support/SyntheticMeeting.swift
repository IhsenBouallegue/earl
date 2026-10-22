import Accelerate
import CryptoKit
import Foundation
@testable import Earl

/// The answer key of a synthetic meeting, saved as `truth.json` (T-1).
struct SyntheticTruth: Codable, Equatable {
    struct Speaker: Codable, Equatable {
        var id: String
        var voice: String
        var name: String
        /// "Them" or "Me".
        var track: String
        var gainDb: Double
        /// `say -r` words per minute before per-line variation.
        var rate: Int
    }

    enum Kind: String, Codable { case turn, interjection, crosstalk }

    struct Utterance: Codable, Equatable {
        var speaker: String
        var track: String
        var start: Double
        var end: Double
        var text: String
        var kind: Kind
    }

    struct Overlap: Codable, Equatable {
        var start: Double
        var end: Double
        var speakers: [String]
    }

    struct Echo: Codable, Equatable {
        var start: Double
        var end: Double
        var delayMs: Double
        var gainDb: Double
    }

    struct Degradations: Codable, Equatable {
        var codec: String?
        var bitrate: Int?
        /// Delay the codec added, measured and already removed from the audio.
        var codecDelayMs: Double?
        var snrDb: Double?
        var packetLoss: Double?
        var bandLimitHz: Double?
        var compressor: Bool?
        var farSpeaker: String?
        var keyboard: Bool?
        var fanHum: Bool?
        var echo: Bool?
    }

    var preset: String
    var seed: UInt64
    var duration: Double
    var speakers: [Speaker]
    var utterances: [Utterance]
    var overlaps: [Overlap]
    var echo: [Echo]
    var degradations: Degradations

    static func load(_ url: URL) throws -> SyntheticTruth {
        try JSONDecoder().decode(SyntheticTruth.self, from: Data(contentsOf: url))
    }

    func speaker(_ id: String) -> Speaker? { speakers.first { $0.id == id } }

    /// Where two or more people talk at once, merged by speaker set.
    static func overlaps(of utterances: [Utterance]) -> [Overlap] {
        var edges = Set<Double>()
        for u in utterances { edges.insert(u.start); edges.insert(u.end) }
        let times = edges.sorted()
        var out: [Overlap] = []
        for (a, b) in zip(times, times.dropFirst()) where b - a > 0.001 {
            let mid = (a + b) / 2
            let active = Set(utterances.filter { $0.start <= mid && mid < $0.end }.map(\.speaker)).sorted()
            guard active.count >= 2 else { continue }
            if var last = out.last, abs(last.end - a) < 0.001, last.speakers == active {
                last.end = b
                out[out.count - 1] = last
            } else {
                out.append(Overlap(start: a, end: b, speakers: active))
            }
        }
        return out.filter { $0.end - $0.start >= 0.02 }
    }
}

/// Builds hard, artificial meetings with a precise answer key (T-1):
/// crosstalk, interjections, the call codec, noise, reverb, packet loss,
/// similar voices and echo. Evaluations call `make(preset:seed:in:)`;
/// `tools/make-test-meeting.sh` writes one to a folder for listening.
struct SyntheticMeeting {
    enum Preset: String, CaseIterable {
        case clean, realistic, hard, speakers, german, backchannel, mixed
    }

    let folder: URL
    let truth: SyntheticTruth
    var system: URL { folder.appendingPathComponent("system-16k.wav") }
    var mic: URL { folder.appendingPathComponent("mic-16k.wav") }
    var mix: URL { folder.appendingPathComponent("mix.wav") }
    var truthURL: URL { folder.appendingPathComponent("truth.json") }

    /// Writes `system-16k.wav`, `mic-16k.wav`, `mix.wav`, `truth.json` and
    /// `README.txt` into `folder`. Same preset, seed and length give the same files.
    @discardableResult
    static func make(preset: Preset, seed: UInt64 = 1, minutes: Double = 5, in folder: URL) throws -> SyntheticMeeting {
        try make(preset: preset, seed: seed, minutes: minutes, remote: nil, in: folder)
    }

    /// The same, with the remote people pinned instead of the preset's. The
    /// preset picks voices, not the seed, so this is how a voice meets
    /// different people (or no one it knows) in a later meeting (R3-3).
    static func make(preset: Preset, seed: UInt64, minutes: Double, remote: [Voice]?,
                     in folder: URL) throws -> SyntheticMeeting {
        var config = Config(preset)
        if let remote { config.remote = remote }
        var builder = Builder(config: config, seed: seed, minutes: minutes, folder: folder)
        return try builder.build()
    }

    // MARK: - Presets

    struct Voice {
        var voice: String
        var name: String
        /// R3-3: the same voice made higher or lower (1.05 = 5 % higher), tempo kept.
        var pitch = 1.0
        /// R3-3: the same voice faster or slower than its seeded rate.
        var rateScale = 1.0
    }

    struct Config {
        var preset: Preset
        var remote: [Voice]
        var me: Voice
        var pool: SyntheticScript.Pool
        var pause: ClosedRange<Double> = 0.3...1.0
        var overlapChance = 0.0
        var overlap: ClosedRange<Double> = 0.2...1.0
        var interjections: ClosedRange<Int> = 0...0
        var crosstalk = 0
        var levelSpreadDb = 0.0
        var snrDb: Double?
        var micSnrDb: Double?
        var bitrate: Int?
        var bandLimitHz: Double?
        var compressor = false
        /// Index into `remote` of the quiet, far-away speaker.
        var farSpeaker: Int?
        var keyboard = false
        var fanHum = false
        var packetLoss: ClosedRange<Double>?
        /// Per-line `say -r` variation, as a fraction of the voice's rate.
        var rateJitter = 0.0
        var echo = false
        var doubleTalk = false
        /// A quiet extra remote participant who takes no part in the script and
        /// only says short things ("mhm", "genau", "kannst du das sehen?"), so
        /// the speaker model only gets short clips of them.
        var backchannel: Voice?
        var backchannelGainDb = -8.0
        /// Said over other people's lines, and as short turns of their own.
        var backchannelLines: [String] = []
        var backchannelTurns: [String] = []
        /// V-1: index into `remote` of a person who speaks only English in
        /// an otherwise German meeting (the case where whisper translated).
        var englishSpeaker: Int?

        init(_ preset: Preset) {
            self.preset = preset
            let rishi = Voice(voice: "Rishi", name: "Alex")
            switch preset {
            case .clean:
                remote = [Voice(voice: "Samantha", name: "Sarah"), Voice(voice: "Daniel", name: "Tom"),
                          Voice(voice: "Moira", name: "Megan")]
                me = rishi
                pool = SyntheticScript.english
                pause = 0.6...1.2
            case .realistic, .speakers:
                remote = preset == .realistic
                    ? [Voice(voice: "Daniel", name: "Tom"), Voice(voice: "Moira", name: "Megan"),
                       Voice(voice: "Tessa", name: "Lisa"), Voice(voice: "Aman", name: "Arjun")]
                    : [Voice(voice: "Moira", name: "Megan"), Voice(voice: "Fred", name: "Frank"),
                       Voice(voice: "Kathy", name: "Claire")]
                me = preset == .realistic ? rishi : Voice(voice: "Ralph", name: "Alex")
                pool = SyntheticScript.english
                applyRealistic()
                if preset == .speakers {
                    echo = true
                    doubleTalk = true
                }
            case .hard:
                // Samantha and Karen are the pair R2-2's speaker model confuses.
                remote = [Voice(voice: "Samantha", name: "Sarah"), Voice(voice: "Karen", name: "Kate"),
                          Voice(voice: "Daniel", name: "Tom"), Voice(voice: "Aman", name: "Arjun"),
                          Voice(voice: "Tessa", name: "Lisa")]
                me = rishi
                pool = SyntheticScript.english
                applyRealistic()
                crosstalk = 2
                farSpeaker = 3
                keyboard = true
                fanHum = true
                packetLoss = 0.01...0.03
                bitrate = 12000
                snrDb = 20
                rateJitter = 0.08
            case .german:
                remote = [Voice(voice: "Anna", name: "Katrin"), Voice(voice: "Eddy (German (Germany))", name: "Markus"),
                          Voice(voice: "Flo (German (Germany))", name: "Lena")]
                me = Voice(voice: "Reed (German (Germany))", name: "Jan")
                pool = SyntheticScript.german
                applyRealistic()
            case .mixed:
                // V-1: a German meeting where one person (Daniel) only speaks English.
                remote = [Voice(voice: "Anna", name: "Katrin"), Voice(voice: "Daniel", name: "Tom"),
                          Voice(voice: "Eddy (German (Germany))", name: "Markus")]
                me = Voice(voice: "Reed (German (Germany))", name: "Jan")
                pool = SyntheticScript.german
                englishSpeaker = 1
                applyRealistic()
            case .backchannel:
                // Modelled on a real call: one person does most of the talking,
                // a third one is quiet and mostly acknowledges.
                remote = [Voice(voice: "Eddy (German (Germany))", name: "Markus"), Voice(voice: "Anna", name: "Katrin")]
                backchannel = Voice(voice: "Flo (German (Germany))", name: "Lena")
                me = Voice(voice: "Reed (German (Germany))", name: "Jan")
                pool = SyntheticScript.german
                applyRealistic()
                backchannelLines = ["Mhm.", "Ja.", "Ja, ja.", "Genau.", "Okay.", "Mhm, ja.", "Stimmt.", "Ah, okay."]
                backchannelTurns = ["Genau, teilen wir kurz.", "Kannst du das auch sehen?", "Ja, passt für mich.",
                                    "Okay, verstanden.", "Mhm, ja, genau.", "Sorry, kurze Frage: bis wann?"]
            }
        }

        private mutating func applyRealistic() {
            pause = 0.2...0.9
            overlapChance = 0.3
            interjections = 4...6
            levelSpreadDb = 8
            snrDb = 25
            micSnrDb = 35
            bitrate = 24000
            bandLimitHz = 7000
            compressor = true
        }
    }

    // MARK: - Building

    private struct Clip {
        var speaker: Int
        var text: String
        var kind: SyntheticTruth.Kind
        var rate: Int
        var audio: [Float] = []
        var duration: Double { SynthDSP.seconds(audio.count) }
    }

    struct Placement: Equatable {
        var clip: Int
        var start: Double
        var end: Double
    }

    private struct Builder {
        let config: Config
        let seed: UInt64
        let minutes: Double
        let folder: URL
        var rng: SeededRNG
        var notes: [String] = []

        init(config: Config, seed: UInt64, minutes: Double, folder: URL) {
            self.config = config
            self.seed = seed
            self.minutes = minutes
            self.folder = folder
            // Mix the preset in so presets with the same seed still differ.
            var h: UInt64 = seed
            for b in config.preset.rawValue.utf8 { h = (h &* 31) &+ UInt64(b) }
            rng = SeededRNG(seed: h)
        }

        var participants: [Voice] { config.remote + (config.backchannel.map { [$0] } ?? []) + [config.me] }
        var meIndex: Int { participants.count - 1 }
        /// The quiet participant, if any: right after the remote people.
        var backchannelIndex: Int? { config.backchannel == nil ? nil : config.remote.count }
        func isRemote(_ s: Int) -> Bool { s < meIndex }

        mutating func build() throws -> SyntheticMeeting {
            let fm = FileManager.default
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let work = fm.temporaryDirectory.appendingPathComponent("earl-synth-\(UUID().uuidString)")
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: work) }

            // Voices: a base rate each, and a level each.
            let rates = participants.map { Int((Double(rng.int(165...205)) * $0.rateScale).rounded()) }
            var gains = participants.indices.map { i -> Double in
                guard isRemote(i), i > 0, config.levelSpreadDb > 0 else { return 0 }
                return -rng.uniform(0, config.levelSpreadDb)
            }
            if let far = config.farSpeaker { gains[far] = -12 }
            if let b = backchannelIndex { gains[b] = config.backchannelGainDb }

            // Script and main turns. The script's length is a guess from word
            // counts; voices differ, so measure once and redo it if it's far off.
            let target = minutes * 60
            let saved = rng
            var clips: [Clip] = []
            var request = target
            for attempt in 0..<2 {
                rng = saved
                // The script is for everyone but the quiet participant.
                let scripted = participants.indices.filter { $0 != backchannelIndex }
                var lines = SyntheticScript.build(pool: config.pool, names: scripted.map { participants[$0].name },
                                                  seconds: request, rng: &rng)
                    .map { SyntheticScript.Line(speaker: scripted[$0.speaker], text: $0.text) }
                if let e = config.englishSpeaker {
                    // V-1: their lines in English, from the English pool's statements.
                    let english = SyntheticScript.english.topics.flatMap(\.statements)
                    lines = lines.map { line in
                        guard line.speaker == e else { return line }
                        return SyntheticScript.Line(speaker: e, text: rng.pick(english))
                    }
                }
                if let b = backchannelIndex, !config.backchannelTurns.isEmpty {
                    // Short turns of their own, about two a minute, spread over the meeting.
                    let count = max(2, Int((minutes * 2).rounded()))
                    for at in pickSpread(Array(2..<max(3, lines.count)), count: count).sorted(by: >) {
                        lines.insert(SyntheticScript.Line(speaker: b, text: rng.pick(config.backchannelTurns)), at: at)
                    }
                }
                clips = lines.map { Clip(speaker: $0.speaker, text: $0.text, kind: .turn, rate: rate(rates[$0.speaker])) }
                try render(&clips)
                let meanPause = (config.pause.lowerBound + config.pause.upperBound) / 2 * (1 - config.overlapChance)
                    - 0.6 * config.overlapChance
                let estimate = clips.reduce(2.5) { $0 + $1.duration + meanPause }
                if attempt == 0, abs(estimate / target - 1) > 0.05 { request *= target / estimate } else { break }
            }
            let turnCount = clips.count

            // Crosstalk and interjections, chosen now that durations are known.
            var crosstalkHosts: [Int: Int] = [:]   // host turn -> clip
            var interjectionHosts: [Int: Int] = [:]
            for n in 0..<config.crosstalk {
                // Spread them out: one in each part of the meeting.
                let lo = turnCount * (n * 2 + 1) / (config.crosstalk * 2 + 1)
                guard let host = (lo..<turnCount - 1).first(where: {
                    isRemote(clips[$0].speaker) && clips[$0].duration >= 4.5 && crosstalkHosts[$0] == nil
                }) else { continue }
                let avoid: Set<Int> = [clips[host].speaker, clips[host + 1].speaker, clips[max(0, host - 1)].speaker]
                let candidates = (0..<meIndex).filter {
                    !avoid.contains($0) && $0 != config.farSpeaker && $0 != backchannelIndex
                }
                guard !candidates.isEmpty else { continue }
                let s = rng.pick(candidates)
                let crosstalkPool = s == config.englishSpeaker ? SyntheticScript.english.crosstalk : config.pool.crosstalk
                clips.append(Clip(speaker: s, text: rng.pick(crosstalkPool), kind: .crosstalk, rate: rate(rates[s])))
                crosstalkHosts[host] = clips.count - 1
            }
            let wanted = config.interjections.upperBound == 0 ? 0
                : Int((Double(rng.int(config.interjections)) * max(1, minutes / 5)).rounded())
            let eligible = (1..<max(1, turnCount - 1)).filter {
                clips[$0].duration >= 3.5 && crosstalkHosts[$0] == nil && crosstalkHosts[$0 - 1] == nil
            }
            for host in pickSpread(eligible, count: wanted) {
                var candidates = (0..<meIndex).filter { $0 != clips[host].speaker && $0 != backchannelIndex }
                if config.doubleTalk, clips[host].speaker != meIndex { candidates.append(meIndex) }
                let s = rng.pick(candidates)
                let interjectionPool = s == config.englishSpeaker
                    ? SyntheticScript.english.interjections : config.pool.interjections
                clips.append(Clip(speaker: s, text: rng.pick(interjectionPool), kind: .interjection,
                                  rate: rate(rates[s])))
                interjectionHosts[host] = clips.count - 1
            }
            if let b = backchannelIndex, !config.backchannelLines.isEmpty {
                // About three acknowledgements a minute, over other people's lines.
                let hosts = (1..<max(1, turnCount - 1)).filter {
                    clips[$0].duration >= 2.5 && clips[$0].speaker != b && crosstalkHosts[$0] == nil
                        && crosstalkHosts[$0 - 1] == nil && interjectionHosts[$0] == nil
                }
                for host in pickSpread(hosts, count: Int((minutes * 3).rounded())) {
                    clips.append(Clip(speaker: b, text: rng.pick(config.backchannelLines), kind: .interjection,
                                      rate: rate(rates[b])))
                    interjectionHosts[host] = clips.count - 1
                }
                let p = participants[b]
                notes.append("Quiet participant: \(p.name) (\(p.voice)), \(Int(config.backchannelGainDb)) dB, "
                    + "no scripted lines, only short turns and acknowledgements over others")
            }
            var extra = Array(clips[turnCount...])
            try render(&extra)
            clips.replaceSubrange(turnCount..., with: extra)

            let placements = layout(clips: clips, turnCount: turnCount,
                                    crosstalk: crosstalkHosts, interjections: interjectionHosts)
            let total = SynthDSP.samples((placements.map(\.end).max() ?? 0) + 1.5)

            // Tracks, dry. Levels start equal; `gains` sets the differences.
            var them = [Float](repeating: 0, count: total)
            var far = [Float](repeating: 0, count: total)
            var me = [Float](repeating: 0, count: total)
            for p in placements {
                let c = clips[p.clip]
                let at = SynthDSP.samples(p.start)
                let g = SynthDSP.linear(gains[c.speaker])
                let voice = SynthDSP.normalizedRMS(c.audio)
                if c.speaker == meIndex {
                    SynthDSP.add(voice, into: &me, at: at, gain: 0.1)
                } else if c.speaker == config.farSpeaker {
                    SynthDSP.add(voice, into: &far, at: at, gain: 0.1 * g)
                } else {
                    SynthDSP.add(voice, into: &them, at: at, gain: 0.1 * g)
                }
            }
            if let e = config.englishSpeaker {
                notes.append("English speaker: \(participants[e].name) (\(participants[e].voice)) speaks only English")
            }
            if let f = config.farSpeaker {
                // Far from their laptop in a bare room: dull and reverberant.
                far = SynthDSP.reverb(SynthDSP.filter(far, .lowpass, 3000), rt60: 0.7, wet: 0.45)
                SynthDSP.add(far, into: &them, at: 0)
                notes.append("Far-away speaker: \(participants[f].name) (\(participants[f].voice)), -12 dB, "
                    + "3 kHz low-pass, reverb RT60 0.7 s, 45 % wet")
            }

            let themRanges = placements.filter { isRemote(clips[$0.clip].speaker) }
                .map { SynthDSP.samples($0.start)..<SynthDSP.samples($0.end) }
            let speechRMS = SynthDSP.rms(them, over: themRanges)
            var degradations = SyntheticTruth.Degradations()

            // Things around the remote people, before the call processes them.
            if config.fanHum {
                SynthDSP.add(SynthDSP.fanHum(total, rng: &rng), into: &them, at: 0, gain: speechRMS * SynthDSP.linear(-30))
                degradations.fanHum = true
                notes.append("Fan hum: brown rumble below 400 Hz plus a wobbling 118 Hz tone, 30 dB below speech")
            }
            if config.keyboard {
                let bursts = max(2, Int(minutes * 1.2))
                let kb = SynthDSP.keyboard(total, bursts: bursts, rng: &rng)
                SynthDSP.add(kb.audio, into: &them, at: 0, gain: speechRMS * SynthDSP.linear(-3))
                degradations.keyboard = true
                let spans = kb.spans.map { String(format: "%.1f-%.1f s", $0.0, $0.1) }.joined(separator: ", ")
                notes.append("Keyboard clicks: \(bursts) typing bursts, peaks 3 dB below speech RMS, at \(spans)")
            }
            if let snr = config.snrDb {
                SynthDSP.add(SynthDSP.pink(total, rng: &rng), into: &them, at: 0, gain: speechRMS * SynthDSP.linear(-snr))
                degradations.snrDb = snr
                notes.append("Background noise: pink, SNR \(Int(snr)) dB against the remote speech")
            }

            // The call: band limit, AGC, codec, network.
            if let band = config.bandLimitHz {
                them = SynthDSP.filter(SynthDSP.filter(them, .highpass, 90), .lowpass, band)
                degradations.bandLimitHz = band
                notes.append("Band limit: 90 Hz high-pass, \(Int(band)) Hz low-pass (wideband call)")
            }
            if config.compressor {
                them = SynthDSP.scaled(them, by: 0.1 / max(SynthDSP.rms(them, over: themRanges), 1e-6))
                them = SynthDSP.compress(them, thresholdDb: -20, ratio: 2)
                degradations.compressor = true
                notes.append("Compressor/AGC (mild): RMS, threshold -20 dBFS (the speech level), ratio 2:1, attack 10 ms, release 150 ms")
            }
            if let bitrate = config.bitrate {
                let result = try SynthDSP.codecRoundTrip(them, bitrate: bitrate, workDir: work)
                them = result.audio
                degradations.codec = result.codec
                degradations.bitrate = bitrate
                degradations.codecDelayMs = result.delayMs
                notes.append("Codec: \(result.codec) at \(bitrate / 1000) kbps via afconvert; measured delay "
                    + String(format: "%.2f ms", result.delayMs) + ", removed"
                    + (result.codec == "opus" ? "" : " (Opus encoding failed here, fell back to AAC)"))
            }
            if let lossRange = config.packetLoss {
                let rate = rng.uniform(lossRange.lowerBound, lossRange.upperBound)
                let loss = SynthDSP.packetLoss(them, rate: rate, rng: &rng)
                them = loss.audio
                let actual = Double(loss.dropped.count) / Double(max(1, total / SynthDSP.samples(0.02)))
                degradations.packetLoss = (actual * 1000).rounded() / 1000
                notes.append(String(format: "Packet loss: %.1f %% of 20 ms frames dropped (%d frames), "
                    + "concealed by repeating the previous frame, faded", actual * 100, loss.dropped.count))
            }
            if let f = config.farSpeaker { degradations.farSpeaker = SyntheticMeeting.id(f) }

            // Your side: your voice, your room, and maybe the call from your speakers.
            let meRanges = placements.filter { clips[$0.clip].speaker == meIndex }
                .map { SynthDSP.samples($0.start)..<SynthDSP.samples($0.end) }
            let meRMS = SynthDSP.rms(me, over: meRanges)
            if let snr = config.micSnrDb {
                SynthDSP.add(SynthDSP.pink(total, rng: &rng), into: &me, at: 0, gain: meRMS * SynthDSP.linear(-snr))
                notes.append("Mic noise: pink, SNR \(Int(snr)) dB")
            }
            var echoes: [SyntheticTruth.Echo] = []
            if config.echo {
                let delayMs = Double(rng.int(60...120))
                let echoGain = -18.0
                var e = SynthDSP.reverb(them, rt60: 0.4, wet: 0.35)
                e = SynthDSP.shifted(e, by: SynthDSP.samples(delayMs / 1000))
                // The call's level relative to your voice, as the laptop plays it.
                let themLevel = SynthDSP.rms(them, over: themRanges)
                SynthDSP.add(e, into: &me, at: 0, gain: SynthDSP.linear(echoGain) * meRMS / max(themLevel, 1e-6))
                degradations.echo = true
                let spans = placements.filter { isRemote(clips[$0.clip].speaker) }
                    .map { ($0.start + delayMs / 1000, $0.end + delayMs / 1000 + 0.15) }.sorted { $0.0 < $1.0 }
                for (s, t) in spans {
                    if var last = echoes.last, s <= last.end {
                        last.end = max(last.end, t)
                        echoes[echoes.count - 1] = last
                    } else {
                        echoes.append(SyntheticTruth.Echo(start: s, end: t, delayMs: delayMs, gainDb: echoGain))
                    }
                }
                notes.append("Echo: the call from laptop speakers into the mic, \(Int(delayMs)) ms delay, "
                    + "18 dB below your voice's level, room reverb RT60 0.4 s")
            }

            // Levels: the mix at about -20 dBFS RMS, one gain for both tracks so
            // their relation stays true, and no clipping.
            let themRMSNow = SynthDSP.rms(them, over: themRanges)
            if themRMSNow > 0 { them = SynthDSP.scaled(them, by: 0.1 / themRMSNow) }
            var mix = SynthDSP.sum(them, me)
            let g = 0.1 / max(SynthDSP.rms(mix), 1e-6)
            them = SynthDSP.scaled(them, by: g)
            me = SynthDSP.scaled(me, by: g)
            mix = SynthDSP.scaled(mix, by: g)
            // Rare peaks would clip at this level; a limiter shared by all three
            // files tames them without changing the balance.
            let limit = SynthDSP.limiterGain(for: [them, me, mix], ceiling: 0.9)
            them = vDSP.multiply(them, limit)
            me = vDSP.multiply(me, limit)
            mix = vDSP.multiply(mix, limit)

            let meeting = SyntheticMeeting(folder: folder, truth: truth(
                clips: clips, placements: placements, rates: rates, gains: gains, total: total,
                echoes: echoes, degradations: degradations))
            try SynthDSP.writeWAV(them, to: meeting.system)
            try SynthDSP.writeWAV(me, to: meeting.mic)
            try SynthDSP.writeWAV(mix, to: meeting.mix)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(meeting.truth).write(to: meeting.truthURL)
            try readme(meeting.truth, finalRMS: SynthDSP.decibels(SynthDSP.rms(mix)))
                .write(to: folder.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
            return meeting
        }

        mutating func rate(_ base: Int) -> Int {
            guard config.rateJitter > 0 else { return base }
            return Int((Double(base) * (1 + rng.uniform(-config.rateJitter, config.rateJitter))).rounded())
        }

        /// Picks `count` items spread evenly over `items`.
        mutating func pickSpread(_ items: [Int], count: Int) -> [Int] {
            guard count > 0, !items.isEmpty else { return [] }
            let n = min(count, items.count)
            return (0..<n).map { k in
                let lo = items.count * k / n, hi = max(lo, items.count * (k + 1) / n - 1)
                return items[rng.int(lo...hi)]
            }
        }

        // MARK: Rendering

        /// Renders each clip with `say`, in parallel, through a cache in the temp
        /// folder (`say` is the slow part). Silence around the words is trimmed so
        /// the truth times are where the voice is.
        func render(_ clips: inout [Clip]) throws {
            let cache = FileManager.default.temporaryDirectory.appendingPathComponent("earl-synth-say-cache")
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            let jobs = clips.map { c -> (voice: String, rate: Int, text: String, pitch: Double) in
                let p = participants[c.speaker]
                // A higher pitch plays the clip faster, so say it slower by as much.
                return (p.voice, Int((Double(c.rate) / p.pitch).rounded()), c.text, p.pitch)
            }
            let box = RenderResults(count: jobs.count)
            DispatchQueue.concurrentPerform(iterations: jobs.count) { i in
                let job = jobs[i]
                do {
                    let key = SHA256.hash(data: Data("\(job.voice)|\(job.rate)|\(job.text)".utf8))
                        .map { String(format: "%02x", $0) }.joined()
                    let file = cache.appendingPathComponent("\(key).wav")
                    if !FileManager.default.fileExists(atPath: file.path) {
                        let tmp = cache.appendingPathComponent("\(key)-\(UUID().uuidString).wav")
                        try SynthDSP.run("/usr/bin/say", ["-v", job.voice, "-r", "\(job.rate)", "--file-format=WAVE",
                                                          "--data-format=LEI16@16000", "-o", tmp.path, job.text])
                        // Another process may have won the race; either copy is the same.
                        if (try? FileManager.default.moveItem(at: tmp, to: file)) == nil {
                            try? FileManager.default.removeItem(at: tmp)
                        }
                    }
                    let audio = SynthDSP.trimSilence(SynthDSP.resampled(try SynthDSP.readAudio(file), by: job.pitch))
                    box.lock.withLock { box.audio[i] = audio }
                } catch {
                    box.lock.withLock { box.failure = error }
                }
            }
            if let failure = box.failure { throw failure }
            for i in clips.indices {
                guard let audio = box.audio[i], !audio.isEmpty else {
                    throw PipelineError.message("say produced no audio for \"\(clips[i].text)\" (\(jobs[i].voice))")
                }
                clips[i].audio = audio
            }
        }

        // MARK: Layout

        /// Places turns one after another with pauses, some overlapping at the
        /// turn change, crosstalk over the end of its host turn, and
        /// interjections inside long turns.
        mutating func layout(clips: [Clip], turnCount: Int, crosstalk: [Int: Int], interjections: [Int: Int]) -> [Placement] {
            var out: [Placement] = []
            var cursor = 1.0        // end of the floor so far
            var prevStart = 0.0
            // Nobody talks over themselves.
            var free = [Double](repeating: 0, count: participants.count)
            var pending: [(host: Placement, clip: Int)] = []
            for i in 0..<turnCount {
                let c = clips[i]
                var start = cursor + rng.uniform(config.pause.lowerBound, config.pause.upperBound)
                let touchesMe = c.speaker == meIndex || (i > 0 && clips[i - 1].speaker == meIndex)
                let chance = config.doubleTalk && touchesMe ? 0.5 : config.overlapChance
                if i > 0, rng.chance(chance) {
                    start = max(prevStart + 0.5, cursor - rng.uniform(config.overlap.lowerBound, config.overlap.upperBound))
                }
                start = max(start, free[c.speaker] + 0.15)
                let p = Placement(clip: i, start: start, end: start + c.duration)
                out.append(p)
                prevStart = start
                cursor = max(cursor, p.end)
                free[c.speaker] = p.end

                if let k = crosstalk[i] {
                    // Two people talking over each other for 3-5 s: the other
                    // one starts well before the host has finished.
                    let ct = clips[k]
                    let o = min(rng.uniform(3, 5), ct.duration, c.duration - 0.8)
                    let ctStart = max(p.end - o, free[ct.speaker] + 0.15)
                    out.append(Placement(clip: k, start: ctStart, end: ctStart + ct.duration))
                    cursor = max(cursor, ctStart + ct.duration)
                    free[ct.speaker] = ctStart + ct.duration
                }
                if let k = interjections[i] { pending.append((p, k)) }
            }
            for (host, k) in pending {
                let ij = clips[k]
                let lo = host.start + 1.0, hi = host.end - 1.0 - ij.duration
                let s = hi > lo ? rng.uniform(lo, hi) : host.start + (host.end - host.start - ij.duration) / 2
                let busy = out.contains { clips[$0.clip].speaker == ij.speaker && $0.start < s + ij.duration + 0.15 && s < $0.end + 0.15 }
                // Rare: the interjector is still talking there. Leave it out.
                if !busy { out.append(Placement(clip: k, start: s, end: s + ij.duration)) }
            }
            return out
        }

        // MARK: Answer key

        func truth(clips: [Clip], placements: [Placement], rates: [Int], gains: [Double], total: Int,
                   echoes: [SyntheticTruth.Echo], degradations: SyntheticTruth.Degradations) -> SyntheticTruth {
            func r3(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }
            let speakers = participants.enumerated().map { i, v in
                SyntheticTruth.Speaker(id: SyntheticMeeting.id(i), voice: v.voice, name: v.name,
                                       track: isRemote(i) ? "Them" : "Me", gainDb: (gains[i] * 10).rounded() / 10,
                                       rate: rates[i])
            }
            let utterances = placements.sorted { $0.start < $1.start }.map { p in
                let c = clips[p.clip]
                return SyntheticTruth.Utterance(speaker: SyntheticMeeting.id(c.speaker), track: isRemote(c.speaker) ? "Them" : "Me",
                                                start: r3(p.start), end: r3(p.end), text: c.text, kind: c.kind)
            }
            let overlaps = SyntheticTruth.overlaps(of: utterances).map {
                SyntheticTruth.Overlap(start: r3($0.start), end: r3($0.end), speakers: $0.speakers)
            }
            return SyntheticTruth(preset: config.preset.rawValue, seed: seed, duration: r3(SynthDSP.seconds(total)),
                                  speakers: speakers, utterances: utterances, overlaps: overlaps,
                                  echo: echoes.map { .init(start: r3($0.start), end: r3($0.end), delayMs: $0.delayMs, gainDb: $0.gainDb) },
                                  degradations: degradations)
        }

        func readme(_ truth: SyntheticTruth, finalRMS: Double) -> String {
            let kinds = Dictionary(grouping: truth.utterances, by: \.kind).mapValues(\.count)
            var s = """
            Synthetic Earl meeting (T-1)
            Preset: \(truth.preset)
            Seed: \(truth.seed)
            Requested length: \(minutes) min, actual \(String(format: "%.1f", truth.duration)) s
            Recreate: tools/make-test-meeting.sh \(truth.preset) <dir> --seed \(truth.seed) --minutes \(minutes)

            Files: system-16k.wav (Them), mic-16k.wav (Me), mix.wav (both), truth.json (answer key)

            Speakers:

            """
            for sp in truth.speakers {
                s += "  \(sp.id)  \(sp.name.padding(toLength: 7, withPad: " ", startingAt: 0)) \(sp.voice), "
                    + "\(sp.track), \(sp.gainDb) dB, say -r \(sp.rate)\n"
            }
            s += """

            Utterances: \(kinds[.turn] ?? 0) turns, \(kinds[.interjection] ?? 0) interjections, \
            \(kinds[.crosstalk] ?? 0) crosstalk
            Overlaps: \(truth.overlaps.count), \(String(format: "%.1f", truth.overlaps.reduce(0) { $0 + $1.end - $1.start })) s in total

            Obstacles:

            """
            if notes.isEmpty { s += "  none (clean speech with pauses)\n" }
            for n in notes { s += "  - \(n)\n" }
            if config.rateJitter > 0 { s += "  - Speed: each line's say rate varies by up to ±\(Int(config.rateJitter * 100)) %\n" }
            if config.doubleTalk { s += "  - Double talk: you talk over the call more often, and some interjections are yours\n" }
            s += String(format: "\nLevels: mix normalized to %.1f dBFS RMS, no clipping.\n", finalRMS)
            return s
        }
    }

    private final class RenderResults: @unchecked Sendable {
        let lock = NSLock()
        var audio: [[Float]?]
        var failure: Error?
        init(count: Int) { audio = Array(repeating: nil, count: count) }
    }

    /// Speaker ids: A, B, C, ... in the order of `truth.speakers`.
    static func id(_ index: Int) -> String { String(UnicodeScalar(UInt8(65 + index))) }
}
