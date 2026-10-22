import SwiftUI

// The sidebar's next meeting, compressed to two lines beside a pocket-watch
// dial. The number in the dial is always minutes: until it starts, or left.
// Before: a red arc fills as the start nears. During: the face fills in ink as
// the meeting runs. Recording: the arc is live red and a dot breathes.

struct SidebarUpNext: View {
    enum Phase: Equatable {
        case soon, armed, ongoing, recording
    }

    let event: CalendarCandidate
    let now: Date
    let phase: Phase
    /// Your to-dos still open from the series, when it has a brief.
    var briefCount: Int?
    var hasBrief = false
    var recordDisabled = false
    var onOpen: () -> Void = {}
    var onRecord: () -> Void = {}
    var onCancel: () -> Void = {}

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 11) {
            Button(action: onOpen) {
                HStack(alignment: .center, spacing: 11) {
                    WatchDial(fraction: fraction, minutes: minutes, phase: phase)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(event.title)
                            .font(.paperTitle(size: 15))
                            .foregroundStyle(Paper.ink)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(line)
                            .font(.system(size: 13, weight: phase == .recording ? .semibold : .regular).monospacedDigit())
                            .foregroundStyle(phase == .recording || phase == .soon && minutes <= 5 ? Paper.masthead : Paper.inkMuted)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(hasBrief ? "Open the brief for \(event.title)" : "Open \(event.title) in Calendar")
            action
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: Paper.Radius.row, style: .continuous)
            .fill(hovering ? Paper.ink.opacity(0.05) : .clear))
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(event.title), \(line)")
    }

    // MARK: Time

    /// Before: how close the start is, over the half hour lead. During: how
    /// much of the meeting has gone.
    private var fraction: Double {
        switch phase {
        case .soon, .armed:
            let lead: TimeInterval = 30 * 60
            return min(1, max(0.04, 1 - event.start.timeIntervalSince(now) / lead))
        case .ongoing, .recording:
            let length = max(60, event.end.timeIntervalSince(event.start))
            return min(1, max(0.02, now.timeIntervalSince(event.start) / length))
        }
    }

    private var minutes: Int {
        switch phase {
        case .soon, .armed: max(0, Int((event.start.timeIntervalSince(now) / 60).rounded(.up)))
        case .ongoing, .recording: max(1, Int((event.end.timeIntervalSince(now) / 60).rounded(.up)))
        }
    }

    /// The one line under the title. The dial already says the minutes, so
    /// the line gives the clock: "13:28 · 2 of yours", "Now · until 14:15".
    private var line: String {
        switch phase {
        case .soon:
            let start = CalendarMatcher.clock(event.start)
            guard let open = briefCount, open > 0 else { return "Starts \(start)" }
            return "\(start) · \(open) of yours"
        case .armed: return "Earl records at \(CalendarMatcher.clock(event.start))"
        case .ongoing: return "Now · until \(CalendarMatcher.clock(event.end))"
        case .recording: return "Recording · until \(CalendarMatcher.clock(event.end))"
        }
    }

    // MARK: Action

    /// A small round button: arm (alarm), disarm (green alarm), or record now
    /// (red dot). Nothing while recording; Stop lives in the toolbar.
    @ViewBuilder
    private var action: some View {
        switch phase {
        case .soon:
            RoundAction(symbol: "alarm", tint: Paper.inkMuted, filled: false, action: onRecord)
                .help("Record when it starts: Earl starts at \(CalendarMatcher.clock(event.start)), or when the call does")
                .accessibilityLabel("Record when it starts")
        case .armed:
            RoundAction(symbol: "alarm.fill", tint: Paper.ok, filled: false, action: onCancel)
                .help("Earl will record at \(CalendarMatcher.clock(event.start)). Click to cancel.")
                .accessibilityLabel("Cancel recording when it starts")
        case .ongoing:
            RoundAction(symbol: "circle.fill", tint: Paper.stop, filled: true, action: onRecord)
                .disabled(recordDisabled)
                .help("Record now")
                .accessibilityLabel("Record now")
        case .recording:
            EmptyView()
        }
    }
}

/// The pocket watch: a ring, an arc or a filled face, and the minutes.
private struct WatchDial: View {
    let fraction: Double
    let minutes: Int
    let phase: SidebarUpNext.Phase

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false

    static let size: CGFloat = 34

    var body: some View {
        ZStack {
            Circle().fill(Paper.card)
            Circle().strokeBorder(Paper.hairline, lineWidth: 1)
            switch phase {
            case .soon, .armed:
                arc(phase == .armed ? Paper.ok : Paper.masthead)
            case .ongoing:
                // The face fills like a pie as the meeting runs.
                Pie(fraction: fraction).fill(Paper.ink.opacity(0.14)).padding(3)
                arc(Paper.ink)
            case .recording:
                arc(Paper.live)
            }
            if phase == .recording {
                Circle()
                    .fill(Paper.live)
                    .frame(width: 9, height: 9)
                    .opacity(breathing ? 0.35 : 1)
                    .onAppear {
                        guard !reduceMotion else { return }
                        withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { breathing = true }
                    }
            } else {
                Text(minutes > 99 ? "·" : "\(minutes)")
                    .font(.system(size: 13, weight: .bold).monospacedDigit())
                    .foregroundStyle(Paper.ink)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(width: Self.size, height: Self.size)
        .animation(.easeOut(duration: 0.6), value: fraction)
        .accessibilityHidden(true)
    }

    private func arc(_ color: Color) -> some View {
        Circle()
            .trim(from: 0, to: fraction)
            .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            .rotationEffect(.degrees(-90))
            .padding(1.25)
    }
}

private struct Pie: Shape {
    var fraction: Double
    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: rect.midX, y: rect.midY)
        p.move(to: c)
        p.addArc(center: c, radius: min(rect.width, rect.height) / 2,
                 startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * fraction), clockwise: false)
        p.closeSubpath()
        return p
    }
}

/// A 26 pt round button on the paper.
private struct RoundAction: View {
    let symbol: String
    let tint: Color
    let filled: Bool
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: filled ? 10 : 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(Paper.card, in: Circle())
                .overlay(Circle().strokeBorder(Paper.hairline))
                .contentShape(Circle())
                .opacity(enabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
    }
}
