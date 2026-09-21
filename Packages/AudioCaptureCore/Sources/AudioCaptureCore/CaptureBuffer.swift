import Foundation

/// Accumulates captured mono samples across the pre-roll → session boundary.
///
/// Phase 4 measured 151 ms between the physical key-press and the semantic
/// `begin` (TECH_RESEARCH §18.1). Capture that starts at `begin` loses the first
/// syllable of every utterance, so capture starts on the *physical* press and
/// lands in a bounded ring until the gesture proves itself. If the key is
/// released before the hold threshold it was an accidental tap and the ring is
/// dropped; if the threshold is reached the ring is spliced onto the front of
/// the session.
///
/// **The splice must be sample-exact.** `append` and `promote` take the same
/// lock, so there is no instant at which an incoming buffer could land in
/// neither destination (a gap) or both (a stutter). That is the entire reason
/// this type exists as a unit rather than as two collaborating ones.
///
/// `append` runs on the real-time audio thread. It never allocates: `session`
/// is reserved to its maximum before capture starts, and the ring is allocated
/// once at init.
public final class CaptureBuffer: @unchecked Sendable {

    /// Development-safe metrics. Frame counts and levels only — never audio.
    public struct Metrics: Sendable, Equatable {
        public var preRollFrames = 0
        public var sessionFrames = 0
        /// Pre-roll frames that aged out of the ring before promotion. Expected
        /// and harmless: it only means the key was held longer than the ring.
        public var evictedPreRollFrames = 0
        /// Frames refused because the hard duration cap was reached.
        public var overflowFrames = 0
        /// Buffers that arrived while not capturing. Should stay at zero.
        public var strayBuffers = 0
        public var peakLevel: Float = 0

        /// Frames that came from the ring, once promoted.
        public var promotedPreRollFrames = 0

        /// Monotonic uptime at which the very first buffer of this capture
        /// arrived. The gap between the physical key-press and this is the real
        /// audio-start latency — `AVAudioEngine.start()` returning says nothing
        /// about when the hardware actually delivers samples.
        public var firstBufferUptime: Double?

        /// Whether the real-time callback ever ran on the main thread.
        ///
        /// Must stay false. A tap closure that inherits MainActor isolation
        /// traps on its first buffer under Swift 6 (TECH_RESEARCH §15.4), and
        /// "it compiled without warnings" is not evidence that it did not —
        /// this is the runtime check that is.
        public var sawMainThreadCallback = false
    }

    public let sampleRate: Double
    /// Ring size in frames. Must comfortably exceed the hold threshold.
    public let preRollCapacity: Int
    /// Hard ceiling on a single dictation, so a stuck key cannot exhaust memory.
    public let maximumFrames: Int

    private let lock = NSLock()

    private var ring: [Float]
    private var ringWrite = 0
    private var ringFilled = 0

    private var session: [Float] = []
    private var isCapturing = false
    private var isPromoted = false
    private var metrics = Metrics()

