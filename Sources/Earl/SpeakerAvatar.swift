import SwiftUI

// R2-5: the faces on the live stage, the badges (R3-5) and the menu bar. Kept
// in one file so the look is easy to iterate on. Everything is drawn in a unit
// square (0...1) and scaled.
//
// U-1 style rules: people are round pastel faces with a thin ink outline,
// eyes, a smile and blush, in their voice colour (VoicePalette); you are the
// blue face. Earl is the only squircle (EarlAvatar). Colour and the name tell
// voices apart; from the ninth voice on colours repeat, so those faces also
// wear an accessory.

/// What a face looks like. Deterministic from the voice number, so a voice
/// keeps its face for the whole recording.
struct AvatarLook: Equatable {
    enum Accessory: String, CaseIterable, Codable {
        case monocle, glasses, moustache, bowTie, beanie, headphones, eyebrow, freckles
    }

    /// Kept for the stored faces' API; every head now draws as a circle.
    enum Head: CaseIterable { case round, squircle, egg }

    var isMe = false
    var head: Head = .round
    var accessories: [Accessory] = []
    /// U-1: the voice number, which picks the colour (`VoicePalette.voice(_:)`).
    var voice = 0

    static let me = AvatarLook(isMe: true)

    /// The main accessory of voice `index` (0-based). Also how a voice's face
    /// is stored (`Speaker.avatar`), so the order must not change.
    static func accessory(forVoice index: Int) -> Accessory {
        Accessory.allCases[((index % 8) + 8) % 8]
    }

    static func voice(_ index: Int) -> AvatarLook {
        let i = max(0, index)
        var accessories = [accessory(forVoice: i)]
        // Past eight voices, faces get a second accessory that doesn't clash.
        if i >= 8 {
            let extras: [Accessory] = [.moustache, .bowTie, .freckles, .eyebrow, .glasses, .beanie, .monocle, .headphones]
            var k = (i / 8 + i) % extras.count
            while clashes(extras[k], accessories[0]) { k = (k + 1) % extras.count }
            accessories.append(extras[k])
        }
        return AvatarLook(head: Head.allCases[i % Head.allCases.count], accessories: accessories, voice: i)
    }

    /// The accessories actually drawn. None for the first eight voices, whose
    /// colours are all different; never the monocle, which is Earl's.
    var drawnAccessories: [Accessory] {
        guard !isMe, voice >= VoicePalette.tones.count else { return [] }
        return accessories.filter { $0 != .monocle }
    }

    private static func clashes(_ a: Accessory, _ b: Accessory) -> Bool {
        let groups: [Set<Accessory>] = [[.monocle, .glasses], [.beanie, .headphones], [.eyebrow, .glasses, .monocle]]
        return a == b || groups.contains { $0.contains(a) && $0.contains(b) }
    }
}

/// The moving parts of a face, all 0...1 unless noted.
struct AvatarPose: Equatable {
    /// How far the mouth is open.
    var mouth: Double = 0
    /// 1 is eyes shut.
    var blink: Double = 0
    /// Where the eyes look, -1 (left) ... 1 (right).
    var glance: Double = 0

    static let rest = AvatarPose()
}

/// One face, drawn with `Canvas`. Motion (sway, bob, springs) is applied by
/// the stage around it, so this view stays a pure drawing of a pose.
struct SpeakerAvatar: View {
    var look: AvatarLook
    var pose: AvatarPose = .rest
    var size: CGFloat = 72
    /// The current speaker: a soft glow in the voice's own colour.
    var isActive = false
    /// R3-5: `.badge` draws a still face for 16–28 pt badges, with bolder lines
    /// and fewer fine details, so it stays legible next to a name.
    var style: Style = .stage
    /// U-1: a small "?" on the shoulder, for a name nobody has confirmed yet.
    var unconfirmed = false

    enum Style { case stage, badge }

    @Environment(\.colorScheme) private var scheme

    /// R3-5: the still face on transcript badges and speaker chips.
    static func badge(_ look: AvatarLook, size: CGFloat = 18, unconfirmed: Bool = false) -> SpeakerAvatar {
        SpeakerAvatar(look: look, pose: .rest, size: size, isActive: false, style: .badge, unconfirmed: unconfirmed)
    }

