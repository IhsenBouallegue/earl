import Foundation
import Testing
@testable import Earl

struct SpeakerConsolidationTests {
    /// Voice prints with the given pairwise cosines (rows of the Cholesky factor of the Gram matrix).
    static func prints(_ gram: [[Double]]) -> [[Float]] {
        let n = gram.count
        var l = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        for i in 0..<n {
            for j in 0...i {
                let s = gram[i][j] - (0..<j).reduce(0) { $0 + l[i][$1] * l[j][$1] }
                l[i][j] = i == j ? s.squareRoot() : s / l[j][j]
            }
        }
        return l.map { $0.map(Float.init) }
    }

    static func diarization(_ seconds: [Double], _ gram: [[Double]]) -> Diarization {
        let embeddings = prints(gram)
        var t = 0.0
        var segments: [(start: Double, end: Double, speaker: Int)] = []
        for (i, s) in seconds.enumerated() {
            segments.append((t, t + s, i))
            t += s + 1
        }
        return Diarization(segments: segments,
                           speakers: seconds.indices.map { (index: $0, embedding: embeddings[$0], seconds: seconds[$0]) })
    }

    @Test func mergesAQuietPersonSplitIntoTinyVoices() {
        // A real call: one main voice, and one quiet person found as three tiny voices.
        let d = Self.diarization([847, 15, 7, 3], [
            [1, 0.40, 0.13, 0.13],
            [0.40, 1, 0.52, 0.25],
            [0.13, 0.52, 1, 0.63],
            [0.13, 0.25, 0.63, 1],
        ])
        let out = SpeakerConsolidation.consolidate(d)
        #expect(out.speakers.count == 2)
        #expect(out.speakers.map(\.seconds) == [847, 25])
        #expect(out.segments.map(\.speaker) == [0, 1, 1, 1])
        #expect(out.speakers[1].embedding.count == 4)
    }

    @Test func keepsSmallVoicesThatSoundLikeDifferentPeople() {
        // Two short interjectors, each closer to a main voice than to each other.
        let d = Self.diarization([300, 200, 12, 8], [
            [1, 0.2, 0.5, 0.1],
            [0.2, 1, 0.1, 0.5],
            [0.5, 0.1, 1, 0.3],
            [0.1, 0.5, 0.3, 1],
        ])
        #expect(SpeakerConsolidation.consolidate(d).speakers.count == 4)
    }

    @Test func leavesMainVoicesAlone() {
        let d = Self.diarization([300, 200, 100], [[1, 0.9, 0.9], [0.9, 1, 0.9], [0.9, 0.9, 1]])
        #expect(SpeakerConsolidation.consolidate(d).speakers.count == 3)
    }

    @Test func foldsWhatIsStillTinyWhenAsked() {
        let d = Self.diarization([300, 200, 2], [[1, 0.1, 0.2], [0.1, 1, 0.4], [0.2, 0.4, 1]])
        #expect(SpeakerConsolidation.consolidate(d).speakers.count == 3)
        let out = SpeakerConsolidation.consolidate(d, options: .init(foldSeconds: 3))
        #expect(out.speakers.count == 2)
        #expect(out.speakers.map(\.seconds) == [300, 202])
    }
}
