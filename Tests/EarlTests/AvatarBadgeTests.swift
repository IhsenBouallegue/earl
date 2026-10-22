import AppKit
import SwiftUI
import Testing
@testable import Earl

/// R3-5: which face each speaker's badge shows.
struct AvatarBadgeTests {
    static func sp(_ id: String, track: String = "Them", seconds: Double = 10, avatar: String? = nil,
                        name: String? = nil) -> Speaker {
        Speaker(id: id, track: track, name: name, embedding: [], seconds: seconds, avatar: avatar)
    }

    @Test func storedAccessoryBringsBackTheLiveFace() {
        #expect(AvatarLook(stored: "monocle") == .voice(0))
        #expect(AvatarLook(stored: "moustache") == .voice(2))
        #expect(AvatarLook(stored: "moustache")?.head == .egg)
        #expect(AvatarLook(stored: "freckles") == .voice(7))
        #expect(AvatarLook(stored: "cape") == nil)
        #expect(AvatarLook(stored: nil) == nil)
    }

    @Test func storedFacesWinAndOthersTakeFreeOnes() {
        // S2 wore the monocle live; S1 and S3 had no live face.
        let speakers = [Self.sp("S1"), Self.sp("S2", avatar: "monocle"), Self.sp("S3")]
        let looks = SpeakerFaces.looks(for: speakers)
        #expect(looks["S2"] == .voice(0))
        #expect(looks["S1"] == .voice(1))
        #expect(looks["S3"] == .voice(2))
        #expect(Set(looks.values.map(\.accessories)).count == 3)
    }

    @Test func oldMeetingsGetStableFacesByNumber() {
        let speakers = [Self.sp("S2"), Self.sp("S1"), Self.sp("S3")]
        let looks = SpeakerFaces.looks(for: speakers)
        #expect(looks == ["S1": AvatarLook.voice(0), "S2": .voice(1), "S3": .voice(2)])
        #expect(SpeakerFaces.looks(for: speakers.reversed()) == looks)
    }

    @Test func aDuplicateStoredFaceIsNotReused() {
        let speakers = [Self.sp("S1", avatar: "glasses"), Self.sp("S2", avatar: "glasses")]
        let looks = SpeakerFaces.looks(for: speakers)
        #expect(looks["S1"] == .voice(1))
        #expect(looks["S2"] == .voice(0))
    }

    @Test func youKeepTheAccentFace() {
        let speakers = [Self.sp("S1", track: "Me", seconds: 300), Self.sp("S2", track: "Me", seconds: 20),
                        Self.sp("S3")]
        let looks = SpeakerFaces.looks(for: speakers)
        #expect(looks["S1"] == .me)
        #expect(looks["S2"]?.isMe == false)
        let me = Turn(start: 0, end: 1, speaker: "Me", text: "", speakerID: "S1")
        let roommate = Turn(start: 0, end: 1, speaker: "Me", text: "", speakerID: "S2")
        #expect(SpeakerFaces.look(for: me, in: speakers) == .me)
        #expect(SpeakerFaces.look(for: roommate, in: speakers).isMe == false)
    }

    @Test func unseparatedTracks() {
        let them = Turn(start: 0, end: 1, speaker: "Them", text: "")
        let me = Turn(start: 0, end: 1, speaker: "Me", text: "")
        #expect(SpeakerFaces.look(for: them, in: []) == .voice(0))
        #expect(SpeakerFaces.look(for: me, in: []) == .me)
    }
}

/// R3-5: renders badges, a transcript excerpt and the speakers strip to PNGs
/// for reviewing the look. Only runs with EARL_AVATAR_PNG set to a folder:
///
///     EARL_AVATAR_PNG=/tmp/earl-avatars ./test.sh --filter AvatarBadgeRenderTests
@MainActor
struct AvatarBadgeRenderTests {
    nonisolated static let out = ProcessInfo.processInfo.environment["EARL_AVATAR_PNG"]

    static let speakers = [
        AvatarBadgeTests.sp("S1", track: "Me", seconds: 240),
        AvatarBadgeTests.sp("S2", seconds: 310, avatar: "glasses", name: "Sarah"),
        AvatarBadgeTests.sp("S3", seconds: 180, avatar: "monocle"),
        AvatarBadgeTests.sp("S4", seconds: 95, name: "Tom"),
    ]

