import AppKit

/// D-2: Earl must live in an Applications folder: a copy run from Downloads is
/// translocated (read-only, random path) and can't update itself (D-4).
enum AppLocation {
    static func needsMove(bundlePath: String, home: String) -> Bool {
        if bundlePath.hasPrefix("/Applications/") || bundlePath.hasPrefix(home + "/Applications/") { return false }
        if bundlePath.contains("/build/") { return false }
        return true
    }

    enum Outcome: Equatable { case stay, moving }

    enum MoveAction: Equatable {
        /// Copy this Earl over (or into) ~/Applications.
        case install
        /// A same-or-newer or running copy is already there: open it, quit this one.
        case useExisting
    }

    /// Never replace a copy that is running or at least as new as this one.
    static func moveAction(destExists: Bool, destRunning: Bool, destBuild: String?, ownBuild: String?) -> MoveAction {
        guard destExists else { return .install }
        if destRunning { return .useExisting }
        guard let destBuild, let ownBuild else { return .install }
        return destBuild.compare(ownBuild, options: .numeric) == .orderedAscending ? .install : .useExisting
    }

    @MainActor private static var asked = false

    /// Copies Earl to ~/Applications, clears quarantine, relaunches from there.
    /// Call once, from the launch path; it returns after the modal resolves.
    /// `.moving` means the moved copy is opening and this one is about to quit.
    @MainActor static func offerMove(onOpenFailed: @escaping @MainActor () -> Void) -> Outcome {
        guard Bundle.main.bundleIdentifier != nil, !DemoMode.isActive, !Sandbox.isActive, !asked else { return .stay }
        asked = true
        let here = Bundle.main.bundleURL.resolvingSymlinksInPath()
        let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath()
        guard needsMove(bundlePath: here.path, home: home.path) else { return .stay }
        if here.path == home.appendingPathComponent("Applications/Earl.app").resolvingSymlinksInPath().path { return .stay }
        let alert = NSAlert()
        alert.messageText = "Move Earl to your Applications folder?"
        alert.informativeText = "Earl can only keep itself up to date from there."
        alert.addButton(withTitle: "Move")
        alert.addButton(withTitle: "Not now")
        NSApp.activate() // a menu-bar app at launch: bring the question to the front
        guard alert.runModal() == .alertFirstButtonReturn else { return .stay }
        let dir = home.appendingPathComponent("Applications", isDirectory: true)
        let dest = dir.appendingPathComponent("Earl.app")
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let exists = fm.fileExists(atPath: dest.path)
            let running = NSWorkspace.shared.runningApplications.first {
                $0.bundleURL?.resolvingSymlinksInPath().path == dest.resolvingSymlinksInPath().path
            }
            let build = { (u: URL) in Bundle(url: u)?.object(forInfoDictionaryKey: "CFBundleVersion") as? String }
            let action = moveAction(destExists: exists, destRunning: running != nil,
                                    destBuild: exists ? build(dest) : nil, ownBuild: build(here))
            if action == .useExisting {
                if let running {
                    running.activate()
                    NSApp.terminate(nil)
                } else {
                    open(dest, newInstance: false, onFailed: onOpenFailed)
                }
                return .moving
            }
            // Copy beside the old one first, so a failed copy never leaves no app.
            let staged = dir.appendingPathComponent("Earl.app.moving")
            if fm.fileExists(atPath: staged.path) { try fm.removeItem(at: staged) }
            try fm.copyItem(at: here, to: staged)
            if exists { try fm.trashItem(at: dest, resultingItemURL: nil) }
            try fm.moveItem(at: staged, to: dest)
            let xattr = try Process.run(URL(fileURLWithPath: "/usr/bin/xattr"), arguments: ["-dr", "com.apple.quarantine", dest.path])
            xattr.waitUntilExit()
            guard xattr.terminationStatus == 0 else {
                let a = NSAlert()
                a.messageText = "Earl is copied, but macOS still blocks it"
                a.informativeText = "Open Terminal and paste:\n\nxattr -dr com.apple.quarantine ~/Applications/Earl.app\n\nThen open Earl from your Applications folder. (See docs/INSTALL.md.)"
                a.runModal()
                return .stay
            }
            open(dest, newInstance: true, onFailed: onOpenFailed)
            return .moving
        } catch {
            NSAlert(error: error).runModal()
            return .stay
        }
    }

    /// Opens the moved copy, then quits this one only if it really opened; else `onFailed`.
    @MainActor private static func open(_ dest: URL, newInstance: Bool, onFailed: @escaping @MainActor () -> Void) {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = newInstance
        NSWorkspace.shared.openApplication(at: dest, configuration: config) { _, error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let error {
                        NSAlert(error: error).runModal()
                        onFailed() // this copy stays, so it starts normally
                    } else {
                        NSApp.terminate(nil)
                    }
                }
            }
        }
    }
}
