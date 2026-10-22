import SwiftUI

// U-1: Earl himself. His avatar is the only squircle on the page (people are
// round pastel faces), and his lines are the only handwriting.

/// Earl's avatar: an ink squircle with cream eyes, a small smile and a gold
/// monocle on a chain. In dark mode it flips to a cream squircle with ink
/// features. Drawn from the mockups' 40-unit symbol ("Earl's final avatar" in
/// `docs/design/mockups/recording-menubar-offer.html`). Meant for 24–40 pt.
struct EarlAvatar: View {
    var size: CGFloat = 32
    /// Now and then the monocle catches the light. Only where Earl stays on
    /// screen (the sidebar), so it stays rare.
    var idle = false
    /// The monocle glints once when he appears (he's looking something up).
    var glintOnAppear = false
    /// Earl nods once each time this changes: he finished something.
    var nod = 0
    /// Earl glances down and right, toward the page, each time this changes.
    var glance = 0

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var glint = 0
    @State private var blinks = 0

    var body: some View {
        let dark = scheme == .dark
        // A blink: the lids close quickly, rest a moment, open a little slower.
        KeyframeAnimator(initialValue: 0.0, trigger: blinks) { blink in
            KeyframeAnimator(initialValue: EarlLook(), trigger: reduceMotion ? 0 : glance) { look in
                Canvas { ctx, canvas in
                    ctx.scaleBy(x: canvas.width / 40, y: canvas.height / 40)
                    EarlDrawing(dark: dark, blink: blink, look: look).draw(in: &ctx)
                }
            } keyframes: { _ in
                KeyframeTrack(\.x) {
                    CubicKeyframe(1, duration: 0.14)
                    LinearKeyframe(1, duration: 0.7)
                    CubicKeyframe(0, duration: 0.26)
                }
                KeyframeTrack(\.y) {
                    CubicKeyframe(0.7, duration: 0.14)
                    LinearKeyframe(0.7, duration: 0.7)
                    CubicKeyframe(0, duration: 0.26)
                }
            }
        } keyframes: { _ in
            KeyframeTrack {
                CubicKeyframe(1, duration: 0.07)
                LinearKeyframe(1, duration: 0.05)
                CubicKeyframe(0, duration: 0.11)
            }
        }
        .frame(width: size, height: size)
        .overlay { MonocleGlint(size: size, trigger: glint) }
        // 0 2px 4px rgba(43,33,24,.25), so he sits on the paper.
        .shadow(color: Color(red: 43 / 255, green: 33 / 255, blue: 24 / 255).opacity(dark ? 0.6 : 0.25), radius: 2, x: 0, y: 2)
        // A butler's nod: down, a touch past level, settle. Nothing with Reduce Motion.
        .keyframeAnimator(initialValue: 0.0, trigger: reduceMotion ? 0 : nod) { content, dip in
            content
                .rotationEffect(.degrees(dip * 2), anchor: .bottom)
                .offset(y: dip * size / 32)
        } keyframes: { _ in
            KeyframeTrack {
                CubicKeyframe(3.5, duration: 0.15)
                CubicKeyframe(-0.8, duration: 0.16)
                CubicKeyframe(0, duration: 0.2)
            }
        }
        .onChange(of: nod) { glint += 1 }
        .onAppear { if glintOnAppear { glint += 1 } }
        // Where he stays on screen he blinks every few seconds, now and then
        // twice, and every so often the monocle catches the light.
        .task(id: idle) {
            guard idle else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(.random(in: 3.5...8)))
                guard !Task.isCancelled else { return }
                blinks += 1
                if Int.random(in: 0..<5) == 0 {
                    try? await Task.sleep(for: .seconds(0.3))
                    blinks += 1
                }
                if Int.random(in: 0..<12) == 0 { glint += 1 }
            }
        }
        .accessibilityLabel("Earl")
    }
}

