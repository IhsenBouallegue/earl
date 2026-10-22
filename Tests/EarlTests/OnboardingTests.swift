import Testing
@testable import Earl

/// D-2: the first-run window's flow and words, without the window.
struct OnboardingTests {
    var ready = SetupState(transcriberPresent: true, whisperModelPresent: true, vadPresent: true,
                           speakerModelsPresent: true, microphone: .granted, microphoneRestricted: false,
                           screenAudio: .granted, screenAudioAskedThisRun: false, notesReady: true)

    @Test func startsWithWelcomeThenNextMissingStep() {
        var s = ready; s.microphone = .notAsked
        var flow = OnboardingFlow(screen: .welcome)
        flow.advance(s)
        #expect(flow.screen == .step(.microphone))
    }

    @Test func movesOnByItselfWhenStateFlips() {
        var s = ready; s.microphone = .notAsked
        var flow = OnboardingFlow(screen: .step(.microphone))
        s.microphone = .granted
        flow.advance(s)
        #expect(flow.screen == .done)
    }

    @Test func afterRelaunchResumesWhereItWas() {
        // Screen audio granted, Earl restarted: the next missing step, not welcome.
        var s = ready; s.notesReady = false
        #expect(OnboardingFlow.resume(s, finishedBefore: false).screen == .step(.notes))
    }

    @Test func headlinesAvoidJargon() {
        let banned = ["whisper", "vad", "diariz", "llm", "model", "tcc"]
        for screen in OnboardingCopy.allHeadlines {
            for word in banned { #expect(!screen.lowercased().contains(word), "\(screen)") }
        }
    }

    @Test func headlinesFitOneLine() {
        for h in OnboardingCopy.allHeadlines { #expect(h.count <= 42, "\(h)") }
    }

    // MARK: Flow details

    @Test func staysOnAStepUntilItIsDone() {
        var s = ready; s.microphone = .notAsked; s.screenAudio = .notAsked
        var flow = OnboardingFlow(screen: .step(.microphone))
        flow.advance(s)
        #expect(flow.screen == .step(.microphone))
    }

    @Test func askingForScreenAudioLeadsToRestart() {
        var s = ready; s.screenAudio = .notAsked
        var flow = OnboardingFlow(screen: .step(.screenAudio))
        s.screenAudioAskedThisRun = true
        flow.advance(s)
        #expect(flow.screen == .step(.relaunch))
    }

    @Test func doneStaysDone() {
        var flow = OnboardingFlow(screen: .done)
        var s = ready; s.microphone = .denied
        flow.advance(s)
        #expect(flow.screen == .done)
    }

    @Test func firstLaunchStartsWithWelcome() {
        var s = ready; s.whisperModelPresent = false; s.microphone = .notAsked; s.screenAudio = .notAsked
        #expect(OnboardingFlow.resume(s, finishedBefore: false).screen == .welcome)
    }

    @Test func comingBackSkipsWelcome() {
        var s = ready; s.whisperModelPresent = false
        #expect(OnboardingFlow.resume(s, finishedBefore: true).screen == .step(.models))
    }

    @Test func restartWithEverythingReadyLandsOnDone() {
        #expect(OnboardingFlow.resume(ready, finishedBefore: false).screen == .done)
    }

    @Test func restartWithTheSwitchStillOffAsksAgain() {
        // Turned off (or never turned on) in System Settings: back to the switch, not a restart loop.
        var s = ready; s.screenAudio = .notAsked
        #expect(OnboardingFlow.resume(s, finishedBefore: false).screen == .step(.screenAudio))
    }

    @Test func pagesCountEveryScreenAhead() {
        var s = ready; s.whisperModelPresent = false; s.screenAudio = .notAsked
        #expect(OnboardingFlow.pages(s, from: .welcome)
                == [.welcome, .step(.models), .step(.screenAudio), .step(.relaunch), .done])
        #expect(OnboardingFlow.pages(s, from: .step(.models))
                == [.step(.models), .step(.screenAudio), .step(.relaunch), .done])
    }

    // MARK: Models later (download in the background, or Not Now after a failure)

    var fresh: SetupState {
        var s = ready
        s.whisperModelPresent = false; s.vadPresent = false; s.speakerModelsPresent = false
        s.microphone = .notAsked; s.screenAudio = .notAsked
        return s
    }

