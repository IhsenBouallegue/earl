import AppKit
import CoreAudio
import SwiftUI
import UserNotifications

// R1-2: notice when a call app starts using the microphone, offer to record,
// and offer to stop when the call ends.

// MARK: - Settings

extension Prefs.Key {
    static let callStartAction = "callStartAction"
    static let callEndAction = "callEndAction"
    /// Comma-separated `CallApp.id`s the user switched off. Empty means all on.
    static let callAppsOff = "callAppsOff"
}

extension Prefs {
    static var callStartAction: CallDetectionMachine.StartAction {
        Prefs.defaults.string(forKey: Key.callStartAction).flatMap { .init(rawValue: $0) } ?? .ask
    }
    static var callEndAction: CallDetectionMachine.EndAction {
        Prefs.defaults.string(forKey: Key.callEndAction).flatMap { .init(rawValue: $0) } ?? .ask
    }
    static var callAppsOff: Set<String> {
        CallApps.parseOff(Prefs.defaults.string(forKey: Key.callAppsOff) ?? "")
    }
}

// MARK: - Known apps

/// An app (or family of apps) that counts as a call when it uses the mic.
struct CallApp: Identifiable, Hashable {
    let id: String
    let name: String
    /// Used in "Teams is using your mic" and "Teams call". nil means use the
    /// running app's own name (browsers).
    let shortName: String?
    let prefixes: [String]
    var settingsLabel: String { id == "browsers" ? "Browsers (Google Meet, Teams on the web…)" : name }
}

enum CallApps {
    static let all: [CallApp] = [
        .init(id: "teams", name: "Microsoft Teams", shortName: "Teams",
              // The VDI plugin is Teams running inside a Citrix desktop.
              prefixes: ["com.microsoft.teams2", "com.microsoft.teams", "com.microsoft.vdi2.teams.citrix"]),
        .init(id: "zoom", name: "Zoom", shortName: "Zoom", prefixes: ["us.zoom.xos"]),
        .init(id: "webex", name: "Webex", shortName: "Webex",
              prefixes: ["com.cisco.webexmeetingsapp", "Cisco-Systems.Spark"]),
        .init(id: "slack", name: "Slack", shortName: "Slack", prefixes: ["com.tinyspeck.slackmacgap"]),
        .init(id: "facetime", name: "FaceTime", shortName: "FaceTime", prefixes: ["com.apple.FaceTime"]),
        .init(id: "discord", name: "Discord", shortName: "Discord", prefixes: ["com.hnc.Discord"]),
        .init(id: "browsers", name: "Browsers", shortName: nil,
              prefixes: ["com.google.Chrome", "com.microsoft.edgemac", "com.apple.Safari", "com.apple.WebKit.GPU",
                         "org.mozilla.firefox", "company.thebrowser.Browser", "com.brave.Browser"]),
    ]

    /// The call app a bundle ID belongs to. Helpers match their app's prefix
    /// (`com.google.Chrome.helper` → Chrome), but only at a dot, so
    /// `com.microsoft.teamsX` doesn't count as Teams. The longest prefix wins.
    static func match(_ bundleID: String) -> (app: CallApp, prefix: String)? {
        let id = bundleID.lowercased()
        var best: (app: CallApp, prefix: String)?
        for app in all {
            for prefix in app.prefixes {
                let p = prefix.lowercased()
                guard id == p || id.hasPrefix(p + ".") else { continue }
                if prefix.count > (best?.prefix.count ?? 0) { best = (app, prefix) }
            }
        }
        return best
    }

    /// WebKit's helper processes are shared by every app with a web view
    /// (Safari, Raycast…) and are named after it: "Safari Graphics and Media".
    static func webKitHostName(_ processName: String?) -> String? {
        guard let name = processName else { return nil }
        for suffix in [" Graphics and Media", " Web Content", " Networking"] where name.hasSuffix(suffix) {
            let host = String(name.dropLast(suffix.count))
            return host.isEmpty ? nil : host
        }
        return nil
    }

