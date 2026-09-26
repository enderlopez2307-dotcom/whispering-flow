import Foundation
import CoreGraphics
import Testing
@testable import WhisperingFlowKit

@Suite("Waveform mapping")
struct WaveformHistoryTests {

    @Test("Silence, garbage and negatives draw as zero")
    func silence() {
        #expect(WaveformHistory.normalise(0) == 0)
        #expect(WaveformHistory.normalise(-0.5) == 0)
        #expect(WaveformHistory.normalise(.nan) == 0)
        #expect(WaveformHistory.normalise(.infinity) == 0)
        // Room noise (~ -54 dBFS) is below the floor.
        #expect(WaveformHistory.normalise(0.002) == 0)
    }

    @Test("Loud input tops out at 1 and never exceeds it")
    func ceiling() {
        #expect(WaveformHistory.normalise(1) == 1)
        #expect(WaveformHistory.normalise(0.6) == 1)
        #expect(WaveformHistory.normalise(0.5) > 0.99)
        #expect(WaveformHistory.normalise(40) == 1)
    }

    @Test("Ordinary speech peaks land in the visible middle, and rise with volume")
    func speechIsVisibleAndMonotonic() {
        let quiet = WaveformHistory.normalise(0.03)   // about -30 dBFS
        let normal = WaveformHistory.normalise(0.15)  // about -16 dBFS
        #expect(quiet > 0.2 && quiet < 0.7)
        #expect(normal > quiet)
        #expect(normal < 1)
    }

    @Test("The history keeps its capacity and drops the oldest bar")
    func capacity() {
        var history = WaveformHistory(capacity: 4)
        for peak: Float in [0.5, 0.5, 0.5, 0.5, 0.5, 0.5] { history.push(peak: peak) }
        #expect(history.bars.count == 4)
    }

    @Test("Bars fall gradually after a loud burst instead of snapping to zero")
    func release() {
        var history = WaveformHistory(capacity: 6)
        history.push(peak: 0.5)
        history.push(peak: 0)
        let afterOne = history.bars.last!
        #expect(afterOne > 0 && afterOne < 1)
        for _ in 0..<60 { history.push(peak: 0) }
        #expect(history.bars.last == 0, "it must settle to a flat line, not hover")
    }

    @Test("Clear resets every bar")
    func clear() {
        var history = WaveformHistory(capacity: 5)
        history.push(peak: 0.5)
        history.clear()
        #expect(history.bars == Array(repeating: 0, count: 5))
    }
}

@Suite("HUD phase follows the session")
@MainActor
struct HUDPhaseTests {

    @Test("Listening shows the waveform, hands-free is carried through")
    func listening() {
        #expect(ListeningHUDController.phase(for: .listening(startedAt: .now), handsFree: false, enabled: true)
                == .listening(handsFree: false))
        #expect(ListeningHUDController.phase(for: .listening(startedAt: .now), handsFree: true, enabled: true)
                == .listening(handsFree: true))
    }

    @Test("Busy states after release show progress; idle, blocked and failed hide")
    func otherStates() {
        #expect(ListeningHUDController.phase(for: .transcribing, handsFree: false, enabled: true)
                == .working(label: "Transcribing…"))
        #expect(ListeningHUDController.phase(for: .processing, handsFree: false, enabled: true)
                == .working(label: "Cleaning up…"))
        #expect(ListeningHUDController.phase(for: .idle, handsFree: false, enabled: true) == .hidden)
        #expect(ListeningHUDController.phase(for: .failed(.noSpeechDetected), handsFree: false, enabled: true) == .hidden)
        #expect(ListeningHUDController.phase(for: .blocked(.secureInput(holder: nil)), handsFree: false, enabled: true) == .hidden)
    }

    @Test("Turned off in Settings, it never shows")
    func disabled() {
        #expect(ListeningHUDController.phase(for: .listening(startedAt: .now), handsFree: true, enabled: false) == .hidden)
        #expect(ListeningHUDController.phase(for: .transcribing, handsFree: false, enabled: false) == .hidden)
    }
}

@Suite("HUD placement")
struct HUDPlacementTests {

    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let pill = CGSize(width: 200, height: 44)

    @Test("Accessibility's top-left coordinates are flipped to AppKit's bottom-left")
    func flipsCoordinates() {
        // A caret 100 pt from the top of a 900 pt primary display, 20 pt tall.
        let ax = CGRect(x: 300, y: 100, width: 2, height: 20)
        let appKit = HUDPlacement.appKitRect(fromAX: ax, primaryScreenHeight: 900)
        #expect(appKit.minY == 780)      // 900 - (100 + 20)
        #expect(appKit.maxY == 800)      // 900 - 100
        #expect(appKit.minX == 300 && appKit.height == 20)
    }

