import SwiftUI

// D-2: the first-run screens. Every screen fills the same five slots, always
// in the same place: hero, headline, body, one prominent button, at most one
// link under it. System colours and materials only (not the warm paper), so
// it reads as a first-party Apple welcome flow; Earl is his face and his lines.

/// The whole window: the page that changes, and the button area that stays.
struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    /// "Get Started": close the window and show Earl.
    var finish: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let size = CGSize(width: 620, height: 580)

    var body: some View {
        let page = model.page
        let copy = screen(page)
        VStack(spacing: 0) {
            // The ZStack stays while the page inside it is swapped, so the transition has a parent.
            ZStack(alignment: .top) {
                OnboardingPage(page: page, copy: copy, model: model)
                    .id(page)
                    .transition(pageTurn)
            }
            .animation(.easeOut(duration: 0.22), value: page)
            .frame(maxHeight: .infinity, alignment: .top)

            PageDots(count: model.pages.count, index: model.pageIndex)
                .padding(.bottom, 20)
            primaryButton(page, title: copy.primary)
            // Once used, "Show Me Where Earl Lives" has done its job; its line stays so nothing moves.
            secondaryLink(page, title: page == .done && model.whereShown ? nil : copy.secondary)
                .padding(.top, 10)
        }
        .padding(.horizontal, 40)
        .padding(.top, 52)
        .padding(.bottom, 28)
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// The next screen settles in from the side; with Reduce Motion it only fades.
    private var pageTurn: AnyTransition {
        let fadeIn = AnyTransition.opacity.animation(.timingCurve(0.2, 0.9, 0.1, 1, duration: 0.32))
        let insertion = reduceMotion ? fadeIn : fadeIn.combined(with: .offset(x: 28))
        return .asymmetric(insertion: insertion, removal: .opacity.animation(.easeOut(duration: 0.1)))
    }

    private func screen(_ page: OnboardingModel.Page) -> OnboardingCopy.Screen {
        switch page {
        case .welcome: return OnboardingCopy.welcome
        case .checking where model.currentStep == .notes:
            var copy = OnboardingCopy.notes
            copy.body = OnboardingCopy.checking
            return copy
        case .models, .checking:
            var copy = OnboardingCopy.models(bytes: model.neededBytes)
            if page == .checking { copy.body = OnboardingCopy.checking }
            // After a failure: the reason and one suggestion, "Use a File I Have…" right
            // under it, Try Again, and Not Now to do the permissions first.
            switch model.stepDownload {
            case .failed(let reason) where reason == OnboardingCopy.transcriberMissing:
                copy.body = reason // a file from a colleague wouldn't help: no link
                copy.primary = OnboardingCopy.tryAgain
                copy.secondary = OnboardingCopy.notNow
                copy.help = nil
            case .failed(let reason), .importFailed(let reason):
                if case .failed = model.stepDownload {
                    copy.body = OnboardingCopy.downloadFailed(reason)
                    copy.primary = OnboardingCopy.tryAgain
                } else {
                    copy.body = OnboardingCopy.importFailed(reason) // nothing to try again: the Download button stays
                }
                copy.secondary = OnboardingCopy.notNow
                copy.help = nil
                copy.action = OnboardingCopy.useFile
            default: break
            }
            return copy
        case .downloading:
            // Every step's download looks the same: its screen, the progress, Cancel.
            var copy = model.currentStep == .notes ? OnboardingCopy.notes : OnboardingCopy.models(bytes: model.neededBytes)
            copy.title = OnboardingCopy.downloadingTitle
            if case .running(let done, let total, let minutes) = model.stepDownload {
                copy.body = OnboardingCopy.downloading(done: done, total: total, minutesLeft: minutes)
            }
            copy.secondary = OnboardingCopy.cancel
            copy.help = nil
            return copy
        case .microphone: return OnboardingCopy.microphone
        case .microphoneOff: return OnboardingCopy.microphoneOff
        case .admin: return OnboardingCopy.admin
        case .screenAudio: return OnboardingCopy.screenAudio
        case .relaunch:
            var copy = OnboardingCopy.relaunch
            copy.primary = RelaunchPlan.button(downloading: model.downloading, waiting: model.relaunchPlan.waiting)
            return copy
        case .notes:
            // After a failure, like the listening tools: the reason, "Use a File I Have…"
            // (the note writer's file from a colleague), Try Again, Not Now.
            var copy = OnboardingCopy.notes
            switch model.stepDownload {
            case .failed(let reason):
                copy.body = OnboardingCopy.downloadFailed(reason, oneFile: true)
                copy.primary = OnboardingCopy.tryAgain
                copy.action = OnboardingCopy.useFile
            case .importFailed(let reason):
                copy.body = OnboardingCopy.importFailed(reason)
                copy.action = OnboardingCopy.useFile
            default: break
            }
            return copy
        case .done: return OnboardingCopy.done(shortcut: Prefs.recordShortcut?.display)
        }
    }

    // MARK: Button area

    /// The only filled element on the screen. While something downloads, a
    /// progress bar takes its place (the button stays, hidden, to hold the size).
    private func primaryButton(_ page: OnboardingModel.Page, title: String) -> some View {
        let busy = page == .downloading || page == .checking
        // Pressed during a download: waiting for it, then the restart by itself.
        let waiting = (page == .relaunch && model.relaunchPlan.waiting) || (page == .notes && model.queuedStep == .notes)
        return ZStack {
            Button {
                if page == .done { model.primary(); finish() } else { model.primary() }
            } label: {
                Text(title).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.extraLarge)
            .keyboardShortcut(.defaultAction)
            .opacity(busy ? 0 : 1)
            .disabled(busy || waiting)
            .accessibilityHidden(busy)

            if busy {
                Group {
                    if case .running(let done, let total, _) = model.stepDownload {
                        ProgressView(value: Double(done), total: Double(max(total, 1)))
                    } else {
                        ProgressView()
                    }
                }
                .progressViewStyle(.linear)
                .accessibilityLabel(page == .checking ? OnboardingCopy.checking : OnboardingCopy.downloadingTitle)
            }
        }
        .frame(width: 280)
    }

    /// Always takes its line, so the button above never moves.
    @ViewBuilder
    private func secondaryLink(_ page: OnboardingModel.Page, title: String?) -> some View {
        if let title {
            Button(title) {
                // "Not Now" with no other step left: close; the menu bar keeps "Finish getting ready".
                if page == .models && model.stepDownload.failed && model.notNowCloses { finish() } else { model.secondary() }
            }
                .buttonStyle(.link)
                .font(.body)
        } else {
            Text(" ").font(.body).hidden().accessibilityHidden(true)
        }
    }
}