    static func parseOff(_ raw: String) -> Set<String> {
        Set(raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    static func shortName(name: String, bundleID: String?) -> String {
        bundleID.flatMap { match($0)?.app.shortName } ?? name
    }
}

extension MeetingInfo {
    /// "Teams call" when the recording belongs to a detected call.
    var callLabel: String? {
        callApp.map { "\(CallApps.shortName(name: $0, bundleID: callAppBundleID)) call" }
    }
}

// MARK: - Decisions

/// The pure decision logic, fed with timestamped events so it can be tested
/// without Core Audio. App keys are opaque strings (the app's bundle ID).
struct CallDetectionMachine {
    enum StartAction: String, CaseIterable { case ask, record, nothing }
    enum EndAction: String, CaseIterable { case ask, stop, nothing }

    enum Decision: Equatable {
        case offerRecording(String)
        case autoStart(String)
        case offerStop(String)
        case autoStop(String)
        /// Remove any pending offer (start or stop): banner and notification.
        case withdrawOffer
    }

    /// R2-6: short, so the offer shows while you're still settling into the
    /// call. A quick mic test still gets withdrawn as soon as its input stops.
    static let debounce: TimeInterval = 2
    /// After "Not now", the app's input must stay off this long before Earl asks again.
    static let cooldown: TimeInterval = 120
    /// Some apps release the mic while muted, so wait before calling the call over.
    static let endGrace: TimeInterval = 20

    var startAction = StartAction.ask
    var endAction = EndAction.ask

    /// Apps running input now, with the time they started.
    private(set) var running: [String: Date] = [:]
    private(set) var pendingOffer: String?
    private(set) var pendingStop: String?
    private(set) var isRecording = false

    private var stoppedAt: [String: Date] = [:]
    private var declined: Set<String> = []
    /// Apps whose current stretch of input was already offered or recorded.
    private var handled: Set<String> = []
    /// Apps covered by the pending offer; "Not now" declines all of them.
    private var offerApps: Set<String> = []
    /// Apps that used the mic during the recording, in order. The first one names the call.
    private var callApps: [String] = []
    private var endHandled = false

    /// The call the current (or an about-to-start) recording belongs to.
    var callApp: String? { isRecording ? callApps.first : Self.earliest(running) }
    /// Whether anything needs periodic ticks.
    var isActive: Bool { !running.isEmpty || isRecording }

    /// R2-6: when the next start offer could fire, so the detector can wake
    /// right then instead of waiting for its periodic scan.
    var nextOfferCheck: Date? {
        guard !isRecording, pendingOffer == nil, startAction != .nothing else { return nil }
        return running.filter { !handled.contains($0.key) && !declined.contains($0.key) }
            .values.min()?.addingTimeInterval(Self.debounce)
    }

    mutating func inputStarted(_ app: String, at now: Date) -> [Decision] {
        guard running[app] == nil else { return tick(at: now) }
        running[app] = now
        if declined.contains(app), let stopped = stoppedAt[app], now.timeIntervalSince(stopped) >= Self.cooldown {
            declined.remove(app)
        }
        stoppedAt[app] = nil
        var out: [Decision] = []
        if pendingOffer != nil {
            offerApps.insert(app)
            handled.insert(app)
        }
        if isRecording {
            if !callApps.contains(app) { callApps.append(app) }
            handled.insert(app)
            endHandled = false
            if pendingStop != nil {
                pendingStop = nil
                out.append(.withdrawOffer)
            }
        }
        return out + tick(at: now)
    }

    mutating func inputStopped(_ app: String, at now: Date) -> [Decision] {
        guard running.removeValue(forKey: app) != nil else { return tick(at: now) }
        stoppedAt[app] = now
        handled.remove(app)
        var out: [Decision] = []
        if pendingOffer != nil, offerApps.remove(app) != nil, offerApps.isDisjoint(with: running.keys) {
            pendingOffer = nil
            offerApps = []
            out.append(.withdrawOffer)
        }
        return out + tick(at: now)
    }

    mutating func recordingStarted(at now: Date) -> [Decision] {
        isRecording = true
        endHandled = false
        pendingStop = nil
        // Recording started by hand during a call still counts as that call.
        callApps = running.sorted { Self.order($0, $1) }.map(\.key)
        handled.formUnion(running.keys)
        guard pendingOffer != nil else { return [] }
        pendingOffer = nil
        offerApps = []
        return [.withdrawOffer]
    }

    mutating func recordingStopped(at now: Date) -> [Decision] {
        isRecording = false
        callApps = []
        endHandled = false
        // Don't offer again for a call that's still going.
        handled.formUnion(running.keys)
        guard pendingStop != nil else { return [] }
        pendingStop = nil
        return [.withdrawOffer]
    }

    /// "Not now" on the start offer.
    mutating func decline() -> [Decision] {
        guard let offered = pendingOffer else { return [] }
        declined.formUnion(offerApps)
        declined.insert(offered)
        pendingOffer = nil
        offerApps = []
        return [.withdrawOffer]
    }

    /// "Keep recording" on the stop offer. Asks again only if the call resumes and ends again.
    mutating func keepRecording() -> [Decision] {
        guard pendingStop != nil else { return [] }
        pendingStop = nil
        return [.withdrawOffer]
    }

    /// Forgets everything but the recording, for example after the Mac wakes.
    mutating func reset(at now: Date) -> [Decision] {
        let hadOffer = pendingOffer != nil || pendingStop != nil
        running = [:]
        stoppedAt = [:]
        declined = []
        handled = []
        pendingOffer = nil
        pendingStop = nil
        offerApps = []
        endHandled = false
        for app in callApps { stoppedAt[app] = now }
        return hadOffer ? [.withdrawOffer] : []
    }

    mutating func tick(at now: Date) -> [Decision] {
        var out: [Decision] = []

        if !isRecording, pendingOffer == nil, startAction != .nothing {
            let ready = running.filter {
                !handled.contains($0.key) && !declined.contains($0.key)
                    && now.timeIntervalSince($0.value) >= Self.debounce
            }
            if let app = Self.earliest(ready) {
                // One offer for everything running now, named after the app that started first.
                handled.formUnion(running.keys)
                if startAction == .ask {
                    pendingOffer = app
                    offerApps = Set(running.keys).subtracting(declined).union([app])
                    out.append(.offerRecording(app))
                } else {
                    out.append(.autoStart(app))
                }
            }
        }

        if isRecording, !endHandled, endAction != .nothing, let app = callApps.first,
           callApps.allSatisfy({ running[$0] == nil }),
           let last = callApps.compactMap({ stoppedAt[$0] }).max(),
           now.timeIntervalSince(last) >= Self.endGrace {
            endHandled = true
            if endAction == .ask {
                pendingStop = app
                out.append(.offerStop(app))
            } else {
                out.append(.autoStop(app))
            }
        }
        return out
    }

    private static func order(_ a: (key: String, value: Date), _ b: (key: String, value: Date)) -> Bool {
        a.value == b.value ? a.key < b.key : a.value < b.value
    }

    private static func earliest(_ apps: [String: Date]) -> String? {
        apps.min { order($0, $1) }?.key
    }
}

// MARK: - Detector

/// An app using the microphone, with helper processes folded into their app.
struct DetectedApp: Identifiable, Hashable {
    let key: String
    let name: String
    let bundleID: String
    let pid: pid_t
    let callApp: CallApp?

    var id: String { key }
    var shortName: String { callApp?.shortName ?? name }
    var icon: NSImage? { NSRunningApplication(processIdentifier: pid)?.icon }
}

/// Watches which processes run audio input, using the Core Audio process
/// objects, and turns the machine's decisions into notifications and actions.
@MainActor
final class CallDetector: NSObject, ObservableObject {
    /// The pending "record this call?" offer, shown in the menu bar panel.
    @Published private(set) var offer: DetectedApp?
    /// R2-6: the pending "call ended?" offer, for the floating panel.
    @Published private(set) var stopOffer: DetectedApp?
    /// R2-6: an armed calendar recording can claim a detected call and start
    /// right away instead of offering. Returns true when it did.
    var claimsCall: ((DetectedApp) -> Bool)?
    /// R2-6: automatic starts and stops, for the floating panel's confirmations.
    var onAnnounce: ((_ title: String, _ body: String, _ recording: Bool) -> Void)?
    /// Everything using the mic right now, watched or not.
    @Published private(set) var liveInputs: [DetectedApp] = []
    @Published private(set) var notificationsDenied = false

    private var machine = CallDetectionMachine()
    private var known: [String: DetectedApp] = [:]
    private var listeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var listListener: AudioObjectPropertyListenerBlock?
    private var timer: Timer?
    private var offerCheck: Timer? // R2-6
    private var wakeObserver: NSObjectProtocol?
    private var onRecord: (() -> Void)?
    private var onStop: (() -> Void)?

    private static let offerID = "earl.call.offer"
    private static let stopID = "earl.call.stop"
    private static let offerCategory = "EARL_CALL_START"
    private static let stopCategory = "EARL_CALL_END"
    private static var canNotify: Bool { Bundle.main.bundleIdentifier != nil }

    func start(record: @escaping () -> Void, stop: @escaping () -> Void) {
        onRecord = record
        onStop = stop

        if Self.canNotify {
            let center = UNUserNotificationCenter.current()
            center.delegate = self
            center.setNotificationCategories([
                UNNotificationCategory(identifier: Self.offerCategory, actions: [
                    UNNotificationAction(identifier: "record", title: "Record"),
                    UNNotificationAction(identifier: "notnow", title: "Not now"),
                ], intentIdentifiers: []),
                UNNotificationCategory(identifier: Self.stopCategory, actions: [
                    UNNotificationAction(identifier: "stop", title: "Stop"),
                    UNNotificationAction(identifier: "keep", title: "Keep recording"),
                ], intentIdentifiers: []),
            ])
            refreshNotificationStatus()
        }

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.rescan() }
        }
        var address = Self.address(kAudioHardwarePropertyProcessObjectList)
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block) == noErr {
            listListener = block
        }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.apply(self.machine.reset(at: Date()))
                self.rescan()
            }
        }

        rescan()
    }

    // MARK: Hooks from AppState

    /// Tells the detector a recording started. Returns the call it belongs to, if any.
    func recordingDidStart() -> DetectedApp? {
        apply(machine.recordingStarted(at: Date()))
        updateTimer()
        return machine.callApp.flatMap { known[$0] }
    }

    func recordingDidStop() {
        apply(machine.recordingStopped(at: Date()))
        updateTimer()
    }

    // MARK: Answers

    func accept() {
        onRecord?()
    }

    func decline() {
        apply(machine.decline())
    }

    /// R2-6: "Stop" on the stop offer in the floating panel.
    func stopFromOffer() {
        handle(action: "stop")
    }

    /// R2-6: "Keep recording" on the stop offer in the floating panel.
    func keepRecording() {
        handle(action: "keep")
    }

    func refreshNotificationStatus() {
        guard Self.canNotify else { return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let denied = settings.authorizationStatus == .denied
            Task { @MainActor [weak self] in self?.notificationsDenied = denied }
        }
    }

    // MARK: Scanning

    private func rescan() {
        let objects = Self.processObjects()
        syncListeners(objects)

        var apps: [String: DetectedApp] = [:]
        let ownPID = getpid()
        let ownBundle = Bundle.main.bundleIdentifier
        for object in objects where Self.isRunningInput(object) {
            let pid = Self.pid(object)
            // Earl records the mic itself while it records.
            guard pid != ownPID else { continue }
            let app = Self.resolve(bundleID: Self.bundleID(object), pid: pid)
            if let ownBundle, app.bundleID == ownBundle { continue }
            if apps[app.key] == nil { apps[app.key] = app }
        }

        let sorted = apps.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if sorted != liveInputs { liveInputs = sorted }

        let off = Prefs.callAppsOff
        let watched = apps.filter { $0.value.callApp.map { !off.contains($0.id) } ?? false }
        known.merge(watched) { _, new in new }

        machine.startAction = Prefs.callStartAction
        machine.endAction = Prefs.callEndAction
        let now = Date()
        var decisions: [CallDetectionMachine.Decision] = []
        for key in machine.running.keys where watched[key] == nil {
            decisions += machine.inputStopped(key, at: now)
        }
        for key in watched.keys.sorted() where machine.running[key] == nil {
            decisions += machine.inputStarted(key, at: now)
        }
        decisions += machine.tick(at: now)
        apply(decisions)
        updateTimer()
    }

    /// The safety net: re-scan every 3 s, but only while a watched app is
    /// using the mic or Earl is recording. Idle otherwise.
    private func updateTimer() {
        scheduleOfferCheck() // R2-6
        if machine.isActive, timer == nil {
            let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.rescan() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else if !machine.isActive, let timer {
            timer.invalidate()
            self.timer = nil
        }
    }

    /// R2-6: one wake-up at the debounce deadline, so offers show after about
    /// 2 s rather than at the next 3 s scan.
    private func scheduleOfferCheck() {
        offerCheck?.invalidate()
        offerCheck = nil
        guard let due = machine.nextOfferCheck else { return }
        let timer = Timer(fire: max(due, Date()).addingTimeInterval(0.05), interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.offerCheck = nil
                self?.rescan()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        offerCheck = timer
    }

    private func syncListeners(_ objects: [AudioObjectID]) {
        let current = Set(objects)
        for (object, block) in listeners where !current.contains(object) {
            var address = Self.address(kAudioProcessPropertyIsRunningInput)
            AudioObjectRemovePropertyListenerBlock(object, &address, .main, block)
            listeners[object] = nil
        }
        for object in objects where listeners[object] == nil {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated { self?.rescan() }
            }
            var address = Self.address(kAudioProcessPropertyIsRunningInput)
            if AudioObjectAddPropertyListenerBlock(object, &address, .main, block) == noErr {
                listeners[object] = block
            }
        }
    }

    // MARK: Decisions

    private func apply(_ decisions: [CallDetectionMachine.Decision]) {
        for decision in decisions {
            switch decision {
            case .offerRecording(let key):
                guard let app = known[key] else { continue }
                if claimsCall?(app) == true { continue } // R2-6: an armed recording starts instead
                offer = app
                post(id: Self.offerID, category: Self.offerCategory,
                     title: "\(app.name) is using your microphone", body: "Want Earl to take notes?")
            case .autoStart(let key):
                if let app = known[key], claimsCall?(app) == true { continue } // R2-6
                onRecord?()
                let app = known[key]
                announce(recording: true, title: app.map { "Recording your \($0.shortName) call" } ?? "Recording your call",
                         body: "Earl started because \(app?.name ?? "a call app") is using your microphone.")
            case .offerStop(let key):
                stopOffer = known[key] // R2-6
                post(id: Self.stopID, category: Self.stopCategory,
                     title: "Call ended?", body: "Earl is still recording.")
            case .autoStop(let key):
                onStop?()
                let app = known[key]
                announce(recording: false, title: "Stopped recording",
                         body: app.map { "Your \($0.shortName) call ended. Earl is taking notes." }
                            ?? "Your call ended. Earl is taking notes.")
            case .withdrawOffer:
                offer = nil
                stopOffer = nil // R2-6
                if Self.canNotify {
                    let center = UNUserNotificationCenter.current()
                    center.removeDeliveredNotifications(withIdentifiers: [Self.offerID, Self.stopID])
                    center.removePendingNotificationRequests(withIdentifiers: [Self.offerID, Self.stopID])
                }
            }
        }
    }

    /// A one-off notification, also shown in the floating panel (R2-6).
    private func announce(recording: Bool, title: String, body: String) {
        post(id: UUID().uuidString, category: nil, title: title, body: body)
        onAnnounce?(title, body, recording)
    }

    private func post(id: String, category: String?, title: String, body: String) {
        guard Self.canNotify else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let category { content.categoryIdentifier = category }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    fileprivate func handle(action: String) {
        switch action {
        case "record": accept()
        case "notnow": decline()
        case "stop":
            apply(machine.keepRecording()) // clears the pending stop
            onStop?()
        case "keep": apply(machine.keepRecording())
        default: break
        }
    }

    // MARK: Core Audio

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    static func processObjects() -> [AudioObjectID] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32 {
        var address = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : 0
    }

    static func pid(_ object: AudioObjectID) -> pid_t {
        var address = address(kAudioProcessPropertyPID)
        var value: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : -1
    }

    static func bundleID(_ object: AudioObjectID) -> String? {
        var address = address(kAudioProcessPropertyBundleID)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr,
              let id = value?.takeRetainedValue() as String?, !id.isEmpty else { return nil }
        return id
    }

    static func isRunningInput(_ object: AudioObjectID) -> Bool {
        uint32(object, kAudioProcessPropertyIsRunningInput) == 1
    }

    /// Folds helper processes into the app they belong to.
    static func resolve(bundleID raw: String?, pid: pid_t) -> DetectedApp {
        let process = NSRunningApplication(processIdentifier: pid)
        var bundleID = raw ?? process?.bundleIdentifier
        var owner = process
        if let id = bundleID, id.hasPrefix("com.apple.WebKit"),
           let host = CallApps.webKitHostName(process?.localizedName),
           let app = NSWorkspace.shared.runningApplications.first(where: {
               $0.localizedName == host && $0.bundleIdentifier?.hasPrefix("com.apple.WebKit") == false
           }) {
            owner = app
            bundleID = app.bundleIdentifier
        }

        if let id = bundleID, let match = CallApps.match(id) {
            // Name helpers after their app: com.google.Chrome.helper → Google Chrome.
            let main = match.prefix.hasPrefix("com.apple.WebKit")
                ? nil : NSRunningApplication.runningApplications(withBundleIdentifier: match.prefix).first
            let app = main ?? owner
            let appID = main?.bundleIdentifier ?? id
            return DetectedApp(key: appID, name: app?.localizedName ?? match.app.name, bundleID: appID,
                               pid: app?.processIdentifier ?? pid, callApp: match.app)
        }
        return DetectedApp(key: bundleID ?? "pid.\(pid)", name: owner?.localizedName ?? bundleID ?? "Process \(pid)",
                           bundleID: bundleID ?? "", pid: owner?.processIdentifier ?? pid, callApp: nil)
    }
}

extension CallDetector: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let action = response.actionIdentifier
        let id = response.notification.request.identifier // S-2
        await MainActor.run { if !BriefNudger.open(notificationID: id) { self.handle(action: action) } }
    }

    /// Show Earl's notifications even while one of its windows is in front.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}

