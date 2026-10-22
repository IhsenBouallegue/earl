import Foundation
import Testing
@testable import Earl

struct CallDetectionMachineTests {
    typealias M = CallDetectionMachine
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    @Test func debouncesBeforeOffering() {
        var m = M()
        #expect(m.inputStarted("teams", at: at(0)).isEmpty)
        #expect(m.tick(at: at(1.9)).isEmpty)
        #expect(m.tick(at: at(2)) == [.offerRecording("teams")])
        // Only once.
        #expect(m.tick(at: at(8)).isEmpty)
    }

    @Test func quickMicTestNeverOffers() {
        var m = M()
        _ = m.inputStarted("teams", at: at(0))
        #expect(m.inputStopped("teams", at: at(1.5)).isEmpty)
        #expect(m.tick(at: at(10)).isEmpty)
    }

    /// R2-6: with the short debounce a mic test can get an offer, but it goes
    /// away as soon as the test ends.
    @Test func quickMicTestOfferIsWithdrawn() {
        var m = M()
        _ = m.inputStarted("teams", at: at(0))
        #expect(m.tick(at: at(2)) == [.offerRecording("teams")])
        #expect(m.inputStopped("teams", at: at(4)) == [.withdrawOffer])
        #expect(m.pendingOffer == nil)
        #expect(m.tick(at: at(10)).isEmpty)
    }

    /// R2-6: the detector wakes at the debounce deadline instead of its 3 s scan.
    @Test func nextOfferCheckIsTheDebounceDeadline() {
        var m = M()
        #expect(m.nextOfferCheck == nil)
        _ = m.inputStarted("zoom", at: at(1))
        _ = m.inputStarted("teams", at: at(0.5))
        #expect(m.nextOfferCheck == at(2.5))
        _ = m.tick(at: at(2.5))
        // Offer pending: nothing to wake for.
        #expect(m.nextOfferCheck == nil)
        _ = m.decline()
        #expect(m.nextOfferCheck == nil)

        var quiet = M()
        quiet.startAction = .nothing
        _ = quiet.inputStarted("teams", at: at(0))
        #expect(quiet.nextOfferCheck == nil)

        var recording = M()
        _ = recording.recordingStarted(at: at(0))
        _ = recording.inputStarted("teams", at: at(1))
        #expect(recording.nextOfferCheck == nil)
    }

    @Test func withdrawsWhenInputStopsBeforeAnswer() {
        var m = M()
        _ = m.inputStarted("zoom", at: at(0))
        #expect(m.tick(at: at(6)) == [.offerRecording("zoom")])
        #expect(m.inputStopped("zoom", at: at(10)) == [.withdrawOffer])
        #expect(m.pendingOffer == nil)
        // A new stretch of input is a new chance to offer.
        _ = m.inputStarted("zoom", at: at(12))
        #expect(m.tick(at: at(14)) == [.offerRecording("zoom")])
    }

    @Test func notNowCooldown() {
        var m = M()
        _ = m.inputStarted("teams", at: at(0))
        #expect(m.tick(at: at(5)) == [.offerRecording("teams")])
        #expect(m.decline() == [.withdrawOffer])
        #expect(m.tick(at: at(60)).isEmpty)

        // Stopped for less than 2 min: still quiet.
        _ = m.inputStopped("teams", at: at(100))
        _ = m.inputStarted("teams", at: at(200))
        #expect(m.tick(at: at(300)).isEmpty)

        // Stopped for 2 min: ask again after the debounce.
        _ = m.inputStopped("teams", at: at(400))
        _ = m.inputStarted("teams", at: at(520))
        #expect(m.tick(at: at(521.9)).isEmpty)
        #expect(m.tick(at: at(522)) == [.offerRecording("teams")])
    }

    @Test func autoStartWhenConfigured() {
        var m = M()
        m.startAction = .record
        _ = m.inputStarted("teams", at: at(0))
        #expect(m.tick(at: at(5)) == [.autoStart("teams")])
        #expect(m.tick(at: at(8)).isEmpty)
    }

    @Test func doNothingNeverOffers() {
        var m = M()
        m.startAction = .nothing
        _ = m.inputStarted("teams", at: at(0))
        #expect(m.tick(at: at(60)).isEmpty)
    }

    @Test func noOfferWhileRecording() {
        var m = M()
        _ = m.recordingStarted(at: at(0))
        _ = m.inputStarted("teams", at: at(1))
        #expect(m.tick(at: at(30)).isEmpty)
    }

    @Test func twoAppsMakeOneOfferNamingTheFirst() {
        var m = M()
        _ = m.inputStarted("teams", at: at(0))
        _ = m.inputStarted("chrome", at: at(1))
        #expect(m.tick(at: at(6)) == [.offerRecording("teams")])
        // Declining covers both, so the browser doesn't get its own offer.
        _ = m.decline()
        #expect(m.tick(at: at(30)).isEmpty)
    }

