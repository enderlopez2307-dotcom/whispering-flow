import AVFoundation
import Foundation

/// Writes a captured clip to a WAV, for development inspection only.
///
/// **Off unless `--debug-audio-export` is passed.** Phase 5's brief is explicit
/// that no audio may be persisted in normal operation, and this is the one
/// deliberate exception: without it there is no way to verify "the first
/// syllable survives the pre-roll splice" before Phase 6 exists to transcribe
/// anything.
///
/// Files land in the system temporary directory and are never cleaned up
/// automatically — an export the user forgot about should be findable, not
/// quietly deleted.
enum DebugAudioExport {

    static let isEnabled = ProcessInfo.processInfo.arguments.contains("--debug-audio-export")

    static var directory: URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("whispering-flow-audio")
    }

    @discardableResult
    static func write(_ clip: AudioClip) -> URL? {
        guard isEnabled, !clip.samples.isEmpty else { return nil }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            Log.audio.error("debug export: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let url = directory.appendingPathComponent("clip-\(stamp).wav")

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: clip.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: clip.sampleRate,
                                         channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(clip.samples.count)),
              let destination = buffer.floatChannelData?[0] else { return nil }

        clip.samples.withUnsafeBufferPointer { source in
            destination.update(from: source.baseAddress!, count: clip.samples.count)
        }
        buffer.frameLength = AVAudioFrameCount(clip.samples.count)

        do {
            let file = try AVAudioFile(forWriting: url, settings: settings)
            try file.write(from: buffer)
            Log.audio.info("debug export -> \(url.lastPathComponent, privacy: .public) (\(clip.samples.count, privacy: .public) frames, pre-roll \(clip.preRollFrameCount, privacy: .public))")
            return url
        } catch {
            Log.audio.error("debug export failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
