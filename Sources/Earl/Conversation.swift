import SwiftUI

// U-2: the conversation beside the front page, as a group chat: a face beside
// each bubble, the name above in the voice's colour, yours blue on the right.
// Click a bubble to hear it; the playing one gets a ring and the list follows.

struct ConversationColumn: View {
    let meeting: Meeting
    let turns: [Turn]
    /// Turns still arriving while the meeting is transcribed.
    let live: Bool
    /// The sidebar search, used when the find field is empty.
    let query: String
    @Binding var findText: String
    @Binding var finding: Bool
    let player: MeetingPlayer
    /// Playback and naming are off while the meeting is processed.
    let enabled: Bool
    var emptyText = "Nothing was said, or it hasn't been transcribed yet."

    @FocusState private var findFocused: Bool
    @State private var currentTurnID: String?

    private var activeQuery: String { findText.isEmpty ? query : findText }
    private var canPlay: Bool { enabled && MeetingPlayer.canPlay(meeting) }

    var body: some View {
        let looks = SpeakerFaces.looks(for: meeting.speakers)
        let query = activeQuery
        let found = query.isEmpty ? [] : turns.filter { PageText.matches($0.text, query: query) }
        VStack(spacing: 0) {
            header(found: found.count)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 13) {
                        ForEach(turns) { turn in
                            ConversationBubble(turn: turn, meeting: meeting, looks: looks, query: query,
                                               isPlaying: turn.id == currentTurnID,
                                               onPlay: canPlay ? { player.play(turn: turn, in: meeting) } : nil,
                                               naming: enabled)
                                .id(turn.id)
                                .transition(.opacity)
                        }
                        if live { listening }
                        if turns.isEmpty && !live {
                            Text(emptyText)
                                .font(.system(size: 14))
                                .foregroundStyle(Paper.inkMuted)
                                .frame(maxWidth: .infinity)
                                .multilineTextAlignment(.center)
                                .padding(.top, 60)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 4)
                    .padding(.bottom, 18)
                    .animation(.easeOut(duration: 0.25), value: turns.count)
                }
                .transcriptPlayback(player, meeting: meeting, active: true, enabled: enabled,
                                    showsBar: !turns.isEmpty && !live)
                .onChange(of: query) { _, _ in
                    if let first = found.first {
                        withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(first.id, anchor: .center) }
                    }
                }
                .onAppear {
                    if let first = found.first { proxy.scrollTo(first.id, anchor: .center) }
                }
            }
        }
        .background(Paper.card)
        .onReceive(MeetingPlayer.currentTurn(of: player)) { currentTurnID = $0 }
    }

    // MARK: Header

    private func header(found: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if finding {
                TextField("Find in the conversation", text: $findText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundStyle(Paper.ink)
                    .focused($findFocused)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Paper.card, in: RoundedRectangle(cornerRadius: Paper.Radius.row, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Paper.Radius.row, style: .continuous).strokeBorder(Paper.hairline))
                    .onExitCommand(perform: closeFind)
                if !findText.isEmpty {
                    Text(found == 1 ? "1 line" : "\(found) lines")
                        .font(.system(size: 13))
                        .foregroundStyle(Paper.inkMuted)
                        .monospacedDigit()
                        .fixedSize()
                }
                Button("Done", action: closeFind)
                    .buttonStyle(.plain)
                    .font(.paperLabel)
                    .foregroundStyle(Paper.inkMuted)
            } else {
                Text("Conversation").font(.paperTitle).foregroundStyle(Paper.ink)
                if !turns.isEmpty {
                    Text(turns.count == 1 ? "1 turn" : "\(turns.count) turns")
                        .font(.system(size: 13))
                        .foregroundStyle(Paper.inkMuted)
                }
                Spacer(minLength: 8)
                Button {
                    finding = true
                } label: {
                    Text("⌘F").font(.system(size: 13)).foregroundStyle(Paper.inkMuted)
                }
                .buttonStyle(.plain)
                .help("Find in the conversation and the notes")
            }
        }
        .background {
            // ⌘F works whether or not the field is showing.
            Button("Find") { finding = true; findFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .frame(minHeight: 50)
        .onChange(of: finding, initial: true) { _, on in if on { findFocused = true } }
    }

    private func closeFind() {
        findText = ""
        finding = false
    }

    private var listening: some View {
        HStack(spacing: 10) {
            TypingDots(color: Paper.inkMuted)
            Text("Listening back…").font(.system(size: 14)).foregroundStyle(Paper.inkMuted)
        }
        .padding(.leading, 37)
        .padding(.top, 4)
    }
}

