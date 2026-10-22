import SwiftUI

// R2-5: the live stage on the recording screen, and its mini version in the
// menu bar panel. Faces come from `LiveStage` (at most 10 updates a second);
// mouths, blinks and sway are computed every frame from the recorder's levels.

/// Per-frame motion shared by the stage views: smoothed mouths and glances,
/// blinks and sway. A reference type held in @State, so updating it while
/// drawing a frame doesn't invalidate the view.
final class StageMotion {
    private var mouths: [Int: Double] = [:]
    private var glances: [Int: Double] = [:]
    private var lastTime: Double?

    /// Maps a track level (0...1 for -60...0 dB) to how open a mouth is. Below
    /// about -36 dB it stays shut, so room noise doesn't make anyone mumble.
    static func mouthTarget(level: Float) -> Double {
        min(1, max(0, (Double(level) - 0.4) / 0.42))
    }

    /// Advances the clock; call once per frame before `mouth` and `glance`.
    func tick(_ time: Double) -> Double {
        let dt = lastTime.map { min(0.1, max(0, time - $0)) } ?? 0
        lastTime = time
        return dt
    }

    /// Opens fast and closes a little slower, like a real mouth. With Reduce
    /// Motion, the mouth changes in three steps instead.
    func mouth(_ id: Int, target: Double, dt: Double, reduceMotion: Bool) -> Double {
        let current = mouths[id] ?? 0
        let tau = target > current ? 0.03 : 0.09
        let next = dt > 0 ? current + (target - current) * (1 - exp(-dt / tau)) : target
        mouths[id] = next
        guard reduceMotion else { return next }
        return next < 0.15 ? 0 : next < 0.55 ? 0.5 : 1
    }

    func glance(_ id: Int, target: Double, dt: Double, reduceMotion: Bool) -> Double {
        if reduceMotion { return target }
        let current = glances[id] ?? 0
        let next = dt > 0 ? current + (target - current) * (1 - exp(-dt / 0.12)) : target
        glances[id] = next
        return next
    }

    /// Eyes shut briefly every few seconds, each face on its own rhythm.
    static func blink(_ time: Double, seed: Int) -> Double {
        let period = 3.4 + Double((seed + 7) % 5) * 0.73
        let x = (time + Double(seed + 1) * 1.37).truncatingRemainder(dividingBy: period)
        let duration = 0.15
        return x < duration ? sin(x / duration * .pi) : 0
    }

    /// A slow sway (radians) and a breathing bob (points).
    static func idle(_ time: Double, seed: Int) -> (sway: Double, bob: Double) {
        let s = Double(seed + 2)
        return (sin(time * 0.8 + s * 1.9) * 0.035, sin(time * 1.3 + s) * 0.8)
    }
}

enum StageFormat {
    /// Talk time under a face: "12 s", "4 min". Quiet faces say so.
    static func talk(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 1 { return "quiet so far" }
        if s < 60 { return "\(s) s" }
        return "\(s / 60) min"
    }

    /// U-4: you, on the recording screen and in the menu bar.
    static let you = "You"

    /// "Speaker 2 is talking", "You're talking", "Listening".
    static func talking(_ face: LiveFace?) -> String {
        guard let face else { return "Listening" }
        return face.isMe ? "You're talking" : "\(face.label) is talking"
    }
}

/// A face with everything needed to draw one frame of it.
private struct FaceFrame: Identifiable {
    var face: LiveFace
    var look: AvatarLook
    var pose: AvatarPose
    var sway: Double
    var bob: Double
    var id: Int { face.id }
}

