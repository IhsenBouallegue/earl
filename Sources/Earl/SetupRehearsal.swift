import Foundation

/// A rehearsal of the first-run window: the real window and flow, but a
/// pretend Mac. Nothing is downloaded, no permission is asked, no file or
/// setting is touched, so the whole flow can be walked through (and its
/// failures provoked) on a Mac that is already set up.
///
///     tools/rehearse-setup.sh [fresh | download-fails | microphone-off | admin]
///
/// which starts Earl with `--rehearse-setup=<scenario>`.
@MainActor
final class SetupRehearsal {
    enum Scenario: String, CaseIterable {
        /// Nothing is set up yet: every step, every download succeeds.
        case fresh
        /// The first download stops part-way; "Try Again" then works.
        case downloadFails = "download-fails"
        /// The microphone was turned down once.
        case microphoneOff = "microphone-off"
        /// An administrator blocks the microphone.
        case admin
    }

    static let listeningToolsBytes: Int64 = 1_730_000_000

    /// The scenario named on the command line; nil in a normal run.
    static var requested: Scenario? {
        for argument in CommandLine.arguments where argument.hasPrefix("--rehearse-setup") {
            let name = argument.split(separator: "=", maxSplits: 1).dropFirst().first.map(String.init)
            return name.flatMap(Scenario.init(rawValue:)) ?? .fresh
        }
        return nil
    }

    let scenario: Scenario
    private(set) var state: SetupState
    private let pace: Duration
    private var failedOnce = false

    /// `pace`: the time between progress steps of a pretend download.
    init(_ scenario: Scenario = .fresh, pace: Duration = .milliseconds(300)) {
        self.scenario = scenario
        self.pace = pace
        var s = SetupState(transcriberPresent: true, whisperModelPresent: false, vadPresent: false,
                           speakerModelsPresent: false, microphone: .notAsked, microphoneRestricted: false,
                           screenAudio: .notAsked, screenAudioAskedThisRun: false, notesReady: false)
        switch scenario {
        case .fresh, .downloadFails: break
        case .microphoneOff: s.microphone = .denied
        case .admin: s.microphone = .denied; s.microphoneRestricted = true
        }
        state = s
    }

    /// What the listening tools still need to download.
    var neededBytes: Int64 {
        state.whisperModelPresent && state.vadPresent && state.speakerModelsPresent ? 0 : Self.listeningToolsBytes
    }

    func grantMicrophone() { state.microphone = .granted }

    /// macOS only lets the switch take effect after a restart.
    func askScreenAudio() { state.screenAudioAskedThisRun = true }

    func relaunch() {
        state.screenAudio = .granted
        state.screenAudioAskedThisRun = false
    }

    /// A pretend download of a step: progress in small beats, then the step's files "arrive".
    func download(_ step: SetupStep) -> StepDownload? {
        let bytes: Int64
        switch step {
        case .models: bytes = Self.listeningToolsBytes
        case .notes: bytes = BuiltInModel.forMemory(ProcessInfo.processInfo.physicalMemory).bytes
        default: return nil
        }
        let beats = 20
        return StepDownload(bytes: bytes, start: { [self] report in
            for beat in 1...beats {
                if Task.isCancelled { return nil }
                report(bytes * Int64(beat) / Int64(beats))
                try? await Task.sleep(for: pace)
                if scenario == .downloadFails, !failedOnce, beat == 8 {
                    failedOnce = true
                    return "The connection dropped at 40%. Check the network and try again."
                }
            }
            arrived(step)
            return nil
        }, cancel: {})
    }

    private func arrived(_ step: SetupStep) {
        switch step {
        case .models:
            state.whisperModelPresent = true
            state.vadPresent = true
            state.speakerModelsPresent = true
        case .notes: state.notesReady = true
        default: break
        }
    }
}