/// Hero, headline and body, then whatever this screen shows to help.
private struct OnboardingPage: View {
    let page: OnboardingModel.Page
    let copy: OnboardingCopy.Screen
    @ObservedObject var model: OnboardingModel

    @State private var helpShown = false

    var body: some View {
        VStack(spacing: 0) {
            OnboardingHero(page: page, step: model.currentStep, ticking: model.ticking)
                .padding(.bottom, 24)
            Text(copy.title)
                .font(.largeTitle.bold())
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, 10)
            Text(markdown(copy.body))
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 430)
                .fixedSize(horizontal: false, vertical: true)
            help
            extra
                .padding(.top, 28)
        }
        .frame(maxWidth: .infinity)
    }

    /// "Can't download?" and the like: one short paragraph, shown when asked for.
    /// Or, in its place, a small link that acts ("Use a File I Have…" after a failure).
    @ViewBuilder
    private var help: some View {
        if let action = copy.action {
            Button(action) { model.action() }
                .buttonStyle(.link)
                .font(.callout)
                .padding(.top, 12)
        } else if let help = copy.help {
            Group {
                if helpShown {
                    Text(help.text)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 400)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                } else {
                    Button(help.link) { withAnimation(.easeOut(duration: 0.2)) { helpShown = true } }
                        .buttonStyle(.link)
                        .font(.callout)
                }
            }
            .padding(.top, 12)
        }
    }

    @ViewBuilder
    private var extra: some View {
        switch page {
        case .welcome:
            VStack(alignment: .leading, spacing: 18) {
                ForEach(OnboardingCopy.features, id: \.self) { FeatureRow(feature: $0) }
            }
            .frame(width: 380, alignment: .leading)
        case .microphone:
            PermissionAlertSketch()
        case .microphoneOff:
            SettingsRowSketch(pane: "Microphone", title: "Earl")
        case .screenAudio:
            SettingsRowSketch(pane: "Screen & System Audio Recording", title: "Earl")
        case .relaunch where model.relaunchPlan.waiting:
            Label(model.relaunchHeld ? OnboardingCopy.relaunchesAfterMeeting : OnboardingCopy.relaunchesByItself,
                  systemImage: "clock")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .relaunch where model.download.failed:
            Label(OnboardingCopy.relaunchDownloadFailed, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .notes where model.queuedStep == .notes:
            Label(OnboardingCopy.startsAfterTools, systemImage: "clock")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .admin where model.copiedNote:
            Label(OnboardingCopy.copiedLine, systemImage: "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(.secondary)
                .symbolRenderingMode(.multicolor)
        case .done where model.whereShown:
            VStack(spacing: 14) {
                MenuBarSketch()
                Text(OnboardingCopy.whereEarlLives)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .transition(.opacity)
        default:
            EmptyView()
        }
    }

    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

/// Slot 1: Earl's face on the welcome and done screens, a large symbol on the steps.
/// When a step is done, a green check takes the symbol's place for a moment.
private struct OnboardingHero: View {
    let page: OnboardingModel.Page
    var step: SetupStep?
    let ticking: Bool

    var body: some View {
        Group {
            switch page {
            case .welcome, .done:
                EarlAvatar(size: 88, glintOnAppear: true)
                    .accessibilityLabel("Earl")
            default:
                Image(systemName: ticking ? "checkmark.circle.fill" : symbol)
                    .font(.system(size: 56))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(ticking ? AnyShapeStyle(.green) : AnyShapeStyle(.tint))
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.pulse, isActive: page == .downloading)
                    .accessibilityLabel(ticking ? "Done" : "")
                    .accessibilityHidden(!ticking)
            }
        }
        .frame(height: 96)
        .animation(.easeOut(duration: 0.25), value: ticking)
    }

    private var symbol: String {
        switch page {
        case .downloading where step == .notes, .checking where step == .notes: "text.document"
        case .models, .downloading, .checking: "arrow.down.circle"
        case .microphone, .microphoneOff: "mic.fill"
        case .admin: "building.2.fill"
        case .screenAudio: "speaker.wave.2.fill"
        case .relaunch: "arrow.clockwise"
        case .notes: "text.document"
        case .welcome, .done: ""
        }
    }
}

/// Apple's What's New row: a symbol in the accent colour, a bold title, one quiet line.
private struct FeatureRow: View {
    let feature: OnboardingCopy.Feature

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: feature.symbol)
                .font(.system(size: 26))
                .foregroundStyle(.tint)
                .frame(width: 36)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(feature.title).font(.headline)
                Text(feature.detail).font(.body).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Page dots above the button, no numbers.
private struct PageDots: View {
    let count: Int
    let index: Int

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<count, id: \.self) { i in
                Circle()
                    .fill(i == index ? AnyShapeStyle(.primary) : AnyShapeStyle(.quaternary))
                    .frame(width: 7, height: 7)
            }
        }
        .opacity(count > 1 ? 1 : 0)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(index + 1) of \(count)")
        .animation(.easeOut(duration: 0.2), value: index)
    }
}

