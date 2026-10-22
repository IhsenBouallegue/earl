import AppKit
import SwiftUI

// U-1: "The Butler's Morning Paper", the shared foundation of the redesign.
// Tokens, type and the small pieces every screen uses. The system itself is in
// /DESIGN.md; the names here are a contract with the screen features (U-2…U-5).

// MARK: - Colours

/// A colour with a light and a dark value, as 0xRRGGBB. Kept as numbers so the
/// contrast tests can check the exact values the app draws.
struct Tone: Hashable, Sendable {
    let light: UInt32
    let dark: UInt32

    init(_ light: UInt32, dark: UInt32) {
        self.light = light
        self.dark = dark
    }

    /// Follows the appearance of whatever draws it, like the system colours.
    var nsColor: NSColor {
        let light = light, dark = dark
        return NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return Self.srgb(isDark ? dark : light)
        }
    }

    var color: Color { Color(nsColor: nsColor) }

    static func srgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }
}

/// The raw values of the paper tokens (DESIGN.md `colors.*`, dark from `night-*`).
/// Where DESIGN.md has no night value, or its value missed 4.5:1, the comment
/// says what was picked and why. PaperContrastTests checks every text pair.
enum PaperTones {
    static let paper = Tone(0xfbf8f2, dark: 0x1d1813)
    static let paperSoft = Tone(0xf6f0e4, dark: 0x221c16)
    static let sidebar = Tone(0xefe6d3, dark: 0x161210)
    static let card = Tone(0xffffff, dark: 0x2a231c)
    static let hairline = Tone(0xe2d6bd, dark: 0x3a3128)
    /// The sidebar's selected row. White on linen; at night the card tone sat
    /// too close to the sidebar to find, so it takes the hairline's lighter brown.
    static let selection = Tone(0xffffff, dark: 0x3a3128)
    static let ink = Tone(0x2b2118, dark: 0xf3eadb)
    static let inkMuted = Tone(0x65573f, dark: 0xc7b79b)
    static let masthead = Tone(0xb93d0c, dark: 0xff8f5e)
    /// The LIVE pill carries white text in both appearances, so it keeps the
    /// light red in dark too (a brighter red would drop white below 4.5:1).
    static let live = Tone(0xb93d0c, dark: 0xb93d0c)
    /// Only the dot or square on Stop/Record, never text.
    static let stop = Tone(0xe0501c, dark: 0xe0501c)
    /// Dark: #ff8a7a, from the round 2 dark mockups.
    static let error = Tone(0xb42318, dark: 0xff8a7a)
    /// Dark: #7a5c0e instead of night-marker #8a6a12, which left cream ink at 4.2:1.
    static let marker = Tone(0xffd66b, dark: 0x7a5c0e)
    /// Dark: #2a6fcc instead of night-you-blue #2f7de1, which left white text at 4.1:1.
    static let you = Tone(0x0b5cc2, dark: 0x2a6fcc)
    static let youFace = Tone(0x60a5fa, dark: 0x60a5fa)
    /// "You" as text on paper (the blue fill is too dark for text in dark mode).
    static let youText = Tone(0x0b5cc2, dark: 0x7fb0f5)
    /// Light: #1b6e34 instead of ok-green #1f7a3a, which was 4.3:1 on linen.
    /// Dark: #5ad37f, from the round 2 dark mockups.
    static let ok = Tone(0x1b6e34, dark: 0x5ad37f)
    /// Dark: the deeper gold from Earl's dark avatar, which sits on cream.
    static let monocleGold = Tone(0xe0a93a, dark: 0xb8862b)
    static let earlCream = Tone(0xf7eedd, dark: 0xf7eedd)
    /// The dashed border of your own tickets (a darker tan than the hairline).
    static let ticketDash = Tone(0xd3c29f, dark: 0x5a4a38)
    /// Text on red and blue fills.
    static let onColor = Tone(0xffffff, dark: 0xffffff)
}

