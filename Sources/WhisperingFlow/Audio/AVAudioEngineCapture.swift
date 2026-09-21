import AVFoundation
import AudioCaptureCore
import CoreAudio
import Foundation
import Observation

/// Production microphone capture.
///
/// The engine is **stopped while idle** — a menu-bar app that holds the
/// microphone open all day is both a battery cost and a privacy claim we are
/// not willing to make. Capture starts on the physical trigger press and the
/// first ~151 ms lands in a pre-roll ring, so the user can speak immediately
/// without waiting for the hold threshold (ADR-018).
///
/// Everything real-time lives in `CaptureBuffer`, which is lock-guarded and
/// allocation-free. This type owns only the engine, the format conversion and
/// the lifecycle.
@MainActor
@Observable
final class AVAudioEngineCapture: AudioCapturing {

    private(set) var isEngineRunning = false
    private(set) var isCapturing = false
    private(set) var lastError: String?

    /// Development-safe diagnostics. Frame counts, durations and formats only.
    private(set) var diagnostics = CaptureDiagnostics()

    private let engine = AVAudioEngine()
    private let buffer: CaptureBuffer
    private let settings: SettingsStore

    private var converter: AVAudioConverter?
    private var tapInstalled = false
    /// Set when a configuration change invalidates the tap and converter.
    /// Preparation is otherwise done once, at launch — doing it per key-press
    /// cost 52 ms of the 151 ms pre-roll budget and, because `setDeviceID`
    /// reconfigures the engine, fired a configuration-change notification that
    /// killed the very first session of every launch.
    private var needsPreparation = true
    private var configuredDeviceID: AudioDeviceID?
    /// Held so the block observer stays registered for the life of the service.
    /// The service lives as long as the app, so there is no removal path — and
    /// `deinit` cannot touch `@MainActor` state to do it anyway.
    private var configurationObserver: (any NSObjectProtocol)?

    /// Uptime of the physical press, for the capture-start measurement.
    private var preRollRequestedAt: Double?

    /// Live feed to the recogniser, open only between promotion and finish.
    private var sampleFeed: AsyncStream<[Float]>.Continuation?

