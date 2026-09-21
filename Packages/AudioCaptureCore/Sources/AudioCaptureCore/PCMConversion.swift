import Foundation

/// Sample-format conversion between the canonical capture format and whatever
/// a recognition engine asks for.
///
/// Pure, so the properties that matter — clipping, silence, quiet speech — are
/// asserted directly rather than inferred from a transcript.
///
/// **Same sample rate only.** `AudioClip` is 16 kHz mono and Apple's analyzer
/// asks for 16 kHz mono, so this is a requantisation, never a resample. If an
/// engine ever wants a different rate, that is `AVAudioConverter`'s job, not
/// this file's.
public enum PCMConversion {

    /// Full-scale for signed 16-bit. **32767, not 32768.**
    ///
    /// `Float(1.0) * 32768` is 32768, which does not fit in `Int16` and traps
    /// in Swift rather than wrapping. Scaling by 32767 makes +1.0 map to
    /// +32767 and −1.0 to −32767, costing one LSB of asymmetry against the
    /// available −32768 — inaudible, and the alternative is a crash on a loud
    /// sample.
    public static let fullScale: Float = 32_767

    /// Float32 in −1…1 → signed 16-bit PCM.
    ///
    /// Out-of-range input is clamped, not wrapped. A microphone or a gain stage
    /// can produce values beyond ±1.0, and wrapping turns a loud syllable into
    /// full-scale noise of the opposite sign, which is far worse for a
    /// recogniser than flat clipping.
    public static func int16(from samples: [Float]) -> [Int16] {
        var output = [Int16](repeating: 0, count: samples.count)
        samples.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                for index in 0..<source.count {
                    let clamped = min(max(source[index], -1), 1)
                    destination[index] = Int16(clamped * fullScale)
                }
            }
        }
        return output
    }

    /// Signed 16-bit PCM → Float32 in −1…1. Used by the corpus harness, which
    /// reads 16-bit WAVs.
    public static func float(from samples: [Int16]) -> [Float] {
        samples.map { Float($0) / fullScale }
    }
}
