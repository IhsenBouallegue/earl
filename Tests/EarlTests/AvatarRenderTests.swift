import AppKit
import SwiftUI
import Testing
@testable import Earl

/// R2-5: renders the stage's faces to PNGs for reviewing the look. Only runs
/// with EARL_AVATAR_PNG set to an output folder:
///
///     EARL_AVATAR_PNG=/tmp/earl-avatars ./test.sh --filter AvatarRenderTests
@MainActor
struct AvatarRenderTests {
    nonisolated static let out = ProcessInfo.processInfo.environment["EARL_AVATAR_PNG"]

    /// A stage row as the recording screen draws it: face, name and talk time.
    private struct Cell: View {
        var look: AvatarLook
        var pose: AvatarPose
        var label: String
        var talk: String
        var isMe = false
        var active = false
        var dimmed = false
        var size: CGFloat = 76

        var body: some View {
            VStack(spacing: 6) {
                SpeakerAvatar(look: look, pose: pose, size: isMe ? size * 1.12 : size, isActive: active)
                    .scaleEffect(active ? 1.05 : 1, anchor: .bottom)
                    .offset(y: active ? -5 : 0)
                VStack(spacing: 1) {
                    Text(label).font(.callout.weight(.medium)).foregroundStyle(isMe ? Theme.accent : Color.primary)
                    Text(talk).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: size)
            .opacity(dimmed ? 0.62 : 1)
        }
    }

    private func sheet(_ scheme: ColorScheme) -> some View {
        let bg = scheme == .dark ? Color(white: 0.16) : Color(white: 0.96)
        return VStack(alignment: .leading, spacing: 28) {
            Text("Idle").font(.headline)
            HStack(alignment: .bottom, spacing: 22) {
                Cell(look: .me, pose: .rest, label: "Me", talk: "quiet so far", isMe: true)
                ForEach(0..<8, id: \.self) { i in
                    Cell(look: .voice(i), pose: AvatarPose(glance: 0), label: "Speaker \(i + 1)", talk: "\(i + 1) min")
                }
            }
            Text("Talking (mouth 0.3, 0.7, 1) and blinking").font(.headline)
            HStack(alignment: .bottom, spacing: 22) {
                Cell(look: .me, pose: AvatarPose(mouth: 0.7), label: "Me", talk: "2 min", isMe: true, active: true)
                ForEach(0..<8, id: \.self) { i in
                    let m = [0.3, 0.7, 1.0][i % 3]
                    Cell(look: .voice(i), pose: AvatarPose(mouth: m, blink: i == 5 ? 1 : 0), label: "Speaker \(i + 1)", talk: "\(i + 1) min")
                }
            }
            Text("A stage: Speaker 2 is talking, the others look at them").font(.headline)
            HStack(alignment: .bottom, spacing: 22) {
                Cell(look: .me, pose: AvatarPose(glance: 1), label: "Alex", talk: "4 min", isMe: true, dimmed: true)
                Cell(look: .voice(0), pose: AvatarPose(glance: 1), label: "Speaker 1", talk: "6 min", dimmed: true)
                Cell(look: .voice(1), pose: AvatarPose(mouth: 0.8), label: "Speaker 2", talk: "3 min", active: true)
                Cell(look: .voice(2), pose: AvatarPose(glance: -1), label: "Speaker 3", talk: "48 s", dimmed: true)
            }
            Text("More voices, and the menu bar size").font(.headline)
            HStack(alignment: .bottom, spacing: 14) {
                ForEach(8..<14, id: \.self) { i in
                    Cell(look: .voice(i), pose: .rest, label: "Speaker \(i + 1)", talk: "12 s", size: 62)
                }
                ForEach(0..<5, id: \.self) { i in
                    SpeakerAvatar(look: i == 0 ? .me : .voice(i - 1), pose: AvatarPose(mouth: i == 2 ? 0.8 : 0),
                                  size: 30, isActive: i == 2)
                }
            }
        }
        .padding(32)
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

    @Test(.enabled(if: out != nil, "Set EARL_AVATAR_PNG to render the avatars"))
    func renderSheets() throws {
        let dir = URL(fileURLWithPath: Self.out!)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try save(sheet(.light), to: dir.appendingPathComponent("stage-light.png"))
        try save(sheet(.dark), to: dir.appendingPathComponent("stage-dark.png"))
        // Close-ups of one face in each state.
        for scheme in [ColorScheme.light, .dark] {
            let name = scheme == .dark ? "dark" : "light"
            let bg = scheme == .dark ? Color(white: 0.16) : Color(white: 0.96)
            let states: [(String, AvatarLook, AvatarPose, Bool)] = [
                ("me-idle", .me, .rest, false), ("me-talking", .me, AvatarPose(mouth: 0.8), true),
                ("monocle-idle", .voice(0), .rest, false), ("monocle-talking", .voice(0), AvatarPose(mouth: 0.8), true),
                ("moustache-talking", .voice(2), AvatarPose(mouth: 0.6), true),
            ]
            for (label, look, pose, active) in states {
                try save(SpeakerAvatar(look: look, pose: pose, size: 160, isActive: active)
                    .padding(24).background(bg).environment(\.colorScheme, scheme),
                         to: dir.appendingPathComponent("\(label)-\(name).png"))
            }
        }
        print("[avatars] wrote PNGs to \(dir.path)")
    }
}