    /// Canonical target. See `AudioClip`.
    static let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                            sampleRate: 16_000,
                                            channels: 1,
                                            interleaved: false)!

    init(settings: SettingsStore,
         preRollSeconds: Double = 0.5,
         maximumSeconds: Double = 300) {
        self.settings = settings
        self.buffer = CaptureBuffer(sampleRate: Self.targetFormat.sampleRate,
                                    preRollSeconds: preRollSeconds,
                                    maximumSeconds: maximumSeconds)
        observeConfigurationChanges()
    }

    // MARK: - Lifecycle

    /// Resolve the device, build the converter and install the tap, without
    /// starting the engine. Idempotent: real work happens only on the first
    /// call and after a configuration change.
    func prepare() throws {
        guard needsPreparation else { return }
        guard AudioDeviceRegistry.hasAnyInput() else {
            throw AudioCaptureError.noInputDevice
        }
        try selectConfiguredDevice()

        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioCaptureError.invalidInputFormat(describe(inputFormat))
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: Self.targetFormat) else {
            throw AudioCaptureError.conversionUnavailable(
                from: describe(inputFormat), to: describe(Self.targetFormat))
        }
        // Multi-channel interfaces must be mixed down, not truncated to
        // channel 0 — otherwise a stereo interface whose mic is on the right
        // channel records silence (acceptance criterion 3).
        converter.downmix = true
        self.converter = converter

        diagnostics.inputFormat = describe(inputFormat)
        diagnostics.convertedFormat = describe(Self.targetFormat)

        installTapIfNeeded(inputFormat: inputFormat)
        engine.prepare()
        needsPreparation = false
    }

    /// Replace the converter and re-point the tap at it. See `beginPreRoll`.
    private func rebuildConverter() throws {
        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        guard let fresh = AVAudioConverter(from: inputFormat, to: Self.targetFormat) else {
            throw AudioCaptureError.conversionUnavailable(
                from: describe(inputFormat), to: describe(Self.targetFormat))
        }
        fresh.downmix = true
        converter = fresh
        // The tap closure captured the previous converter by value, so it has
        // to be rebuilt to see the new one.
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        installTapIfNeeded(inputFormat: inputFormat)
    }

    /// Physical trigger down. Provisional: may be promoted or discarded.
    func beginPreRoll() throws {
        guard !isCapturing else { return }
        preRollRequestedAt = ProcessInfo.processInfo.systemUptime

        // Normally a no-op: preparation happened at launch. It only does work
        // here after a device change, which is exactly when it must.
        try prepare()

        // Build a *fresh* converter for every capture.
        //
        // A retained `AVAudioConverter` carries its resampler's delay line
        // across sessions: clips were opening with a decaying tail of the
        // previous utterance, its amplitude tracking whatever was recorded last
        // (0.018 after a hum, 0.003 after silence). `reset()` did not clear it.
        // After a *cancelled* session that resurrects audio the user asked to
        // discard, so this is a privacy fix as much as a correctness one.
        //
        // The cost is one allocation per press, measured below and reported in
        // the capture-start latency. Safe here: the engine is stopped, so the
        // real-time callback is not running and cannot hold the old converter.
        try rebuildConverter()

        buffer.beginPreRoll()
        do {
            try engine.start()
        } catch {
            buffer.discard()
            isEngineRunning = false
            // A start failure with a granted-looking permission is the shape of
            // an externally revoked microphone grant: Phase 3 established that
            // `AVCaptureDevice.authorizationStatus` caches per-process and a
            // running app cannot see the revocation (TECH_RESEARCH §17).
            throw AudioCaptureError.engineStartFailed(
                error.localizedDescription,
                cachedPermission: PermissionProbe.status(of: .microphone).rawValue)
        }

        isEngineRunning = true
        isCapturing = true
        diagnostics.captureStartMilliseconds =
            (ProcessInfo.processInfo.systemUptime - (preRollRequestedAt ?? 0)) * 1000
        Log.audio.info("pre-roll started in \(Self.round2(self.diagnostics.captureStartMilliseconds), privacy: .public) ms — \(self.diagnostics.inputFormat, privacy: .public) -> \(self.diagnostics.convertedFormat, privacy: .public)")
    }

    /// Hold threshold reached. Splices the pre-roll onto the session and opens
    /// the live feed to the recogniser, beginning with the pre-roll audio.
    @discardableResult
    func promoteToSession() -> AsyncStream<[Float]> {
        let (stream, continuation) = AsyncStream<[Float]>.makeStream()
        guard isCapturing else {
            continuation.finish()
            return stream
        }
        let promoted = buffer.promoteAndCopy()
        sampleFeed = continuation
        // The pre-roll goes first, so the recogniser sees the utterance from its
        // true beginning rather than from the moment the threshold elapsed.
        if !promoted.isEmpty { continuation.yield(promoted) }
        // Unbounded on purpose: dropping audio to bound a queue would silently
        // truncate a transcript. At 16 kHz mono Float32 the feed is 64 KB/s and
        // the analyzer keeps up (Phase 2 measured this).
        // Continuations are value types and safe to yield to from any thread;
        // `closeSampleFeed` clears this sink, so there is no retain cycle to
        // break with `weak`.
        buffer.onSessionSamples = { samples in continuation.yield(samples) }
        let metrics = buffer.currentMetrics
        diagnostics.preRollFrames = metrics.promotedPreRollFrames
        if let first = metrics.firstBufferUptime, let requested = preRollRequestedAt {
            diagnostics.firstBufferMilliseconds = (first - requested) * 1000
        }
        Log.audio.info("promoted — pre-roll \(metrics.promotedPreRollFrames, privacy: .public) frames (\(Self.round2(self.buffer.seconds(metrics.promotedPreRollFrames) * 1000), privacy: .public) ms), first buffer at \(Self.round2(self.diagnostics.firstBufferMilliseconds), privacy: .public) ms")
        return stream
    }

    /// Close the live feed. Both finish and cancel must do this, or the
    /// recogniser waits forever for audio that will never arrive.
    private func closeSampleFeed() {
        buffer.onSessionSamples = nil
        sampleFeed?.finish()
        sampleFeed = nil
    }

    func finishRecording() async throws -> AudioClip {
        guard isCapturing else { throw AudioCaptureError.notCapturing }
        let startedStopping = ProcessInfo.processInfo.systemUptime

        stopEngine()
        closeSampleFeed()
        let samples = buffer.finish()
        let metrics = buffer.currentMetrics
        isCapturing = false

        diagnostics.finalizeMilliseconds =
            (ProcessInfo.processInfo.systemUptime - startedStopping) * 1000
        diagnostics.capturedFrames = samples.count
        diagnostics.overflowFrames = metrics.overflowFrames
        diagnostics.strayBuffers = metrics.strayBuffers
        diagnostics.evictedPreRollFrames = metrics.evictedPreRollFrames
        diagnostics.audioCallbackRanOnMainThread = metrics.sawMainThreadCallback
        if metrics.sawMainThreadCallback {
            Log.audio.error("AUDIO CALLBACK RAN ON THE MAIN THREAD — real-time safety violated")
        }

        guard !samples.isEmpty else { throw AudioCaptureError.noAudioCaptured }

        Log.audio.info("captured \(samples.count, privacy: .public) frames (\(Self.round2(Double(samples.count) / 16_000), privacy: .public) s), pre-roll \(metrics.promotedPreRollFrames, privacy: .public), overflow \(metrics.overflowFrames, privacy: .public), stray \(metrics.strayBuffers, privacy: .public), finalize \(Self.round2(self.diagnostics.finalizeMilliseconds), privacy: .public) ms")

        return AudioClip(samples: samples,
                         sampleRate: Self.targetFormat.sampleRate,
                         preRollFrameCount: metrics.promotedPreRollFrames)
    }

    func cancel() {
        guard isCapturing || isEngineRunning else { return }
        stopEngine()
        closeSampleFeed()
        buffer.discard()
        isCapturing = false
        Log.audio.info("capture discarded")
    }

    func consumePeakLevel() -> Float { buffer.consumePeakLevel() }

    // MARK: - Engine

    private func stopEngine() {
        if engine.isRunning { engine.stop() }
        isEngineRunning = false
    }

    /// The tap is installed once and left in place across sessions. Removing and
    /// reinstalling it per press adds latency to the one path that cannot
    /// afford any, and the buffer already ignores audio that arrives while idle.
    private func installTapIfNeeded(inputFormat: AVAudioFormat) {
        guard !tapInstalled else { return }
        Self.installTap(on: engine.inputNode,
                        format: inputFormat,
                        target: Self.targetFormat,
                        converter: converter,
                        buffer: buffer)
        tapInstalled = true
    }

    /// **`nonisolated` on purpose, and this is not a style choice.**
    ///
    /// A closure written inside an `@MainActor` method inherits MainActor
    /// isolation from its lexical scope, whatever it captures. `AVAudioEngine`
    /// then invokes it on `RealtimeMessenger.mServiceQueue`, Swift 6 inserts an
    /// executor assertion, and the very first buffer traps with SIGTRAP
    /// (TECH_RESEARCH §15.4 — this cost a full debugging session in Phase 2, and
    /// a first attempt at fixing it by making the captured state `Sendable` did
    /// *not* work). Building the closure in a `nonisolated static` context is
    /// what actually fixes it.
    ///
    /// The closure therefore captures only `Sendable` values with no actor
    /// isolation: the converter, the two formats, and the lock-guarded buffer.
    nonisolated private static func installTap(on input: AVAudioInputNode,
                                               format: AVAudioFormat,
                                               target: AVAudioFormat,
                                               converter: AVAudioConverter?,
                                               buffer: CaptureBuffer) {
        // 512 frames ≈ 10.7 ms at 48 kHz. The first tap callback cannot arrive
        // before one buffer's worth of audio exists, so this size is a direct
        // term in the pre-roll latency; 1024 measurably delayed the first
        // buffer for no benefit.
        input.installTap(onBus: 0, bufferSize: 512, format: format) { incoming, _ in
            guard let converter else { return }
            convert(incoming, using: converter, to: target, into: buffer)
        }
    }

    /// Real-time audio thread. No allocation beyond the converter's own output
    /// buffer, no locks held across work, no logging, no actor hops, no I/O.
    nonisolated private static func convert(_ incoming: AVAudioPCMBuffer,
                                            using converter: AVAudioConverter,
                                            to target: AVAudioFormat,
                                            into buffer: CaptureBuffer) {
        guard incoming.frameLength > 0 else { return }
        let ratio = target.sampleRate / incoming.format.sampleRate
        let capacity = AVAudioFrameCount(Double(incoming.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }

        // The converter pulls its input through this block. It is invoked
        // synchronously, but the compiler cannot prove that, so the "already
        // supplied" flag lives in a Sendable box rather than a captured `var`.
        final class Supply: @unchecked Sendable {
            var delivered = false
            let source: AVAudioPCMBuffer
            init(_ source: AVAudioPCMBuffer) { self.source = source }
        }
        let supply = Supply(incoming)

        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supply.delivered { status.pointee = .noDataNow; return nil }
            supply.delivered = true
            status.pointee = .haveData
            return supply.source
        }
        guard error == nil,
              output.frameLength > 0,
              let channel = output.floatChannelData?[0] else { return }

        buffer.append(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }

    // MARK: - Device selection

    /// Use the stored microphone if it is still present, otherwise fall back to
    /// the system default and clear the stale preference.
    private func selectConfiguredDevice() throws {
        var chosen: AudioDeviceID?
        var fellBack = false

        if let uid = settings.preferences.inputDeviceUID {
            if let deviceID = AudioDeviceRegistry.deviceID(forUID: uid) {
                chosen = deviceID
            } else {
                fellBack = true
                Log.audio.info("selected microphone is gone — falling back to the system default")
                settings.preferences.inputDeviceUID = nil
            }
        }
        if chosen == nil { chosen = AudioDeviceRegistry.defaultInputDeviceID() }
        guard let deviceID = chosen else { throw AudioCaptureError.noInputDevice }

        // Setting the device reconfigures the engine and posts a
        // configuration-change notification, so do it only when it changes.
        guard deviceID != configuredDeviceID else { return }
        do {
            try engine.inputNode.auAudioUnit.setDeviceID(deviceID)
            configuredDeviceID = deviceID
            diagnostics.didFallBackToDefaultDevice = fellBack
        } catch {
            throw AudioCaptureError.deviceUnavailable(error.localizedDescription)
        }
    }

    // MARK: - Route changes

    /// A device disconnect, sample-rate change or route switch invalidates the
    /// converter that the real-time thread is using.
    ///
    /// Mid-capture this **fails the session** rather than trying to re-splice
    /// across a format change: audio either side of the change is not
    /// contiguous, and silently concatenating it would corrupt the transcript.
    /// ADR-015 still holds — the failure is visible and the coordinator returns
    /// to idle rather than hanging in `listening`.
    private func observeConfigurationChanges() {
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.handleConfigurationChange()
            }
        }
    }

    private func handleConfigurationChange() {
        diagnostics.configurationChanges += 1
        Log.audio.info("audio configuration changed (total \(self.diagnostics.configurationChanges, privacy: .public))")

        // The tap is bound to the old input format; it must be rebuilt.
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        converter = nil
        needsPreparation = true
        // `configuredDeviceID` is deliberately NOT cleared. Setting the device
        // is itself what posts this notification, so re-setting it here would
        // loop forever. If the device really did go away, the next resolve
        // returns a different ID and the set happens then.

        guard isCapturing else {
            // Re-warm now rather than on the next key-press, so the pre-roll
            // budget is not spent re-preparing.
            do { try prepare() } catch {
                Log.audio.info("re-prepare after configuration change failed: \(error.localizedDescription, privacy: .public)")
            }
            return
        }
        lastError = "The microphone changed while recording."
        cancel()
        onCaptureInterrupted?("The microphone changed or was disconnected while recording.")
    }

    /// Set by the coordinator so an interruption cannot leave it in `listening`.
    var onCaptureInterrupted: ((String) -> Void)?

    // MARK: - Helpers

    private func describe(_ format: AVAudioFormat) -> String {
        let name = switch format.commonFormat {
        case .pcmFormatFloat32: "f32"
        case .pcmFormatFloat64: "f64"
        case .pcmFormatInt16: "i16"
        case .pcmFormatInt32: "i32"
        default: "other"
        }
        return "\(Int(format.sampleRate)) Hz \(format.channelCount) ch \(name)"
    }

    nonisolated static func round2(_ value: Double) -> Double { (value * 100).rounded() / 100 }
}

