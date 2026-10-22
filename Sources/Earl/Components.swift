import AppKit
import SwiftUI

// MARK: - Theme

/// The older names for Earl's look, kept so every screen keeps compiling.
/// U-1 points them at the paper tokens (`Paper`, in Paper.swift); new code
/// uses `Paper` directly.
enum Theme {
    /// The system accent, for system controls only (toggles, pickers).
    static let accent = Color.accentColor
    static let recording = Paper.live
    static let attention = Paper.error

    static let surface = Paper.card
    static let surfaceStrong = PaperTones.hairline.color.opacity(0.7)
    static let hairline = Paper.hairline

    static let cardRadius: CGFloat = Paper.Radius.card
    static let rowRadius: CGFloat = Paper.Radius.row
}

extension View {
    /// The one grouped-block style used across the app: a white card on paper.
    func surface(padding: CGFloat = 16, radius: CGFloat = Theme.cardRadius) -> some View {
        paperCard(padding: padding, radius: radius)
    }
}

// MARK: - Brand

/// The app icon, for use inside the UI.
struct AppIconView: View {
    var size: CGFloat = 32

    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}

/// Earl's monocle as a template image for the menu bar.
enum MenuBarIcon {
    // Built once: the menu bar label re-renders often, and replacing the status
    // item's image each time is expensive.
    static let idle = make(recording: false)
    static let recording = make(recording: true)
    /// R2-6: a call offer is waiting for an answer.
    static let offer = make(recording: false, badge: true)

    static func image(recording: Bool, offer: Bool = false) -> NSImage {
        recording ? Self.recording : offer ? Self.offer : idle
    }

    private static func make(recording: Bool, badge: Bool = false) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let r = rect.insetBy(dx: 0.5, dy: 0.5)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.addPath(Glyph.rim(in: r))
            ctx.fillPath(using: .evenOdd)
            ctx.addPath(Glyph.chain(in: r))
            ctx.fillPath()
            if recording {
                // Solid lens with the waveform knocked out.
                ctx.addPath(Glyph.lens(in: r))
                ctx.addPath(Glyph.waveform(in: r))
                ctx.fillPath(using: .evenOdd)
            } else {
                ctx.addPath(Glyph.waveform(in: r))
                ctx.fillPath()
            }
            if badge {
                // A dot in the free top right corner, with a gap cut around it
                // so it reads as a badge on the rim.
                let dot = CGRect(x: r.minX + r.width * 0.70, y: r.minY, width: r.width * 0.30, height: r.width * 0.30)
                ctx.setBlendMode(.clear)
                ctx.fillEllipse(in: dot.insetBy(dx: -r.width * 0.07, dy: -r.width * 0.07))
                ctx.setBlendMode(.normal)
                ctx.fillEllipse(in: dot)
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

// MARK: - Status

/// Status as a symbol and a few words. No coloured lamps: green means "fine",
/// error red means "needs you", muted ink means "off/idle".
struct StatusLabel: View {
    enum Kind { case ok, attention, idle }
    var kind: Kind
    var text: String

    var body: some View {
        Label {
            Text(text).foregroundStyle(kind == .attention ? Paper.ink : Paper.inkMuted)
        } icon: {
            Image(systemName: symbol).foregroundStyle(color)
        }
        .labelStyle(.titleAndIcon)
        .font(.system(size: 14))
    }

    private var symbol: String {
        switch kind {
        case .ok: return "checkmark.circle.fill"
        case .attention: return "exclamationmark.circle.fill"
        case .idle: return "moon.circle"
        }
    }

    private var color: Color {
        switch kind {
        case .ok: return Paper.ok
        case .attention: return Paper.error
        case .idle: return Paper.inkMuted
        }
    }
}

/// The recording symbol, gently pulsing.
struct RecordingSymbol: View {
    var font: Font = .body

    var body: some View {
        Image(systemName: "record.circle.fill")
            .font(font)
            .foregroundStyle(Theme.recording)
            .symbolEffect(.pulse, options: .repeating)
    }
}

// MARK: - Meters

/// U-4: four little bars that rise with a track's level, in place of the old
/// level bar: enough to see that sound arrives, quiet enough for a footer.
struct LevelBars: View {
    var level: Float
    var tint: Color

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<4, id: \.self) { i in
                // Each bar lights from its own share of the level.
                let lit = min(1, max(0, (CGFloat(level) - CGFloat(i) * 0.18) / 0.3))
                Capsule()
                    .fill(tint.opacity(0.35 + 0.65 * lit))
                    .frame(width: 3, height: 4 + 9 * lit)
            }
        }
        .frame(height: 13, alignment: .bottom)
        .animation(.easeOut(duration: 0.12), value: level)
        .accessibilityHidden(true)
    }
}

