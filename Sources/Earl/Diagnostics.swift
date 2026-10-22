import Foundation

/// D-2: facts about this Mac and this install, for pasting into a message to whoever set Earl up.
/// Never meeting content: no titles, names or transcript text.
struct DiagnosticsSnapshot {
    var version: String
    var build: String
    var macOS: String
    var chip: String
    var memoryGB: Int
    var bundlePath: String
    var whisperPath: String
    var whisperVersion: String?
    var models: [String: Int64]
    var vad: Bool
    var speakerModels: Bool
    var mic: String
    var screenAudio: String
    var llmURL: String
    var llmReachable: Bool
    var llmKind: String
    var llmModel: String
    var meetingCount: Int
    var recentErrors: [String]
}

enum Diagnostics {
    /// `/Users/<name>/` becomes `/Users/~/`.
    static func mask(_ s: String) -> String {
        s.replacingOccurrences(of: "/Users/[^/\\s]+/", with: "/Users/~/", options: .regularExpression)
            .replacingOccurrences(of: "(//)[^/@\\s]+@", with: "$1", options: .regularExpression)
    }

    /// A URL without credentials.
    static func safeURL(_ s: String) -> String {
        if var c = URLComponents(string: s), c.user != nil || c.password != nil {
            c.user = nil
            c.password = nil
            if let out = c.string { return mask(out) }
        }
        return mask(s)
    }

    /// An error as safe to paste: the AI server's reply body can echo the request (the transcript),
    /// so anything after the server's status is dropped. Only the part before the first colon survives (the tail may be external text). Masked first, then cut.
    static func safeError(_ e: String) -> String {
        var out = mask(e)
        if let r = out.range(of: "AI server returned HTTP \\d+", options: .regularExpression) {
            out = String(out[r])
        } else if let r = out.range(of: ": ") {
            out = String(out[..<r.lowerBound])
        }
        return String(out.prefix(200))
    }

    static func report(_ s: DiagnosticsSnapshot) -> String {
        var lines: [String] = []
        func heading(_ h: String) { if !lines.isEmpty { lines.append("") }; lines.append(h) }
        func yesNo(_ b: Bool) -> String { b ? "yes" : "no" }

        heading("App")
        lines.append("Earl \(s.version) (\(s.build))")
        lines.append("Location: \(s.bundlePath)")
        lines.append("Meetings: \(s.meetingCount)")

        heading("Mac")
        lines.append("macOS: \(s.macOS)")
        lines.append("Chip: \(s.chip)")
        lines.append("Memory: \(s.memoryGB) GB")

        heading("Transcription")
        lines.append("whisper-cli: \(s.whisperPath.isEmpty ? "not found" : s.whisperPath)")
        lines.append("whisper version: \(s.whisperVersion ?? "unknown")")
        if s.models.isEmpty {
            lines.append("Models: none")
        } else {
            for (name, bytes) in s.models.sorted(by: { $0.key < $1.key }) { lines.append("Model: \(name) (\(bytes) bytes)") }
        }
        lines.append("Voice activity model: \(yesNo(s.vad))")
        lines.append("Speaker models: \(yesNo(s.speakerModels))")

        heading("Permissions")
        lines.append("Microphone: \(s.mic)")
        lines.append("Screen & System Audio: \(s.screenAudio)")

        heading("Notes")
        lines.append("Server: \(s.llmKind)")
        lines.append("URL: \(safeURL(s.llmURL))")
        lines.append("Reachable: \(yesNo(s.llmReachable))")
        lines.append("Model: \(s.llmModel)")

        heading("Recent errors")
        if s.recentErrors.isEmpty { lines.append("none") } else { lines.append(contentsOf: s.recentErrors.map(safeError)) }

        return lines.map(mask).joined(separator: "\n")
    }

    @MainActor
    static func snapshot(engine: Engine, meetings: [Meeting]) -> DiagnosticsSnapshot {
        let info = Bundle.main.infoDictionary
        func perm(_ p: Engine.Permission) -> String {
            switch p { case .granted: "granted"; case .denied: "denied"; case .notAsked: "not asked" }
        }
        let kind = NotesEngine.kind(engine.notesBackend)
        let errors = meetings.sorted { $0.info.startedAt > $1.info.startedAt }
            .compactMap { $0.info.error }.prefix(5).map(safeError)
        return DiagnosticsSnapshot(
            version: info?["CFBundleShortVersionString"] as? String ?? "dev",
            build: info?["CFBundleVersion"] as? String ?? "dev",
            macOS: ProcessInfo.processInfo.operatingSystemVersion.formatted(),
            chip: sysctlString("machdep.cpu.brand_string") ?? "unknown",
            memoryGB: Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824),
            bundlePath: Bundle.main.bundlePath, whisperPath: Prefs.whisperPath,
            whisperVersion: engine.whisperVersion, models: engine.installedModels,
            vad: engine.vadInstalled, speakerModels: Diarizer().isInstalled,
            mic: engine.microphoneRestricted ? "restricted" : perm(engine.microphone),
            screenAudio: perm(engine.screenAudio),
            llmURL: NotesEngine.baseURL(for: engine.notesBackend) ?? "—", llmReachable: engine.server.reachable, llmKind: kind, llmModel: engine.notesModel,
            meetingCount: meetings.count, recentErrors: errors)
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }
}

private extension OperatingSystemVersion {
    func formatted() -> String { "\(majorVersion).\(minorVersion)" + (patchVersion > 0 ? ".\(patchVersion)" : "") }
}