    @Test func offerStaysWhileAnotherAppOfTheOfferRuns() {
        var m = M()
        _ = m.inputStarted("teams", at: at(0))
        _ = m.inputStarted("chrome", at: at(1))
        _ = m.tick(at: at(6))
        #expect(m.inputStopped("teams", at: at(7)).isEmpty)
        #expect(m.inputStopped("chrome", at: at(8)) == [.withdrawOffer])
    }

    @Test func acceptingWithdrawsTheOffer() {
        var m = M()
        _ = m.inputStarted("teams", at: at(0))
        _ = m.tick(at: at(5))
        #expect(m.recordingStarted(at: at(7)) == [.withdrawOffer])
        #expect(m.callApp == "teams")
    }

    @Test func callEndOffersStopAfterGrace() {
        var m = M()
        _ = m.inputStarted("teams", at: at(0))
        _ = m.tick(at: at(5))
        _ = m.recordingStarted(at: at(6))
        #expect(m.inputStopped("teams", at: at(100)).isEmpty)
        #expect(m.tick(at: at(119)).isEmpty)
        #expect(m.tick(at: at(120)) == [.offerStop("teams")])
        #expect(m.tick(at: at(150)).isEmpty)
        #expect(m.keepRecording() == [.withdrawOffer])
        #expect(m.tick(at: at(200)).isEmpty)
    }

    @Test func mutedMomentDoesNotEndTheCall() {
        var m = M()
        _ = m.inputStarted("teams", at: at(0))
        _ = m.recordingStarted(at: at(1))
        _ = m.inputStopped("teams", at: at(10))
        _ = m.inputStarted("teams", at: at(25))
        #expect(m.tick(at: at(40)).isEmpty)
    }

    @Test func resumedCallWithdrawsStopOffer() {
        var m = M()
        _ = m.inputStarted("teams", at: at(0))
        _ = m.recordingStarted(at: at(1))
        _ = m.inputStopped("teams", at: at(10))
        #expect(m.tick(at: at(30)) == [.offerStop("teams")])
        #expect(m.inputStarted("teams", at: at(35)) == [.withdrawOffer])
        // Ends again: asks again.
        _ = m.inputStopped("teams", at: at(50))
        #expect(m.tick(at: at(70)) == [.offerStop("teams")])
    }

    @Test func autoStopWhenConfigured() {
        var m = M()
        m.endAction = .stop
        _ = m.inputStarted("teams", at: at(0))
        _ = m.recordingStarted(at: at(1))
        _ = m.inputStopped("teams", at: at(10))
        #expect(m.tick(at: at(30)) == [.autoStop("teams")])
    }

    @Test func callEndWaitsForEveryApp() {
        var m = M()
        _ = m.inputStarted("teams", at: at(0))
        _ = m.inputStarted("chrome", at: at(2))
        _ = m.recordingStarted(at: at(3))
        _ = m.inputStopped("teams", at: at(10))
        #expect(m.tick(at: at(40)).isEmpty)
        _ = m.inputStopped("chrome", at: at(50))
        #expect(m.tick(at: at(69)).isEmpty)
        #expect(m.tick(at: at(70)) == [.offerStop("teams")])
    }

    @Test func manualRecordingDuringCallCountsAsTheCall() {
        var m = M()
        _ = m.inputStarted("zoom", at: at(0))
        // Recording by hand before the debounce even ran out.
        #expect(m.recordingStarted(at: at(2)).isEmpty)
        #expect(m.callApp == "zoom")
        _ = m.inputStopped("zoom", at: at(60))
        #expect(m.tick(at: at(80)) == [.offerStop("zoom")])
    }

    @Test func manualRecordingWithoutCallNeverOffersStop() {
        var m = M()
        _ = m.recordingStarted(at: at(0))
        #expect(m.callApp == nil)
        #expect(m.tick(at: at(600)).isEmpty)
    }

    @Test func callJoinedDuringRecordingCounts() {
        var m = M()
        _ = m.recordingStarted(at: at(0))
        _ = m.inputStarted("teams", at: at(10))
        #expect(m.callApp == "teams")
        _ = m.inputStopped("teams", at: at(100))
        #expect(m.tick(at: at(120)) == [.offerStop("teams")])
    }

    @Test func noOfferRightAfterStoppingDuringCall() {
        var m = M()
        _ = m.inputStarted("teams", at: at(0))
        _ = m.recordingStarted(at: at(1))
        _ = m.recordingStopped(at: at(30))
        #expect(m.tick(at: at(60)).isEmpty)
    }

    @Test func stoppingWithdrawsStopOffer() {
        var m = M()
        _ = m.inputStarted("teams", at: at(0))
        _ = m.recordingStarted(at: at(1))
        _ = m.inputStopped("teams", at: at(10))
        _ = m.tick(at: at(30))
        #expect(m.recordingStopped(at: at(35)) == [.withdrawOffer])
    }

