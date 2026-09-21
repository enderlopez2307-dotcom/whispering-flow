import AppKit
import Observation
import SwiftUI

/// What the HUD is showing. Derived from the coordinator's state; the HUD owns
/// no state of its own beyond animation.
enum HUDPhase: Equatable {
    case hidden
    case listening(handsFree: Bool)
    case working(label: String)
}

@MainActor
@Observable
final class HUDModel {
    var phase: HUDPhase = .hidden
    var history = WaveformHistory()
    /// "Tap Right Command to finish · Esc cancels" — derived from the actual
    /// binding, never hardcoded (ADR-017).
    var handsFreeHint = ""
    var reduceMotion = false
}

/// A floating pill with a live waveform while the microphone is open.
///
/// **It must never take focus.** Dictated text is inserted at whatever has
/// keyboard focus, so a HUD that activated this app would redirect the very
/// text it is showing progress for. The panel is non-activating, cannot become
/// key or main, ignores the mouse, and is ordered front without activating.
@MainActor
final class ListeningHUDController {

    private let coordinator: DictationCoordinator
    private let audio: any AudioCapturing
    private let settings: SettingsStore

    private let model = HUDModel()
    private var panel: HUDPanel?
    private var host: NSHostingView<ListeningHUDView>?
    private var levelTimer: Timer?
    /// Bumped on every show/hide so a stale fade-out completion cannot hide a
    /// HUD that has since been shown again.
    private var generation = 0
    /// Where the text cursor was when this dictation began. Looked up once per
    /// session and held, so the pill never jumps while you speak.
    private var anchor: HUDPlacement.Anchor?
    /// Invalidates a caret lookup that finishes after the session is over.
    private var lookupTicket = 0

    init(coordinator: DictationCoordinator,
         audio: any AudioCapturing,
         settings: SettingsStore) {
        self.coordinator = coordinator
        self.audio = audio
        self.settings = settings
    }

    func start() {
        observe()
        stateChanged()
    }

    // MARK: - Observation

