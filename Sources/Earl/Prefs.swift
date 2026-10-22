import Foundation

/// User settings, backed by UserDefaults. The keys are shared with the
/// `@AppStorage` properties in the views.
enum Prefs {
    enum Key {
        static let storagePath = "storagePath"
        static let keepAudio = "keepAudio"
        static let textOnly = "textOnly" // P-1
        static let whisperPath = "whisperPath"
        static let whisperModel = "whisperModel"
        static let language = "language"
        static let summariesEnabled = "summariesEnabled"
        static let llmURL = "llmURL"
        static let llmModel = "llmModel"
    }

    // U-0: demo mode keeps everything under a throwaway home folder.
    static let supportDir = (DemoMode.home ?? FileManager.default.homeDirectoryForCurrentUser)
        .appendingPathComponent("Library/Application Support/Earl")
    static let modelsDir = supportDir.appendingPathComponent("models", isDirectory: true)

    static let defaultStoragePath = "~/Meetings"
    // D-1: Earl.app ships its own whisper-cli; Homebrew's is the fallback for swift run.
    static let homebrewWhisperPath = "/opt/homebrew/bin/whisper-cli"
    static var defaultWhisperPath: String { bundledHelper("whisper-cli") ?? homebrewWhisperPath }

    /// A helper tool inside Earl.app/Contents/Helpers, when Earl runs as an app.
    static func bundledHelper(_ name: String) -> String? {
        let path = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(name)").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    /// The stored path, unless it's empty or the old Homebrew default: then the bundled one.
    static func resolveWhisperPath(stored: String?, bundled: String?) -> String {
        if let stored, !stored.isEmpty, stored != homebrewWhisperPath { return expand(stored) }
        return bundled ?? homebrewWhisperPath
    }
    static let defaultWhisperModel = modelsDir.appendingPathComponent("ggml-large-v3-turbo.bin").path
    static let vadModel = modelsDir.appendingPathComponent("ggml-silero-v5.1.2.bin").path
    static let defaultLanguage = "auto"
    static let defaultLLMURL = "http://localhost:1234/v1"
    static let defaultLLMModel = "google/gemma-4-e4b"

    static func register() {
        UserDefaults.standard.register(defaults: [
            Key.storagePath: defaultStoragePath,
            Key.keepAudio: true,
            Key.textOnly: false,
            Key.whisperModel: defaultWhisperModel,
            Key.language: defaultLanguage,
            Key.summariesEnabled: true,
            Key.llmURL: defaultLLMURL,
            Key.llmModel: defaultLLMModel,
        ])
    }

    private static var d: UserDefaults { .standard }

    static var storageURL: URL {
        URL(fileURLWithPath: expand(d.string(forKey: Key.storagePath) ?? defaultStoragePath), isDirectory: true)
    }
    /// P-1: "Keep only the text" wins over the audio switch.
    static var keepAudio: Bool { d.bool(forKey: Key.keepAudio) && !textOnly }
    static var textOnly: Bool { d.bool(forKey: Key.textOnly) }
    static var whisperPath: String {
        resolveWhisperPath(stored: d.string(forKey: Key.whisperPath), bundled: bundledHelper("whisper-cli"))
    }
    static var whisperModel: String { expand(d.string(forKey: Key.whisperModel) ?? defaultWhisperModel) }
    static var language: String { d.string(forKey: Key.language) ?? defaultLanguage }
    static var summariesEnabled: Bool { d.bool(forKey: Key.summariesEnabled) }
    static var llmURL: String { d.string(forKey: Key.llmURL) ?? defaultLLMURL }
    static var llmModel: String { d.string(forKey: Key.llmModel) ?? defaultLLMModel }
    /// D-3: a notes model was picked (stored), not just the registered default.
    static var llmModelStored: Bool {
        d.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?[Key.llmModel] != nil
    }

    static func expand(_ path: String) -> String {
        if let home = DemoMode.home, path == "~" || path.hasPrefix("~/") { // U-0
            return home.path + path.dropFirst()
        }
        return (path as NSString).expandingTildeInPath
    }

    static let languages: [(code: String, name: String)] = [
        ("auto", "Detect automatically"), ("en", "English"), ("fr", "French"), ("de", "German"),
        ("ar", "Arabic"), ("es", "Spanish"), ("it", "Italian"), ("nl", "Dutch"), ("pt", "Portuguese"),
    ]

    static func languageName(_ code: String) -> String {
        languages.first { $0.code == code }?.name
            ?? Locale.current.localizedString(forLanguageCode: code)?.capitalized
            ?? code
    }
}

/// Whisper models Earl knows how to download.
struct WhisperModelOption: Identifiable, Hashable {
    let file: String
    let name: String
    let approxSize: String
    let note: String
    let sha256: String
    let bytes: Int64
    /// Hugging Face repository the file comes from.
    var source: String = "ggerganov/whisper.cpp"

    var id: String { file }
    var path: String { Prefs.modelsDir.appendingPathComponent(file).path }
    var url: URL { URL(string: "https://huggingface.co/\(source)/resolve/main/\(file)")! }

    static let all: [WhisperModelOption] = [
        .init(file: "ggml-large-v3-turbo.bin", name: "Large v3 Turbo", approxSize: "1.6 GB",
              note: "Recommended. Accurate and fast on Apple silicon.",
              sha256: "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69",
              bytes: 1624555275),
        .init(file: "ggml-large-v3-turbo-q5_0.bin", name: "Large v3 Turbo (compact)", approxSize: "574 MB",
              note: "Nearly the same accuracy at a third of the size.",
              sha256: "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2",
              bytes: 574041195),
        .init(file: "ggml-large-v3.bin", name: "Large v3", approxSize: "3.1 GB",
              note: "Most accurate, especially for accents. About 3× slower.",
              sha256: "64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2",
              bytes: 3095033483),
        .init(file: "ggml-small.bin", name: "Small", approxSize: "488 MB",
              note: "Fast, but misses more words.",
              sha256: "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b",
              bytes: 487601967),
        .init(file: "ggml-base.bin", name: "Base", approxSize: "148 MB",
              note: "Fastest. Rough transcripts.",
              sha256: "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe",
              bytes: 147951465),
    ]

    /// The silence-detection model: downloaded like a model, but not offered as a transcription model.
    static let vad = WhisperModelOption(
        file: URL(fileURLWithPath: Prefs.vadModel).lastPathComponent, name: "Silence detection", approxSize: "1 MB",
        note: "Skips silence so Whisper doesn't invent words.",
        sha256: "29940d98d42b91fbd05ce489f3ecf7c72f0a42f027e4875919a28fb4c04ea2cf",
        bytes: 885_098, source: "ggml-org/whisper-vad")

    static func matching(sha256: String, in options: [WhisperModelOption] = all + [vad]) -> WhisperModelOption? {
        options.first { $0.sha256 == sha256 }
    }

    /// Display name for any model path, including ones not in the list.
    static func displayName(forPath path: String) -> String {
        let file = URL(fileURLWithPath: path).lastPathComponent
        return all.first { $0.file == file }?.name
            ?? file.replacingOccurrences(of: "ggml-", with: "").replacingOccurrences(of: ".bin", with: "")
    }
}

enum Format {
    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s) s" }
        let m = s / 60
        if m < 60 { return s % 60 == 0 || m >= 10 ? "\(m) min" : "\(m) min \(s % 60) s" }
        return "\(m / 60) h \(m % 60) min"
    }
}
