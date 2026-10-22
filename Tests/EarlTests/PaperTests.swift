import Foundation
import Testing
@testable import Earl

/// U-1: every text colour passes WCAG 4.5:1 on the surfaces it sits on, in
/// light and dark, and the voice palette and Earl's lines behave.
struct PaperContrastTests {
    /// WCAG 2 relative luminance of 0xRRGGBB.
    static func luminance(_ hex: UInt32) -> Double {
        func channel(_ v: UInt32) -> Double {
            let c = Double(v) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel((hex >> 16) & 0xff) + 0.7152 * channel((hex >> 8) & 0xff) + 0.0722 * channel(hex & 0xff)
    }

    static func ratio(_ a: UInt32, _ b: UInt32) -> Double {
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    /// Checks `text` on `surface` in both appearances.
    private func expectReadable(_ text: Tone, on surface: Tone, _ label: String) {
        let light = Self.ratio(text.light, surface.light)
        let dark = Self.ratio(text.dark, surface.dark)
        #expect(light >= 4.5, "\(label), light: \(light)")
        #expect(dark >= 4.5, "\(label), dark: \(dark)")
    }

    /// S-3: a citation chip, ink on hairline, in Ask Earl's answers.
    @Test func citationChip() {
        expectReadable(PaperTones.ink, on: PaperTones.hairline, "ink on hairline (citation chip)")
    }

    @Test func knownRatios() {
        #expect(abs(Self.ratio(0x000000, 0xffffff) - 21) < 0.01)
        #expect(abs(Self.ratio(0x777777, 0xffffff) - 4.48) < 0.01)
    }

    @Test func textOnPaper() {
        let t = PaperTones.self
        let surfaces: [(String, Tone)] = [("paper", t.paper), ("paperSoft", t.paperSoft), ("sidebar", t.sidebar),
                                          ("card", t.card), ("selection", t.selection)]
        let texts: [(String, Tone)] = [("ink", t.ink), ("inkMuted", t.inkMuted), ("masthead", t.masthead),
                                       ("error", t.error), ("ok", t.ok), ("youText", t.youText)]
        for (textName, text) in texts {
            for (surfaceName, surface) in surfaces {
                expectReadable(text, on: surface, "\(textName) on \(surfaceName)")
            }
        }
    }

    @Test func textOnFills() {
        let t = PaperTones.self
        expectReadable(t.paper, on: t.ink, "primary button text")
        expectReadable(t.onColor, on: t.live, "LIVE pill")
        expectReadable(t.onColor, on: t.you, "your bubble")
        expectReadable(t.ink, on: t.marker, "decision under the marker")
    }

    @Test func voiceText() {
        let t = PaperTones.self
        for v in VoicePalette.tones {
            expectReadable(v.text, on: v.bubble, "\(v.name) text on its bubble")
            expectReadable(t.ink, on: v.bubble, "ink on the \(v.name) bubble")
            // Name labels sit above the bubble, on the conversation's soft paper.
            for (name, surface) in [("paperSoft", t.paperSoft), ("paper", t.paper), ("card", t.card)] {
                expectReadable(v.text, on: surface, "\(v.name) name on \(name)")
            }
        }
        expectReadable(VoicePalette.youTones.text, on: VoicePalette.youTones.bubble, "you")
    }
}

struct VoicePaletteTests {
    @Test func eightDistinctVoicesThenCycle() {
        let faces = VoicePalette.tones.map(\.face.light)
        #expect(faces.count >= 8)
        #expect(Set(faces).count == faces.count)
        #expect(!faces.contains(PaperTones.youFace.light)) // blue is yours
        #expect(VoicePalette.voice(8) == VoicePalette.voice(0))
        #expect(VoicePalette.voice(-1) == VoicePalette.voice(VoicePalette.tones.count - 1))
    }

    @Test func speakerIDs() {
        #expect(VoicePalette.index(forSpeakerID: "S1") == 0)
        #expect(VoicePalette.index(forSpeakerID: "S12") == 11)
        #expect(VoicePalette.index(forSpeakerID: "Them") == nil)
        #expect(VoicePalette.index(forSpeakerID: "S0") == nil)
        #expect(VoicePalette.speakerVoice(forID: nil, speaker: "Me") == .you)
        #expect(VoicePalette.speakerVoice(forID: "S3", speaker: "Them") == .other(2))
        #expect(VoicePalette.speakerVoice(forID: nil, speaker: "Them") == .other(0))
    }

    @Test func faceAndBubbleAgree() {
        #expect(AvatarLook.voice(3).voice == 3)
        #expect(VoicePalette.voice(for: .voice(5)) == VoicePalette.voice(5))
        #expect(VoicePalette.voice(for: .me) == VoicePalette.you)
        // Colour tells the first eight apart; accessories only from the ninth on,
        // and never Earl's monocle.
        #expect((0..<8).allSatisfy { AvatarLook.voice($0).drawnAccessories.isEmpty })
        #expect(!AvatarLook.voice(9).drawnAccessories.isEmpty)
        #expect((0..<40).allSatisfy { !AvatarLook.voice($0).drawnAccessories.contains(.monocle) })
    }
}

struct EarlVoiceTests {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return c
    }

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }

    @Test func partOfDay() {
        #expect(EarlVoice.partOfDay(date(25, 9), calendar: calendar) == .morning)
        #expect(EarlVoice.partOfDay(date(25, 14), calendar: calendar) == .afternoon)
        #expect(EarlVoice.partOfDay(date(25, 19), calendar: calendar) == .evening)
        #expect(EarlVoice.partOfDay(date(25, 23), calendar: calendar) == .night)
        #expect(EarlVoice.partOfDay(date(25, 3), calendar: calendar) == .night)
    }

    @Test func stableWithinADay() {
        let a = EarlVoice.greeting(name: "Alex Morgan", at: date(25, 13), daysKnown: 1, calendar: calendar)
        let b = EarlVoice.greeting(name: "Alex Morgan", at: date(25, 17, 40), daysKnown: 1, calendar: calendar)
        #expect(a == b)
        #expect(a.contains("Alex"))
        #expect(!a.contains("Morgan"))
        // Over a few days the wording varies.
        let week = (20...26).map { EarlVoice.greeting(name: "Alex", at: date($0, 9), daysKnown: 1, calendar: calendar) }
        #expect(Set(week).count > 1)
    }

    @Test func noNameNoPlaceholder() {
        for day in 20...26 {
            for hour in [3, 9, 14, 19] {
                let g = EarlVoice.greeting(name: nil, at: date(day, hour), daysKnown: 0, calendar: calendar)
                #expect(!g.contains("{name}"))
                #expect(!g.contains(",  ") && !g.hasPrefix(","))
            }
        }
    }

    @Test func quieterOnceFamiliar() {
        let g = EarlVoice.greeting(name: "Alex", at: date(25, 14), daysKnown: EarlVoice.familiarAfterDays + 1, calendar: calendar)
        #expect(g == "Afternoon.")
        #expect(EarlVoice.greeting(name: "Alex", at: date(25, 9), daysKnown: 30, calendar: calendar) == "Morning.")
    }

    @Test func dayKeys() {
        #expect(EarlVoice.dayKey(date(5, 9), calendar: calendar) == "2026-09-05")
        #expect(EarlVoice.isThis("Sarah") == "Is this Sarah?")
    }
}