    var body: some View {
        let voice = VoicePalette.voice(for: look)
        Canvas { ctx, canvas in
            ctx.scaleBy(x: canvas.width, y: canvas.height)
            AvatarDrawing(look: look, pose: pose, dark: scheme == .dark, isActive: isActive, badge: style == .badge,
                          face: voice.face)
                .draw(in: &ctx)
        }
        .frame(width: size, height: size)
        .overlay(alignment: .topTrailing) {
            if unconfirmed { UnconfirmedMark(voice: voice, size: size) }
        }
        .accessibilityHidden(true)
    }
}

/// The "?" on a face whose name is a guess.
private struct UnconfirmedMark: View {
    let voice: VoiceColors
    let size: CGFloat

    var body: some View {
        let d = max(13, size * 0.5)
        Circle()
            .fill(voice.text)
            .overlay(Image(systemName: "questionmark").font(.system(size: d * 0.58, weight: .heavy)).foregroundStyle(voice.bubble))
            .overlay(Circle().strokeBorder(Paper.paper, lineWidth: 1.2))
            .frame(width: d, height: d)
            .offset(x: d * 0.3, y: -d * 0.3)
    }
}

/// An unnamed voice's label: "Speaker 3" in a dashed capsule.
struct SpeakerTag: View {
    var name: String

    var body: some View {
        Text(name)
            .font(.paperLabel)
            .foregroundStyle(Paper.inkMuted)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 2)
            .overlay(Capsule().strokeBorder(Paper.inkMuted.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
    }
}

/// The drawing itself, in unit coordinates. Proportions follow the mockups'
/// 40-unit face (`docs/design/mockups/`): r 18.5, eyes ±6 across and 3 up.
private struct AvatarDrawing {
    let look: AvatarLook
    let pose: AvatarPose
    let dark: Bool
    let isActive: Bool
    /// R3-5: small and still. Line widths in unit space shrink with the face,
    /// so badges draw them thicker and drop details that would turn to mush.
    var badge = false
    let face: Color

    /// Stroke multiplier for the badge size.
    var k: CGFloat { badge ? 1.5 : 1 }

    // MARK: Palette

    /// Features on the face: always dark, like ink on a pastel.
    let ink = Color(red: 0x1b / 255, green: 0x1b / 255, blue: 0x1f / 255)
    /// The outline, so pale faces never dissolve into the paper.
    var outline: Color { Color(red: 0x2b / 255, green: 0x21 / 255, blue: 0x18 / 255).opacity(dark ? 0.55 : 0.4) }
    /// Accessories that stick out past the head: must read on the paper too.
    var gear: Color { dark ? Color(white: 0.8) : Color(white: 0.2) }
    let blush = Color(red: 1, green: 0x7a / 255, blue: 0x90 / 255)
    let tongue = Color(red: 1, green: 0x6b / 255, blue: 0x81 / 255)

    // MARK: Geometry

    /// Room around the head for the glow on the stage; badges fill the frame.
    var radius: CGFloat { badge ? 0.47 : 0.41 }
    /// One unit of the mockups' 40-unit face.
    var u: CGFloat { radius / 18.5 }
    var center: CGPoint { CGPoint(x: 0.5, y: 0.5) }
    var headRect: CGRect { CGRect(x: 0.5 - radius, y: 0.5 - radius, width: 2 * radius, height: 2 * radius) }
    var headPath: Path { Path(ellipseIn: headRect) }

    /// The eyes lift a little as the mouth opens, as in the talking mockup.
    var eyeY: CGFloat { 0.5 - 3 * u - 2 * u * CGFloat(min(1, max(0, pose.mouth))) }
    var mouthY: CGFloat { 0.5 + 6 * u }
    var eyeX: (left: CGFloat, right: CGFloat) { (0.5 - 6 * u, 0.5 + 6 * u) }

    func has(_ a: AvatarLook.Accessory) -> Bool { !badge && look.drawnAccessories.contains(a) }

    // MARK: Drawing

