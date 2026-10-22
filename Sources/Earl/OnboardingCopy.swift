import Foundation

// D-2: every word of the first-run window in one place. Apple's voice in the
// headlines and buttons (Title Case, short, literal); Earl's warmth only in
// the body lines. No "Whisper", "model" or other jargon in a headline.
// Bodies are Markdown: **bold** for what to click, *italics* for the name of
// a place in System Settings, as macOS writes them. A line break keeps a
// sentence or a place name from wrapping onto a line of its own.

enum OnboardingCopy {
    struct Screen: Equatable {
        var title: String
        var body: String
        var primary: String
        var secondary: String? = nil
        /// A small link under the body that reveals one short paragraph.
        var help: Help? = nil
        /// Or, in the same place, a small link that does something ("Use a File I Have…").
        var action: String? = nil
    }

    struct Help: Equatable {
        var link: String
        var text: String
    }

    struct Feature: Hashable {
        var symbol: String
        var title: String
        var detail: String
    }

    // MARK: Screens

    static let welcome = Screen(
        title: "Welcome to Earl",
        body: "Your meeting notes, written for you.\nSetup takes about five minutes.",
        primary: "Continue")

    /// Apple's What's New pattern on the welcome screen.
    static let features = [
        Feature(symbol: "waveform", title: "Notes from every call",
                detail: "Who said what, what was decided, what's still open."),
        Feature(symbol: "lock.fill", title: "Stays on your Mac",
                detail: "No bot joins the call. Nothing is sent anywhere."),
        Feature(symbol: "checklist", title: "To-dos, already sorted",
                detail: "Yours first, then everyone else's."),
    ]

    static func models(bytes: Int64) -> Screen {
        Screen(
            title: "Download Listening Tools",
            body: "I need about \(size(bytes)) of listening tools, downloaded once.\nYou can keep working while they arrive.",
            primary: downloadButton(bytes: bytes),
            secondary: useFile,
            help: Help(link: "Can't download?",
                       text: "Your company network may block the download. A colleague can give you the files; choose them here."))
    }

    static let downloadingTitle = "Downloading…"
    static let cancel = "Cancel"
    static let useFile = "Use a File I Have…"
    static let tryAgain = "Try Again"

    /// The body while the tools download: "0.4 of 1.7 GB · about 3 min left".
    static func downloading(done: Int64, total: Int64, minutesLeft: Int?) -> String {
        let line = "\(gigabytes(done)) of \(size(total))"
        guard let minutesLeft else { return line }
        return line + " · about \(max(1, minutesLeft)) min left"
    }

    /// A failed download keeps the headline; the reason goes in the body, and
    /// one suggestion: the link under it ("Use a File I Have…") acts on it.
    /// `oneFile`: the note writer is one file; the listening tools are several.
    static func downloadFailed(_ reason: String, oneFile: Bool = false) -> String {
        // "Download of <model name> failed: <why>", "Download failed: <why>": only the why means something here.
        "The download stopped. \(sentence(after: "Download", in: reason))\nA colleague can give you \(oneFile ? "the file" : "the files") instead."
    }

    /// A file chosen by hand didn't work: say why, nothing about a download.
    /// The link under it picks another file, so no advice here.
    static func importFailed(_ reason: String) -> String {
        // "Couldn't add <model name>: <why>": the name is jargon.
        guard reason.hasPrefix("Couldn't add") else { return sentence(after: "", in: reason) }
        return "Earl couldn't add that file. \(sentence(after: "Couldn't add", in: reason))"
    }

    /// The part after "<prefix> …: ", ending with a full stop.
    private static func sentence(after prefix: String, in reason: String) -> String {
        var why = reason
        if !prefix.isEmpty, why.hasPrefix(prefix), let colon = why.range(of: ": ") { why = String(why[colon.upperBound...]) }
        if !why.hasSuffix(".") { why += "." }
        return why
    }

    /// After a failure the models step can wait: the permissions come first.
    static let notNow = "Not Now"

    static let checking = "Checking the file…"
    static let transcriberMissing = "Part of Earl is missing. Download Earl again and replace the copy in your Applications folder."

    static let microphone = Screen(
        title: "Allow Microphone Access",
        body: "Earl hears your side of the call. When macOS asks, click **Allow**.",
        primary: "Continue",
        help: Help(link: "When does Earl listen?", text: "Only during recordings you start or accept."))

    /// Microphone access was turned down once: macOS won't ask again, so it's the switch in System Settings.
    static let microphoneOff = Screen(
        title: "Allow Microphone Access",
        body: "The microphone is off for Earl.\nIn the window that opens, turn on **Earl** under *Microphone*.",
        primary: openSettings,
        help: Help(link: "When does Earl listen?", text: "Only during recordings you start or accept."))

