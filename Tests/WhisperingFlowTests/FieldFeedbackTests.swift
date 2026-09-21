import Foundation
import Testing
import TextProcessingCore
@testable import WhisperingFlowKit

private func trace(smartRequested: Bool,
                   fellBack: Bool = false,
                   reason: String? = nil,
                   ms: Double = 0) -> ProductionTextProcessor.Trace {
    var t = ProductionTextProcessor.Trace(
        engine: "a", afterVocabulary: "a", deterministic: "a",
        smart: smartRequested && !fellBack ? "A." : nil,
        vocabularyHits: [], vocabularyMilliseconds: 0, deterministicMilliseconds: 0,
        smartMilliseconds: ms, smartFellBack: fellBack, smartFallbackReason: reason)
    t.smartRequested = smartRequested
    return t
}

@Suite("Smart timeout scales with input (field feedback §0)")
struct SmartTimeoutTests {

    @Test("The measured 1282-character run is no longer at the edge of its budget")
    func fieldMeasurementHasHeadroom() {
        // Field: 1282 chars took 3988.88 ms against a flat 4000 ms budget —
        // 11 ms of headroom. Anything longer silently fell back to Fast.
        let budget = SmartCleanup.timeout(forCharacters: 1_282)
        #expect(budget >= .milliseconds(3_989 * 2),
                "budget \(budget) must be at least twice the measured cost")
    }

    @Test("Short input keeps the original floor, long input is capped")
    func floorAndCap() {
        #expect(SmartCleanup.timeout(forCharacters: 20) == .seconds(4))
        #expect(SmartCleanup.timeout(forCharacters: 50_000) == .seconds(15))
    }

    @Test("The budget never shrinks as input grows")
    func monotonic() {
        var previous = Duration.zero
        for count in stride(from: 0, through: 5_000, by: 50) {
            let budget = SmartCleanup.timeout(forCharacters: count)
            #expect(budget >= previous)
            previous = budget
        }
    }
}

@Suite("Smart fallback is visible (field feedback §0)")
@MainActor
struct SmartFallbackVisibilityTests {

    private func model(_ trace: ProductionTextProcessor.Trace?, unseen: Bool) -> MenuBarModel {
        MenuBarModel.make(session: .idle, preferences: .default, permissionStatuses: [:],
                          latestRecoverable: nil, launchAtLogin: false, isDebugBuild: false,
                          lastTrace: trace, smartSkipUnseen: unseen)
    }

    @Test("A skipped Smart run changes the icon until the menu is opened")
    func iconSignalsTheSkip() {
        let skipped = trace(smartRequested: true, fellBack: true, reason: "timed out after 9.7 s")
        #expect(model(skipped, unseen: true).state == .smartSkipped)
        #expect(model(skipped, unseen: false).state == .idle,
                "once seen, the icon returns to normal")
    }

    @Test("The menu says why Smart was skipped and what was inserted instead")
    func menuExplainsTheSkip() {
        let skipped = trace(smartRequested: true, fellBack: true, reason: "timed out after 9.7 s")
        let titles = MenuBarMenuBuilder.items(for: model(skipped, unseen: false)).map(\.title)
        let notice = titles.first { $0.contains("Smart cleanup skipped") } ?? ""
        #expect(notice.contains("timed out after 9.7 s"))
        #expect(notice.contains("Fast text was inserted"))
    }

    @Test("A successful Smart run says so; a Fast run says nothing")
    func successAndFast() {
        let applied = trace(smartRequested: true, ms: 2_004)
        #expect(MenuBarModel.notice(for: applied)?.contains("applied (2.0 s)") == true)
        #expect(MenuBarModel.notice(for: trace(smartRequested: false)) == nil,
                "Fast is the normal case and needs no comment")
    }

    @Test("A failed session still takes priority over the Smart icon")
    func failureOutranksSkip() {
        let skipped = trace(smartRequested: true, fellBack: true, reason: "x")
        let failed = MenuBarModel.make(
            session: .failed(.insertionFailed("no")), preferences: .default,
            permissionStatuses: [:], latestRecoverable: nil, launchAtLogin: false,
            isDebugBuild: false, lastTrace: skipped, smartSkipUnseen: true)
        #expect(failed.state == .failed)
    }
}

@Suite("Diagnostics and correction capture (field feedback §1, §2)")
@MainActor
struct DiagnosticsAndCorrectionTests {

    @Test("Transcript recording is off by default and persists when enabled")
    func recordingPreferencePersists() {
        #expect(Preferences.default.recordDiagnosticTranscripts == false,
                "a plaintext record of everything said must never be on by default")
        let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        let first = SettingsStore(defaults: defaults)
        first.preferences.recordDiagnosticTranscripts = true
        #expect(SettingsStore(defaults: defaults).preferences.recordDiagnosticTranscripts)
    }

    @Test("The correction flow is reachable from the menu bar")
    func correctionItemIsInTheMenu() {
        let model = MenuBarModel.make(session: .idle, preferences: .default,
                                      permissionStatuses: [:], latestRecoverable: nil,
                                      launchAtLogin: false, isDebugBuild: false)
        let items = MenuBarMenuBuilder.items(for: model)
        #expect(items.contains { $0.action == .addVocabularyCorrection })
    }

    @Test("Starting a correction opens the Vocabulary tab pre-filled, even twice")
    func draftOpensVocabularyTab() {
        let draft = VocabularyDraft()
        draft.begin(spoken: "  Soneto ")
        #expect(draft.selectedTab == .vocabulary)
        #expect(draft.spoken == "Soneto")
        let revision = draft.revision
        draft.begin(spoken: "Soneto")
        #expect(draft.revision == revision + 1,
                "choosing the same word again must still re-apply the pre-fill")
    }
}