    @Test func downloadRunningMovesOnToTheMicrophone() {
        var flow = OnboardingFlow(screen: .step(.models))
        flow.advance(fresh, modelsDeferred: true)
        #expect(flow.screen == .step(.microphone))
    }

    @Test func notNowAfterAFailureMovesOnToTheMicrophone() {
        // Same flag: the step is put off, not done; SetupGuide still lists it.
        var flow = OnboardingFlow(screen: .step(.models))
        flow.advance(fresh, modelsDeferred: true)
        #expect(flow.screen == .step(.microphone))
        #expect(SetupGuide.next(fresh) == .models)
    }

    @Test func withoutTheFlagTheModelsStepStays() {
        var flow = OnboardingFlow(screen: .step(.models))
        flow.advance(fresh)
        #expect(flow.screen == .step(.models))
    }

    @Test func permissionsDoneWithModelsMissingEndsOnModelsNotDone() {
        var s = fresh; s.microphone = .granted; s.screenAudio = .granted
        var flow = OnboardingFlow(screen: .step(.microphone))
        flow.advance(s, modelsDeferred: true)
        #expect(flow.screen == .step(.models))
        flow.advance(s, modelsDeferred: true) // and waits there
        #expect(flow.screen == .step(.models))
    }

    @Test func modelsArrivingAtTheEndLeadToDone() {
        var flow = OnboardingFlow(screen: .step(.models))
        flow.advance(ready, modelsDeferred: true)
        #expect(flow.screen == .done)
    }

