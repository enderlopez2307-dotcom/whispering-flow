import Foundation
import HotkeyGestureCore

/// Placeholders for the phases not yet built.
///
/// They fail loudly rather than silently doing nothing, so a wiring mistake in
/// Phase 3 cannot masquerade as a working app. Each is replaced wholesale by its
/// phase; none of this logic survives.

/// Kept for tests only: a processor that changes nothing, so a coordinator
/// test can assert routing without depending on cleanup behaviour.
struct PassthroughTextProcessor: TextProcessing {
    func process(_ transcript: EngineTranscript, smart: Bool) async -> String { transcript.text }
}
