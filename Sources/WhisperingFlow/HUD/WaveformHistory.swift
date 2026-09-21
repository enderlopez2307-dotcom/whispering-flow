import Foundation

/// Turns raw per-buffer peak levels into the bar heights the HUD draws.
///
/// Pure and clock-free so the mapping is testable. Speech peaks sit far below
/// full scale (roughly −30…−12 dBFS), so a linear meter would look almost flat;
/// the bars use a decibel scale with a noise floor instead.
struct WaveformHistory: Equatable, Sendable {

    /// Peaks quieter than this draw as zero, so room noise is a flat line.
    static let floorDecibels: Float = -50
    /// Peaks at or above this draw at full height.
    static let ceilingDecibels: Float = -6
    /// How much of the previous bar survives one step. A fast attack with a
    /// slow release reads as a waveform instead of flicker.
    static let releaseFactor: Float = 0.82

    let capacity: Int
    /// Oldest first, each in 0…1.
    private(set) var bars: [Float]

    init(capacity: Int = 28) {
        self.capacity = max(1, capacity)
        self.bars = Array(repeating: 0, count: max(1, capacity))
    }

    /// 0 (silence / floor) … 1 (loud). Non-finite and negative input is silence.
    static func normalise(_ peak: Float) -> Float {
        guard peak.isFinite, peak > 0 else { return 0 }
        let decibels = 20 * log10(peak)
        let scaled = (decibels - floorDecibels) / (ceilingDecibels - floorDecibels)
        return min(1, max(0, scaled))
    }

    mutating func push(peak: Float) {
        let target = Self.normalise(peak)
        let previous = bars.last ?? 0
        let next = max(target, previous * Self.releaseFactor)
        bars.removeFirst()
        bars.append(next < 0.01 ? 0 : next)
    }

    mutating func clear() {
        bars = Array(repeating: 0, count: capacity)
    }
}