/// Builds the frame for every face: mouths follow the levels, the call audio
/// goes to whichever voice the tracker holds as talking, and eyes look at
/// whoever is talking.
private func frames(me: LiveFace, remote: [LiveFace], live: LiveSnapshot, levels: (them: Float, me: Float),
                    time: Double, motion: StageMotion, reduceMotion: Bool) -> [FaceFrame] {
    let dt = motion.tick(time)
    let all = [me] + remote
    let activeIndex = all.firstIndex { $0.isActive }
    return all.enumerated().map { i, face in
        let level: Float = face.isMe ? (live.micIsEcho ? 0 : levels.me) : (face.voice == live.mouthVoice ? levels.them : 0)
        let mouth = motion.mouth(face.id, target: StageMotion.mouthTarget(level: level), dt: dt, reduceMotion: reduceMotion)
        let lookAt: Double = activeIndex.map { $0 == i ? 0 : $0 < i ? -1 : 1 } ?? 0
        let seed = face.isMe ? 11 : face.voice
        let idle = reduceMotion ? (sway: 0.0, bob: 0.0) : StageMotion.idle(time, seed: seed)
        return FaceFrame(
            face: face, look: face.isMe ? .me : .voice(face.voice),
            pose: AvatarPose(mouth: mouth, blink: StageMotion.blink(time, seed: seed),
                             glance: motion.glance(face.id, target: lookAt, dt: dt, reduceMotion: reduceMotion)),
            sway: idle.sway, bob: idle.bob - (reduceMotion ? 0 : mouth * 1.5))
    }
}

/// The recording screen's stage: you, plus one face per voice on the call.
/// U-4: 64 pt faces 40 pt apart, the talker 82 pt and glowing in its colour.
struct SpeakerStage: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var stage: LiveStage
    let meeting: Meeting
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var motion = StageMotion()

    /// Sortformer tells at most four voices apart, so five faces is the usual
    /// most; the fallback keeps a crowd on one line.
    private var faceSize: CGFloat {
        switch stage.faces.count + 1 {
        case ...5: 64
        case ...7: 54
        default: 46
        }
    }

    private var talkerSize: CGFloat { (faceSize * 82 / 64).rounded() }

    var body: some View {
        VStack(spacing: 16) {
            TimelineView(.animation) { context in
                let live = stage.live
                let me = LiveFace(voice: -1, label: StageFormat.you, seconds: stage.meSeconds, isActive: live.meTalking)
                let faces = stage.faces.map { f in
                    var f = f
                    if let live = live.faces.first(where: { $0.voice == f.voice }) { f.isActive = live.isActive }
                    return f
                }
                HStack(alignment: .bottom, spacing: faceSize * 40 / 64) {
                    ForEach(frames(me: me, remote: faces, live: live, levels: state.levels,
                                   time: context.date.timeIntervalSinceReferenceDate, motion: motion,
                                   reduceMotion: reduceMotion)) { frame in
                        cell(frame)
                            .transition(reduceMotion ? .opacity : .scale(scale: 0.3).combined(with: .opacity))
                    }
                }
                .animation(reduceMotion ? nil : .spring(duration: 0.5, bounce: 0.35), value: stage.faces.map(\.id))
            }
            .frame(maxWidth: .infinity)
            invited
        }
        // Above the faces without taking room, so the stage stays centred.
        .overlay(alignment: .top) { announcement.alignmentGuide(.top) { $0[.bottom] + 12 } }
    }

    private func cell(_ frame: FaceFrame) -> some View {
        let active = frame.face.isActive
        return VStack(spacing: 7) {
            SpeakerAvatar(look: frame.look, pose: frame.pose, size: active ? talkerSize : faceSize, isActive: active)
                .rotationEffect(.radians(frame.sway), anchor: .bottom)
                .offset(y: frame.bob)
                .animation(reduceMotion ? nil : .spring(duration: 0.4, bounce: 0.35), value: active)
            VStack(spacing: 3) {
                if frame.face.label.hasPrefix("Speaker ") {
                    SpeakerTag(name: frame.face.label)
                } else {
                    Text(frame.face.label)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Paper.ink)
                        .lineLimit(1)
                }
                Text(StageFormat.talk(frame.face.seconds))
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(Paper.inkMuted)
                    .contentTransition(.numericText())
            }
        }
        .frame(minWidth: talkerSize + 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(frame.face.label), \(StageFormat.talk(frame.face.seconds))\(active ? ", talking" : "")")
    }

    /// "Speaker 2 joined", for a few seconds.
    private var announcement: some View {
        ZStack {
            if let text = stage.announcement {
                Text(text)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Paper.inkMuted)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .frame(height: 18)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: stage.announcement)
    }

    /// Calendar attendees, as quiet chips: the calendar says who was invited,
    /// not which voice is whose, so they stay apart from the faces.
    @ViewBuilder
    private var invited: some View {
        let names = (meeting.info.attendees ?? []).filter { !$0.isMe }.map { AttendeeName.firstName($0.name) }
        if !names.isEmpty {
            HStack(spacing: 8) {
                Text("Invited").foregroundStyle(Paper.inkMuted)
                ForEach(Array(names.prefix(6).enumerated()), id: \.offset) { _, name in
                    Text(name)
                        .fontWeight(.semibold)
                        .foregroundStyle(Paper.ink)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 3)
                        .background(Paper.card, in: Capsule())
                        .overlay(Capsule().strokeBorder(Paper.hairline))
                }
                if names.count > 6 {
                    Text("+\(names.count - 6)").foregroundStyle(Paper.inkMuted)
                }
            }
            .font(.system(size: 14))
            .lineLimit(1)
        }
    }
}