// MARK: - Views

/// The offer at the top of the menu bar panel. U-5: the floating offer's
/// words on a white card; Earl himself is already in the panel's header.
struct CallOfferBanner: View {
    @ObservedObject var detector: CallDetector
    /// Names the meeting the call probably is.
    var calendar: CalendarService?

    var body: some View {
        if let app = detector.offer {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(EarlVoice.shallIRecord).font(.earlVoice(size: 20)).foregroundStyle(Paper.ink)
                    OfferCopy.callLine(app: app.shortName, event: calendar?.likelyEvent(for: app))
                        .font(.system(size: 14.5))
                        .foregroundStyle(Paper.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Button("Not now") { detector.decline() }
                        .buttonStyle(.paperSecondary)
                    Button { detector.accept() } label: { OfferMarkLabel(title: "Record", mark: .dot) }
                        .buttonStyle(.paperPrimary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .paperCard(padding: 14)
        }
    }
}

/// The "Call detection" card in Under the Hood.
struct CallDetectionSettings: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        CallDetectionCard(detector: state.callDetector)
    }
}

private struct CallDetectionCard: View {
    @ObservedObject var detector: CallDetector

    @AppStorage(Prefs.Key.callStartAction, store: Prefs.defaults) private var startAction = CallDetectionMachine.StartAction.ask
    @AppStorage(Prefs.Key.callEndAction, store: Prefs.defaults) private var endAction = CallDetectionMachine.EndAction.ask
    @AppStorage(Prefs.Key.callAppsOff, store: Prefs.defaults) private var appsOff = ""
    @AppStorage(Prefs.Key.showOffersOnScreen, store: Prefs.defaults) private var showOnScreen = true // R2-6

