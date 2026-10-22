import Foundation
import Testing
@testable import Earl

/// D-1: the whisper-cli inside Earl.app wins, unless the user chose another one.
struct BundledToolsTests {
    let bundled = "/Apps/Earl.app/Contents/Helpers/whisper-cli"

    @Test func bundledWinsWhenNothingStored() {
        #expect(Prefs.resolveWhisperPath(stored: nil, bundled: bundled) == bundled)
    }

    @Test func oldHomebrewDefaultMovesToBundled() {
        #expect(Prefs.resolveWhisperPath(stored: Prefs.homebrewWhisperPath, bundled: bundled) == bundled)
    }

    @Test func customPathIsKept() {
        #expect(Prefs.resolveWhisperPath(stored: "~/bin/whisper-cli", bundled: bundled)
                == NSString(string: "~/bin/whisper-cli").expandingTildeInPath)
    }

    @Test func withoutBundleFallsBackToHomebrew() {
        // swift run / tests: no Helpers folder.
        #expect(Prefs.resolveWhisperPath(stored: nil, bundled: nil) == Prefs.homebrewWhisperPath)
    }

    @Test func noHelpersFolderInTests() {
        #expect(Prefs.bundledHelper("whisper-cli") == nil)
    }
}
