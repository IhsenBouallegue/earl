import Foundation
import Sparkle

/// D-4: updates from the feed in Info.plist (SUFeedURL), EdDSA-signed.
/// Background checks only speak up when there's an update. Without a feed
/// (tests, `swift run`, a build not yet bundled) the updater never starts.
@MainActor
final class Updates: NSObject, SPUUpdaterDelegate {
    static let shared = Updates()
    /// Set by AppState: a meeting, a notes-server lease or a download is under way.
    var isBusy: () -> Bool = { false }
    private var retry: Timer?

    nonisolated static var hasFeed: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
    }

    private lazy var controller = SPUStandardUpdaterController(startingUpdater: Self.hasFeed,
                                                               updaterDelegate: self, userDriverDelegate: nil)

    /// An update may install only when nothing is recorded, processed, served or downloaded.
    nonisolated static func mayInstallNow(busy: Bool, serving: Bool, downloading: Bool) -> Bool {
        !busy && !serving && !downloading
    }

    func start() { if Self.hasFeed { _ = controller } }
    func checkNow() { if isRunning { controller.checkForUpdates(nil) } }
    /// The updater started, so checks make sense in this build.
    var isRunning: Bool { Self.hasFeed }
    var canCheck: Bool { Self.hasFeed && controller.updater.canCheckForUpdates }
    var automaticallyChecks: Bool {
        get { Self.hasFeed && controller.updater.automaticallyChecksForUpdates }
        set { if Self.hasFeed { controller.updater.automaticallyChecksForUpdates = newValue } }
    }

    nonisolated func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                             untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        MainActor.assumeIsolated {
            guard isBusy() else { return false }
            retry?.invalidate()
            // Try again every minute until the meeting is done.
            retry = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] timer in
                MainActor.assumeIsolated {
                    guard let self, !self.isBusy() else { return }
                    timer.invalidate()
                    self.retry = nil
                    installHandler()
                }
            }
            return true
        }
    }
}