/// Light crossing Earl's monocle once each time `trigger` changes. Opacity
/// only along the lens, so it stays with Reduce Motion as a soft flash.
private struct MonocleGlint: View {
    let size: CGFloat
    let trigger: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // The lens: centre (26, 18), radius 6.4, in Earl's 40-unit drawing.
        let unit = size / 40
        let lens = 12.8 * unit
        let still = reduceMotion
        Rectangle()
            .fill(Color.white.opacity(0.9))
            .frame(width: 2.2 * unit, height: lens * 1.6)
            .rotationEffect(.degrees(35))
            .keyframeAnimator(initialValue: -1.0, trigger: trigger) { bar, x in
                // Off the lens on either side, so the end state is invisible.
                bar.offset(x: still ? 0 : x * lens)
                    .opacity(still ? (abs(x) < 1 ? 0.6 : 0) : 1)
            } keyframes: { _ in
                KeyframeTrack {
                    LinearKeyframe(-1, duration: 0.2)
                    CubicKeyframe(1, duration: 0.8)
                }
            }
            .frame(width: lens, height: lens)
            .clipShape(Circle())
            .position(x: 26 * unit, y: 18 * unit)
            .frame(width: size, height: size)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Where Earl's eyes point: 0 straight ahead, 1 toward the page (right, down).
private struct EarlLook {
    var x = 0.0
    var y = 0.0
}

private struct EarlDrawing {
    let dark: Bool
    /// 0 open, 1 shut.
    var blink = 0.0
    var look = EarlLook()

    private static let ink = Tone.srgb(PaperTones.ink.light)
    private static let cream = Tone.srgb(PaperTones.earlCream.light)

    var body: Color { Color(nsColor: dark ? Self.cream : Self.ink) }
    var features: Color { Color(nsColor: dark ? Self.ink : Self.cream) }
    var gold: Color { Color(nsColor: Tone.srgb(dark ? PaperTones.monocleGold.dark : PaperTones.monocleGold.light)) }

