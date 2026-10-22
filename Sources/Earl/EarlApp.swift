import SwiftUI

/// Opening Earl (Finder, Spotlight, Dock) shows the Meetings window, so the app
/// stays reachable even when the menu bar icon is hidden behind the notch.
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var openMeetings: (() -> Void)?
    /// D-2: the first-run window ("Finish getting ready").
    static var openOnboarding: (() -> Void)?

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        Self.openMeetings?()
        return false
    }

    // D-3: the built-in notes server never outlives Earl.
    func applicationWillTerminate(_ notification: Notification) {
        BuiltInServer.killOrphan()
    }

    // R3-2: earl://meeting/<id> links from reminders.
    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach(EarlLink.open)
    }
}

/// U-0: `--demo` renders the UI with made-up data to PNGs instead of running
/// the app (see DemoMode.swift and tools/snapshot-ui.sh).
@main
enum Launcher {
    @MainActor static func main() {
        if DemoMode.isActive { DemoMode.run() } else { EarlApp.main() }
    }
}

struct EarlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarPanel()
                .environmentObject(state)
                .environmentObject(state.engine)
        } label: {
            MenuBarLabel()
                .environmentObject(state)
        }
        .menuBarExtraStyle(.window)

        Window("Earl", id: "meetings") {
            MeetingsView()
                .environmentObject(state)
                .environmentObject(state.engine)
        }
        .defaultSize(width: 1180, height: 760) // U-3
        // No title bar or toolbar, so the paper itself moves the window.
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        .commands {
            SidebarCommands()
            CommandGroup(after: .newItem) {
                Button(state.isRecording ? "Stop Recording" : "Start Recording") { state.toggleRecording() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        // D-2: the first-run window, Apple-style (system background, not the paper).
        Window("Set Up Earl", id: Onboarding.windowID) {
            OnboardingWindow(engine: state.engine, hasMeetings: !state.meetings.isEmpty)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .windowBackgroundDragBehavior(.enabled)
        .defaultPosition(.center)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Settings {
            ScrollView {
                EngineView()
                    .padding(20)
            }
            .paperBackground() // U-3
            .frame(width: 640, height: 720)
            .environmentObject(state)
            .environmentObject(state.engine)
        }
    }
}

struct MenuBarLabel: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.openWindow) private var openWindow

    /// The post-launch setup: windows, onboarding or meetings, links.
    private func startNormally() {
        AppDelegate.openMeetings = {
            openWindow(id: "meetings")
            NSApp.activate()
        }
        AppDelegate.openOnboarding = {
            openWindow(id: Onboarding.windowID)
            NSApp.activate()
        }
        // D-3: the restart after a download never ends a call being recorded or a meeting being processed.
        OnboardingModel.appBusy = { [state] in state.isBusy }
        // D-2: a first run opens the setup window instead; "Get Started" shows the meetings.
        if Onboarding.shouldOpenAtLaunch(state.engine) {
            AppDelegate.openOnboarding?()
        } else {
            AppDelegate.openMeetings?()
        }
        EarlLink.handler = { id in // R3-2
            state.selection = .meeting(id)
            AppDelegate.openMeetings?()
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            MenuBarIconImage(detector: state.callDetector, recording: state.isRecording) // R2-6: offer badge
            if state.isRecording {
                Text(state.elapsedText).monospacedDigit()
            }
        }
        .onAppear {
            // The label always exists, so it hands openWindow to the app delegate
            // and shows the main window on launch.
            // D-2: the single move offer comes first and blocks until answered; a copy
            // that is moving quits, so it must not consume the onboarding flags.
            if AppLocation.offerMove(onOpenFailed: { startNormally() }) == .moving { return }
            startNormally()
        }
    }
}
