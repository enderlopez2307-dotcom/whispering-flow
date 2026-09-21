import Foundation

/// Development-only transcript logging.
///
/// **Off unless enabled in Settings (or `--debug-transcripts`), and clearly marked when on.**
/// Production logging records character counts and timings, never words — a
/// dictation tool that writes what you said into the system log is a tool that
/// leaks passwords, medical details and private messages to anything that can
/// read `log show`.
///
/// This exists because Phase 6 has no text insertion yet (that is Phase 7), so
/// without it there is no way to see what the recogniser actually returned
/// during live testing. It writes to a file the user can delete, not to OSLog,
/// so the transcripts do not enter the system-wide log store at all.
enum DiagnosticTranscriptLog {

    /// The launch flag still works, for testing without touching settings.
    static let launchFlag = ProcessInfo.processInfo.arguments.contains("--debug-transcripts")

    /// Next to the vocabulary file, not in the temp folder: macOS clears temp
    /// folders, and this log is the only record of real-world dictation quality.
    static var directory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhisperingFlow", isDirectory: true)
    }

    static var url: URL {
        directory.appendingPathComponent("whispering-flow-transcripts.log")
    }

    /// One entry per dictation: every stage's text, plus where it went and how.
    ///
    /// The point is to make a quality complaint localisable. If the engine line
    /// is already wrong, it is recognition; if the engine line is right and the
    /// final line is wrong, it is processing; if the final line is right and the
    /// document is wrong, it is insertion — and the strategy is recorded so a
    /// target-specific insertion bug can be seen.
    static func record(trace: ProductionTextProcessor.Trace?,
                       final: String,
                       locale: String,
                       audioSeconds: Double,
                       finalizeMs: Double,
                       delivery: String,
                       target: String?) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        var entry = "[\(stamp)] \(locale) audio=\(String(format: "%.2f", audioSeconds))s "
        entry += "finalize=\(String(format: "%.1f", finalizeMs))ms\n"
        if let trace {
            entry += "  engine       : \(trace.engine)\n"
            if trace.afterVocabulary != trace.engine {
                entry += "  vocabulary   : \(trace.afterVocabulary)\n"
                entry += "  rules fired  : \(trace.vocabularyHits.joined(separator: ", "))\n"
            }
            entry += "  deterministic: \(trace.deterministic)\n"
            if trace.smartRequested {
                if let smart = trace.smart {
                    entry += "  smart        : \(smart)  (\(Int(trace.smartMilliseconds)) ms)\n"
                } else {
                    entry += "  smart        : SKIPPED — \(trace.smartFallbackReason ?? "?") (\(Int(trace.smartMilliseconds)) ms)\n"
                }
            }
        }
        entry += "  final        : \(final)\n"
        entry += "  delivered    : \(delivery) → \(target ?? "unknown target")\n"

        guard let data = entry.data(using: .utf8) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        rotateIfNeeded(at: url)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            // 0600: readable only by this user.
            FileManager.default.createFile(atPath: url.path, contents: data,
                                           attributes: [.posixPermissions: 0o600])
        }
    }

    /// Above this the log rolls over. It is a plaintext record of everything
    /// dictated, so it must not grow forever just because it was left on.
    static let rotationLimitBytes = 4_000_000

    /// Keep at most two files: the current log and one previous roll-over.
    static func rotateIfNeeded(at url: URL, limit: Int = rotationLimitBytes) {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard size > limit else { return }
        let previous = previousURL(for: url)
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.moveItem(at: url, to: previous)
    }

    static func previousURL(for url: URL) -> URL { url.appendingPathExtension("1") }

    static func clear() {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: previousURL(for: url))
    }
}
