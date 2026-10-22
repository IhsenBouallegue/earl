import AppKit
import Carbon.HIToolbox
import Testing
@testable import Earl

struct GlobalShortcutTests {
    @Test func displaysInMenuOrder() {
        #expect(KeyCombo.defaultRecord.display == "⌃⌥⌘R")
        let all = KeyCombo(keyCode: UInt32(kVK_ANSI_M), modifiers: [.command, .shift, .option, .control])
        #expect(all.display == "⌃⌥⇧⌘M")
        #expect(KeyCombo(keyCode: UInt32(kVK_F5), modifiers: [.control]).display == "⌃F5")
        #expect(KeyCombo(keyCode: UInt32(kVK_Space), modifiers: [.command]).display == "⌘Space")
        #expect(KeyCombo(keyCode: 200, modifiers: [.command]).display == "⌘Key 200")
    }

    @Test func ignoresIrrelevantModifiers() {
        let combo = KeyCombo(keyCode: UInt32(kVK_ANSI_R), modifiers: [.command, .capsLock, .function, .numericPad])
        #expect(combo.flags == [.command])
        #expect(combo.display == "⌘R")
    }

    @Test func codableRoundTrip() throws {
        let combo = KeyCombo(keyCode: UInt32(kVK_ANSI_M), modifiers: [.control, .option, .command])
        #expect(KeyCombo.fromSetting(combo.json) == combo)
        let data = try JSONEncoder().encode(combo)
        #expect(try JSONDecoder().decode(KeyCombo.self, from: data) == combo)
    }

    @Test func readsSetting() {
        #expect(KeyCombo.fromSetting(nil) == KeyCombo.defaultRecord)
        #expect(KeyCombo.fromSetting("") == nil)
        #expect(KeyCombo.fromSetting("not json") == nil)
    }

    @Test func convertsToCarbonModifiers() {
        #expect(KeyCombo.defaultRecord.carbonModifiers == UInt32(controlKey | optionKey | cmdKey))
        #expect(KeyCombo(keyCode: 0, modifiers: [.shift, .command]).carbonModifiers == UInt32(shiftKey | cmdKey))
        #expect(KeyCombo(keyCode: 0, modifiers: [.option]).carbonModifiers == UInt32(optionKey))
        #expect(KeyCombo(keyCode: 0, modifiers: []).carbonModifiers == 0)
    }

    @Test func requiresCommandOrControl() {
        #expect(KeyCombo(keyCode: 0, modifiers: [.command]).isAllowed)
        #expect(KeyCombo(keyCode: 0, modifiers: [.control]).isAllowed)
        #expect(!KeyCombo(keyCode: 0, modifiers: []).isAllowed)
        #expect(!KeyCombo(keyCode: 0, modifiers: [.shift, .option]).isAllowed)
    }
}