    @Test func putOffModelsGoLastInThePageDots() {
        let pages: [OnboardingScreen] = [.welcome, .step(.models), .step(.microphone), .step(.screenAudio), .done]
        #expect(OnboardingFlow.modelsLast(pages)
                == [.welcome, .step(.microphone), .step(.screenAudio), .step(.models), .done])
    }

    @Test func backAfterARestartMidDownloadSkipsWelcome() {
        // Microphone already answered: the user has been through welcome.
        var s = fresh; s.microphone = .granted; s.screenAudio = .granted
        #expect(OnboardingFlow.resume(s, finishedBefore: false).screen == .step(.models))
    }

    // MARK: Copy

    @Test func everyStepHasCopy() {
        for step in SetupStep.allCases {
            let copy = OnboardingCopy.step(step)
            #expect(!copy.title.isEmpty && !copy.primary.isEmpty, "\(step)")
        }
    }

    @Test func downloadLineShowsSizeAndTimeLeft() {
        #expect(OnboardingCopy.downloading(done: 400_000_000, total: 1_700_000_000, minutesLeft: 3)
                == "0.4 of 1.7 GB · about 3 min left")
        #expect(OnboardingCopy.downloading(done: 0, total: 1_700_000_000, minutesLeft: nil) == "0 of 1.7 GB")
    }

    @Test func noteForITNamesTheApp() {
        #expect(OnboardingCopy.itNote.contains("local.earl.app"))
    }

    @Test func downloadButtonShowsTheSize() {
        #expect(OnboardingCopy.downloadButton(bytes: 1_730_000_000) == "Download (1.7 GB)")
        #expect(OnboardingCopy.downloadButton(bytes: 128_000_000) == "Download (128 MB)")
    }

    @Test func failedDownloadDropsTheFileName() {
        let body = OnboardingCopy.downloadFailed("Download of Large v3 Turbo failed: The Internet connection appears to be offline.")
        #expect(body == "The download stopped. The Internet connection appears to be offline.\n"
                + "A colleague can give you the files instead.")
    }

    @Test func noteWriterFailureSaysTheFile() { // D-3: one file, not the listening tools' several
        #expect(OnboardingCopy.downloadFailed("Download failed: The request timed out.", oneFile: true)
                .hasSuffix("A colleague can give you the file instead."))
    }

    @Test func failedImportDoesNotTalkAboutADownload() {
        for reason in ["Earl couldn't read that file.", "That file isn't one of Earl's models.",
                       "Couldn't add Large v3 Turbo: The disk is full."] {
            let body = OnboardingCopy.importFailed(reason)
            #expect(!body.lowercased().contains("download"), "\(body)")
            #expect(!body.contains("colleague"), "\(body)") // the link under it says what to do
        }
        #expect(OnboardingCopy.importFailed("Couldn't add Large v3 Turbo: The disk is full.")
                == "Earl couldn't add that file. The disk is full.")
    }

    @Test func failureAdviceIsGivenOnce() {
        let body = OnboardingCopy.downloadFailed("Download failed: The request timed out.")
        #expect(body.components(separatedBy: "colleague").count == 2)
        #expect(!body.contains("Try again")) // the button says it
    }

    @Test func doneNamesTheConfiguredShortcut() {
        #expect(OnboardingCopy.done(shortcut: "⌃⌥⌘R").body.contains("You can also press ⌃⌥⌘R."))
        #expect(OnboardingCopy.done(shortcut: "⇧⌘F12").body.contains("⇧⌘F12"))
        #expect(!OnboardingCopy.done(shortcut: nil).body.contains("press"))
    }

    @Test func restartCopyFitsADenialToo() {
        // The switch may be off after the restart: no promise that sound is on.
        let body = OnboardingCopy.relaunch.body.lowercased()
        #expect(!body.contains("turns the sound on"))
        #expect(!body.contains("on this page"))
    }

    // MARK: D-3: notes, and restarting during a download

    @Test func notesCopyNamesTheModelAndSize() {
        let copy = OnboardingCopy.notes(name: "Qwen3 4B", size: "2.5 GB")
        #expect(copy.title == "Notes, Written on Your Mac")
        #expect(copy.body == "No LM Studio or Ollama here, so Earl brings its own\nnote writer: *Qwen3 4B*, 2.5 GB.")
        #expect(copy.primary == "Download (2.5 GB)")
        #expect(copy.secondary == "Not Now (transcripts only)")
    }

    @Test func restartWithoutADownloadIsNow() {
        var plan = RelaunchPlan()
        #expect(plan.press(downloading: false) == true)
    }

    @Test func restartDuringADownloadWaitsForIt() {
        var plan = RelaunchPlan()
        #expect(RelaunchPlan.button(downloading: true, waiting: false) == "Restart After Download")
        #expect(plan.press(downloading: true) == false) // the 1.7 GB aren't thrown away
        #expect(plan.waiting)
        #expect(!plan.shouldRelaunch(downloading: true, busy: false))
        #expect(plan.shouldRelaunch(downloading: false, busy: false)) // done: restart by itself
    }

    @Test func notWaitingNeverRestartsByItself() {
        #expect(!RelaunchPlan().shouldRelaunch(downloading: false, busy: false))
        #expect(RelaunchPlan.button(downloading: false, waiting: false) == OnboardingCopy.relaunch.primary)
    }

    @Test func onlyAQuitMidDownloadResumesIt() {
        #expect(RelaunchPlan.resumeOnQuit(downloading: true))
        #expect(!RelaunchPlan.resumeOnQuit(downloading: false))
    }

    // MARK: Review fixes

    @Test func neverRestartsDuringARecordingOrProcessing() {
        var plan = RelaunchPlan()
        _ = plan.press(downloading: true)
        #expect(!plan.shouldRelaunch(downloading: false, busy: true)) // a call is being recorded: wait
        #expect(plan.shouldRelaunch(downloading: false, busy: false))
        var other = RelaunchPlan()
        let now = other.press(downloading: false, busy: true)
        #expect(!now && other.waiting) // pressed during a recording: wait too
    }

    @Test func aFailedDownloadDisarmsTheRestart() {
        var plan = RelaunchPlan()
        _ = plan.press(downloading: true)
        plan.downloadEnded(failed: true)
        #expect(!plan.waiting)
        #expect(!plan.shouldRelaunch(downloading: false, busy: false))
        #expect(RelaunchPlan.button(downloading: false, waiting: plan.waiting) == "Restart Earl")
    }

    @Test func cancellingDisarmsTheRestart() {
        var plan = RelaunchPlan()
        _ = plan.press(downloading: true)
        plan.cancel()
        #expect(!plan.waiting)
    }

    @Test func aSecondDownloadWaitsForTheFirst() {
        #expect(DownloadQueue.request(.notes, running: nil) == .start)
        #expect(DownloadQueue.request(.notes, running: .models) == .queue) // starts after the listening tools
        #expect(DownloadQueue.request(.models, running: .models) == .ignore)
        #expect(DownloadQueue.next(queued: .notes, ended: .models) == .notes)
        #expect(DownloadQueue.next(queued: nil, ended: .models) == nil)
        #expect(DownloadQueue.next(queued: .notes, ended: .notes) == nil)
    }
}
