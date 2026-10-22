import SwiftUI

// U-1: every shared piece of the paper design on one page, so the foundation
// can be reviewed at a glance (tools/snapshot-ui.sh renders it as
// "components"). Made-up names only.

struct ComponentSheet: View {
    var next: CalendarCandidate
    var now: Date

    private let people = ["Priya", "Sarah", "Tom", "Guest", "Nina", "Jonas", "Lea", "Marco"]

    var body: some View {
        VStack(alignment: .leading, spacing: Paper.Space.xl) {
            Masthead(text: "Thursday 25 September · Components") {
                LivePill(elapsed: 23 * 60 + 47)
            }
            Text("The Butler's Morning Paper").font(.paperHeadline).foregroundStyle(Paper.ink)

            section("Earl") { earl }
            section("Voices") { voices }
            HStack(alignment: .top, spacing: Paper.Space.xl) {
                section("Conversation") { chat }
                    .frame(width: 430)
                VStack(alignment: .leading, spacing: Paper.Space.xl) {
                    section("Tickets") { tickets }
                    section("Buttons") { buttons }
                }
            }
            HStack(alignment: .top, spacing: Paper.Space.xl) {
                section("Next meeting") { nextMeeting }
                    .frame(width: 290)
                VStack(alignment: .leading, spacing: Paper.Space.xl) {
                    section("Type") { type }
                    section("Cards and rows") { cards }
                }
            }
            section("Paper") { swatches }
        }
        .padding(Paper.Space.pageX)
        .frame(maxWidth: .infinity, alignment: .leading)
        .paperBackground()
    }

