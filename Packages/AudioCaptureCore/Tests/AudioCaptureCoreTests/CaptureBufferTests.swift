import Testing
@testable import AudioCaptureCore

/// Every test drives the buffer with a monotonically increasing ramp, so a
/// missing sample, a duplicated sample, or a reordering is visible as a break in
/// the sequence rather than as a plausible-looking float.
private struct Ramp {
    var next: Float = 1
    mutating func take(_ count: Int) -> [Float] {
        let values = (0..<count).map { Float(self.next) + Float($0) }
        next += Float(count)
        return values
    }
}

private extension CaptureBuffer {
    func append(_ values: [Float]) {
        values.withUnsafeBufferPointer { append($0) }
    }
}

@Suite("Pre-roll → session splice is sample-exact")
struct CaptureSpliceTests {

    /// 16 kHz, 0.5 s ring, so the numbers line up with the real service.
    private func makeBuffer(preRollSeconds: Double = 0.5) -> CaptureBuffer {
        CaptureBuffer(sampleRate: 16_000, preRollSeconds: preRollSeconds, maximumSeconds: 300)
    }

    @Test("Audio captured before the threshold is kept, in order, exactly once")
    func preRollIsSplicedIntact() {
        let buffer = makeBuffer()
        var ramp = Ramp()
        buffer.beginPreRoll()

        // 150 ms of pre-threshold audio, in realistic 1024-frame chunks.
        var expected: [Float] = []
        for _ in 0..<3 {
            let chunk = ramp.take(1024)
            expected += chunk
            buffer.append(chunk)
        }
        buffer.promote()
        // …then a second of real session audio.
        for _ in 0..<16 {
            let chunk = ramp.take(1024)
            expected += chunk
            buffer.append(chunk)
        }

        let clip = buffer.finish()
        #expect(clip == expected, "the clip must be the concatenation of every frame, unmodified")
        #expect(clip.count == expected.count)
    }

    @Test("Promotion neither drops nor duplicates a frame at the boundary")
    func boundaryHasNoGapAndNoStutter() {
        // Sweep the promotion point across a chunk boundary and one frame either
        // side of it. An off-by-one in the ring drain shows up here and nowhere
        // else.
        for preRollChunks in 0...4 {
            for tailFrames in [0, 1, 7, 1023] {
                let buffer = makeBuffer()
                var ramp = Ramp()
                var expected: [Float] = []
                buffer.beginPreRoll()

                for _ in 0..<preRollChunks {
                    let chunk = ramp.take(1024)
                    expected += chunk
                    buffer.append(chunk)
                }
                if tailFrames > 0 {
                    let tail = ramp.take(tailFrames)
                    expected += tail
                    buffer.append(tail)
                }
                buffer.promote()
                let after = ramp.take(2048)
                expected += after
                buffer.append(after)

                let clip = buffer.finish()
                #expect(clip == expected,
                        "gap or stutter at preRollChunks=\(preRollChunks) tail=\(tailFrames)")
            }
        }
    }

    @Test("A ring that wraps keeps the most recent audio, oldest-first")
    func ringWrapKeepsRecentAudioInOrder() {
        // 100 ms ring, 500 ms of pre-threshold audio: the ring must hold the
        // *last* 100 ms and hand it back in arrival order.
        let buffer = CaptureBuffer(sampleRate: 16_000, preRollSeconds: 0.1, maximumSeconds: 300)
        var ramp = Ramp()
        buffer.beginPreRoll()

        var all: [Float] = []
        for _ in 0..<10 {
            let chunk = ramp.take(800)   // 50 ms each
            all += chunk
            buffer.append(chunk)
        }
        buffer.promote()
        let clip = buffer.finish()

        #expect(clip.count == 1_600, "a 100 ms ring at 16 kHz holds 1600 frames")
        #expect(clip == Array(all.suffix(1_600)), "kept audio must be the most recent, in order")
        #expect(buffer.currentMetrics.evictedPreRollFrames == all.count - 1_600)
    }

    @Test("A single buffer larger than the whole ring keeps its tail")
    func oversizedBufferKeepsItsTail() {
        let buffer = CaptureBuffer(sampleRate: 16_000, preRollSeconds: 0.05, maximumSeconds: 300)
        var ramp = Ramp()
        buffer.beginPreRoll()
        let huge = ramp.take(10_000)
        buffer.append(huge)
        buffer.promote()

        let clip = buffer.finish()
        #expect(clip.count == 800)
        #expect(clip == Array(huge.suffix(800)))
    }

    @Test("Releasing before promotion still returns the pre-roll audio")
    func finishWithoutPromoteStillCarriesPreRoll() {
        // The service calls discard() for an accidental tap, but finish() must
        // not silently lose audio if the two ever race.
        let buffer = makeBuffer()
        var ramp = Ramp()
        buffer.beginPreRoll()
        let chunk = ramp.take(1024)
        buffer.append(chunk)

        #expect(buffer.finish() == chunk)
    }
}

