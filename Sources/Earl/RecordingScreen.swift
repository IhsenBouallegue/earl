import SwiftUI

// U-4: the recording screen. Top to bottom: a masthead with LIVE, the title and
// Stop; the stage of faces; a soft band where the turns build up as bubbles of
// dots (live shows who talks, never what is said); a linen footer with Earl
// and the capture checks. Two loud things: the talking face and Stop.

struct RecordingView: View {
    @EnvironmentObject private var state: AppState
    let meeting: Meeting

    var body: some View {
        VStack(spacing: 0) {
            masthead
            SpeakerStage(stage: state.liveStage, meeting: meeting) // R2-5
                .padding(.horizontal, Paper.Space.pageX)
                .padding(.vertical, Paper.Space.md)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            LiveChatBand(stage: state.liveStage)
                .frame(height: 290)
            RecordingFooter(meeting: meeting, elapsed: elapsed)
        }
        .paperBackground()
        // The masthead carries the title; keep the toolbar clear.
        .navigationTitle("")
    }

    private var elapsed: TimeInterval {
        state.recordingStartedAt.map { max(0, state.now.timeIntervalSince($0)) } ?? 0
    }

    /// The calendar's title while the meeting still has its default one.
    private var title: String {
        let info = meeting.info
        return info.titleIsDefault ? (info.calendarTitle ?? info.title) : info.title
    }