/// Earl's colours, each following light and dark.
enum Paper {
    static let paper = PaperTones.paper.color
    static let paperSoft = PaperTones.paperSoft.color
    static let sidebar = PaperTones.sidebar.color
    static let card = PaperTones.card.color
    static let hairline = PaperTones.hairline.color
    static let selection = PaperTones.selection.color
    static let ink = PaperTones.ink.color
    static let inkMuted = PaperTones.inkMuted.color
    static let masthead = PaperTones.masthead.color
    static let live = PaperTones.live.color
    static let stop = PaperTones.stop.color
    static let error = PaperTones.error.color
    static let marker = PaperTones.marker.color
    static let you = PaperTones.you.color
    static let youFace = PaperTones.youFace.color
    static let youText = PaperTones.youText.color
    static let ok = PaperTones.ok.color
    static let monocleGold = PaperTones.monocleGold.color
    static let earlCream = PaperTones.earlCream.color
    static let ticketDash = PaperTones.ticketDash.color
    static let onColor = PaperTones.onColor.color

    /// DESIGN.md `rounded.*`.
    enum Radius {
        static let row: CGFloat = 8
        static let button: CGFloat = 9
        static let card: CGFloat = 12
        static let panel: CGFloat = 16
        static let bubble: CGFloat = 16
    }

    /// DESIGN.md `spacing.*`.
    enum Space {
        static let xs: CGFloat = 6
        static let sm: CGFloat = 10
        static let md: CGFloat = 14
        static let lg: CGFloat = 22
        static let xl: CGFloat = 30
        static let pageX: CGFloat = 34
    }
}

// MARK: - Type

extension Font {
    /// The meeting headline: Georgia bold 34 (26 as the recording title).
    static var paperHeadline: Font { paperHeadline(size: 34) }
    static func paperHeadline(size: CGFloat) -> Font { serif(size: size) }
    /// Section titles: Georgia bold 17 (16–18 in cards).
    static var paperTitle: Font { paperTitle(size: 17) }
    static func paperTitle(size: CGFloat) -> Font { serif(size: size) }
    /// Earl's "In short —" briefing.
    static let paperLede = Font.system(size: 16)
    /// Everything you read.
    static let paperBody = Font.system(size: 15)
    /// Chat bubbles and sidebar rows.
    static let paperChat = Font.system(size: 14.5)
    /// Names, times, counts, footers. The 13 pt floor.
    static let paperLabel = Font.system(size: 13, weight: .semibold)
    /// The date line. Use with `.textCase(.uppercase)` and `.tracking(PaperType.mastheadTracking)`.
    static let paperMasthead = Font.system(size: 13)
    /// Earl's handwriting, for his first few words only.
    static var earlVoice: Font { earlVoice(size: 19) }
    static func earlVoice(size: CGFloat) -> Font {
        PaperType.hasBradleyHand ? .custom(PaperType.bradleyHand, size: size) : .system(size: size, weight: .semibold)
    }

    private static func serif(size: CGFloat) -> Font {
        PaperType.hasGeorgia ? .custom(PaperType.georgiaBold, size: size) : .system(size: size, weight: .bold, design: .serif)
    }
}

enum PaperType {
    /// Both ship with macOS; the fallbacks are there for a stripped-down system.
    static let georgiaBold = "Georgia-Bold"
    static let bradleyHand = "BradleyHandITCTT-Bold"
    static let hasGeorgia = NSFont(name: georgiaBold, size: 13) != nil
    static let hasBradleyHand = NSFont(name: bradleyHand, size: 13) != nil
    /// 0.08 em at 13 pt.
    static let mastheadTracking: CGFloat = 1.04
    /// The smallest text size anywhere in the app.
    static let floor: CGFloat = 13
}

// MARK: - Backgrounds

enum PaperSurface {
    case paper, soft, sidebar

    var color: Color {
        switch self {
        case .paper: Paper.paper
        case .soft: Paper.paperSoft
        case .sidebar: Paper.sidebar
        }
    }
}

extension View {
    /// Warm paper behind a whole page or column.
    func paperBackground(_ surface: PaperSurface = .paper) -> some View {
        background(surface.color.ignoresSafeArea())
    }

    /// A white card on paper with a tan hairline.
    func paperCard(padding: CGFloat = Paper.Space.md, radius: CGFloat = Paper.Radius.card) -> some View {
        self
            .padding(padding)
            .background(Paper.card, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Paper.hairline))
    }
}