    private func section(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Paper.Space.md) {
            Text(title).font(.paperTitle).foregroundStyle(Paper.ink)
            content()
        }
    }

    // MARK: Earl

    private var earl: some View {
        HStack(alignment: .center, spacing: Paper.Space.xl) {
            HStack(alignment: .bottom, spacing: 18) {
                ForEach([24, 32, 40] as [CGFloat], id: \.self) { size in
                    VStack(spacing: 6) {
                        EarlAvatar(size: size)
                        Text("\(Int(size))").font(.paperLabel).foregroundStyle(Paper.inkMuted)
                    }
                }
            }
            // Earl beside the speakers: the only squircle, the only dark face.
            HStack(spacing: 8) {
                EarlAvatar(size: 24)
                ForEach(0..<3, id: \.self) { i in SpeakerAvatar.badge(.voice(i), size: 24) }
                SpeakerAvatar.badge(.me, size: 24)
                Text("next to speakers").font(.system(size: 14)).foregroundStyle(Paper.inkMuted)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Paper.paperSoft, in: RoundedRectangle(cornerRadius: Paper.Radius.card, style: .continuous))
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    EarlAvatar(size: 34)
                    Text(EarlVoice.greeting(name: DemoData.me.name, at: now, daysKnown: 2)).font(.earlVoice(size: 21))
                        .foregroundStyle(Paper.ink)
                }
                HStack(alignment: .top, spacing: 12) {
                    EarlAvatar(size: 34)
                    EarlLine(lead: EarlVoice.inShort,
                             text: "Beta drop-off fell from 31 % to 18 %, so it ships. Sarah will redesign the empty state.",
                             textFont: .paperLede)
                }
                .frame(width: 420, alignment: .leading)
                .paperCard(padding: 14, radius: Paper.Radius.panel)
                HStack(spacing: 10) {
                    EarlAvatar(size: 28)
                    EarlLine(lead: EarlVoice.listening, text: "The words appear after the call.", inline: true)
                }
            }
        }
    }

    // MARK: Voices

    private var voices: some View {
        HStack(alignment: .top, spacing: 16) {
            voiceColumn(look: .me, name: "You", talking: false)
            ForEach(0..<8, id: \.self) { i in
                voiceColumn(look: .voice(i), name: people[i], talking: i == 2)
            }
        }
    }

    private func voiceColumn(look: AvatarLook, name: String, talking: Bool) -> some View {
        let voice = VoicePalette.voice(for: look)
        return VStack(spacing: 8) {
            SpeakerAvatar(look: look, pose: talking ? AvatarPose(mouth: 0.8) : .rest, size: 64, isActive: talking)
            HStack(spacing: 4) {
                SpeakerAvatar.badge(look, size: 24, unconfirmed: name == "Sarah")
                SpeakerAvatar.badge(look, size: 18)
            }
            if name == "Guest" {
                SpeakerTag(name: "Speaker 4")
            } else {
                Text(name + (name == "Sarah" ? "?" : "")).font(.paperLabel).foregroundStyle(look.isMe ? Paper.youText : voice.text)
            }
            Text(look.isMe ? "Hi" : "Hello")
                .font(.paperChat)
                .foregroundStyle(look.isMe ? Paper.onColor : Paper.ink)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(look.isMe ? Paper.you : voice.bubble,
                            in: RoundedRectangle(cornerRadius: Paper.Radius.bubble, style: .continuous))
        }
        .frame(width: 92)
    }

    // MARK: Chat

    private var chat: some View {
        VStack(alignment: .leading, spacing: 13) {
            ChatBubble(voice: VoicePalette.voice(0), name: "Priya", text: "Do we ship the new onboarding with October?",
                       face: .voice(0))
            ChatBubble(voice: VoicePalette.you, text: "Beta numbers are in the doc. Permissions got a lot better.",
                       mine: true, face: .me)
            ChatBubble(voice: VoicePalette.voice(1), name: "Sarah?",
                       text: "Three of five testers thought the empty state was an error.", isPlaying: true, face: .voice(1))
            ChatBubble(voice: VoicePalette.voice(2), name: "Tom", text: "Copy problem or design problem?", face: .voice(2))
            ChatBubble(voice: VoicePalette.voice(0), name: "Speaker 1", content: .dots(6), face: .voice(0))
            ChatBubble(voice: VoicePalette.you, content: .dots(3), mine: true, face: .me)
            ChatBubble(voice: VoicePalette.voice(2), content: .typing, face: .voice(2), talking: true)
        }
        .padding(18)
        .background(Paper.paperSoft, in: RoundedRectangle(cornerRadius: Paper.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Paper.Radius.card, style: .continuous).strokeBorder(Paper.hairline))
    }

    // MARK: Tickets and buttons

    private var tickets: some View {
        VStack(alignment: .leading, spacing: 8) {
            Ticket(mine: true) {
                TicketBox()
                Text("Book a usability session with two beta customers")
            }
            Ticket(mine: false) {
                SpeakerAvatar.badge(.voice(1), size: 20)
                Text("Sarah · Redesign the empty state")
            }
            Ticket(mine: false) {
                SpeakerAvatar.badge(.voice(2), size: 20)
                Text("Tom · Confirm translation timing")
            }
        }
        .frame(width: 360)
    }

    private var buttons: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Button("Yes") {}.buttonStyle(.paperPrimary)
                Button("Not now") {}.buttonStyle(.paperSecondary)
                Button("Try again") {}.buttonStyle(.paperPrimary).disabled(true)
            }
            HStack(spacing: 10) {
                Button {} label: {
                    HStack {
                        Text("Record")
                        Spacer()
                        Text("⌃⌥⌘R").font(.system(size: 13)).opacity(0.75)
                    }
                }
                .buttonStyle(.paperRecord)
                .frame(width: 240)
                Button("Stop") {}.buttonStyle(.paperStop).frame(width: 140)
            }
        }
    }

    // MARK: Next meeting

    private var nextMeeting: some View {
        VStack(alignment: .leading, spacing: 4) {
            NextMeetingCardView(content: .event(next), now: now)
            NextMeetingCardView(content: .event(next), now: now, isArmed: { _ in true })
            NextMeetingCardView(content: .event(next), now: next.start.addingTimeInterval(5 * 60))
            NextMeetingCardView(content: .empty, now: now)
        }
        .padding(.vertical, 8)
        .background(Paper.sidebar, in: RoundedRectangle(cornerRadius: Paper.Radius.card, style: .continuous))
    }

    // MARK: Type and cards

    private var type: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Onboarding ships on October 6").font(.paperHeadline(size: 26)).foregroundStyle(Paper.ink)
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text("Decided").font(.paperTitle).foregroundStyle(Paper.ink)
                Text("Ship to 20 % of new users")
                    .font(.paperBody).foregroundStyle(Paper.ink)
                    .background(alignment: .bottom) { Paper.marker.frame(height: 9) }
                Text("Still open").font(.paperLabel).foregroundStyle(Paper.inkMuted)
                Text("Needs you").font(.paperLabel).foregroundStyle(Paper.error)
            }
            Text("Lede 16 · Body 15 · Chat 14.5 · Label 13, the floor.").font(.paperLede).foregroundStyle(Paper.ink)
        }
    }

    private var cards: some View {
        HStack(alignment: .top, spacing: 16) {
            Card(title: "Card", subtitle: "White on paper, a tan hairline, 12 pt corners.") {
                VStack(alignment: .leading, spacing: 8) {
                    InfoRow("Model", "Large v3 Turbo")
                    StatusLabel(kind: .ok, text: "Ready")
                    StatusLabel(kind: .attention, text: "LM Studio isn't running")
                    StatusLabel(kind: .idle, text: "Off")
                }
            }
            .frame(width: 330)
            VStack(alignment: .leading, spacing: 4) {
                ListRow(selected: true) { RadioMark(selected: true); Text("Large v3 Turbo").font(.paperBody) }
                ListRow { RadioMark(selected: false); Text("Small").font(.paperBody) }
                HStack(spacing: 6) {
                    SpeakerBadge(name: "You", isMe: true, look: .me)
                    SpeakerBadge(name: "Priya", isMe: false, look: .voice(0))
                    SpeakerBadge(name: "Tom", isMe: false, look: .voice(2), byVoice: true)
                }
                .padding(.top, 6)
            }
            .frame(width: 290, alignment: .leading)
            .paperCard()
        }
    }

    private var swatches: some View {
        let tokens: [(String, Color)] = [
            ("paper", Paper.paper), ("paperSoft", Paper.paperSoft), ("sidebar", Paper.sidebar), ("card", Paper.card),
            ("hairline", Paper.hairline), ("ink", Paper.ink), ("inkMuted", Paper.inkMuted), ("masthead", Paper.masthead),
            ("live", Paper.live), ("stop", Paper.stop), ("error", Paper.error), ("marker", Paper.marker),
            ("you", Paper.you), ("youFace", Paper.youFace), ("ok", Paper.ok), ("monocleGold", Paper.monocleGold),
        ]
        return LazyVGrid(columns: Array(repeating: GridItem(.fixed(118), spacing: 12, alignment: .leading), count: 8),
                         alignment: .leading, spacing: 12) {
            ForEach(tokens, id: \.0) { name, color in
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(color)
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Paper.hairline))
                        .frame(width: 26, height: 26)
                    Text(name).font(.system(size: 13)).foregroundStyle(Paper.inkMuted)
                }
            }
        }
    }
}
