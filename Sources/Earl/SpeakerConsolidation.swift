import Foundation

// R2-2 follow-up: a quiet participant who mostly says "mhm", "ja", "genau"
// only gives the speaker model short clips, whose voice prints are noisy, so
// the clustering splits that one person into several tiny voices (seen on a
// real call: one main voice of 847 s and "speakers" of 15, 7 and 3 s that were
// one person). This merges tiny voices that sound more like each other than
// like any of the main voices.

enum SpeakerConsolidation {
    struct Options: Equatable {
        /// A voice with less talk time than this (and under a quarter of the
        /// main voice's) counts as small and may be merged.
        var smallSeconds = 30.0
        /// Small voices merge only when their voice prints are at least this
        /// similar (cosine; one person on long clips scores ≥ 0.9, different
        /// people ≤ 0.6, short clips far less for either).
        var minSimilarity = 0.35
        /// When set, a voice still shorter than this after merging is folded
        /// into the voice it's most similar to.
        var foldSeconds: Double?
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in a.indices {
            dot += Double(a[i]) * Double(b[i])
            na += Double(a[i]) * Double(a[i])
            nb += Double(b[i]) * Double(b[i])
        }
        return na > 0 && nb > 0 ? dot / (na * nb).squareRoot() : 0
    }

    /// Merges small voices, single linkage: two groups of small voices merge
    /// when their closest pair is at least `minSimilarity` alike and closer
    /// than either group is to any main voice. The most alike pair goes first.
    static func consolidate(_ d: Diarization, options: Options = .init()) -> Diarization {
        let speakers = d.speakers
        guard speakers.count > 2 else { return d }
        let longest = speakers.map(\.seconds).max() ?? 0
        let isSmall = speakers.map { $0.seconds < options.smallSeconds && $0.seconds < longest / 4 && !$0.embedding.isEmpty }
        let large = speakers.indices.filter { !isSmall[$0] }
        guard !large.isEmpty else { return d }

        let sim = speakers.map { a in speakers.map { b in cosine(a.embedding, b.embedding) } }
        // How close a voice is to the nearest main voice.
        let toLarge = speakers.indices.map { i in large.filter { $0 != i }.map { sim[i][$0] }.max() ?? -1 }

        var groups = speakers.indices.filter { isSmall[$0] }.map { [$0] }
        while groups.count > 1 {
            var best: (a: Int, b: Int, link: Double)?
            for a in groups.indices {
                for b in groups.indices where b > a {
                    let link = groups[a].flatMap { i in groups[b].map { sim[i][$0] } }.max() ?? -1
                    let near = max(groups[a].map { toLarge[$0] }.max() ?? -1, groups[b].map { toLarge[$0] }.max() ?? -1)
                    guard link >= options.minSimilarity, link > near else { continue }
                    if best == nil || link > best!.link { best = (a, b, link) }
                }
            }
            guard let best else { break }
            groups[best.a] += groups[best.b]
            groups.remove(at: best.b)
        }

        // Each voice -> the voice it becomes.
        var target = Array(speakers.indices)
        for group in groups {
            let keep = group.min()!
            for i in group { target[i] = keep }
        }
        if let fold = options.foldSeconds {
            var seconds: [Int: Double] = [:]
            for (i, s) in speakers.enumerated() { seconds[target[i], default: 0] += s.seconds }
            for (t, total) in seconds where total < fold {
                let others = Set(target).subtracting([t])
                guard let into = others.max(by: { sim[t][$0] < sim[t][$1] }) else { continue }
                for i in target.indices where target[i] == t { target[i] = into }
            }
        }
        guard target != Array(speakers.indices) else { return d }
        return relabel(d, target: target)
    }

    /// Applies the merges and numbers the voices 0, 1, … by first appearance again.
    private static func relabel(_ d: Diarization, target: [Int]) -> Diarization {
        var index: [Int: Int] = [:]
        var segments: [(start: Double, end: Double, speaker: Int)] = []
        for seg in d.segments.sorted(by: { $0.start < $1.start }) {
            let t = target[seg.speaker]
            let i = index[t] ?? index.count
            index[t] = i
            segments.append((seg.start, seg.end, i))
        }
        var merged: [Int: (embedding: [Float], seconds: Double)] = [:]
        for (s, speaker) in d.speakers.enumerated() {
            guard let i = index[target[s]] else { continue }
            var m = merged[i] ?? ([Float](repeating: 0, count: speaker.embedding.count), 0)
            // Talk-time weighted mean of the voice prints.
            if m.embedding.count == speaker.embedding.count {
                for k in m.embedding.indices { m.embedding[k] += speaker.embedding[k] * Float(speaker.seconds) }
            }
            m.seconds += speaker.seconds
            merged[i] = m
        }
        let speakers = merged.sorted { $0.key < $1.key }.map { i, m in
            (index: i, embedding: m.seconds > 0 ? m.embedding.map { $0 / Float(m.seconds) } : m.embedding, seconds: m.seconds)
        }
        return Diarization(segments: segments, speakers: speakers)
    }
}