    func draw(in ctx: inout GraphicsContext) {
        // The squircle: 38 units with a 12-unit continuous corner (0.3 × size).
        ctx.fill(Path(roundedRect: CGRect(x: 1, y: 1, width: 38, height: 38), cornerRadius: 12, style: .continuous),
                 with: .color(body))
        // Eyes; the right one behind the monocle.
        // Shut, an eye is a short line, not nothing.
        let height = 6.2 * (1 - 0.82 * blink)
        let dx = 1.3 * look.x, dy = 1.1 * look.y
        for x in [13.5, 26.0] {
            ctx.fill(Path(ellipseIn: CGRect(x: x - 2.5 + dx, y: 18 + dy - height / 2, width: 5, height: height)),
                     with: .color(features))
        }
        let lens = Path(ellipseIn: CGRect(x: 26 - 6.4, y: 18 - 6.4, width: 12.8, height: 12.8))
        ctx.stroke(lens, with: .color(gold), lineWidth: 2.4)
        var chain = Path()
        chain.move(to: CGPoint(x: 32.2, y: 20.5))
        chain.addQuadCurve(to: CGPoint(x: 32, y: 34), control: CGPoint(x: 35, y: 27))
        ctx.stroke(chain, with: .color(gold), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
        // A small, slightly wry smile.
        var smile = Path()
        smile.move(to: CGPoint(x: 11.5, y: 27.5))
        smile.addQuadCurve(to: CGPoint(x: 20, y: 27.5), control: CGPoint(x: 15.5, y: 25))
        smile.addQuadCurve(to: CGPoint(x: 28.5, y: 27.5), control: CGPoint(x: 24.5, y: 25))
        ctx.stroke(smile, with: .color(features), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
    }
}

// MARK: - Earl's voice

/// Earl's short lines. They vary, and get shorter as he gets to know you
/// (PRODUCT.md, Brand Commitments). Never jokes in errors: error copy is plain
/// and lives with the screen that shows it.
enum EarlVoice {
    static let inShort = "In short —"
    static let shallIRecord = "Shall I record?"
    static let readyWhenYouAre = "Ready when you are."
    static let listening = "Listening."
    static let soundedLikeGoodbye = "That sounded like goodbye."
    static let allDone = "All done."
    static let oneMoment = "One moment."
    static let nothingYet = "Nothing yet."

    /// "Is this Sarah?" for an unconfirmed name.
    static func isThis(_ name: String) -> String { "Is this \(name)?" }

    enum PartOfDay: CaseIterable { case morning, afternoon, evening, night }

    static func partOfDay(_ date: Date, calendar: Calendar = .current) -> PartOfDay {
        switch calendar.component(.hour, from: date) {
        case 5..<12: .morning
        case 12..<18: .afternoon
        case 18..<22: .evening
        default: .night
        }
    }

    /// After this many different days, Earl drops the name and the flourishes.
    static let familiarAfterDays = 7

    /// "Morning, Alex." / "Good afternoon, Alex." / "Evening." Stable for a
    /// whole day, so it doesn't change on every redraw. Counts today as a day
    /// Earl was seen.
    static func greeting(name: String?, at date: Date = Date()) -> String {
        noteSeen(date)
        return greeting(name: name, at: date, daysKnown: Prefs.earlSeenDays.count)
    }

    /// The pure part, for tests.
    static func greeting(name: String?, at date: Date, daysKnown: Int, calendar: Calendar = .current) -> String {
        let part = partOfDay(date, calendar: calendar)
        if daysKnown > familiarAfterDays { return familiar[part]! }
        let options = variants[part]!
        let pick = options[stableIndex(date, count: options.count, calendar: calendar)]
        let first = name.flatMap { AttendeeName.firstName($0) }.flatMap { $0.isEmpty ? nil : $0 }
        guard let first else { return pick.without }
        return pick.with.replacingOccurrences(of: "{name}", with: first)
    }

    private static let familiar: [PartOfDay: String] = [
        .morning: "Morning.", .afternoon: "Afternoon.", .evening: "Evening.", .night: "Late one.",
    ]

    private static let variants: [PartOfDay: [(with: String, without: String)]] = [
        .morning: [("Morning, {name}.", "Morning."), ("Good morning, {name}.", "Good morning."),
                   ("A fine morning, {name}.", "A fine morning.")],
        .afternoon: [("Afternoon, {name}.", "Afternoon."), ("Good afternoon, {name}.", "Good afternoon."),
                     ("Ah, {name}. Afternoon.", "Good afternoon.")],
        .evening: [("Evening, {name}.", "Evening."), ("Good evening, {name}.", "Good evening."),
                   ("Still at it, {name}?", "Still at it?")],
        .night: [("Late one, {name}.", "Late one."), ("Still up, {name}?", "Still up?"),
                 ("Good evening, {name}.", "Good evening.")],
    ]

    /// The same pick all day; a different one most days.
    static func stableIndex(_ date: Date, count: Int, calendar: Calendar = .current) -> Int {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        let seed = (c.year ?? 0) * 372 + (c.month ?? 0) * 31 + (c.day ?? 0)
        return (seed * 7 + 3) % max(1, count)
    }

    /// Remembers that Earl was seen on `date`'s day.
    static func noteSeen(_ date: Date, calendar: Calendar = .current) {
        let day = dayKey(date, calendar: calendar)
        var days = Prefs.earlSeenDays
        guard !days.contains(day) else { return }
        days.append(day)
        // Only "more than a week of days" matters; keep the list short.
        Prefs.earlSeenDays = Array(days.suffix(familiarAfterDays + 5))
    }

    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

extension Prefs.Key {
    /// U-1: the different days Earl greeted you, as "yyyy-MM-dd".
    static let earlSeenDays = "earlSeenDays"
}

extension Prefs {
    static var earlSeenDays: [String] {
        get { Prefs.defaults.stringArray(forKey: Key.earlSeenDays) ?? [] }
        set { Prefs.defaults.set(newValue, forKey: Key.earlSeenDays) }
    }
}