    @Test("With a caret, the pill sits just below it and is centred on it")
    func belowCaret() {
        let caret = HUDPlacement.Anchor(rect: CGRect(x: 600, y: 500, width: 2, height: 18), kind: .caret)
        let origin = HUDPlacement.origin(for: caret, size: pill, screen: screen)
        #expect(origin.y == 500 - 44 - HUDPlacement.gap)
        #expect(abs((origin.x + 100) - 601) < 1)
    }

    @Test("A caret near the bottom of the screen puts the pill above it instead")
    func aboveWhenNoRoom() {
        let caret = HUDPlacement.Anchor(rect: CGRect(x: 600, y: 30, width: 2, height: 18), kind: .caret)
        let origin = HUDPlacement.origin(for: caret, size: pill, screen: screen)
        #expect(origin.y == 48 + HUDPlacement.gap)
    }

    @Test("The pill is kept fully on screen at both edges")
    func clampedHorizontally() {
        let left = HUDPlacement.Anchor(rect: CGRect(x: 2, y: 500, width: 2, height: 18), kind: .caret)
        let right = HUDPlacement.Anchor(rect: CGRect(x: 1438, y: 500, width: 2, height: 18), kind: .caret)
        #expect(HUDPlacement.origin(for: left, size: pill, screen: screen).x >= HUDPlacement.screenMargin)
        let r = HUDPlacement.origin(for: right, size: pill, screen: screen)
        #expect(r.x + pill.width <= screen.maxX - HUDPlacement.screenMargin + 0.001)
    }

    @Test("A big editor with no caret gets the pill inside its bottom edge")
    func bigElement() {
        let editor = HUDPlacement.Anchor(rect: CGRect(x: 200, y: 100, width: 800, height: 600), kind: .element)
        let origin = HUDPlacement.origin(for: editor, size: pill, screen: screen)
        #expect(origin.y == 100 + HUDPlacement.gap)
    }

    @Test("A small element such as a chat box is treated like a caret: pill below it")
    func smallElement() {
        let box = HUDPlacement.Anchor(rect: CGRect(x: 200, y: 300, width: 600, height: 40), kind: .element)
        let origin = HUDPlacement.origin(for: box, size: pill, screen: screen)
        #expect(origin.y == 300 - 44 - HUDPlacement.gap)
    }

    @Test("No anchor falls back to the bottom centre of the screen")
    func fallback() {
        let origin = HUDPlacement.origin(for: nil, size: pill, screen: screen)
        #expect(origin.x == 620)
        #expect(origin.y == 28)
    }

    @Test("Zero and non-finite rectangles are rejected")
    func usable() {
        #expect(!HUDPlacement.isUsable(.zero))
        #expect(!HUDPlacement.isUsable(CGRect(x: CGFloat.nan, y: 0, width: 1, height: 1)))
        #expect(!HUDPlacement.isUsable(CGRect(x: 10, y: 10, width: 5, height: 0)))
        #expect(HUDPlacement.isUsable(CGRect(x: 10, y: 10, width: 0, height: 16)), "a zero-width caret is valid")
    }
}

@Suite("Hands-free countdown")
struct HandsFreeCountdownTests {
    private let hint = "Tap Right Command to finish · Esc cancels"
    private let now = Date(timeIntervalSinceReferenceDate: 1_000)

    @Test("Before the last 15 s the usual hint shows")
    func hintUntilWindow() {
        let line = HUDModel.handsFreeLine(hint: hint, endsAt: now.addingTimeInterval(15.5), now: now)
        #expect(line.text == hint)
        #expect(!line.urgent)
    }

    @Test("Inside the window it counts down in whole seconds, rounded up", arguments: [
        (15.0, "Stops in 15 s · tap to finish"),
        (9.2, "Stops in 10 s · tap to finish"),
        (0.4, "Stops in 1 s · tap to finish"),
        (-2.0, "Stops in 0 s · tap to finish"),
    ])
    func countsDown(remaining: Double, expected: String) {
        let line = HUDModel.handsFreeLine(hint: hint, endsAt: now.addingTimeInterval(remaining), now: now)
        #expect(line.text == expected)
        #expect(line.urgent)
    }

    @Test("No deadline means no countdown")
    func noDeadline() {
        #expect(HUDModel.handsFreeLine(hint: hint, endsAt: nil, now: now).text == hint)
    }

    @Test("The countdown is never wider than the hint it replaces, so the pill never grows")
    func neverWider() {
        let line = HUDModel.handsFreeLine(hint: hint, endsAt: now.addingTimeInterval(15), now: now)
        #expect(line.text.count <= hint.count)
    }

    @Test("The limit stays under the 300 s capture buffer")
    func underBuffer() {
        #expect(HandsFreeLimit.seconds <= 285)
        #expect(HandsFreeLimit.warningWindow < HandsFreeLimit.seconds)
    }
}