    private var masthead: some View {
        VStack(spacing: 0) {
            HStack(spacing: Paper.Space.md) {
                LivePill(elapsed: elapsed)
                Text(title)
                    .font(.paperHeadline(size: 26))
                    .foregroundStyle(Paper.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help([meeting.info.callLabel, meeting.info.attendeeLine].compactMap { $0 }.joined(separator: " · ")) // R1-2, R2-1
                Spacer(minLength: Paper.Space.md)
                Button("Stop") { state.stopRecording() }
                    .buttonStyle(.paperStop)
                    .fixedSize()
                    .help("Stop and take notes")
            }
            .padding(.horizontal, 26)
            .padding(.top, 14)
            .padding(.bottom, 12)
            DoubleRule()
        }
    }

    static func tilde(_ url: URL) -> String {
        if let home = Sandbox.home { return url.path.replacingOccurrences(of: home.path, with: "~") } // U-0
        return url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}

// MARK: - Chat band

/// The turns so far as bubbles, newest at the bottom; older ones slide up and
/// fade out under the stage. Redraws when `LiveStage` publishes (about once a
/// second while someone talks).
struct LiveChatBand: View {
    @ObservedObject var stage: LiveStage
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// About what fits in the band; older turns are dropped, not scrolled.
    private static let visible = 4

    var body: some View {
        let turns = Array(stage.turns.suffix(Self.visible))
        ZStack {
            if turns.isEmpty {
                Text("Turns appear here as people talk.")
                    .font(.system(size: 14))
                    .foregroundStyle(Paper.inkMuted)
            } else {
                VStack(spacing: 13) {
                    ForEach(turns) { turn in
                        LiveTurnRow(turn: turn, name: name(for: turn),
                                    talking: stage.turnOpen && turn.id == stage.turns.last?.id)
                            .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .frame(maxWidth: 640)
                .padding(.horizontal, Paper.Space.pageX)
                .padding(.top, 18)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .animation(reduceMotion ? nil : .spring(duration: 0.45, bounce: 0.2), value: turns.map(\.id))
                .mask {
                    // The oldest bubble fades out at the top instead of being cut.
                    LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.07)],
                                   startPoint: .top, endPoint: .bottom)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .background(Paper.paperSoft)
        .overlay(alignment: .top) { Rectangle().fill(Paper.hairline).frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Turns so far")
    }

    private func name(for turn: LiveTurn) -> String {
        if turn.isMe { return StageFormat.you }
        return stage.faces.first { $0.voice == turn.voice }?.label ?? "Speaker \(turn.voice + 1)"
    }
}

/// One turn: the face, a bubble in the voice's colour holding a dot per few
/// seconds (or typing dots while the turn goes on), and the length on hover.
struct LiveTurnRow: View {
    var turn: LiveTurn
    var name: String
    var talking: Bool

    @State private var hovering = false

    private var voice: VoiceColors { turn.isMe ? VoicePalette.you : VoicePalette.voice(turn.voice) }
    private var look: AvatarLook { turn.isMe ? .me : .voice(turn.voice) }

    var body: some View {
        // Laid out like `ChatBubble`: the name above in the voice's text shade
        // (none on yours), the face at the bubble's foot.
        HStack(alignment: .bottom, spacing: 9) {
            if turn.isMe {
                Spacer(minLength: 40)
                HStack(spacing: 10) { caption; bubble }
                face
            } else {
                face
                VStack(alignment: .leading, spacing: 3) {
                    Text(name).font(.paperLabel).foregroundStyle(voice.text).lineLimit(1).padding(.leading, 4)
                    HStack(spacing: 10) { bubble; caption }
                }
                Spacer(minLength: 40)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(talking ? StageFormat.talking(LiveFace(voice: turn.voice, label: name, seconds: turn.seconds,
                                                                     isActive: true))
                                    : "\(name), \(StageFormat.talk(turn.seconds))")
    }

    private var face: some View {
        SpeakerAvatar(look: look, pose: talking ? AvatarPose(mouth: 0.7) : .rest, size: 28, style: .badge)
    }

    private var bubble: some View {
        let shape = RoundedRectangle(cornerRadius: Paper.Radius.bubble, style: .continuous)
        let ink = turn.isMe ? Paper.onColor : voice.text
        return Group {
            if talking {
                TypingDots(color: ink)
            } else {
                HStack(spacing: 7) {
                    ForEach(0..<LiveTurn.dots(for: turn.seconds), id: \.self) { _ in
                        Circle().fill(ink).frame(width: 5, height: 5)
                    }
                }
            }
        }
        .frame(minHeight: 20)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(turn.isMe ? Paper.you : voice.bubble, in: shape)
        .animation(.spring(duration: 0.4, bounce: 0.3), value: LiveTurn.dots(for: turn.seconds))
    }

    /// "talking" for the current turn (the name is above); the length only on hover.
    private var caption: some View {
        Text(talking ? (turn.isMe ? "You're talking" : "talking") : StageFormat.talk(turn.seconds))
            .font(.system(size: 13).monospacedDigit())
            .foregroundStyle(Paper.inkMuted)
            .opacity(talking || hovering ? 1 : 0)
            .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

// MARK: - Footer

/// Earl, a short line, and the capture checks, on linen.
struct RecordingFooter: View {
    let meeting: Meeting
    var elapsed: TimeInterval

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var penTilt = false

    var body: some View {
        let line = EarlVoice.whileRecording(elapsed: elapsed)
        HStack(spacing: 12) {
            EarlAvatar(size: 28)
            Image(systemName: "pencil")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Paper.inkMuted)
                .rotationEffect(.degrees(penTilt ? 10 : -10), anchor: .bottomLeading)
                .accessibilityHidden(true)
            EarlLine(lead: line.lead, text: line.text, inline: true, leadSize: 18, textFont: .system(size: 14))
                .lineLimit(1)
                .id(line.lead)
                .transition(.opacity)
                .help("Audio is saved to \(RecordingView.tilde(meeting.folder.deletingLastPathComponent())).")
            Spacer(minLength: 16)
            HStack(spacing: 18) {
                LiveMeters()
                if meeting.info.usedSpeakers == true { // R2-4
                    Label("Echo cleanup", systemImage: "checkmark")
                        .font(.system(size: 14))
                        .foregroundStyle(Paper.inkMuted)
                        .help(EchoHint.text(usedSpeakers: true))
                }
            }
            .fixedSize()
        }
        .animation(.easeInOut(duration: 0.6), value: line.lead)
        .padding(.horizontal, 26)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(Paper.sidebar)
        .overlay(alignment: .top) { Rectangle().fill(Paper.hairline).frame(height: 1) }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { penTilt = true }
        }
    }
}

extension EarlVoice {
    /// U-4: what Earl says in the recording footer. The line changes every few
    /// minutes, so it stays alive without ever asking to be read.
    static let recordingLines: [(lead: String, text: String)] = [
        (listening, "The words appear after the call."),
        ("Noted.", "Notes follow when you stop."),
        ("Still here.", "Nothing leaves this Mac."),
        ("All ears.", "Who talks shows above; what they said comes after."),
    ]

    static func whileRecording(elapsed: TimeInterval) -> (lead: String, text: String) {
        recordingLines[Int(max(0, elapsed) / 240) % recordingLines.count]
    }
}
