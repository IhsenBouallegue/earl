import AppKit
import Combine
import SwiftUI

// R2-6: call offers you can't miss. Notifications are hidden while you share
// your screen, and the menu bar icon can hide behind the notch, so offers also
// show in a small floating panel in the top right corner. It never takes focus
// and is left out of screen captures, so the people watching don't see it.

extension Prefs.Key {
    static let showOffersOnScreen = "showOffersOnScreen"
}

extension Prefs {
    static var showOffersOnScreen: Bool {
        UserDefaults.standard.object(forKey: Key.showOffersOnScreen) as? Bool ?? true
    }
}

/// What the floating panel shows.
enum OfferItem: Equatable {
    case callOffer(DetectedApp)
    case stopOffer(DetectedApp?)
    /// Automatic starts and stops. Hides by itself.
    case confirmation(title: String, body: String, recording: Bool)

    var isOffer: Bool {
        if case .confirmation = self { return false }
        return true
    }
}

/// Shows `OfferItem`s in a floating, non-activating panel.
@MainActor
final class OfferPanel: ObservableObject {
    /// Confirmations hide after this long.
    static let confirmationTime: Duration = .seconds(4)

    @Published private(set) var item: OfferItem?

    private weak var detector: CallDetector?
    /// U-5: names the meeting a call probably is ("· Weekly sync with Priya").
    private weak var calendar: CalendarService?
    private var panel: FloatingPanel?
    private var host: FirstClickHostingView<AnyView>?
    private var hideTask: Task<Void, Never>?
    private var subscription: AnyCancellable?
    /// The detector's latest offers, so a confirmation can give way to them.
    private var pending: (offer: DetectedApp?, stop: DetectedApp?) = (nil, nil)

    func attach(to detector: CallDetector, calendar: CalendarService? = nil) {
        self.detector = detector
        self.calendar = calendar
        // @Published emits before the property changes, so use the emitted values.
        subscription = detector.$offer.combineLatest(detector.$stopOffer)
            .sink { [weak self] offer, stop in
                MainActor.assumeIsolated {
                    self?.pending = (offer, stop)
                    self?.showPending()
                }
            }
    }

    /// An automatic start or stop: shown for a few seconds.
    func confirm(title: String, body: String, recording: Bool) {
        show(.confirmation(title: title, body: body, recording: recording))
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: Self.confirmationTime)
            guard !Task.isCancelled else { return }
            self?.hide()
            self?.showPending()
        }
    }

    private func showPending() {
        // A confirmation stays up until its time is over.
        if case .confirmation = item, hideTask != nil { return }
        if let offer = pending.offer {
            show(.callOffer(offer))
        } else if let stop = pending.stop {
            show(.stopOffer(stop))
        } else if item?.isOffer == true {
            hide()
        }
    }

    private func show(_ new: OfferItem) {
        hideTask?.cancel()
        hideTask = nil
        guard Prefs.showOffersOnScreen else { return hide() }
        guard new != item || panel?.isVisible != true else { return }
        item = new

        let panel = self.panel ?? FloatingPanel()
        self.panel = panel
        var event: CalendarCandidate?
        if case .callOffer(let app) = new { event = calendar?.likelyEvent(for: app) }
        let view = AnyView(OfferPanelView(item: new, event: event, actions: actions))
        if let host {
            host.rootView = view
        } else {
            let host = FirstClickHostingView(rootView: view)
            panel.contentView = host
            self.host = host
        }
        let size = host?.fittingSize ?? NSSize(width: OfferPanelView.width, height: 80)
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? .zero
        // Top right, under the menu bar, where notifications appear.
        let origin = NSPoint(x: visible.maxX - size.width - 12, y: visible.maxY - size.height - 10)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.2; panel.animator().alphaValue = 1 }
        }
    }

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        item = nil
        panel?.orderOut(nil)
    }

    private var actions: OfferPanelView.Actions {
        OfferPanelView.Actions(
            record: { [weak self] in self?.hide(); self?.detector?.accept() },
            notNow: { [weak self] in self?.hide(); self?.detector?.decline() },
            stop: { [weak self] in self?.hide(); self?.detector?.stopFromOffer() },
            keep: { [weak self] in self?.hide(); self?.detector?.keepRecording() },
            dismiss: { [weak self] in self?.hide() })
    }
}

extension CalendarService {
    /// U-5: the event a detected call most likely is, for the offer's wording
    /// only. Pure matching over the cached events: it doesn't touch the event
    /// "Up next" chose for the recording.
    func likelyEvent(for app: DetectedApp, at date: Date = Date()) -> CalendarCandidate? {
        guard isActive else { return nil }
        return CalendarMatcher.best(from: upcomingEvents, at: date, callApp: app.name)
    }
}

/// Borderless, floats over every app and Space (full-screen ones too), and
/// never becomes key, so it doesn't take focus from the call.
final class FloatingPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        // Out of screen sharing and screenshots of the screen.
        sharingType = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Buttons work on the first click, although the panel is never key.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - View