// MARK: - Buttons

/// Record, Stop, Yes, Try again: ink fill, paper text.
struct PaperPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PaperButtonBody(configuration: configuration, fill: Paper.ink, text: Paper.paper, stroke: nil,
                        radius: Paper.Radius.button)
    }
}

/// Not now, Keep going, Someone else: a white card with a hairline.
struct PaperSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PaperButtonBody(configuration: configuration, fill: Paper.card, text: Paper.ink, stroke: Paper.hairline,
                        radius: Paper.Radius.button)
    }
}

/// The big Record / Stop: ink fill, a red dot (Record) or square (Stop) before
/// the label. Stretches to the width it's given.
struct PaperRecordButtonStyle: ButtonStyle {
    var isStop = false
    /// Small in the masthead, so the masthead keeps its height.
    @Environment(\.controlSize) private var controlSize

    func makeBody(configuration: Configuration) -> some View {
        let small = controlSize == .small
        PaperButtonBody(configuration: configuration, fill: Paper.ink, text: Paper.paper, stroke: nil,
                        radius: small ? Paper.Radius.button : Paper.Radius.card, vertical: small ? 6 : 11,
                        font: .system(size: small ? 14 : 15, weight: .bold), mark: isStop ? .square : .dot)
    }
}

extension ButtonStyle where Self == PaperPrimaryButtonStyle {
    static var paperPrimary: PaperPrimaryButtonStyle { .init() }
}

extension ButtonStyle where Self == PaperSecondaryButtonStyle {
    static var paperSecondary: PaperSecondaryButtonStyle { .init() }
}

extension ButtonStyle where Self == PaperRecordButtonStyle {
    static var paperRecord: PaperRecordButtonStyle { .init() }
    /// The same button while recording: a square before "Stop".
    static var paperStop: PaperRecordButtonStyle { .init(isStop: true) }
}

private struct PaperButtonBody: View {
    enum Mark { case dot, square }

    let configuration: ButtonStyleConfiguration
    let fill: Color
    let text: Color
    let stroke: Color?
    let radius: CGFloat
    var vertical: CGFloat = 6
    var font: Font = .system(size: 14, weight: .semibold)
    var mark: Mark?

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        HStack(spacing: 10) {
            switch mark {
            case .dot: Circle().fill(Paper.stop).frame(width: 11, height: 11)
            case .square: RoundedRectangle(cornerRadius: 2).fill(Paper.stop).frame(width: 11, height: 11)
            case nil: EmptyView()
            }
            configuration.label
                .frame(maxWidth: mark == nil ? nil : .infinity, alignment: .leading)
        }
        .font(font)
        .foregroundStyle(text)
        .padding(.horizontal, 14)
        .padding(.vertical, vertical)
        .background(fill, in: shape)
        .overlay { if let stroke { shape.strokeBorder(stroke) } }
        .contentShape(shape)
        .opacity(isEnabled ? (configuration.isPressed ? 0.78 : 1) : 0.45)
    }
}

// MARK: - Small pieces

/// The red LIVE pill, with the elapsed time.
struct LivePill: View {
    /// Seconds recorded so far; nil shows just "LIVE".
    var elapsed: TimeInterval?

    @State private var dim = false

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(.white).frame(width: 8, height: 8).opacity(dim ? 0.3 : 1)
            Text(label)
                .font(.system(size: 13, weight: .heavy).monospacedDigit())
                .tracking(0.65)
        }
        .foregroundStyle(Paper.onColor)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Paper.live, in: Capsule())
        .onAppear {
            withAnimation(.easeInOut(duration: 0.7).repeatForever()) { dim = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(elapsed.map { "Recording, \(Format.duration($0))" } ?? "Recording")
    }

    private var label: String {
        guard let elapsed else { return "LIVE" }
        return "LIVE \(Self.clock(elapsed))"
    }

    /// "23:47", "1:02:05".
    static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// The line over every page: small letter-spaced capitals, actions on the
/// right, a 3 pt double rule under it, edge to edge. One height and one inset
/// on every page, so the top of the window never moves between clicks.
struct Masthead<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing
    @Environment(\.mastheadRecord) private var showsRecord

    static var height: CGFloat { 20 }
    /// With Record at its end: the same height on every page, whether or not
    /// Record is showing, level with the window's buttons.
    static var recordHeight: CGFloat { 32 }
    static var inset: CGFloat { 26 }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                leading
                    .font(.paperMasthead)
                    .tracking(PaperType.mastheadTracking)
                    .textCase(.uppercase)
                    .foregroundStyle(Paper.inkMuted)
                    .lineLimit(1)
                Spacer(minLength: 0)
                trailing
                if showsRecord { RecordControl() }
            }
            .frame(minHeight: showsRecord ? Self.recordHeight : Self.height)
            .padding(.horizontal, Self.inset)
            .padding(.top, 10)
            .padding(.bottom, 8)
            DoubleRule()
        }
    }
}

