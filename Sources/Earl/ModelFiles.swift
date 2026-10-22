import CryptoKit
import Foundation

/// D-2: model files are checked before Earl uses them. A proxy page or a cut-off
/// download otherwise only shows up later as "whisper-cli failed (exit code 3)".
enum ModelFiles {
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func verify(_ url: URL, sha256 expected: String) throws {
        guard try sha256(of: url) == expected else {
            throw PipelineError.message("The downloaded file is damaged or incomplete. Try again, or ask a colleague for the file.")
        }
    }

    /// Puts a verified copy of `source` at `destination`. Copies beside the destination, checks the
    /// copy, then swaps it in, so a failure never leaves a truncated or missing model behind.
    /// Installing a file onto itself does nothing.
    static func install(from source: URL, to destination: URL, sha256 expected: String) throws {
        func canonical(_ u: URL) -> URL { u.standardizedFileURL.resolvingSymlinksInPath() }
        if canonical(source) == canonical(destination) { return }
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temp = destination.appendingPathExtension("importing")
        try? fm.removeItem(at: temp)
        do {
            try fm.copyItem(at: source, to: temp)
            try verify(temp, sha256: expected)
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: temp)
            } else {
                try fm.moveItem(at: temp, to: destination)
            }
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
    }
}