/// U-5: the offer on paper. Earl asks in his handwriting, one plain line says
/// which call, and two buttons answer: Record / Not now, or Stop / Keep going.
struct OfferPanelView: View {
    static let width: CGFloat = 380

    struct Actions {
        var record: () -> Void = {}
        var notNow: () -> Void = {}
        var stop: () -> Void = {}
        var keep: () -> Void = {}
        var dismiss: () -> Void = {}
    }

    let item: OfferItem
    /// The calendar event the call probably is, named in the call offer.
    var event: CalendarCandidate?
    var actions = Actions()

    private static let radius: CGFloat = 18

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        content
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 14)
            .frame(width: Self.width, alignment: .leading)
            .background(Paper.paper, in: shape)
            .overlay(shape.strokeBorder(Paper.hairline))
            .clipShape(shape)
    }

    @ViewBuilder
    private var content: some View {
        switch item {
        case .callOffer(let app):
            VStack(alignment: .leading, spacing: 14) {
                EarlSays(lead: EarlVoice.shallIRecord, line: OfferCopy.callLine(app: app.shortName, event: event))
                buttons {
                    Button("Not now", action: actions.notNow).buttonStyle(.paperSecondary)
                    Button(action: actions.record) { OfferMarkLabel(title: "Record", mark: .dot) }
                        .buttonStyle(.paperPrimary)
                }
            }
        case .stopOffer(let app):
            VStack(alignment: .leading, spacing: 14) {
                EarlSays(lead: EarlVoice.soundedLikeGoodbye, line: Text(OfferCopy.stopLine(app: app?.shortName)))
                buttons {
                    Button("Keep going", action: actions.keep).buttonStyle(.paperSecondary)
                    Button(action: actions.stop) { OfferMarkLabel(title: "Stop", mark: .square) }
                        .buttonStyle(.paperPrimary)
                }
            }
        case .confirmation(let title, let body, let recording):
            // The caller's plain title ("Recording Sprint planning"), not
            // Earl's lead-in, so no handwriting.
            HStack(alignment: .top, spacing: 12) {
                EarlAvatar(size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        if recording {
                            Circle().fill(Paper.stop).frame(width: 9, height: 9)
                                .accessibilityLabel("Recording")
                        }
                        Text(title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Paper.ink)
                            .lineLimit(2)
                    }
                    Text(body)
                        .font(.paperBody)
                        .foregroundStyle(Paper.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 1)
                .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: actions.dismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Paper.inkMuted)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Hide")
            }
        }
    }

    private func buttons(@ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            content()
        }
    }
}

/// Earl, his handwritten lead-in, then one plain line under it.
struct EarlSays: View {
    var lead: String
    var line: Text
    var avatar: CGFloat = 40

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            EarlAvatar(size: avatar)
            VStack(alignment: .leading, spacing: 3) {
                Text(lead).font(.earlVoice(size: 20)).foregroundStyle(Paper.ink)
                line
                    .font(.paperBody)
                    .lineSpacing(2)
                    .foregroundStyle(Paper.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// "● Record" / "■ Stop" for a small primary button: the red mark of the big
/// menu bar button, at the size of the text.
struct OfferMarkLabel: View {
    enum Mark { case dot, square }
    var title: String
    var mark: Mark

    var body: some View {
        HStack(spacing: 7) {
            Group {
                switch mark {
                case .dot: Circle().fill(Paper.stop)
                case .square: RoundedRectangle(cornerRadius: 2).fill(Paper.stop)
                }
            }
            .frame(width: 9, height: 9)
            Text(title)
        }
    }
}

/// The offer's words, apart from the views so they can be tested.
enum OfferCopy {
    /// "Teams is using your mic · Weekly sync with Priya". The event is only a
    /// guess from the calendar, so it follows the fact.
    static func callParts(app: String, event: CalendarCandidate?) -> (fact: String, title: String?, with: String?) {
        let fact = "\(app) is using your mic"
        let title = event?.title.trimmingCharacters(in: .whitespaces) ?? ""
        guard let event, !title.isEmpty else { return (fact + ".", nil, nil) }
        return (fact, title, AttendeeName.line(event.attendees))
    }

    static func callLine(app: String, event: CalendarCandidate?) -> Text {
        let parts = callParts(app: app, event: event)
        guard let title = parts.title else { return Text(parts.fact) }
        let with = parts.with.map { Text(" \($0)") } ?? Text("")
        return Text("\(parts.fact) · \(Text(title).fontWeight(.semibold))\(with)")
    }

    /// Plain: what happened, and that nothing stopped yet.
    static func stopLine(app: String?) -> String {
        guard let app else { return "Earl is still recording." }
        return "\(app) let go of the mic. Earl is still recording."
    }
}

// MARK: - Menu bar badge

/// The menu bar icon, with a badge while a call offer waits for an answer.
struct MenuBarIconImage: View {
    @ObservedObject var detector: CallDetector
    let recording: Bool

    var body: some View {
        Image(nsImage: MenuBarIcon.image(recording: recording, offer: detector.offer != nil))
    }
}