/// Frame counts, durations and formats. Never audio.
struct CaptureDiagnostics: Sendable, Equatable {
    var inputFormat = "—"
    var convertedFormat = "—"
    /// Physical trigger → `engine.start()` returned.
    var captureStartMilliseconds: Double = 0
    /// Physical trigger → first buffer actually delivered by the hardware.
    var firstBufferMilliseconds: Double = 0
    var finalizeMilliseconds: Double = 0
    var preRollFrames = 0
    var capturedFrames = 0
    var evictedPreRollFrames = 0
    var overflowFrames = 0
    var strayBuffers = 0
    var configurationChanges = 0
    var didFallBackToDefaultDevice = false
    /// Must remain false. See `CaptureBuffer.Metrics.sawMainThreadCallback`.
    var audioCallbackRanOnMainThread = false

    var summary: String {
        "in \(inputFormat) → \(convertedFormat) | start \(AVAudioEngineCapture.round2(captureStartMilliseconds))ms"
        + " first-buffer \(AVAudioEngineCapture.round2(firstBufferMilliseconds))ms"
        + " pre-roll \(preRollFrames)f finalize \(AVAudioEngineCapture.round2(finalizeMilliseconds))ms"
        + " overflow \(overflowFrames) stray \(strayBuffers)"
        + (audioCallbackRanOnMainThread ? " ⚠️ RT-ON-MAIN" : "")
    }
}

enum AudioCaptureError: LocalizedError, Equatable {
    case noInputDevice
    case invalidInputFormat(String)
    case conversionUnavailable(from: String, to: String)
    case deviceUnavailable(String)
    case engineStartFailed(String, cachedPermission: String)
    case notCapturing
    case noAudioCaptured

    var errorDescription: String? {
        switch self {
        case .noInputDevice:
            "No microphone is available. Connect one and try again."
        case .invalidInputFormat(let format):
            "The microphone reported an unusable format (\(format))."
        case .conversionUnavailable(let from, let to):
            "Cannot convert microphone audio from \(from) to \(to)."
        case .deviceUnavailable(let detail):
            "The selected microphone could not be opened: \(detail)"
        case .engineStartFailed(let detail, let cachedPermission):
            // Naming the cached value matters: the app cannot detect a
            // revocation while running, so "granted" here is not evidence.
            "The microphone could not be started: \(detail) "
            + "(this process still believes permission is '\(cachedPermission)' — "
            + "if access was revoked in System Settings, quit and reopen the app)."
        case .notCapturing:
            "No recording was in progress."
        case .noAudioCaptured:
            "No audio was captured. Check that the right microphone is selected and unmuted."
        }
    }
}