    func draw(in ctx: inout GraphicsContext) {
        if has(.headphones) { drawHeadphoneBand(&ctx) }
        if isActive { drawGlow(&ctx) }

        ctx.fill(headPath, with: .color(face))
        ctx.stroke(headPath.applying(scaled((radius - 0.75 * u * k) / radius, around: center)),
                   with: .color(outline), lineWidth: 1.5 * u * k)

        if has(.freckles) { drawFreckles(&ctx) } else { drawBlush(&ctx) }
        drawEyes(&ctx)
        if has(.eyebrow) { drawEyebrows(&ctx) }
        if has(.glasses) { drawGlasses(&ctx) }
        drawMouth(&ctx)
        if has(.moustache) { drawMoustache(&ctx) }
        if has(.beanie) { drawBeanie(&ctx) }
        if has(.headphones) { drawHeadphoneCups(&ctx) }
        if has(.bowTie) { drawBowTie(&ctx) }
    }

    private func drawGlow(_ ctx: inout GraphicsContext) {
        // A blurred halo in the voice's colour with a thin ring on top: soft,
        // but still clear at 30 pt.
        let outline = headPath.applying(scaled(1.1, around: center))
        ctx.drawLayer { layer in
            layer.addFilter(.blur(radius: 0.04))
            layer.fill(outline, with: .color(face.opacity(0.75)))
        }
        ctx.stroke(outline, with: .color(face.opacity(0.9)), lineWidth: 0.02)
    }