    @Test func resetForgetsStateAndOffersAgain() {
        var m = M()
        _ = m.inputStarted("teams", at: at(0))
        _ = m.tick(at: at(5))
        #expect(m.reset(at: at(100)) == [.withdrawOffer])
        #expect(m.running.isEmpty)
        _ = m.inputStarted("teams", at: at(101))
        #expect(m.tick(at: at(106)) == [.offerRecording("teams")])
    }

    @Test func isActiveOnlyWhenSomethingIsGoingOn() {
        var m = M()
        #expect(!m.isActive)
        _ = m.inputStarted("teams", at: at(0))
        #expect(m.isActive)
        _ = m.inputStopped("teams", at: at(1))
        #expect(!m.isActive)
    }
}

struct CallAppsTests {
    @Test func matchesAppsAndHelpers() {
        #expect(CallApps.match("com.microsoft.teams2")?.app.id == "teams")
        #expect(CallApps.match("com.microsoft.teams2.helper")?.app.id == "teams")
        #expect(CallApps.match("com.microsoft.teams2.helper")?.prefix == "com.microsoft.teams2")
        #expect(CallApps.match("com.microsoft.vdi2.teams.citrix")?.app.id == "teams")
        #expect(CallApps.match("com.microsoft.teams")?.app.id == "teams")
        #expect(CallApps.match("us.zoom.xos")?.app.id == "zoom")
        #expect(CallApps.match("com.google.Chrome.helper")?.app.id == "browsers")
        #expect(CallApps.match("com.google.Chrome.helper")?.prefix == "com.google.Chrome")
        #expect(CallApps.match("com.apple.WebKit.GPU")?.app.id == "browsers")
        #expect(CallApps.match("Cisco-Systems.Spark")?.app.id == "webex")
        #expect(CallApps.match("cisco-systems.spark")?.app.id == "webex")
    }

    @Test func ignoresOtherApps() {
        #expect(CallApps.match("com.apple.VoiceMemos") == nil)
        #expect(CallApps.match("com.apple.PhotoBooth") == nil)
        #expect(CallApps.match("com.apple.QuickTimePlayerX") == nil)
        #expect(CallApps.match("local.earl.app") == nil)
        // A prefix only matches at a dot.
        #expect(CallApps.match("com.google.ChromeRemoteDesktop") == nil)
        #expect(CallApps.match("com.microsoft.teamsX") == nil)
    }

    @Test func webKitHostNames() {
        #expect(CallApps.webKitHostName("Safari Graphics and Media") == "Safari")
        #expect(CallApps.webKitHostName("Raycast Graphics and Media") == "Raycast")
        #expect(CallApps.webKitHostName("Safari Web Content") == "Safari")
        #expect(CallApps.webKitHostName("Safari") == nil)
        #expect(CallApps.webKitHostName(nil) == nil)
    }

    @Test func shortNamesAndLabels() {
        #expect(CallApps.shortName(name: "Microsoft Teams", bundleID: "com.microsoft.teams2") == "Teams")
        #expect(CallApps.shortName(name: "Google Chrome", bundleID: "com.google.Chrome") == "Google Chrome")
        var info = MeetingInfo(title: "x", titleIsDefault: true, startedAt: Date(), duration: 0,
                               status: .done, error: nil)
        #expect(info.callLabel == nil)
        info.callApp = "Microsoft Teams"
        info.callAppBundleID = "com.microsoft.teams2"
        #expect(info.callLabel == "Teams call")
    }

    @Test func parsesDisabledApps() {
        #expect(CallApps.parseOff("") == [])
        #expect(CallApps.parseOff("zoom, browsers,") == ["zoom", "browsers"])
    }

    @Test func oldMeetingJSONStillLoads() throws {
        let json = #"{"title":"x","titleIsDefault":true,"startedAt":"2026-01-01T10:00:00Z","duration":0,"status":"done"}"#
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        let info = try d.decode(MeetingInfo.self, from: Data(json.utf8))
        #expect(info.callApp == nil)
    }
}

/// Not a check: prints what's using audio input right now, to discover real
/// bundle IDs. Run with `./test.sh --filter printMicUsers`.
@MainActor
struct CallDetectorDebug {
    @Test func printMicUsers() {
        for object in CallDetector.processObjects() {
            let pid = CallDetector.pid(object)
            let raw = CallDetector.bundleID(object) ?? "?"
            let input = CallDetector.isRunningInput(object)
            let app = CallDetector.resolve(bundleID: CallDetector.bundleID(object), pid: pid)
            guard input || ProcessInfo.processInfo.environment["EARL_ALL_PROCESSES"] != nil else { continue }
            print("[mic] pid \(pid) input=\(input) \(raw) → \(app.name) (\(app.bundleID)) \(app.callApp?.id ?? "not a call app")")
        }
    }
}
