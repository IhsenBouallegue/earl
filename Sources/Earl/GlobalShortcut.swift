import AppKit
import Carbon.HIToolbox
import SwiftUI

// MARK: - Key combo

/// A key plus modifiers, stored as the virtual key code so it doesn't depend on
/// what the key types in the current keyboard layout.
struct KeyCombo: Codable, Hashable {
    var keyCode: UInt32
    /// Raw `NSEvent.ModifierFlags`, limited to ⌃⌥⇧⌘.
    var modifiers: UInt

    static let relevantFlags: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    /// ⌃⌥⌘R. Not ⇧⌘R: browsers use that for a hard reload, and Teams on the web
    /// runs in a browser.
    static let defaultRecord = KeyCombo(keyCode: UInt32(kVK_ANSI_R), modifiers: [.control, .option, .command])

    init(keyCode: UInt32, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection(Self.relevantFlags).rawValue
    }

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers).intersection(Self.relevantFlags) }

    /// Plain letters (or ⇧ + letter) would take over typing in every app.
    var isAllowed: Bool { flags.contains(.command) || flags.contains(.control) }

    /// "⌃⌥⌘R", with modifiers in the order macOS menus use.
    var display: String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s + Self.keyName(keyCode)
    }

    var carbonModifiers: UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }

    // MARK: Setting

    var json: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    /// Reads the stored setting: missing means the default, empty means off.
    static func fromSetting(_ value: String?) -> KeyCombo? {
        guard let value else { return defaultRecord }
        guard !value.isEmpty, let data = value.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(KeyCombo.self, from: data)
    }

    // MARK: Key names

    static func keyName(_ code: UInt32) -> String {
        keyNames[Int(code)] ?? "Key \(code)"
    }

    /// Names by position on an ANSI keyboard, which is what menus show too.
    private static let keyNames: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E",
        kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J",
        kVK_ANSI_K: "K", kVK_ANSI_L: "L", kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O",
        kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X", kVK_ANSI_Y: "Y",
        kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
        kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
        kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_Backslash: "\\", kVK_ANSI_Comma: ",",
        kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/", kVK_ANSI_Grave: "`",
        kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_Escape: "⎋", kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17",
        kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]
}

// MARK: - Settings

extension Prefs.Key {
    static let recordShortcut = "recordShortcut"
    static let shortcutSound = "shortcutSound"
}

extension Prefs {
    /// The start/stop shortcut, or nil when turned off.
    static var recordShortcut: KeyCombo? {
        get { KeyCombo.fromSetting(Prefs.defaults.string(forKey: Key.recordShortcut)) }
        set { Prefs.defaults.set(newValue?.json ?? "", forKey: Key.recordShortcut) }
    }

    static var shortcutSound: Bool {
        Prefs.defaults.object(forKey: Key.shortcutSound) as? Bool ?? true
    }
}

// MARK: - Registration

/// A system-wide hot key through Carbon's `RegisterEventHotKey`. Unlike a global
/// `NSEvent` monitor it needs no Accessibility permission, and it swallows the
/// keystroke so the front app doesn't also act on it.
@MainActor
final class GlobalShortcut: ObservableObject {
    /// The combo that is registered and working right now.
    @Published private(set) var active: KeyCombo?
    /// Set when the configured combo couldn't be registered.
    @Published private(set) var registrationError: String?

    var onPress: (() -> Void)?

    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var observer: NSObjectProtocol?
    private var suspended = false

    private static let signature: OSType = 0x4561_726C // 'Earl'

    /// Installs the event handler, registers the saved combo and follows changes to the setting.
    func start() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard id.signature == GlobalShortcut.signature else { return OSStatus(eventNotHandledErr) }
            // Carbon dispatches hot keys on the main thread.
            let shortcut = Unmanaged<GlobalShortcut>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { shortcut.onPress?() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)

        // Covers @AppStorage writes from Settings, so changes apply without a relaunch.
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.apply() }
        }
        apply()
    }

    /// U-0: shows the saved combo as working, without registering it.
    func showDemo() {
        active = Prefs.recordShortcut
    }

    /// Brings the registration in line with the setting. If the new combo can't be
    /// registered, the previous one stays active.
    func apply() {
        guard !suspended else { return }
        let wanted = Prefs.recordShortcut
        if wanted == active, wanted == nil || hotKey != nil {
            registrationError = nil
            return
        }
        guard let wanted else {
            unregister()
            active = nil
            registrationError = nil
            return
        }
        if let ref = register(wanted) {
            unregister()
            hotKey = ref
            active = wanted
            registrationError = nil
        } else {
            let fallback = active.map { " \($0.display) still works." } ?? ""
            registrationError = "\(wanted.display) is already used by another app.\(fallback)"
        }
    }

    /// Lets the shortcut field capture the current combo without triggering it.
    func setSuspended(_ on: Bool) {
        guard on != suspended else { return }
        suspended = on
        if on {
            unregister()
        } else {
            if let active {
                hotKey = register(active)
                if hotKey == nil { self.active = nil }
            }
            apply()
        }
    }

    private func register(_ combo: KeyCombo) -> EventHotKeyRef? {
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: 1)
        // Exclusive, so a combo another app holds fails with eventHotKeyExistsErr
        // instead of silently going to whoever registered first.
        let status = RegisterEventHotKey(combo.keyCode, combo.carbonModifiers, id, GetEventDispatcherTarget(),
                                         OptionBits(kEventHotKeyExclusive), &ref)
        return status == noErr ? ref : nil
    }

    private func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
    }
}

extension AppState {
    /// R1-1: the global shortcut toggles recording, with a quiet sound because
    /// Earl's window usually isn't in front.
    func shortcutPressed() {
        let wasRecording = isRecording
        if !wasRecording, isStarting { return }
        toggleRecording()
        guard Prefs.shortcutSound else { return }
        NSSound(named: wasRecording ? "Pop" : "Tink")?.play()
    }
}

// MARK: - Views

/// The combo as a small hint, for example on the Start Recording button. Empty when off.
struct ShortcutHint: View {
    @ObservedObject var shortcut: GlobalShortcut

    var body: some View {
        if let combo = shortcut.active {
            Text(combo.display).font(.settingsNote).opacity(0.7)
        }
    }
}

/// A field that shows the combo and records a new one when clicked.
struct ShortcutRecorder: View {
    @Binding var combo: KeyCombo?
    var onCapture: (Bool) -> Void = { _ in }

    @State private var capturing = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            capturing ? stop() : begin()
        } label: {
            Text(label)
                .font(.settingsRow.monospaced())
                .foregroundStyle(capturing || combo == nil ? Paper.inkMuted : Paper.ink)
                .frame(minWidth: 110)
        }
        .buttonStyle(.paperSecondary)
        .help(capturing ? "Esc cancels. Delete turns the shortcut off." : "Click to change")
        .onDisappear { stop() }
    }

    private var label: String {
        if capturing { return "Type a shortcut…" }
        return combo?.display ?? "None"
    }

    private func begin() {
        capturing = true
        onCapture(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
            return nil
        }
    }

    private func handle(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(KeyCombo.relevantFlags)
        if flags.isEmpty {
            switch Int(event.keyCode) {
            case kVK_Escape: return stop()
            case kVK_Delete, kVK_ForwardDelete:
                combo = nil
                return stop()
            default: break
            }
        }
        let new = KeyCombo(keyCode: UInt32(event.keyCode), modifiers: flags)
        guard new.isAllowed else { return NSSound.beep() }
        combo = new
        stop()
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if capturing { onCapture(false) }
        capturing = false
    }
}

/// R1-1 settings: the start/stop shortcut and its sound.
struct ShortcutSettings: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        ShortcutCard(shortcut: state.shortcut)
    }
}

private struct ShortcutCard: View {
    @ObservedObject var shortcut: GlobalShortcut

    @AppStorage(Prefs.Key.recordShortcut, store: Prefs.defaults) private var stored = KeyCombo.defaultRecord.json
    @AppStorage(Prefs.Key.shortcutSound, store: Prefs.defaults) private var sound = true

    private var combo: Binding<KeyCombo?> {
        Binding(get: { KeyCombo.fromSetting(stored) }, set: { stored = $0?.json ?? "" })
    }

    var body: some View {
        Card(title: "Shortcut", subtitle: "Start and stop recording from any app.") {
            HStack(spacing: 12) {
                Text("Start or stop recording").font(.settingsRow)
                Spacer()
                if combo.wrappedValue != KeyCombo.defaultRecord {
                    Button("Use Default") { combo.wrappedValue = KeyCombo.defaultRecord }
                        .buttonStyle(.paperSecondary)
                }
                ShortcutRecorder(combo: combo) { shortcut.setSuspended($0) }
            }
            if let error = shortcut.registrationError {
                StatusLabel(kind: .attention, text: error).font(.settingsRow)
            }
            SettingsRule()
            Toggle("Play a sound", isOn: $sound)
        }
    }
}
