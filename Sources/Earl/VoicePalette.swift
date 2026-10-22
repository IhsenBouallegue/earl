import SwiftUI

// U-1: one colour per voice, carried through faces, bubbles, name labels and
// the waveform (DESIGN.md, The Voice Colour Rule). Assigned in order of first
// speech; blue is yours alone.

/// A voice's colours: the face, the pale bubble, and the dark text shade used
/// for its name. `text` passes 4.5:1 on `bubble` (and on soft paper) in light
/// and dark; body text in a bubble is `Paper.ink`.
/// Named VoiceColors because `Voice` is voice memory's stored voice
/// (VoiceLibrary.swift); `VoicePalette.Voice` is the same type.
struct VoiceColors: Equatable {
    var face: Color
    var bubble: Color
    var text: Color
}

/// The raw values behind a `VoiceColors`, for the contrast tests.
struct VoiceTones: Hashable, Sendable {
    var name: String
    var face: Tone
    var bubble: Tone
    var text: Tone

    var voice: VoiceColors { VoiceColors(face: face.color, bubble: bubble.color, text: text.color) }
}

enum VoicePalette {
    typealias Voice = VoiceColors

    /// Other people's voices, in order. In dark, bubbles become deep tints of
    /// the voice and text a light tint; faces stay the same pastel.
    static let tones: [VoiceTones] = [
        VoiceTones(name: "lavender", face: Tone(0xa78bfa, dark: 0xa78bfa),
                   bubble: Tone(0xece4ff, dark: 0x33284d), text: Tone(0x5b21b6, dark: 0xd6c6ff)),
        VoiceTones(name: "marigold", face: Tone(0xf6b93b, dark: 0xf6b93b),
                   bubble: Tone(0xfff0cc, dark: 0x3f2f10), text: Tone(0x8a4b00, dark: 0xffd88a)),
        VoiceTones(name: "mint", face: Tone(0x34d399, dark: 0x34d399),
                   bubble: Tone(0xd8f5e8, dark: 0x143a2c), text: Tone(0x065f46, dark: 0x9df0c9)),
        VoiceTones(name: "guest", face: Tone(0xcbd5e1, dark: 0xcbd5e1),
                   bubble: Tone(0xeef1f5, dark: 0x2c3038), text: Tone(0x3f4a5a, dark: 0xd6dde8)),
        VoiceTones(name: "rose", face: Tone(0xfb7185, dark: 0xfb7185),
                   bubble: Tone(0xffe4e8, dark: 0x4a1f29), text: Tone(0x9f1239, dark: 0xffc4cf)),
        VoiceTones(name: "teal", face: Tone(0x2cc2b0, dark: 0x2cc2b0),
                   bubble: Tone(0xd3f3ef, dark: 0x0f3a37), text: Tone(0x115e59, dark: 0x9ff0e5)),
        VoiceTones(name: "peach", face: Tone(0xfb9a5b, dark: 0xfb9a5b),
                   bubble: Tone(0xffe8d6, dark: 0x45260f), text: Tone(0x9a3412, dark: 0xffc99e)),
        VoiceTones(name: "sage", face: Tone(0xa3b18a, dark: 0xa3b18a),
                   bubble: Tone(0xe8eddf, dark: 0x2e3524), text: Tone(0x3f4f2a, dark: 0xd4e0bf)),
    ]

    /// You: the blue face, and blue bubbles with white text.
    static let youTones = VoiceTones(name: "you", face: PaperTones.youFace, bubble: PaperTones.you,
                                     text: PaperTones.onColor)

    private static let voices = tones.map(\.voice)

    /// Voice `index` (0 = the first voice heard), cycling after eight.
    static func voice(_ index: Int) -> VoiceColors {
        voices[((index % voices.count) + voices.count) % voices.count]
    }

    static let you = youTones.voice

    /// The colours for a face: yours, or its voice's.
    static func voice(for look: AvatarLook) -> VoiceColors {
        look.isMe ? you : voice(look.voice)
    }
}

// MARK: - Which voice is whose

/// Whose colour a speaker gets.
enum SpeakerVoice: Hashable {
    case you
    case other(Int)

    var voice: VoiceColors {
        switch self {
        case .you: VoicePalette.you
        case .other(let i): VoicePalette.voice(i)
        }
    }

    var look: AvatarLook {
        switch self {
        case .you: .me
        case .other(let i): .voice(i)
        }
    }
}

extension VoicePalette {
    /// The palette index of a speaker id: "S1" → 0, "S2" → 1, …; nil for
    /// anything else.
    static func index(forSpeakerID id: String) -> Int? {
        guard id.first == "S", let n = Int(id.dropFirst()), n >= 1 else { return nil }
        return n - 1
    }

    /// The voice of a turn, for the meeting page and the recording screen alike.
    /// Goes through the same faces as the badges (`SpeakerFaces`), so a face and
    /// its bubbles always share a colour. "Me" is you; unseparated call audio
    /// is the first voice.
    static func speakerVoice(for turn: Turn, in speakers: [Speaker],
                             looks: [String: AvatarLook]? = nil) -> SpeakerVoice {
        let look = SpeakerFaces.look(for: turn, in: speakers, looks: looks)
        return look.isMe ? .you : .other(look.voice)
    }

    /// The voice of a speaker id when there are no speakers yet (live, before
    /// the file exists): "Me" is you, "S2" is the second voice.
    static func speakerVoice(forID id: String?, speaker: String) -> SpeakerVoice {
        if speaker == "Me" { return .you }
        return .other(id.flatMap(index(forSpeakerID:)) ?? 0)
    }
}