@Suite("Accidental taps leave nothing behind")
struct CaptureDiscardTests {

    @Test("Discard drops pre-roll audio and the next session starts clean")
    func discardLeavesNoResidue() {
        let buffer = CaptureBuffer(sampleRate: 16_000, preRollSeconds: 0.5, maximumSeconds: 300)
        var ramp = Ramp()

        buffer.beginPreRoll()
        buffer.append(ramp.take(2048))
        buffer.discard()
        #expect(!buffer.isActive)
        #expect(buffer.currentMetrics.preRollFrames == 0)

        // The tap can still deliver a buffer or two after stop() is requested.
        buffer.append(ramp.take(1024))
        #expect(buffer.currentMetrics.strayBuffers == 1, "late buffers are counted, not stored")

        buffer.beginPreRoll()
        let fresh = ramp.take(512)
        buffer.append(fresh)
        buffer.promote()
        #expect(buffer.finish() == fresh, "no audio from the discarded tap may survive")
    }

    @Test("Discard after promotion drops the session too")
    func discardAfterPromotionDropsEverything() {
        let buffer = CaptureBuffer(sampleRate: 16_000, preRollSeconds: 0.5, maximumSeconds: 300)
        var ramp = Ramp()
        buffer.beginPreRoll()
        buffer.append(ramp.take(1024))
        buffer.promote()
        buffer.append(ramp.take(16_000))
        buffer.discard()

        buffer.beginPreRoll()
        let fresh = ramp.take(256)
        buffer.append(fresh)
        buffer.promote()
        #expect(buffer.finish() == fresh)
    }

    @Test("Audio arriving while idle is never stored")
    func idleNeverAccumulates() {
        let buffer = CaptureBuffer(sampleRate: 16_000, preRollSeconds: 0.5, maximumSeconds: 300)
        var ramp = Ramp()
        for _ in 0..<10 { buffer.append(ramp.take(1024)) }
        #expect(buffer.currentMetrics.strayBuffers == 10)
        #expect(buffer.currentMetrics.preRollFrames == 0)
        #expect(buffer.currentMetrics.sessionFrames == 0)
    }
}

@Suite("Bounded memory")
struct CaptureBoundsTests {

    @Test("A session cannot grow past the hard cap")
    func sessionIsCapped() {
        // 1-second ceiling so the test stays fast.
        let buffer = CaptureBuffer(sampleRate: 16_000, preRollSeconds: 0.1, maximumSeconds: 1)
        var ramp = Ramp()
        buffer.beginPreRoll()
        buffer.promote()
        for _ in 0..<10 { buffer.append(ramp.take(8_000)) }

        let clip = buffer.finish()
        #expect(clip.count == 16_000, "capped at exactly the maximum, not somewhere near it")
        #expect(buffer.currentMetrics.overflowFrames == 80_000 - 16_000)
    }

    @Test("Frame counts convert to the durations reported in diagnostics")
    func secondsConversion() {
        let buffer = CaptureBuffer(sampleRate: 16_000, preRollSeconds: 0.5, maximumSeconds: 300)
        #expect(buffer.seconds(16_000) == 1.0)
        #expect(buffer.seconds(2_400) == 0.15)
        #expect(buffer.preRollCapacity == 8_000)
        #expect(buffer.maximumFrames == 4_800_000)
    }
}

@Suite("Level metering")
struct CaptureLevelTests {

    @Test("Peak reflects the loudest frame and resets when read")
    func peakIsTrackedAndConsumed() {
        let buffer = CaptureBuffer(sampleRate: 16_000, preRollSeconds: 0.5, maximumSeconds: 300)
        buffer.beginPreRoll()
        [0.1, -0.7, 0.3].withUnsafeBufferPointer { buffer.append($0) }
        #expect(abs(buffer.consumePeakLevel() - 0.7) < 0.0001, "magnitude, so a negative peak counts")
        #expect(buffer.consumePeakLevel() == 0, "reading resets, so the meter decays")
    }
}

@Suite("Real-time thread expectations")
struct CaptureThreadTests {

