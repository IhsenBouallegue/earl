import Foundation
@testable import Earl

/// Scores a transcript against a synthetic meeting's `truth.json` (T-1), so
/// every evaluation measures the same things the same way.
///
/// Words are aligned per true utterance: the longest common subsequence of
/// normalized words between the utterance and the transcript words on the
/// same track near its time, each transcript word used once. Aligning per
/// utterance rather than over the whole track keeps overlapping speech and
/// interjections from breaking the alignment of the line they overlap.
struct SyntheticScore {
    /// One piece of transcript. `track` is "Them" or "Me"; `speaker` is the
    /// label the system gave it, e.g. "Them" without separation or "S2" with it.
    struct Segment {
        var start: Double
        var end: Double
        var track: String
        var speaker: String
        var text: String
    }

    struct Report: CustomStringConvertible {
        var truthWords = 0
        var matchedWords = 0
        /// Matched words whose found speaker maps to the true speaker.
        var correctSpeakerWords = 0
        var lostInCrosstalk = 0, wordsInCrosstalk = 0
        var lostInOverlap = 0, wordsInOverlap = 0
        var lostElsewhere = 0, wordsElsewhere = 0
        var interjections = 0
        var interjectionsRightSpeaker = 0
        var interjectionsWrongSpeaker = 0
        var interjectionsLost = 0
        /// Words of the call that show up on the "Me" track (only with echo).
        var echoWordsAsMe = 0
        /// Transcript words that match nothing in the truth.
        var extraWords = 0
        /// Utterances that lost words, with the lost words in [brackets], for reading.
        var lostExamples: [String] = []
        /// Lost words per track ("Them", "Me").
        var lostByTrack: [String: Int] = [:]
        /// Found speaker label -> the true speaker id it covers most.
        var mapping: [String: String] = [:]
        /// True speaker id -> found label ("Them/S2") -> matched words, to see
        /// which voices were merged or split.
        var confusion: [String: [String: Int]] = [:]

        var lostWords: Int { truthWords - matchedWords }
        func lostWords(track: String) -> Int { lostByTrack[track] ?? 0 }
        var lostShare: Double { share(lostWords, truthWords) }
        var speakerAccuracy: Double { share(correctSpeakerWords, matchedWords) }
        var lostInCrosstalkShare: Double { share(lostInCrosstalk, wordsInCrosstalk) }
        var lostInOverlapShare: Double { share(lostInOverlap, wordsInOverlap) }
        var lostElsewhereShare: Double { share(lostElsewhere, wordsElsewhere) }

        private func share(_ a: Int, _ b: Int) -> Double { b == 0 ? 0 : Double(a) / Double(b) }

        var description: String {
            func pct(_ x: Double) -> String { String(format: "%.1f %%", x * 100) }
            return """
            words: \(truthWords), lost \(lostWords) (\(pct(lostShare))), extra \(extraWords)
            lost in crosstalk: \(lostInCrosstalk)/\(wordsInCrosstalk) (\(pct(lostInCrosstalkShare))), \
            in other overlaps: \(lostInOverlap)/\(wordsInOverlap) (\(pct(lostInOverlapShare))), \
            elsewhere: \(lostElsewhere)/\(wordsElsewhere) (\(pct(lostElsewhereShare)))
            right speaker: \(correctSpeakerWords)/\(matchedWords) (\(pct(speakerAccuracy)))
            interjections: \(interjections), right speaker \(interjectionsRightSpeaker), \
            wrong speaker \(interjectionsWrongSpeaker), lost \(interjectionsLost)
            echo words attributed to Me: \(echoWordsAsMe)
            """
        }
    }

    /// Earl's turns without speaker separation: the label is the track.
    static func segments(from turns: [Turn]) -> [Segment] {
        turns.map { Segment(start: $0.start, end: $0.end, track: $0.speaker, speaker: $0.speaker, text: $0.text) }
    }