/// The recording footer's capture checks: call audio and mic as quiet words
/// with a small level each, read about ten times a second. A track that stays
/// silent turns into a plain warning in error red.
struct LiveMeters: View {
    @EnvironmentObject private var state: AppState
    /// Seconds the mic may stay quiet before it's worth a warning: listening
    /// for a while is normal, a silent call isn't.
    var micQuietAfter: TimeInterval = 120

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { context in
            let levels = state.levels
            let lastSound = state.lastSound
            HStack(spacing: 18) {
                check("Call audio", level: levels.them,
                      problem: SilenceHint.text(lastSound.them, since: state.recordingStartedAt, now: context.date,
                                                isThem: true))
                check("Mic", level: levels.me,
                      problem: SilenceHint.text(lastSound.me, since: state.recordingStartedAt, now: context.date,
                                                isThem: false, after: micQuietAfter))
                    .help(state.engine.microphoneName ?? "Microphone")
            }
        }
    }

    @ViewBuilder
    private func check(_ label: String, level: Float, problem: String?) -> some View {
        if let problem {
            Label(problem, systemImage: "exclamationmark.circle.fill")
                .foregroundStyle(Paper.error)
                .font(.system(size: 14, weight: .medium))
        } else {
            HStack(spacing: 6) {
                LevelBars(level: level, tint: Paper.ok)
                Text(label).foregroundStyle(Paper.inkMuted)
            }
            .font(.system(size: 14))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(label) is coming through")
        }
    }
}


// MARK: - Building blocks

/// A titled group with the shared surface style.
struct Card<Content: View>: View {
    var title: String?
    var subtitle: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if title != nil || subtitle != nil {
                VStack(alignment: .leading, spacing: 4) {
                    if let title { Text(title).font(.paperTitle).foregroundStyle(Paper.ink) }
                    if let subtitle {
                        Text(subtitle).font(.system(size: 14)).foregroundStyle(Paper.inkMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface()
    }
}

/// A "label: value" line used across detail pages.
struct InfoRow<Trailing: View>: View {
    var label: String
    var value: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .foregroundStyle(Paper.inkMuted)
                .frame(width: 120, alignment: .leading)
            Text(value)
                .foregroundStyle(Paper.ink)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .font(.system(size: 14))
    }
}

extension InfoRow where Trailing == EmptyView {
    init(_ label: String, _ value: String) {
        self.init(label: label, value: value) { EmptyView() }
    }
}

/// A selectable row inside a card list (models, files).
struct ListRow<Content: View>: View {
    var selected = false
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 12) { content }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(selected ? Paper.paperSoft : .clear,
                        in: RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous))
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous).strokeBorder(Paper.hairline)
                }
            }
            .contentShape(Rectangle())
    }
}

/// Radio mark for single-choice lists.
struct RadioMark: View {
    var selected: Bool

    var body: some View {
        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 17))
            .foregroundStyle(selected ? Paper.ink : Paper.inkMuted.opacity(0.7))
    }
}

/// A blinking caret shown at the end of streaming text.
struct StreamingCaret: View {
    @State private var on = true

    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Paper.ink)
            .frame(width: 2, height: 16)
            .opacity(on ? 1 : 0.1)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.55).repeatForever()) { on = false }
            }
    }
}

/// Speaker label for transcripts and meters: the name in the voice's colour on
/// its pale bubble tint; blue for you.
struct SpeakerBadge: View {
    var name: String
    var isMe: Bool
    /// R3-5: the speaker's face, tucked into the capsule's leading end.
    var look: AvatarLook?
    /// R3-3: named by voice memory, shown with a small waveform.
    var byVoice = false

    var body: some View {
        let voice = isMe ? VoicePalette.you : VoicePalette.voice(for: look ?? .voice(0))
        HStack(spacing: 5) {
            if let look { SpeakerAvatar.badge(look, size: 18) }
            Text(name)
                .font(.paperLabel)
                .lineLimit(1)
                .foregroundStyle(isMe ? Paper.youText : voice.text)
            if byVoice { RecognisedMark() }
        }
        .padding(.leading, look == nil ? 9 : 2)
        .padding(.trailing, 9)
        .frame(minWidth: 42, minHeight: 22)
        .background(isMe ? Paper.youFace.opacity(0.18) : voice.bubble, in: Capsule())
    }
}

struct HoverRowStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous)
                    .fill(Paper.ink.opacity(configuration.isPressed ? 0.1 : hovering ? 0.05 : 0)))
            .onHover { hovering = $0 }
    }
}