    static let admin = Screen(
        title: "Managed by Your Organisation",
        body: "Ask IT to allow Earl to use the microphone and record system audio.",
        primary: "Copy a Note for IT")

    static let copiedLine = "Copied. Paste it into a message to IT."

    /// What "Copy a Note for IT" puts on the clipboard.
    static let itNote = """
        Hello, could you allow the Mac app Earl (bundle ID local.earl.app) to use the microphone and to record \
        system audio? In a privacy profile (PPPC) that's Microphone and Screen & System Audio Recording. \
        Earl writes meeting notes on the Mac itself; no audio or text leaves the computer. Thank you!
        """

    static let screenAudio = Screen(
        title: "Hear the Other Side",
        body: "In the window that opens, turn on **Earl** under\n*Screen & System Audio Recording*. I only take the sound.",
        primary: openSettings,
        help: Help(link: "Why does it say screen?",
                   text: "macOS uses one switch for screen and sound. Earl never records your screen."))

    static let relaunch = Screen(
        title: "Restart Earl",
        body: "macOS applies the switch when Earl restarts.\nI'll reopen this window right after.",
        primary: "Restart Earl",
        secondary: "Open System Settings Again")

    /// Restarting while a download runs would throw it away: Earl waits for it.
    static let relaunchAfterDownload = "Restart After Download"
    static let relaunchesByItself = "Earl restarts by itself when the download is done."
    static let relaunchesAfterMeeting = "Earl restarts by itself when the current meeting is done."
    static let relaunchDownloadFailed = "The download stopped. You can try again after the restart."
    /// The notes model waits for the listening tools: one download at a time.
    static let startsAfterTools = "Starts after the listening tools."

    /// D-3: no LM Studio or Ollama models on this Mac, so the built-in note writer.
    static func notes(name: String, size: String) -> Screen {
        Screen(
            title: "Notes, Written on Your Mac",
            body: "No LM Studio or Ollama here, so Earl brings its own\nnote writer: *\(name)*, \(size).",
            primary: "Download (\(size))",
            secondary: "Not Now (transcripts only)")
    }

    static var notes: Screen {
        let model = BuiltInModel.forMemory(ProcessInfo.processInfo.physicalMemory)
        return notes(name: model.displayName, size: model.approxSize)
    }

    /// `shortcut` is the start/stop shortcut as macOS writes it ("⌃⌥⌘R"), nil when it's turned off.
    static func done(shortcut: String?) -> Screen {
        let press = shortcut.map { "You can also press \($0). " } ?? ""
        return Screen(
            title: "You're All Set",
            body: "When a call starts in Teams, Zoom, Meet or Webex, I'll offer to take notes. \(press)"
                + "Please let the others know you're taking notes.",
            primary: "Get Started",
            secondary: "Show Me Where Earl Lives")
    }

    /// Revealed by "Show Me Where Earl Lives".
    static let whereEarlLives = """
        Look for the monocle at the top right of your screen, in the menu bar. If your Mac has a notch and \
        many icons, it can hide there: open Earl from your Applications folder and his window appears.
        """

    static let openSettings = "Open System Settings"

    static func step(_ step: SetupStep) -> Screen {
        switch step {
        case .models: models(bytes: 1_700_000_000)
        case .microphone: microphone
        case .screenAudio: screenAudio
        case .relaunch: relaunch
        case .notes: notes
        }
    }

    static var allHeadlines: [String] {
        [welcome.title, downloadingTitle, microphoneOff.title, admin.title, done(shortcut: nil).title]
            + SetupStep.allCases.map { step($0).title }
    }

    // MARK: Sizes

    /// "Download (1.7 GB)", "Download (128 MB)".
    static func downloadButton(bytes: Int64) -> String { "Download (\(size(bytes)))" }

    /// Decimal units, as Finder counts them: "1.7 GB", "128 MB".
    static func size(_ bytes: Int64) -> String {
        bytes >= 1_000_000_000 ? "\(gigabytes(bytes)) GB" : "\(max(1, Int((Double(bytes) / 1e6).rounded()))) MB"
    }

    /// "0.4", "1.7", "0": one decimal, none when it's whole.
    static func gigabytes(_ bytes: Int64) -> String {
        let tenths = Int((Double(bytes) / 1e8).rounded())
        return tenths % 10 == 0 ? "\(tenths / 10)" : "\(tenths / 10).\(tenths % 10)"
    }
}
