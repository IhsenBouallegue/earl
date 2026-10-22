import Foundation
import Testing
@testable import Earl

@Suite struct SandboxTests {
    @Test func folderComesFromTheFlagOrTheEnvironment() {
        #expect(Sandbox.folder(arguments: ["Earl"], environment: [:]) == nil)
        #expect(Sandbox.folder(arguments: ["Earl", "--sandbox", "/tmp/one"], environment: [:])?.path == "/tmp/one")
        #expect(Sandbox.folder(arguments: ["Earl"], environment: ["EARL_SANDBOX": "/tmp/two"])?.path == "/tmp/two")
        #expect(Sandbox.folder(arguments: ["Earl", "--sandbox", "/tmp/one"], environment: ["EARL_SANDBOX": "/tmp/two"])?.path == "/tmp/one")
        #expect(Sandbox.folder(arguments: ["Earl", "--sandbox"], environment: [:]) == nil)
        #expect(Sandbox.folder(arguments: ["Earl", "--sandbox", "--demo"], environment: [:]) == nil)
        #expect(Sandbox.folder(arguments: ["Earl"], environment: ["EARL_SANDBOX": ""]) == nil)
    }

    @Test func eachFolderHasSettingsOfItsOwn() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("earl-sandbox-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let a = try #require(Sandbox.defaults(in: base.appendingPathComponent("a")))
        let b = try #require(Sandbox.defaults(in: base.appendingPathComponent("b")))
        a.set("Ahsan", forKey: Prefs.Key.userName)
        #expect(a.string(forKey: Prefs.Key.userName) == "Ahsan")
        #expect(b.string(forKey: Prefs.Key.userName) == nil)
        #expect(UserDefaults.standard.string(forKey: Prefs.Key.userName) != "Ahsan" || Sandbox.isActive)
    }

    @Test func settingsLandInTheFolderNotInThePreferencesFolder() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("earl-sandbox-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let d = try #require(Sandbox.defaults(in: base))
        d.set(true, forKey: "probe")
        d.synchronize()
        #expect(Sandbox.settingsPath(in: base).hasPrefix(base.path))
        #expect(d.persistentDomain(forName: Sandbox.settingsPath(in: base))?["probe"] as? Bool == true)
    }

    @Test func aNormalRunIsNotASandbox() {
        #expect(!Sandbox.isActive)
        #expect(Sandbox.defaults === UserDefaults.standard)
    }
}