    /// `slack` is how far (seconds) a transcript word may sit outside an
    /// utterance's true span and still match it.
    static func score(truth: SyntheticTruth, segments: [Segment], slack: Double = 3) -> Report {
        var report = Report()
        // Whisper's segments can span long silences (with VAD especially), so a
        // word's time inside its segment isn't known; a word may match an
        // utterance when its segment's span (plus `slack`) touches it.
        let hyp = segments.sorted { $0.start < $1.start }.flatMap { seg in
            normalize(seg.text).map {
                HypWord(word: $0, from: seg.start - slack, to: seg.end + slack, track: seg.track, speaker: seg.speaker)
            }
        }
        var claimed = [Bool](repeating: false, count: hyp.count)
        let byTrack = Dictionary(grouping: hyp.indices, by: { hyp[$0].track })
        let words = truth.utterances.map { normalize($0.text) }
        var matches = words.map { [Int?](repeating: nil, count: $0.count) }

        // Pass 1, per track: one LCS over the turns and crosstalk in order of
        // their start against the transcript in order, as Whisper reads it.
        for (track, candidates) in byTrack {
            let order = truth.utterances.indices
                .filter { truth.utterances[$0].track == track && truth.utterances[$0].kind != .interjection }
                .sorted { truth.utterances[$0].start < truth.utterances[$1].start }
            let refs = order.flatMap { u in words[u].indices.map { (u, $0) } }
            let pairs = lcs(refs.map { words[$0.0][$0.1] }, candidates.map { hyp[$0].word }) { i, j in
                let utt = truth.utterances[refs[i].0], h = hyp[candidates[j]]
                return h.from <= utt.end && utt.start <= h.to
            }
            for (i, j) in pairs {
                matches[refs[i].0][refs[i].1] = candidates[j]
                claimed[candidates[j]] = true
            }
        }
        // Pass 2, per utterance: interjections and words pass 1 couldn't place
        // in order (overlapping speech read in another order) take what's left.
        let rest = truth.utterances.indices.sorted { a, b in
            let ua = truth.utterances[a], ub = truth.utterances[b]
            if (ua.kind == .interjection) != (ub.kind == .interjection) { return ub.kind == .interjection }
            return ua.start < ub.start
        }
        for u in rest {
            let utt = truth.utterances[u]
            let missing = matches[u].indices.filter { matches[u][$0] == nil }
            guard !missing.isEmpty else { continue }
            let candidates = (byTrack[utt.track] ?? []).filter {
                !claimed[$0] && hyp[$0].from <= utt.end && utt.start <= hyp[$0].to
            }
            for (i, j) in lcs(missing.map { words[u][$0] }, candidates.map { hyp[$0].word }) {
                matches[u][missing[i]] = candidates[j]
                claimed[candidates[j]] = true
            }
        }

        // Map each found label to the true speaker it covers most.
        var votes: [String: [String: Int]] = [:]
        for (u, m) in matches.enumerated() {
            for h in m.compactMap({ $0 }) {
                votes[hyp[h].track + "/" + hyp[h].speaker, default: [:]][truth.utterances[u].speaker, default: 0] += 1
            }
        }
        for (label, v) in votes {
            report.mapping[label] = v.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key
        }

        let crosstalkSpans = truth.utterances.filter { $0.kind == .crosstalk }
        for (u, m) in matches.enumerated() {
            let utt = truth.utterances[u]
            let timed = timedWords(utt.text, start: utt.start, end: utt.end)
            let times = timed.map(\.time)
            if m.contains(where: { $0 == nil }) {
                let marked = zip(timed, m).map { $1 == nil ? "[\($0.word)]" : $0.word }.joined(separator: " ")
                report.lostExamples.append(String(format: "%.1f %@ %@: ", utt.start, utt.speaker, utt.kind.rawValue) + marked)
            }
            var rightWords = 0, found = 0
            for (i, h) in m.enumerated() {
                let t = times[i]
                let inOverlap = truth.overlaps.contains { $0.start <= t && t <= $0.end && $0.speakers.contains(utt.speaker) }
                let inCrosstalk = inOverlap && crosstalkSpans.contains { $0.start <= t && t <= $0.end }
                report.truthWords += 1
                if inCrosstalk { report.wordsInCrosstalk += 1 } else if inOverlap { report.wordsInOverlap += 1 } else { report.wordsElsewhere += 1 }
                guard let h else {
                    report.lostByTrack[utt.track, default: 0] += 1
                    if inCrosstalk { report.lostInCrosstalk += 1 } else if inOverlap { report.lostInOverlap += 1 } else { report.lostElsewhere += 1 }
                    continue
                }
                found += 1
                report.matchedWords += 1
                report.confusion[utt.speaker, default: [:]][hyp[h].track + "/" + hyp[h].speaker, default: 0] += 1
                if report.mapping[hyp[h].track + "/" + hyp[h].speaker] == utt.speaker {
                    report.correctSpeakerWords += 1
                    rightWords += 1
                }
            }
            if utt.kind == .interjection {
                report.interjections += 1
                if found == 0 { report.interjectionsLost += 1 }
                else if rightWords * 2 >= found { report.interjectionsRightSpeaker += 1 }
                else { report.interjectionsWrongSpeaker += 1 }
            }
        }

        // Echo: leftover "Me" words that repeat what the call said just before.
        if !truth.echo.isEmpty {
            let delay = (truth.echo.first?.delayMs ?? 0) / 1000
            for utt in truth.utterances where utt.track == "Them" {
                let candidates = (byTrack["Me"] ?? []).filter {
                    !claimed[$0] && hyp[$0].from <= utt.end + delay && utt.start + delay <= hyp[$0].to
                }
                for (_, j) in lcs(normalize(utt.text), candidates.map { hyp[$0].word }) {
                    claimed[candidates[j]] = true
                    report.echoWordsAsMe += 1
                }
            }
        }
        report.extraWords = claimed.filter { !$0 }.count
        return report
    }

