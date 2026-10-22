import SwiftUI

// R3-5: the live stage's faces on transcript badges and speaker chips. A voice
// keeps the face it wore live (`Speaker.avatar`); voices without one get a
// stable face from their speaker number, so older meetings look the same way.

extension AvatarLook {
    /// The live face that wore `accessory`: the stage gives voice N the Nth
    /// accessory and the (N mod 3)th head, so both come back from the name.
    init?(stored accessory: String?) {
        guard let raw = accessory, let a = Accessory(rawValue: raw),
              let index = Accessory.allCases.firstIndex(of: a) else { return nil }
        self = .voice(index)
    }
}

enum SpeakerFaces {
    /// A face per speaker ID. Stored faces first; the rest take the first
    /// faces nobody else wears, by speaker number, so two voices in one
    /// meeting never look alike. You get the accent face.
    static func looks(for speakers: [Speaker]) -> [String: AvatarLook] {
        var out: [String: AvatarLook] = [:]
        var taken = Set<Int>()
        for s in speakers where !Speaker.isYou(s, in: speakers) {
            if let look = AvatarLook(stored: s.avatar), let a = look.accessories.first,
               let i = AvatarLook.Accessory.allCases.firstIndex(of: a), !taken.contains(i) {
                out[s.id] = look
                taken.insert(i)
            }
        }
        var next = 0
        for s in speakers.sorted(by: { $0.number < $1.number }) where out[s.id] == nil {
            if Speaker.isYou(s, in: speakers) {
                out[s.id] = .me
                continue
            }
            while taken.contains(next) { next += 1 }
            out[s.id] = .voice(next)
            taken.insert(next)
        }
        return out
    }

    /// The face for a turn. Unseparated call audio is one voice: the first face.
    static func look(for turn: Turn, in speakers: [Speaker], looks: [String: AvatarLook]? = nil) -> AvatarLook {
        if Speaker.isMe(turn, in: speakers) { return .me }
        if let id = turn.speakerID, let look = (looks ?? self.looks(for: speakers))[id] { return look }
        return .voice(0)
    }
}