    /// Live tap on session audio, set between promotion and finish.
    ///
    /// Called on the real-time thread with a **copy**, because the recogniser
    /// outlives the callback's buffer. One ~1.4 KB allocation per ~10 ms buffer
    /// is the price of streaming recognition; the alternative — handing out the
    /// raw pointer — is a use-after-free waiting to happen.
    public var onSessionSamples: (@Sendable ([Float]) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onSessionSamples }
        set { lock.lock(); defer { lock.unlock() }; _onSessionSamples = newValue }
    }
    private var _onSessionSamples: (@Sendable ([Float]) -> Void)?

    public init(sampleRate: Double = 16_000,
                preRollSeconds: Double = 0.5,
                maximumSeconds: Double = 300) {
        self.sampleRate = sampleRate
        self.preRollCapacity = max(1, Int(sampleRate * preRollSeconds))
        self.maximumFrames = max(1, Int(sampleRate * maximumSeconds))
        self.ring = [Float](repeating: 0, count: preRollCapacity)
    }

    // MARK: - Lifecycle (main thread)

    /// Physical trigger down. Everything from here is provisional.
    public func beginPreRoll() {
        lock.lock(); defer { lock.unlock() }
        ringWrite = 0
        ringFilled = 0
        session.removeAll(keepingCapacity: true)
        // Reserved before any audio arrives so the real-time thread never
        // reallocates. malloc is lazy, so the pages are only committed as
        // audio is actually written.
        session.reserveCapacity(maximumFrames)
        isCapturing = true
        isPromoted = false
        metrics = Metrics()
    }

    /// Hold threshold reached: the provisional audio is now real. Splices the
    /// ring onto the front of the session in arrival order.
    public func promote() {
        _ = promoteAndCopy()
    }

    /// Promote, and hand back the pre-roll audio so a recogniser can be fed the
    /// beginning of the utterance immediately.
    ///
    /// One call rather than promote-then-read: between two calls the real-time
    /// thread could append, and the caller would either miss those frames or
    /// send them twice.
    @discardableResult
    public func promoteAndCopy() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        guard isCapturing, !isPromoted else { return [] }
        let carried = drainRingLocked()
        session.append(contentsOf: carried)
        metrics.promotedPreRollFrames = carried.count
        metrics.sessionFrames = session.count
        isPromoted = true
        return carried
    }

    /// Release. Returns the complete clip, pre-roll first.
    public func finish() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        // A release that beats `promote` still has its audio in the ring.
        if !isPromoted {
            let carried = drainRingLocked()
            session.append(contentsOf: carried)
            metrics.promotedPreRollFrames = carried.count
        }
        _onSessionSamples = nil
        isCapturing = false
        isPromoted = false
        metrics.sessionFrames = session.count
        let result = session
        session = []
        return result
    }

    /// Accidental tap, Escape, or a failure. Drops everything.
    public func discard() {
        lock.lock(); defer { lock.unlock() }
        _onSessionSamples = nil
        isCapturing = false
        isPromoted = false
        ringWrite = 0
        ringFilled = 0
        // `removeAll(keepingCapacity:)` would hold the reservation — up to
        // 19 MB — for the entire idle life of the app. Release it.
        session = []
        metrics.preRollFrames = 0
        metrics.sessionFrames = 0
    }

    // MARK: - Real-time thread

    /// Called from the `AVAudioEngine` tap callback. No allocation, no logging,
    /// no actor hops, no awaits.
    public func append(_ samples: UnsafeBufferPointer<Float>) {
        guard let base = samples.baseAddress, !samples.isEmpty else { return }
        let count = samples.count

        var peak: Float = 0
        for index in 0..<count {
            let magnitude = abs(base[index])
            if magnitude > peak { peak = magnitude }
        }

        lock.lock(); defer { lock.unlock() }
        guard isCapturing else {
            metrics.strayBuffers += 1
            return
        }
        if metrics.firstBufferUptime == nil {
            metrics.firstBufferUptime = ProcessInfo.processInfo.systemUptime
            // Checked once per capture, not per buffer: the answer cannot change
            // mid-session and the check is not free.
            metrics.sawMainThreadCallback = Thread.isMainThread
        }
        if peak > metrics.peakLevel { metrics.peakLevel = peak }

        if isPromoted {
            let room = maximumFrames - session.count
            guard room > 0 else {
                metrics.overflowFrames += count
                return
            }
            let taken = min(room, count)
            session.append(contentsOf: UnsafeBufferPointer(start: base, count: taken))
            if taken < count { metrics.overflowFrames += count - taken }
            metrics.sessionFrames = session.count
            if let sink = _onSessionSamples {
                sink(Array(UnsafeBufferPointer(start: base, count: taken)))
            }
        } else {
            writeRingLocked(base, count)
            metrics.preRollFrames = min(metrics.preRollFrames + count, preRollCapacity)
        }
    }

    // MARK: - Observation

    public var currentMetrics: Metrics {
        lock.lock(); defer { lock.unlock() }
        return metrics
    }

    public var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return isCapturing
    }

    /// Peak since the last read, then reset. Drives the future waveform HUD.
    public func consumePeakLevel() -> Float {
        lock.lock(); defer { lock.unlock() }
        let peak = metrics.peakLevel
        metrics.peakLevel = 0
        return peak
    }

    public func seconds(_ frames: Int) -> Double { Double(frames) / sampleRate }

    // MARK: - Ring

    private func writeRingLocked(_ base: UnsafePointer<Float>, _ count: Int) {
        // An incoming buffer longer than the whole ring: keep only its tail,
        // which is the audio closest to the trigger.
        if count >= preRollCapacity {
            let offset = count - preRollCapacity
            ring.withUnsafeMutableBufferPointer { destination in
                destination.baseAddress!.update(from: base + offset, count: preRollCapacity)
            }
            metrics.evictedPreRollFrames += count - preRollCapacity + ringFilled
            ringWrite = 0
            ringFilled = preRollCapacity
            return
        }

        if ringFilled + count > preRollCapacity {
            metrics.evictedPreRollFrames += ringFilled + count - preRollCapacity
        }

        ring.withUnsafeMutableBufferPointer { destination in
            let head = min(count, preRollCapacity - ringWrite)
            destination.baseAddress!.advanced(by: ringWrite).update(from: base, count: head)
            if head < count {
                destination.baseAddress!.update(from: base + head, count: count - head)
            }
        }
        ringWrite = (ringWrite + count) % preRollCapacity
        ringFilled = min(ringFilled + count, preRollCapacity)
    }

    /// Ring contents in arrival order, oldest first. Caller holds the lock.
    private func drainRingLocked() -> [Float] {
        guard ringFilled > 0 else { return [] }
        var carried = [Float]()
        carried.reserveCapacity(ringFilled)
        let start = ringFilled == preRollCapacity ? ringWrite : 0
        for offset in 0..<ringFilled {
            carried.append(ring[(start + offset) % preRollCapacity])
        }
        ringWrite = 0
        ringFilled = 0
        return carried
    }
}