    var body: some View {
        Card(title: "Call detection",
             subtitle: "Earl notices when a call app starts using your microphone, so you don't have to remember Record.") {
            HStack {
                Text("When a call starts").font(.settingsRow)
                Spacer()
                Picker("When a call starts", selection: $startAction) {
                    Text("Ask me").tag(CallDetectionMachine.StartAction.ask)
                    Text("Record automatically").tag(CallDetectionMachine.StartAction.record)
                    Text("Do nothing").tag(CallDetectionMachine.StartAction.nothing)
                }
                .labelsHidden()
                .fixedSize()
            }
            HStack {
                Text("When the call ends").font(.settingsRow)
                Spacer()
                Picker("When the call ends", selection: $endAction) {
                    Text("Ask me").tag(CallDetectionMachine.EndAction.ask)
                    Text("Stop automatically").tag(CallDetectionMachine.EndAction.stop)
                    Text("Do nothing").tag(CallDetectionMachine.EndAction.nothing)
                }
                .labelsHidden()
                .fixedSize()
            }
            Text("Some apps let go of the mic while you're muted, which is why asking is the default.")
                .font(.settingsNote)
                .foregroundStyle(Paper.inkMuted)
                .fixedSize(horizontal: false, vertical: true)

            // R2-6
            Toggle("Show call offers on screen", isOn: $showOnScreen)
                .font(.settingsRow)
            Text("A small panel in the top right corner, next to the notifications. It stays visible while you share your screen, and the people watching don't see it.")
                .font(.settingsNote)
                .foregroundStyle(Paper.inkMuted)
                .fixedSize(horizontal: false, vertical: true)

            if detector.notificationsDenied {
                HStack {
                    StatusLabel(kind: .attention, text: "Notifications are off, so offers only show in the menu bar.")
                        .font(.settingsRow)
                    Spacer()
                    Button("Open Settings") {
                        NSWorkspace.shared.open(
                            URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                    }
                    .buttonStyle(.paperSecondary)
                }
            }

            SettingsRule()

            Text("Apps that count as calls").font(.settingsRowTitle)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(CallApps.all) { app in
                    Toggle(app.settingsLabel, isOn: binding(for: app))
                }
            }
            .font(.settingsRow)

            SettingsRule()

            Text("Using the microphone right now").font(.settingsRowTitle)
            if detector.liveInputs.isEmpty {
                Text("Nobody. The mic is enjoying some quiet time.")
                    .font(.settingsNote)
                    .foregroundStyle(Paper.inkMuted)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(detector.liveInputs) { app in
                        HStack(spacing: 10) {
                            AppIcon(app: app, size: 20)
                            Text(app.name).font(.settingsRow)
                            Text(app.bundleID)
                                .font(.settingsNote.monospaced())
                                .foregroundStyle(Paper.inkMuted)
                                .textSelection(.enabled)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text(status(app)).font(.settingsNote).foregroundStyle(Paper.inkMuted)
                        }
                    }
                }
            }
        }
        .onAppear { detector.refreshNotificationStatus() }
    }

    private func status(_ app: DetectedApp) -> String {
        guard let callApp = app.callApp else { return "Not a call app" }
        return CallApps.parseOff(appsOff).contains(callApp.id) ? "Ignored" : "Watched"
    }

    private func binding(for app: CallApp) -> Binding<Bool> {
        Binding(
            get: { !CallApps.parseOff(appsOff).contains(app.id) },
            set: { on in
                var off = CallApps.parseOff(appsOff)
                if on { off.remove(app.id) } else { off.insert(app.id) }
                appsOff = off.sorted().joined(separator: ",")
            })
    }
}

struct AppIcon: View {
    let app: DetectedApp
    var size: CGFloat

    var body: some View {
        if let icon = app.icon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else {
            Image(systemName: "app.dashed")
                .font(.system(size: size * 0.7))
                .foregroundStyle(Paper.inkMuted)
                .frame(width: size, height: size)
        }
    }
}