    @Test("The callback thread is recorded so a MainActor leak is detectable at runtime")
    func mainThreadUseIsObservable() async {
        let buffer = CaptureBuffer(sampleRate: 16_000, preRollSeconds: 0.5, maximumSeconds: 300)
        buffer.beginPreRoll()

        // Appending off the main thread must be reported as such. If this ever
        // reads `true` in production, the tap closure inherited MainActor
        // isolation and is one buffer away from trapping.
        await Task.detached {
            [Float](repeating: 0, count: 128).withUnsafeBufferPointer { buffer.append($0) }
        }.value
        #expect(buffer.currentMetrics.sawMainThreadCallback == false)
    }

    @Test("Concurrent appends and a promotion never lose or duplicate a frame")
    func concurrentAppendAndPromoteIsSafe() async {
        // The real thing has one producer and one main-thread promoter. This
        // hammers that exact shape, because the lock is the only thing standing
        // between a correct splice and a corrupted one.
        for _ in 0..<50 {
            let buffer = CaptureBuffer(sampleRate: 16_000, preRollSeconds: 0.5, maximumSeconds: 300)
            buffer.beginPreRoll()

            let producer = Task.detached {
                for chunk in 0..<64 {
                    let values = (0..<128).map { Float(chunk * 128 + $0 + 1) }
                    values.withUnsafeBufferPointer { buffer.append($0) }
                }
            }
            buffer.promote()
            await producer.value

            let clip = buffer.finish()
            // Whatever survived must be a contiguous run of the ramp: every
            // value exactly one greater than the last.
            for index in 1..<clip.count {
                #expect(clip[index] == clip[index - 1] + 1,
                        "discontinuity at \(index): \(clip[index - 1]) → \(clip[index])")
            }
        }
    }
}

@Suite("Float32 ↔ Int16 requantisation")
struct PCMConversionTests {

    @Test("Silence stays exactly silent")
    func silenceIsPreserved() {
        // A recogniser treats near-silence as speech onset if conversion adds a
        // DC offset or dither.
        #expect(PCMConversion.int16(from: [Float](repeating: 0, count: 512))
                .allSatisfy { $0 == 0 })
    }

    @Test("Full scale maps to the endpoints without trapping")
    func fullScaleDoesNotOverflow() {
        // Float(1.0) * 32768 does not fit in Int16 and traps in Swift — a loud
        // syllable would crash the app rather than clip.
        #expect(PCMConversion.int16(from: [1.0]) == [32_767])
        #expect(PCMConversion.int16(from: [-1.0]) == [-32_767])
    }

    @Test("Out-of-range input clips rather than wrapping")
    func outOfRangeClips() {
        // Wrapping would turn a loud sample into full-scale noise of the
        // opposite sign, which is much worse than flat clipping.
        #expect(PCMConversion.int16(from: [1.5, -1.5, 12, -12]) ==
                [32_767, -32_767, 32_767, -32_767])
    }

    @Test("Quiet speech survives with usable resolution")
    func lowLevelSpeechIsPreserved() {
        // Measured capture peaks in Phase 5 were 0.03–0.14 full scale, so this
        // is the range that actually matters, not the loud end.
        let quiet: [Float] = [0.001, 0.005, 0.03, 0.08, 0.14]
        let converted = PCMConversion.int16(from: quiet)
        #expect(converted == [32, 163, 983, 2_621, 4_587])
        for (original, back) in zip(quiet, PCMConversion.float(from: converted)) {
            #expect(abs(original - back) < 0.0001, "round trip lost \(original)")
        }
    }

    @Test("Sign and ordering are preserved sample for sample")
    func orderAndSignPreserved() {
        let ramp = (-100...100).map { Float($0) / 100 }
        let converted = PCMConversion.int16(from: ramp)
        #expect(converted.count == ramp.count, "conversion must not change the frame count")
        for index in 1..<converted.count {
            #expect(converted[index] > converted[index - 1], "monotonicity broken at \(index)")
        }
        #expect(converted[100] == 0, "zero must stay zero")
    }

    @Test("Conversion is stateless — the same input always gives the same output")
    func conversionIsStateless() {
        // No cross-session contamination is possible if there is no state at
        // all. Phase 5 lost a day to an AVAudioConverter that had some.
        let a = PCMConversion.int16(from: [0.5, -0.5, 0.25])
        let b = PCMConversion.int16(from: [0.5, -0.5, 0.25])
        _ = PCMConversion.int16(from: [1.0, 1.0, 1.0])
        #expect(PCMConversion.int16(from: [0.5, -0.5, 0.25]) == a)
        #expect(a == b)
    }
}