private struct MastheadRecordKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// The main window's pages end their masthead with Record.
    var mastheadRecord: Bool {
        get { self[MastheadRecordKey.self] }
        set { self[MastheadRecordKey.self] = newValue }
    }
}

extension Masthead where Leading == Text {
    init(text: String, @ViewBuilder trailing: () -> Trailing) {
        self.init(leading: { Text(text) }, trailing: trailing)
    }
}

extension Masthead where Leading == Text, Trailing == EmptyView {
    init(_ text: String) {
        self.init(text: text) { EmptyView() }
    }
}

/// Every page's top: where the headline starts under the masthead, and how far
/// in from the edge. Meetings, series, to-dos, Ask and Settings all use it.
enum PageGrid {
    static let top: CGFloat = 22
    static let bottom: CGFloat = 34
    /// Headline to its one-line subline.
    static let subline: CGFloat = 6
    static let sublineFont = Font.system(size: 15)
}

/// Two 1 pt ink lines 1 pt apart: the masthead rule.
struct DoubleRule: View {
    var body: some View {
        VStack(spacing: 1) {
            Rectangle().fill(Paper.ink).frame(height: 1)
            Rectangle().fill(Paper.ink).frame(height: 1)
        }
        .frame(height: 3)
    }
}

/// A to-do "ticket". Yours: white with a dashed tan border; everyone else's:
/// a plain line, no border. The checkbox, face and hover actions are
/// the screen's job.
struct Ticket<Content: View>: View {
    var mine: Bool
    @ViewBuilder var content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Paper.Radius.card, style: .continuous)
        HStack(spacing: 10) { content }
            .font(.paperBody)
            .foregroundStyle(Paper.ink)
            // A plain line sits flush with its heading; a ticket brings its own inset.
            .padding(.horizontal, mine ? 12 : 0)
            .padding(.vertical, mine ? 9 : 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(mine ? Paper.card : Color.clear, in: shape)
            .overlay {
                // Only yours are tickets; everyone else's are plain lines, so
                // a page of to-dos isn't a page of boxes.
                if mine {
                    shape.strokeBorder(Paper.ticketDash, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                }
            }
    }
}

/// The empty box on a ticket.
struct TicketBox: View {
    var checked = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .strokeBorder(Paper.inkMuted, lineWidth: 2)
            .background(checked ? Paper.ink : .clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay {
                if checked {
                    // The tick is stamped in; unticking just lets it go.
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Paper.paper)
                        .transition(reduceMotion ? .opacity
                                    : .asymmetric(insertion: .scale(scale: 0.3).combined(with: .opacity), removal: .opacity))
                }
            }
            .frame(width: 18, height: 18)
            .keyframeAnimator(initialValue: 1.0, trigger: reduceMotion ? false : checked) { box, scale in
                box.scaleEffect(scale)
            } keyframes: { _ in
                KeyframeTrack {
                    CubicKeyframe(0.86, duration: 0.08)
                    SpringKeyframe(1, duration: 0.3, spring: .snappy)
                }
            }
            .animation(.spring(duration: 0.22, bounce: 0.15), value: checked)
    }
}

/// Earl's lead-in in handwriting, then the rest in the system font. The Two
/// Fonts Per Line rule: handwriting only for the lead-in.
struct EarlLine: View {
    var lead: String
    var text: String?
    /// Inline puts the text right after the lead-in, on the same line
    /// ("Listening. The words appear after the call.").
    var inline = false
    var leadSize: CGFloat = 19
    var textFont: Font = .paperBody