// MARK: - Show, don't describe

/// The row in System Settings with Earl's switch, drawn with the real
/// controls so it looks like the place the user is about to see. The switch
/// turns on by itself every few seconds (once, with Reduce Motion).
struct SettingsRowSketch: View {
    let pane: String
    let title: String

    @State private var on = DemoMode.isActive // a still picture shows the switch on
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(pane)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 10)
            VStack(spacing: 0) {
                placeholderRow
                Divider().padding(.leading, 44)
                HStack(spacing: 10) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 24, height: 24)
                    Text(title).font(.body)
                    Spacer()
                    Toggle(title, isOn: $on)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .controlSize(.small)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
        }
        .frame(width: 340)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("In System Settings, under \(pane), the switch next to \(title) is turned on.")
        .task {
            if reduceMotion || DemoMode.isActive { on = true; return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.2))
                withAnimation(.spring(duration: 0.35)) { on = true }
                try? await Task.sleep(for: .seconds(3))
                withAnimation(.easeOut(duration: 0.2)) { on = false }
            }
        }
    }

    /// Another app above Earl's row, greyed out: the list, without naming anyone.
    private var placeholderRow: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 5).fill(.quaternary).frame(width: 24, height: 24)
            RoundedRectangle(cornerRadius: 3).fill(.quaternary).frame(width: 90, height: 9)
            Spacer()
            Toggle("", isOn: .constant(false)).toggleStyle(.switch).labelsHidden().controlSize(.small).opacity(0.5)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

/// macOS's microphone question, with "Allow" ringed: what to click when it appears.
private struct PermissionAlertSketch: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 36, height: 36)
            Text("“Earl” would like to access the microphone.")
                .font(.callout.weight(.semibold))
                .multilineTextAlignment(.center)
            HStack(spacing: 8) {
                fakeButton("Don’t Allow", ringed: false)
                fakeButton("Allow", ringed: true)
            }
        }
        .padding(16)
        .frame(width: 260)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("macOS asks if Earl may use the microphone. Click Allow.")
    }

    /// Drawn, not a Button: the screen's only real button stays the blue one.
    private func fakeButton(_ title: String, ringed: Bool) -> some View {
        Text(title)
            .font(.callout)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7).fill(.quaternary))
            .overlay {
                if ringed {
                    RoundedRectangle(cornerRadius: 9).strokeBorder(.tint, lineWidth: 2).padding(-3)
                }
            }
    }
}

/// The right end of the menu bar, Earl's monocle ringed.
private struct MenuBarSketch: View {
    var body: some View {
        HStack(spacing: 16) {
            Image(nsImage: MenuBarIcon.image(recording: false, offer: false))
                .renderingMode(.template)
                .padding(5)
                .overlay(Circle().strokeBorder(.tint, lineWidth: 2))
            Image(systemName: "wifi")
            Image(systemName: "battery.75percent")
            Image(systemName: "switch.2")
            Text("9:41").monospacedDigit()
        }
        .font(.callout)
        .foregroundStyle(.primary)
        .padding(.horizontal, 14)
        .frame(width: 340, height: 34, alignment: .trailing)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Earl's monocle, in the menu bar at the top right of the screen.")
    }
}