enum SilenceHint {
    /// A hint once a track has been quiet for longer than `after` seconds.
    static func text(_ last: Date?, since start: Date?, now: Date, isThem: Bool, after: TimeInterval = 15) -> String? {
        guard let start, now.timeIntervalSince(start) > after else { return nil }
        let quiet = now.timeIntervalSince(last ?? start)
        guard quiet > after else { return nil }
        return isThem ? "No call audio for \(Format.duration(quiet))" : "Mic quiet for \(Format.duration(quiet))"
    }
}

/// The menu bar panel's faces: the same mouths at 38 pt (the talker 50 pt,
/// glowing) on a white card, and who's talking under it. Redrawn at most 30
/// times a second: the panel is small and this keeps it cheap.
struct MiniStage: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var stage: LiveStage
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var motion = StageMotion()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let live = stage.live
            let me = LiveFace(voice: -1, label: StageFormat.you, seconds: stage.meSeconds, isActive: live.meTalking)
            let faces = stage.faces.map { f in
                var f = f
                if let live = live.faces.first(where: { $0.voice == f.voice }) { f.isActive = live.isActive }
                return f
            }
            let all = Array(frames(me: me, remote: faces, live: live, levels: state.levels,
                                   time: context.date.timeIntervalSinceReferenceDate, motion: motion,
                                   reduceMotion: reduceMotion).prefix(8))
            let size: CGFloat = all.count <= 5 ? 38 : 30
            let talker = all.first { $0.face.isActive && !$0.face.isMe } ?? all.first { $0.face.isActive }
            VStack(spacing: 10) {
                HStack(alignment: .center, spacing: all.count <= 5 ? 12 : 8) {
                    ForEach(all) { frame in
                        let active = frame.face.isActive
                        SpeakerAvatar(look: frame.look, pose: frame.pose,
                                      size: active ? (size * 50 / 38).rounded() : size, isActive: active)
                            .rotationEffect(.radians(frame.sway), anchor: .bottom)
                            .animation(reduceMotion ? nil : .spring(duration: 0.4, bounce: 0.35), value: active)
                            .help(frame.face.label)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 54)
                .paperCard(padding: 16)
                .animation(reduceMotion ? nil : .spring(duration: 0.5, bounce: 0.35), value: stage.faces.map(\.id))
                Text(StageFormat.talking(talker?.face))
                    .font(.system(size: 14))
                    .foregroundStyle(Paper.inkMuted)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
        }
    }
}