    var body: some View {
        if inline, let text {
            Text("\(Text(lead).font(.earlVoice(size: leadSize))) \(Text(text).font(textFont))")
                .foregroundStyle(Paper.ink)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text(lead).font(.earlVoice(size: leadSize))
                if let text {
                    Text(text).font(textFont).fixedSize(horizontal: false, vertical: true)
                }
            }
            .foregroundStyle(Paper.ink)
        }
    }
}

// MARK: - Chat

/// One turn of the conversation as a chat bubble: the name above in the voice's
/// text shade, a pale bubble in the voice's colour, the face beside it. Yours
/// are blue, on the right, without a name. While recording, a bubble holds
/// dots that grow with the turn, or animated typing dots for whoever is talking.
struct ChatBubble: View {
    enum Content: Equatable {
        case text(String)
        /// Still recording: one dot per few seconds of speech.
        case dots(Int)
        /// The current speaker: animated typing dots.
        case typing
    }

    var voice: VoiceColors
    var name: String?
    var content: Content
    var mine = false
    /// The line being played: a 2 pt ring in the voice's colour.
    var isPlaying = false
    /// The face beside the bubble; nil leaves the space out.
    var face: AvatarLook?
    var faceSize: CGFloat = 28
    /// Shows the face with its mouth open.
    var talking = false

    init(voice: VoiceColors, name: String? = nil, content: Content, mine: Bool = false, isPlaying: Bool = false,
         face: AvatarLook? = nil, faceSize: CGFloat = 28, talking: Bool = false) {
        self.voice = voice
        self.name = name
        self.content = content
        self.mine = mine
        self.isPlaying = isPlaying
        self.face = face
        self.faceSize = faceSize
        self.talking = talking
    }

    init(voice: VoiceColors, name: String? = nil, text: String, mine: Bool = false, isPlaying: Bool = false,
         face: AvatarLook? = nil) {
        self.init(voice: voice, name: name, content: .text(text), mine: mine, isPlaying: isPlaying, face: face)
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 9) {
            if mine { Spacer(minLength: 40) }
            if !mine { faceView }
            VStack(alignment: mine ? .trailing : .leading, spacing: 3) {
                if let name, !mine {
                    Text(name).font(.paperLabel).foregroundStyle(voice.text).padding(.leading, 4)
                }
                bubble
            }
            if mine { faceView }
            if !mine { Spacer(minLength: 40) }
        }
    }

    @ViewBuilder private var faceView: some View {
        if let face {
            SpeakerAvatar(look: face, pose: talking ? AvatarPose(mouth: 0.7) : .rest, size: faceSize,
                          style: faceSize < 30 ? .badge : .stage)
        }
    }

    private var bubble: some View {
        let shape = RoundedRectangle(cornerRadius: Paper.Radius.bubble, style: .continuous)
        return Group {
            switch content {
            case .text(let text):
                Text(text)
                    .font(.paperChat)
                    .lineSpacing(3)
                    .foregroundStyle(mine ? Paper.onColor : Paper.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            case .dots(let n):
                HStack(spacing: 7) {
                    ForEach(0..<max(1, n), id: \.self) { _ in
                        Circle().frame(width: 4, height: 4)
                    }
                }
                .foregroundStyle(mine ? Paper.onColor : voice.text)
                .frame(minHeight: 20)
            case .typing:
                TypingDots(color: mine ? Paper.onColor : voice.text).frame(minHeight: 20)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .background(mine ? Paper.you : voice.bubble, in: shape)
        .overlay { if isPlaying { shape.strokeBorder(voice.face, lineWidth: 2) } }
    }
}

/// Three dots that light up in turn.
struct TypingDots: View {
    var color: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.1)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { i in
                    let phase = (t / 1.2 + Double(i) * 0.2).truncatingRemainder(dividingBy: 1)
                    Circle().fill(color).frame(width: 8, height: 8)
                        .opacity(phase < 0.4 ? 0.35 + phase / 0.4 * 0.65 : 1 - (phase - 0.4) / 0.6 * 0.65)
                }
            }
        }
        .accessibilityLabel("Talking")
    }
}