    // MARK: - Words

    private struct HypWord {
        var word: String
        /// The word's segment span, widened by the slack.
        var from: Double
        var to: Double
        var track: String
        var speaker: String
    }

    /// Words with a time each, spread over the span by character count.
    static func timedWords(_ text: String, start: Double, end: Double) -> [(word: String, time: Double)] {
        let words = normalize(text)
        let total = words.reduce(0) { $0 + $1.count + 1 }
        var pos = 0
        return words.map { w in
            let mid = Double(pos) + Double(w.count + 1) / 2
            pos += w.count + 1
            return (w, start + (end - start) * mid / Double(max(total, 1)))
        }
    }

    /// Lowercase words without punctuation; digits spelled out, hyphenated
    /// words split and filler spellings unified, so "90%" matches "ninety percent".
    static func normalize(_ text: String) -> [String] {
        var t = text.lowercased()
            .replacingOccurrences(of: "%", with: " percent")
            .replacingOccurrences(of: "’", with: "'")
        t = t.replacingOccurrences(of: #"\bm+-?h+m+\b"#, with: "mhm", options: .regularExpression)
        t = t.replacingOccurrences(of: "-", with: " ")
        var out: [String] = []
        for raw in t.split(whereSeparator: { $0.isWhitespace }) {
            var w = String(raw.filter { $0.isLetter || $0.isNumber })
            guard !w.isEmpty else { continue }
            // "14th" -> "14"; ordinals and cardinals then read the same.
            for suffix in ["st", "nd", "rd", "th"] where w.hasSuffix(suffix) && w.dropLast(2).allSatisfy(\.isNumber) && w.count > 2 {
                w = String(w.dropLast(2))
            }
            if let n = Int(w), n < 1_000_000 {
                out += spell(n)
                continue
            }
            out.append(fillers[w] ?? w)
        }
        return out
    }

    private static let fillers = [
        "ok": "okay", "yep": "yeah",
    ]

    private static let ones = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
                               "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen",
                               "eighteen", "nineteen"]
    private static let tens = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]

    static func spell(_ n: Int) -> [String] {
        if n < 20 { return [ones[n]] }
        if n < 100 { return [tens[n / 10]] + (n % 10 == 0 ? [] : [ones[n % 10]]) }
        if n < 1000 { return [ones[n / 100], "hundred"] + (n % 100 == 0 ? [] : spell(n % 100)) }
        return spell(n / 1000) + ["thousand"] + (n % 1000 == 0 ? [] : spell(n % 1000))
    }

    /// Longest common subsequence; returns matched index pairs in order.
    /// `allowed` can veto pairs of equal words, e.g. too far apart in time.
    static func lcs(_ a: [String], _ b: [String], allowed: ((Int, Int) -> Bool)? = nil) -> [(Int, Int)] {
        guard !a.isEmpty, !b.isEmpty else { return [] }
        let w = b.count + 1
        var dp = [Int](repeating: 0, count: (a.count + 1) * w)
        func same(_ i: Int, _ j: Int) -> Bool { a[i] == b[j] && (allowed?(i, j) ?? true) }
        for i in 1...a.count {
            for j in 1...b.count {
                let skip = max(dp[(i - 1) * w + j], dp[i * w + j - 1])
                dp[i * w + j] = same(i - 1, j - 1) ? max(skip, dp[(i - 1) * w + j - 1] + 1) : skip
            }
        }
        var pairs: [(Int, Int)] = []
        var i = a.count, j = b.count
        while i > 0, j > 0 {
            if same(i - 1, j - 1), dp[i * w + j] == dp[(i - 1) * w + j - 1] + 1 {
                pairs.append((i - 1, j - 1)); i -= 1; j -= 1
            } else if dp[(i - 1) * w + j] >= dp[i * w + j - 1] {
                i -= 1
            } else {
                j -= 1
            }
        }
        return pairs.reversed()
    }
}