    static var meeting: Meeting {
        var speakers = speakers
        speakers[3].nameSource = .guessed
        speakers[3].evidence = "“Thanks, Tom.”"
        let turns = [
            Turn(start: 12, end: 20, speaker: "Them", text: "Morning! Can everyone see my screen? I put the release numbers up top.", speakerID: "S2"),
            Turn(start: 21, end: 25, speaker: "Me", text: "Yes, looks good. Let's start with the crash rate.", speakerID: "S1"),
            Turn(start: 26, end: 34, speaker: "Them", text: "It's down to 0.2 percent since the fix went out on Tuesday.", speakerID: "S3"),
            Turn(start: 35, end: 41, speaker: "Them", text: "Nice. I'll write it up for the changelog.", speakerID: "S4"),
            Turn(start: 42, end: 47, speaker: "Me", text: "Great, thanks Tom.", speakerID: "S1"),
        ]
        return Meeting(id: "m", folder: URL(fileURLWithPath: "/tmp/m"),
                       info: MeetingInfo(title: "Release sync", titleIsDefault: false, startedAt: Date(), duration: 60, status: .done),
                       turns: turns, summary: "", files: [], speakers: speakers)
    }

    private func sheet(_ scheme: ColorScheme) -> some View {
        let meeting = Self.meeting
        let bg = scheme == .dark ? Color(white: 0.16) : Color(white: 0.96)
        return VStack(alignment: .leading, spacing: 22) {
            Text("Badges").font(.headline)
            HStack(spacing: 8) {
                SpeakerBadge(name: "Me", isMe: true, look: .me)
                SpeakerBadge(name: "Sarah", isMe: false, look: .voice(1))
                SpeakerBadge(name: "Speaker 3", isMe: false, look: .voice(0))
                SpeakerBadge(name: "Tom?", isMe: false, look: .voice(2))
                SpeakerBadge(name: "Them", isMe: false, look: .voice(0))
                SpeakerBadge(name: "Them", isMe: false)
            }
            HStack(spacing: 8) {
                ForEach(0..<8, id: \.self) { i in
                    SpeakerBadge(name: "S\(i + 1)", isMe: false, look: .voice(i))
                }
            }
            Text("Cast").font(.headline)
            HStack(spacing: 8) {
                ForEach(CastMember.cast(turns: meeting.turns, speakers: meeting.speakers)) { member in
                    SpeakerAvatar.badge(member.look, size: 24, unconfirmed: CastRow.name(member).hasSuffix("?"))
                    Text(CastRow.name(member))
                }
            }
            Text("Conversation").font(.headline)
            VStack(alignment: .leading, spacing: 13) {
                ForEach(meeting.turns) { turn in
                    ConversationBubble(turn: turn, meeting: meeting)
                }
            }
            .frame(width: 640, alignment: .leading)
        }
        .padding(28)
        .background(bg)
        .environment(\.colorScheme, scheme)
    }

    private func save(_ view: some View, to url: URL, scale: CGFloat = 2) throws {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        let image = try #require(renderer.cgImage)
        let rep = NSBitmapImageRep(cgImage: image)
        try #require(rep.representation(using: .png, properties: [:])).write(to: url)
    }

    @Test(.enabled(if: out != nil, "Set EARL_AVATAR_PNG to render the badges"))
    func renderSheets() throws {
        let dir = URL(fileURLWithPath: Self.out!)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try save(sheet(.light), to: dir.appendingPathComponent("badges-light.png"))
        try save(sheet(.dark), to: dir.appendingPathComponent("badges-dark.png"))
        // Close-ups at 6x, to judge the small faces pixel by pixel.
        for scheme in [ColorScheme.light, .dark] {
            let name = scheme == .dark ? "dark" : "light"
            let bg = scheme == .dark ? Color(white: 0.16) : Color(white: 0.96)
            let row = HStack(spacing: 6) {
                SpeakerBadge(name: "Me", isMe: true, look: .me)
                ForEach(0..<8, id: \.self) { i in SpeakerAvatar.badge(.voice(i), size: 16) }
                ForEach(0..<8, id: \.self) { i in SpeakerAvatar.badge(.voice(i), size: 22) }
            }
            try save(row.padding(10).background(bg).environment(\.colorScheme, scheme),
                     to: dir.appendingPathComponent("badges-zoom-\(name).png"), scale: 6)
        }
        print("[badges] wrote PNGs to \(dir.path)")
    }
}