    private func observe() {
        withObservationTracking {
            _ = coordinator.state
            _ = coordinator.isHandsFree
            _ = settings.preferences.showListeningHUD
            _ = settings.preferences.hotkey
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.stateChanged()
                self?.observe()
            }
        }
    }

    static func phase(for state: SessionState, handsFree: Bool, enabled: Bool) -> HUDPhase {
        guard enabled else { return .hidden }
        switch state {
        case .listening: return .listening(handsFree: handsFree)
        case .transcribing: return .working(label: "Transcribing…")
        case .processing: return .working(label: "Cleaning up…")
        case .inserting: return .working(label: "Inserting…")
        case .idle, .blocked, .failed: return .hidden
        }
    }

    private func stateChanged() {
        let next = Self.phase(for: coordinator.state,
                              handsFree: coordinator.isHandsFree,
                              enabled: settings.preferences.showListeningHUD)
        guard next != model.phase else { return }
        let wasListening: Bool
        if case .listening = model.phase { wasListening = true } else { wasListening = false }

        model.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        model.handsFreeHint = "Tap \(settings.preferences.hotkey.displayName) to finish · Esc cancels"
        model.phase = next

        switch next {
        case .hidden:
            stopLevelTimer()
            lookupTicket += 1
            hide()
        case .listening:
            if !wasListening {
                model.history.clear()
                startLevelTimer()
                beginAnchorLookup()
            } else if panel?.isVisible == true {
                // Same session, different content (hands-free hint appeared).
                show()
            }
        case .working:
            stopLevelTimer()
            show()
        }
    }

    // MARK: - Caret

    /// Ask the frontmost app where its text cursor is, then show the pill there.
    /// Bounded to 200 ms; if the app will not say, the pill falls back to the
    /// bottom of the screen. The pill is shown only once the answer is in, so
    /// it never appears in one place and then jumps.
    private func beginAnchorLookup() {
        anchor = nil
        lookupTicket += 1
        let ticket = lookupTicket
        Task { @MainActor [weak self] in
            let found = await CaretLocator.locate()
            guard let self, self.lookupTicket == ticket else { return }
            self.anchor = found
            if self.model.phase != .hidden { self.show() }
        }
    }

    // MARK: - Levels

    private func startLevelTimer() {
        stopLevelTimer()
        // 30 Hz is plenty for a meter and costs one lock acquisition per tick.
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.model.history.push(peak: self.audio.consumePeakLevel())
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        levelTimer = timer
    }

    private func stopLevelTimer() {
        levelTimer?.invalidate()
        levelTimer = nil
    }

    // MARK: - Panel

    private func makePanelIfNeeded() -> HUDPanel {
        if let panel { return panel }
        let panel = HUDPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = NSHostingView(rootView: ListeningHUDView(model: model))
        panel.contentView = host
        self.host = host
        self.panel = panel
        return panel
    }

    private func show() {
        generation += 1
        let panel = makePanelIfNeeded()
        resizeAndPosition(panel)
        if !panel.isVisible {
            panel.alphaValue = model.reduceMotion ? 1 : 0
            // Never `makeKeyAndOrderFront`: that would activate this app.
            panel.orderFrontRegardless()
            if !model.reduceMotion {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.12
                    panel.animator().alphaValue = 1
                }
            }
        } else {
            panel.alphaValue = 1
        }
    }

    private func hide() {
        generation += 1
        guard let panel, panel.isVisible else { return }
        let ticket = generation
        if model.reduceMotion {
            panel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.generation == ticket else { return }
                self.panel?.orderOut(nil)
            }
        })
    }

    private func resizeAndPosition(_ panel: NSPanel) {
        guard let host else { return }
        let size = host.fittingSize
        let screen = anchor.flatMap { anchor in
            NSScreen.screens.first { $0.frame.contains(CGPoint(x: anchor.rect.midX, y: anchor.rect.midY)) }
        } ?? NSScreen.main ?? NSScreen.screens.first
        guard let frame = screen?.visibleFrame else { return }
        let origin = HUDPlacement.origin(for: anchor, size: size, screen: frame)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }
}

/// Cannot become key or main, so showing it never moves keyboard focus.
private final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - View

struct ListeningHUDView: View {
    let model: HUDModel

    var body: some View {
        HStack(spacing: 10) {
            switch model.phase {
            case .hidden:
                EmptyView()
            case .listening(let handsFree):
                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)
                WaveformBars(bars: model.history.bars)
                    .frame(width: 112, height: 26)
                if handsFree {
                    Text(model.handsFreeHint)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .fixedSize()
                }
            case .working(let label):
                ProgressDots(animated: !model.reduceMotion)
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .fixedSize()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(.black.opacity(0.78), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        .padding(6)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        switch model.phase {
        case .hidden: ""
        case .listening: "Listening"
        case .working(let label): label
        }
    }
}

private struct WaveformBars: View {
    let bars: [Float]

    var body: some View {
        GeometryReader { proxy in
            let count = max(1, bars.count)
            let spacing: CGFloat = 2
            let width = max(1, (proxy.size.width - spacing * CGFloat(count - 1)) / CGFloat(count))
            HStack(alignment: .center, spacing: spacing) {
                ForEach(0..<bars.count, id: \.self) { index in
                    Capsule()
                        .fill(.white.opacity(0.92))
                        .frame(width: width, height: max(3, proxy.size.height * CGFloat(bars[index])))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }
}

private struct ProgressDots: View {
    let animated: Bool

    var body: some View {
        if animated {
            TimelineView(.animation(minimumInterval: 0.2)) { context in
                dots(phase: Int(context.date.timeIntervalSinceReferenceDate * 5) % 3)
            }
        } else {
            dots(phase: 1)
        }
    }

    private func dots(phase: Int) -> some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(.white.opacity(index == phase ? 0.95 : 0.35))
                    .frame(width: 5, height: 5)
            }
        }
    }
}
