import Foundation
import Testing
@testable import Earl

/// The first-run window against a pretend Mac: the flow works end to end,
/// the failures can be provoked, and nothing real is saved.
@MainActor
struct SetupRehearsalTests {
    @Test func freshMacNeedsEveryStepInOrder() {
        let r = SetupRehearsal(.fresh, pace: .zero)
        #expect(SetupGuide.steps(r.state) == [.models, .microphone, .screenAudio, .notes])
        #expect(r.neededBytes == SetupRehearsal.listeningToolsBytes)
    }

    @Test func screenAudioNeedsARestartThenIsGranted() {
        let r = SetupRehearsal(.fresh, pace: .zero)
        r.askScreenAudio()
        #expect(SetupGuide.steps(r.state).contains(.relaunch))
        #expect(!SetupGuide.steps(r.state).contains(.screenAudio))
        r.relaunch()
        #expect(r.state.screenAudio == .granted)
    }

    @Test func adminScenarioIsBlockedByAdministrator() {
        #expect(SetupGuide.blockedByAdmin(SetupRehearsal(.admin).state))
        #expect(!SetupGuide.blockedByAdmin(SetupRehearsal(.microphoneOff).state))
    }

    @Test func downloadFailsOnceThenWorks() async {
        let r = SetupRehearsal(.downloadFails, pace: .zero)
        var seen: Int64 = 0
        let first = await r.download(.models)?.start { seen = $0 }
        #expect(first != nil)
        #expect(seen < SetupRehearsal.listeningToolsBytes)
        #expect(r.neededBytes > 0)
        let second = await r.download(.models)?.start { _ in }
        #expect(second == nil)
        #expect(r.neededBytes == 0)
    }

    @Test func walksTheWholeFlowAndSavesNothing() async throws {
        let defaults = UserDefaults.standard
        let finishedBefore = defaults.object(forKey: Prefs.Key.onboardingFinished)
        let summariesBefore = defaults.object(forKey: Prefs.Key.summariesEnabled)
        let model = OnboardingModel(rehearsal: SetupRehearsal(.fresh, pace: .zero))
        #expect(model.page == .welcome)
        var visited: [OnboardingModel.Page] = []
        for _ in 0..<400 where model.page != .done {
            if visited.last != model.page { visited.append(model.page) }
            switch model.page {
            case .welcome, .models, .microphone, .screenAudio, .relaunch, .notes: model.primary()
            default: break
            }
            try await Task.sleep(for: .milliseconds(30))
            model.refresh()
        }
        #expect(model.page == .done)
        #expect(visited.contains(.welcome) && visited.contains(.models) && visited.contains(.microphone))
        #expect(visited.contains(.screenAudio) && visited.contains(.relaunch) && visited.contains(.notes))
        // Nothing real was saved: a rehearsal on a set-up Mac must not mark setup finished.
        #expect(defaults.object(forKey: Prefs.Key.onboardingFinished) as? Bool == finishedBefore as? Bool)
        #expect(defaults.object(forKey: Prefs.Key.summariesEnabled) as? Bool == summariesBefore as? Bool)
    }
}