    private func drawBlush(_ ctx: inout GraphicsContext) {
        let r = 2.6 * u
        for x in [0.5 - 10 * u, 0.5 + 10 * u] {
            ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: 0.5 + 3 * u - r, width: 2 * r, height: 2 * r)),
                     with: .color(blush.opacity(0.45)))
        }
    }

    private func drawEyes(_ ctx: inout GraphicsContext) {
        let open = 1 - min(1, max(0, pose.blink))
        let dx = CGFloat(pose.glance) * 1.2 * u
        for x in [eyeX.left, eyeX.right] {
            let w = 2 * 2.6 * u * (badge ? 1.15 : 1), h = max(0.8 * u, 2 * 3.4 * u * (badge ? 1.1 : 1) * open)
            let eye = CGRect(x: x - w / 2 + dx, y: eyeY - h / 2, width: w, height: h)
            ctx.fill(Path(ellipseIn: eye), with: .color(ink))
            if open > 0.6 && !badge {
                let d = 1.8 * u
                ctx.fill(Path(ellipseIn: CGRect(x: eye.midX + u * 0.1, y: eye.minY + u * 0.7, width: d, height: d)),
                         with: .color(.white.opacity(0.9)))
            }
        }
    }

    private func drawMouth(_ ctx: inout GraphicsContext) {
        let m = CGFloat(min(1, max(0, pose.mouth)))
        let cx: CGFloat = 0.5
        if m < 0.04 {
            // The mockups' smile: M13 25 Q20 31 27 25.
            var smile = Path()
            smile.move(to: CGPoint(x: cx - 7 * u, y: 0.5 + 5 * u))
            smile.addQuadCurve(to: CGPoint(x: cx + 7 * u, y: 0.5 + 5 * u), control: CGPoint(x: cx, y: 0.5 + 11 * u))
            ctx.stroke(smile, with: .color(ink), style: StrokeStyle(lineWidth: 2.4 * u * k, lineCap: .round))
            return
        }
        // Open: an oval that grows with the voice, with the tongue at the bottom.
        let rx = (3.2 + 2.3 * m) * u, ry = (1.8 + 2.7 * m) * u
        let c = CGPoint(x: cx, y: mouthY + ry * 0.2)
        let mouth = Path(ellipseIn: CGRect(x: c.x - rx, y: c.y - ry, width: 2 * rx, height: 2 * ry))
        ctx.fill(mouth, with: .color(ink))
        if m > 0.25 {
            var inner = ctx
            inner.clip(to: mouth)
            let tw = rx * 1.16, th = ry * 0.7
            inner.fill(Path(ellipseIn: CGRect(x: cx - tw / 2, y: c.y + ry * 0.55 - th / 2, width: tw, height: th)),
                       with: .color(tongue))
        }
    }

    // MARK: Accessories

    private func drawGlasses(_ ctx: inout GraphicsContext) {
        let r: CGFloat = 0.088
        for x in [eyeX.left, eyeX.right] {
            let rim = Path(ellipseIn: CGRect(x: x - r, y: eyeY - r, width: 2 * r, height: 2 * r))
            ctx.fill(rim, with: .color(.white.opacity(dark ? 0.08 : 0.2)))
            ctx.stroke(rim, with: .color(ink), lineWidth: 0.02 * k)
        }
        var bridge = Path()
        bridge.move(to: CGPoint(x: eyeX.left + r, y: eyeY - 0.01))
        bridge.addQuadCurve(to: CGPoint(x: eyeX.right - r, y: eyeY - 0.01), control: CGPoint(x: 0.5, y: eyeY - 0.045))
        var temples = Path()
        temples.move(to: CGPoint(x: eyeX.left - r, y: eyeY - 0.015))
        temples.addLine(to: CGPoint(x: headRect.minX + 0.012, y: eyeY - 0.035))
        temples.move(to: CGPoint(x: eyeX.right + r, y: eyeY - 0.015))
        temples.addLine(to: CGPoint(x: headRect.maxX - 0.012, y: eyeY - 0.035))
        ctx.stroke(bridge, with: .color(ink), style: StrokeStyle(lineWidth: 0.02 * k, lineCap: .round))
        ctx.stroke(temples, with: .color(ink), style: StrokeStyle(lineWidth: 0.016 * k, lineCap: .round))
    }

    private func drawMoustache(_ ctx: inout GraphicsContext) {
        // Lifts a little when the mouth opens.
        let lift = CGFloat(pose.mouth) * 0.022
        let y = mouthY - 0.075 - lift
        var half = Path()
        half.move(to: CGPoint(x: 0.5, y: y + 0.018))
        half.addQuadCurve(to: CGPoint(x: 0.36, y: y + 0.005), control: CGPoint(x: 0.44, y: y - 0.03))
        half.addQuadCurve(to: CGPoint(x: 0.31, y: y - 0.03), control: CGPoint(x: 0.325, y: y + 0.025))
        half.addQuadCurve(to: CGPoint(x: 0.37, y: y + 0.045), control: CGPoint(x: 0.3, y: y + 0.05))
        half.addQuadCurve(to: CGPoint(x: 0.5, y: y + 0.035), control: CGPoint(x: 0.45, y: y + 0.055))
        half.closeSubpath()
        ctx.fill(half, with: .color(ink))
        ctx.fill(half.applying(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 1, ty: 0)), with: .color(ink))
    }

    private func drawBowTie(_ ctx: inout GraphicsContext) {
        let c = CGPoint(x: 0.5, y: min(0.94, headRect.maxY + 0.05))
        var wing = Path()
        wing.move(to: CGPoint(x: c.x - 0.02, y: c.y))
        wing.addLine(to: CGPoint(x: c.x - 0.11, y: c.y - 0.045))
        wing.addQuadCurve(to: CGPoint(x: c.x - 0.11, y: c.y + 0.045), control: CGPoint(x: c.x - 0.135, y: c.y))
        wing.closeSubpath()
        // It wiggles a touch while its owner talks.
        var tie = ctx
        tie.translateBy(x: c.x, y: c.y)
        tie.rotate(by: .degrees(pose.mouth * 7))
        tie.translateBy(x: -c.x, y: -c.y)
        tie.fill(wing, with: .color(gear))
        tie.fill(wing.applying(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 2 * c.x, ty: 0)), with: .color(gear))
        tie.fill(Path(roundedRect: CGRect(x: c.x - 0.025, y: c.y - 0.027, width: 0.05, height: 0.054), cornerRadius: 0.014),
                 with: .color(gear))
    }

    private func drawBeanie(_ ctx: inout GraphicsContext) {
        let r = headRect
        let cuffY = r.minY + r.height * 0.27
        var dome = Path()
        dome.move(to: CGPoint(x: r.minX + 0.01, y: cuffY + 0.02))
        dome.addCurve(to: CGPoint(x: r.maxX - 0.01, y: cuffY + 0.02),
                      control1: CGPoint(x: r.minX + 0.02, y: r.minY - 0.11), control2: CGPoint(x: r.maxX - 0.02, y: r.minY - 0.11))
        dome.closeSubpath()
        ctx.fill(dome, with: .color(gear))
        // Ribs on the cuff.
        let cuff = CGRect(x: r.minX - 0.01, y: cuffY - 0.015, width: r.width + 0.02, height: 0.085)
        let band = Path(roundedRect: cuff, cornerRadius: 0.04, style: .continuous)
        ctx.fill(band, with: .color(gear))
        if badge { return drawPom(&ctx) }
        var ribs = Path()
        var x = cuff.minX + 0.05
        while x < cuff.maxX - 0.03 {
            ribs.move(to: CGPoint(x: x, y: cuff.minY + 0.018))
            ribs.addLine(to: CGPoint(x: x, y: cuff.maxY - 0.018))
            x += 0.045
        }
        ctx.stroke(ribs, with: .color(dark ? .black.opacity(0.18) : .white.opacity(0.18)),
                   style: StrokeStyle(lineWidth: 0.012, lineCap: .round))
        drawPom(&ctx)
    }

    private func drawPom(_ ctx: inout GraphicsContext) {
        let pom: CGFloat = 0.1
        ctx.fill(Path(ellipseIn: CGRect(x: 0.5 - pom / 2, y: headRect.minY - 0.075, width: pom, height: pom)), with: .color(gear))
    }

    private func drawHeadphoneBand(_ ctx: inout GraphicsContext) {
        let r = headRect
        var band = Path()
        band.addArc(center: CGPoint(x: r.midX, y: r.minY + r.height * 0.5), radius: r.width * 0.5 + 0.035,
                    startAngle: .degrees(195), endAngle: .degrees(345), clockwise: false)
        ctx.stroke(band, with: .color(gear), style: StrokeStyle(lineWidth: badge ? 0.06 : 0.045, lineCap: .round))
    }

    private func drawHeadphoneCups(_ ctx: inout GraphicsContext) {
        let r = headRect
        let h: CGFloat = 0.22, w: CGFloat = 0.1, y = r.minY + r.height * 0.5 - h / 2
        for x in [r.minX - w * 0.55, r.maxX - w * 0.45] {
            ctx.fill(Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: 0.045, style: .continuous),
                     with: .color(gear))
        }
    }

    private func drawEyebrows(_ ctx: inout GraphicsContext) {
        // One brow stays raised, and goes higher when its owner talks.
        let raise = CGFloat(pose.mouth) * 0.025
        var left = Path()
        left.move(to: CGPoint(x: eyeX.left - 0.065, y: eyeY - 0.1 - raise))
        left.addQuadCurve(to: CGPoint(x: eyeX.left + 0.06, y: eyeY - 0.115 - raise),
                          control: CGPoint(x: eyeX.left - 0.01, y: eyeY - 0.19 - raise))
        var right = Path()
        right.move(to: CGPoint(x: eyeX.right - 0.06, y: eyeY - 0.095))
        right.addQuadCurve(to: CGPoint(x: eyeX.right + 0.065, y: eyeY - 0.085), control: CGPoint(x: eyeX.right, y: eyeY - 0.11))
        let style = StrokeStyle(lineWidth: 0.028 * k, lineCap: .round)
        ctx.stroke(left, with: .color(ink), style: style)
        ctx.stroke(right, with: .color(ink), style: style)
    }

    private func drawFreckles(_ ctx: inout GraphicsContext) {
        let dots: [(CGFloat, CGFloat)] = [(0.0, 0.0), (0.04, 0.018), (-0.035, 0.024), (0.008, 0.042)]
        let y = eyeY + 0.12, d: CGFloat = badge ? 0.036 : 0.022
        for base in [eyeX.left - 0.03, eyeX.right + 0.01] {
            for (dx, dy) in dots {
                ctx.fill(Path(ellipseIn: CGRect(x: base + dx - d / 2, y: y + dy - d / 2, width: d, height: d)),
                         with: .color(ink.opacity(badge ? 0.5 : 0.4)))
            }
        }
    }

    private func scaled(_ s: CGFloat, around c: CGPoint) -> CGAffineTransform {
        CGAffineTransform(translationX: c.x, y: c.y).scaledBy(x: s, y: s).translatedBy(x: -c.x, y: -c.y)
    }
}