// MARK: - A bubble

/// One turn: the face beside it, the name above in the voice's text shade
/// (with the time on hover), a pale bubble in the voice's colour. Yours are
/// blue, on the right, without a name. Mirrors U-1's `ChatBubble`, with the
/// meeting page's extras: search marks, the time on hover, playing, naming.
struct ConversationBubble: View {
    let turn: Turn
    let meeting: Meeting
    var looks: [String: AvatarLook]? = nil
    var query = ""
    var isPlaying = false
    var onPlay: (() -> Void)?
    var naming = false

    @State private var hovering = false
    @State private var namingOpen = false

    var body: some View {
        let speakers = meeting.speakers
        let mine = Speaker.isMe(turn, in: speakers)
        let look = SpeakerFaces.look(for: turn, in: speakers, looks: looks)
        let voice = VoicePalette.speakerVoice(for: turn, in: speakers, looks: looks).voice
        HStack(alignment: .bottom, spacing: 9) {
            if mine {
                Spacer(minLength: 34)
                time.padding(.bottom, 9)
            } else {
                face(look)
            }
            VStack(alignment: mine ? .trailing : .leading, spacing: 3) {
                if !mine {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        name(voice)
                        time
                    }
                    .padding(.leading, 4)
                }
                bubble(voice, mine: mine)
            }
            if mine { face(look) } else { Spacer(minLength: 34) }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private func face(_ look: AvatarLook) -> some View {
        SpeakerAvatar(look: look, pose: isPlaying ? AvatarPose(mouth: 0.7) : .rest, size: 28, style: .badge)
    }

    private var time: some View {
        HStack(spacing: 3) {
            if onPlay != nil { Image(systemName: "play.fill").font(.system(size: 13, weight: .bold)).imageScale(.small) }
            Text(Meeting.timestamp(turn.start)).monospacedDigit()
        }
        .font(.system(size: 13))
        .foregroundStyle(Paper.inkMuted)
        .opacity(hovering || isPlaying ? 1 : 0)
        .accessibilityHidden(!hovering)
    }

    @ViewBuilder
    private func name(_ voice: VoiceColors) -> some View {
        let badge = Speaker.badge(for: turn, in: meeting.speakers)
        let label = Text(badge.name).font(.paperLabel).foregroundStyle(voice.text).lineLimit(1)
        if naming, let id = turn.speakerID, meeting.speakers.contains(where: { $0.id == id }) {
            Button { namingOpen = true } label: { label }
                .buttonStyle(.plain)
                .help(badge.help ?? "Name this speaker")
                .popover(isPresented: $namingOpen, arrowEdge: .bottom) {
                    SpeakerNamePopover(meeting: meeting, speakerID: id) { namingOpen = false }
                }
        } else {
            label.help(badge.help ?? "")
        }
    }

    private func bubble(_ voice: VoiceColors, mine: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: Paper.Radius.bubble, style: .continuous)
        var text = AttributedString(turn.text)
        PageText.highlight(&text, query: query)
        return Text(text)
            .font(.paperChat)
            .lineSpacing(3)
            .foregroundStyle(mine ? Paper.onColor : Paper.ink)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .background(mine ? Paper.you : voice.bubble, in: shape)
            .overlay { if isPlaying { shape.strokeBorder(mine ? Paper.youFace : voice.face, lineWidth: 2) } }
            .contentShape(shape)
            .onTapGesture { onPlay?() }
            .help(onPlay == nil ? "" : "Play from \(Meeting.timestamp(turn.start))")
    }
}
