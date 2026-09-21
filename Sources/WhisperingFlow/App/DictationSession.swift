import Foundation

/// One press→insert cycle. A value type, so it can be logged and compared
/// without reaching into live services.
struct DictationSession: Sendable, Identifiable, Equatable {
    let id: UUID
    let startedAt: Date
    let locale: String
    let processingMode: String

    var releasedAt: Date?
    var transcriptID: UUID?
    var targetBundleIdentifier: String?

    /// Release → complete `AudioClip`.
    var audioFinalizeMilliseconds: Double?
    /// Release → finalised `EngineTranscript`. Small, because recognition ran
    /// during capture (ADR-020).
    var finalizeMilliseconds: Double?
    var processingMilliseconds: Double?
    var insertionMilliseconds: Double?

    init(locale: String, processingMode: String, startedAt: Date = Date()) {
        self.id = UUID()
        self.startedAt = startedAt
        self.locale = locale
        self.processingMode = processingMode
    }

    var heldMilliseconds: Double? {
        guard let releasedAt else { return nil }
        return releasedAt.timeIntervalSince(startedAt) * 1000
    }

    /// Key-up → text visible. The number Phase 11 holds to a p95 budget.
    var keyUpToInsertedMilliseconds: Double? {
        guard let finalize = finalizeMilliseconds else { return nil }
        return finalize + (processingMilliseconds ?? 0) + (insertionMilliseconds ?? 0)
    }
}
