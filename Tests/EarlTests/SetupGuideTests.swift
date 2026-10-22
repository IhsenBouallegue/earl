import Testing
@testable import Earl

struct SetupGuideTests {
    var ready = SetupState(transcriberPresent: true, whisperModelPresent: true, vadPresent: true,
                           speakerModelsPresent: true, microphone: .granted, microphoneRestricted: false,
                           screenAudio: .granted, screenAudioAskedThisRun: false, notesReady: true)

    @Test func readyMeansNothingLeft() { #expect(SetupGuide.next(ready) == nil) }

    @Test func modelsComeFirst() {
        var s = ready; s.whisperModelPresent = false; s.microphone = .notAsked
        #expect(SetupGuide.steps(s) == [.models, .microphone])
    }

    @Test func missingVadOrSpeakersAlsoNeedsModels() {
        var s = ready; s.speakerModelsPresent = false
        #expect(SetupGuide.next(s) == .models)
    }

    @Test func screenAudioGrantedThisRunNeedsRelaunch() {
        // CGPreflight keeps saying false until Earl restarts.
        var s = ready; s.screenAudio = .notAsked; s.screenAudioAskedThisRun = true
        #expect(SetupGuide.next(s) == .relaunch)
    }

    @Test func adminBlockedMicIsNotAStepLoop() {
        var s = ready; s.microphone = .denied; s.microphoneRestricted = true
        #expect(SetupGuide.blockedByAdmin(s))
        #expect(SetupGuide.next(s) == .microphone)
    }

    @Test func notesLast() {
        var s = ready; s.notesReady = false; s.microphone = .notAsked
        #expect(SetupGuide.steps(s) == [.microphone, .notes])
    }
}
