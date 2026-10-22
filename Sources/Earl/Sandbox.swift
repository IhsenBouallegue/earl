import Foundation

/// A copy of Earl with data of its own, so it can run beside the real one
/// (rehearsals, UI checks, parallel test runs):
///
///     Earl --sandbox <folder>        (or EARL_SANDBOX=<folder>)
///
/// Everything the copy keeps lives under the folder: settings in `settings.plist`,
/// meetings and Application Support under `home/`. The system-wide things the
/// real Earl owns stay off (record shortcut, call detection, calendar
/// reminders, notifications, update checks, moving into Applications).
/// macOS permissions belong to the app, not to a copy, so they can't be
/// separated; the setup rehearsal pretends them instead.
enum Sandbox {
    /// The sandbox folder, nil in a normal run.
    static let root: URL? = folder(arguments: CommandLine.arguments, environment: ProcessInfo.processInfo.environment)

    static var isActive: Bool { root != nil }

    /// Where the copy's meetings and Application Support live. The demo's
    /// throwaway home takes the same place (see DemoMode).
    static let home: URL? = DemoMode.home ?? root?.appendingPathComponent("home", isDirectory: true)

    /// The copy's settings; `UserDefaults.standard` in a normal run.
    static let defaults: UserDefaults = root.flatMap(defaults(in:)) ?? .standard

    /// The defaults domain Earl's settings live in: the app's, or the sandbox file.
    static var domain: String { root.map(settingsPath(in:)) ?? Bundle.main.bundleIdentifier ?? "" }

    // MARK: Pure parts (tested)

    static func folder(arguments: [String], environment: [String: String]) -> URL? {
        var path: String?
        if let i = arguments.firstIndex(of: "--sandbox"), i + 1 < arguments.count, !arguments[i + 1].hasPrefix("--") {
            path = arguments[i + 1]
        } else if let fromEnvironment = environment["EARL_SANDBOX"], !fromEnvironment.isEmpty {
            path = fromEnvironment
        }
        return path.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL }
    }

    /// An absolute path as the suite name keeps the settings in that file
    /// (the ".plist" is added by macOS) and out of ~/Library/Preferences.
    static func settingsPath(in folder: URL) -> String {
        folder.appendingPathComponent("settings", isDirectory: false).path
    }

    static func defaults(in folder: URL) -> UserDefaults? {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return UserDefaults(suiteName: settingsPath(in: folder))
    }
}
