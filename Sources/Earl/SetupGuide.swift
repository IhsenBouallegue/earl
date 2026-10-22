import Foundation

/// D-2: what's left before Earl can take a meeting, in the order to do it.
/// Pure, so the first-run page and the menu bar agree.
struct SetupState: Equatable {
    var transcriberPresent: Bool      // engine.whisperInstalled
    var whisperModelPresent: Bool     // file at Prefs.whisperModel
    var vadPresent: Bool
    var speakerModelsPresent: Bool    // Diarizer isInstalled
    var microphone: Engine.Permission
    var microphoneRestricted: Bool    // .restricted from AVCaptureDevice
    var screenAudio: Engine.Permission
    var screenAudioAskedThisRun: Bool // asked, needs relaunch
    var notesReady: Bool              // D-3 fills this; true until then
}

enum SetupStep: String, CaseIterable { case models, microphone, screenAudio, relaunch, notes }

enum SetupGuide {
    static func steps(_ s: SetupState) -> [SetupStep] {
        var left: [SetupStep] = []
        if !(s.transcriberPresent && s.whisperModelPresent && s.vadPresent && s.speakerModelsPresent) { left.append(.models) }
        if s.microphone != .granted { left.append(.microphone) }
        if s.screenAudio != .granted { left.append(s.screenAudioAskedThisRun ? .relaunch : .screenAudio) }
        if !s.notesReady { left.append(.notes) }
        return left
    }
    static func next(_ s: SetupState) -> SetupStep? { steps(s).first }
    static func blockedByAdmin(_ s: SetupState) -> Bool { s.microphone == .denied && s.microphoneRestricted }
}
