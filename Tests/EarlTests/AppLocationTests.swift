import Testing
@testable import Earl

struct AppLocationTests {
    let home = "/Users/anna"
    @Test func applicationsFoldersAreFine() {
        #expect(!AppLocation.needsMove(bundlePath: "/Users/anna/Applications/Earl.app", home: home))
        #expect(!AppLocation.needsMove(bundlePath: "/Applications/Earl.app", home: home))
    }
    @Test func downloadsAndTranslocationMove() {
        #expect(AppLocation.needsMove(bundlePath: "/Users/anna/Downloads/Earl.app", home: home))
        #expect(AppLocation.needsMove(bundlePath: "/private/var/folders/x/AppTranslocation/ABC/d/Earl.app", home: home))
    }
    @Test func devBuildsAreLeftAlone() {
        #expect(!AppLocation.needsMove(bundlePath: "/Users/anna/repos/earl/build/Earl.app", home: home))
    }
}

struct MoveActionTests {
    @Test func freshInstall() {
        #expect(AppLocation.moveAction(destExists: false, destRunning: false, destBuild: nil, ownBuild: "5") == .install)
    }
    @Test func runningCopyIsKept() {
        #expect(AppLocation.moveAction(destExists: true, destRunning: true, destBuild: "1", ownBuild: "5") == .useExisting)
    }
    @Test func newerOrEqualIsKept() {
        #expect(AppLocation.moveAction(destExists: true, destRunning: false, destBuild: "10", ownBuild: "9") == .useExisting)
        #expect(AppLocation.moveAction(destExists: true, destRunning: false, destBuild: "5", ownBuild: "5") == .useExisting)
    }
    @Test func olderIsReplaced() {
        #expect(AppLocation.moveAction(destExists: true, destRunning: false, destBuild: "9", ownBuild: "10") == .install)
    }
}
