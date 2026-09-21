import AudioCaptureCore
import Foundation

/// Replays the Phase 2.5 benchmark corpus through the **production** engine.
///
/// The point is not accuracy — that was settled in QUALITY_BENCHMARK with these
/// same 20 recordings. The point is that moving from spike code to production
/// architecture did not change what the recogniser returns. Any difference is a
/// regression in the plumbing (streaming, requantisation, session teardown)
/// until proven otherwise, and gets explained rather than adopted.
///
/// Runs headless: no microphone, no hotkey, no TCC involvement.
enum CorpusValidation {

    struct Record: Sendable {
        let id: Int
        let audioFile: String
        let locale: String
        let expected: String
        let audioSeconds: Double
        let spikeFinalizeMs: Double
    }

    struct Outcome: Sendable {
        let record: Record
        let produced: String
        let finalizeMs: Double
        let conversionMs: Double

        var matches: Bool { produced == record.expected }
        /// Catastrophic regressions, which are what this harness must never miss.
        var isEmpty: Bool { produced.trimmingCharacters(in: .whitespaces).isEmpty }
        var isSeverelyTruncated: Bool {
            !record.expected.isEmpty &&
            Double(produced.count) < Double(record.expected.count) * 0.6
        }
    }

    static func loadCorpus(at root: URL) throws -> [Record] {
        let url = root.appendingPathComponent("records.jsonl")
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = object["id"] as? Int,
                  let file = object["audioFile"] as? String,
                  let locale = object["locale"] as? String,
                  let expected = object["engineTranscript"] as? String
            else { return nil }
            return Record(id: id,
                          audioFile: file,
                          locale: locale,
                          expected: expected,
                          audioSeconds: object["audioSeconds"] as? Double ?? 0,
                          spikeFinalizeMs: object["finalizeMs"] as? Double ?? 0)
        }
    }

    /// Read a 16-bit mono WAV into the canonical capture format.
    ///
    /// Deliberately a plain parser rather than `AVAudioFile`: the corpus is
    /// exactly 16 kHz mono 16-bit, and going through AVFoundation would let a
    /// silent resample hide a bug this harness exists to catch.
    static func readClip(at url: URL) throws -> AudioClip {
        let data = try Data(contentsOf: url)
        guard data.count > 44 else { throw SpeechEngineError.analyzerUnavailable("short WAV \(url.lastPathComponent)") }

        // Walk the chunk list rather than assuming a 44-byte header.
        var offset = 12
        var dataRange: Range<Int>?
        var sampleRate = 16_000.0
        var channels = 1
        var bits = 16
        while offset + 8 <= data.count {
            let id = String(bytes: data[offset..<offset + 4], encoding: .ascii) ?? ""
            let size = Int(data[(offset + 4)..<(offset + 8)].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
            let body = offset + 8
            if id == "fmt " , body + 16 <= data.count {
                channels = Int(data[(body + 2)..<(body + 4)].withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) })
                sampleRate = Double(data[(body + 4)..<(body + 8)].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
                bits = Int(data[(body + 14)..<(body + 16)].withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) })
            } else if id == "data" {
                dataRange = body..<min(body + size, data.count)
                break
            }
            offset = body + size + (size % 2)
        }
        // An empty `data` chunk would crash the pointer read below.
        guard let range = dataRange, !range.isEmpty, channels == 1, bits == 16 else {
            throw SpeechEngineError.analyzerUnavailable(
                "\(url.lastPathComponent): expected 16-bit mono, got \(bits)-bit \(channels) ch")
        }

        let pcm = data[range].withUnsafeBytes { raw -> [Int16] in
            Array(UnsafeBufferPointer(start: raw.baseAddress!.assumingMemoryBound(to: Int16.self),
                                      count: raw.count / 2))
        }
        return AudioClip(samples: PCMConversion.float(from: pcm),
                         sampleRate: sampleRate,
                         preRollFrameCount: 0)
    }

    static func run(corpusRoot: URL, engine: AppleSpeechEngine) async -> [Outcome] {
        var outcomes: [Outcome] = []
        let records: [Record]
        do { records = try loadCorpus(at: corpusRoot) } catch {
            print("cannot read corpus: \(error.localizedDescription)")
            return []
        }

        for locale in Set(records.map(\.locale)) {
            do { try await engine.prepare(locale: locale) } catch {
                print("prepare \(locale) failed: \(error.localizedDescription)")
            }
        }

        for record in records.sorted(by: { $0.id < $1.id }) {
            let url = corpusRoot.appendingPathComponent("audio").appendingPathComponent(record.audioFile)
            do {
                let conversionStart = Date()
                let clip = try readClip(at: url)
                let conversionMs = Date().timeIntervalSince(conversionStart) * 1000

                let start = Date()
                let transcript = try await engine.transcribe(clip, locale: record.locale)
                outcomes.append(Outcome(record: record,
                                        produced: transcript.text,
                                        finalizeMs: Date().timeIntervalSince(start) * 1000,
                                        conversionMs: conversionMs))
            } catch {
                outcomes.append(Outcome(record: record,
                                        produced: "<<ERROR: \(error.localizedDescription)>>",
                                        finalizeMs: 0, conversionMs: 0))
            }
        }
        return outcomes
    }

    /// One JSON line per `<id>__<locale>.wav`; errors are reported per file and
    /// never stop the run. Text is printed exactly as the engine returned it.
    static func transcribeDirectory(_ directory: URL, engine: AppleSpeechEngine) async {
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasSuffix(".wav") && $0.contains("__") }
            .sorted()

        var prepared = Set<String>()
        for name in files {
            let locale = String(name.dropLast(4).components(separatedBy: "__").last ?? "en-US")
            if prepared.insert(locale).inserted {
                do { try await engine.prepare(locale: locale) } catch {
                    FileHandle.standardError.write(Data("prepare \(locale) failed: \(error.localizedDescription)\n".utf8))
                }
            }
            var record: [String: String] = ["file": name, "locale": locale]
            do {
                let clip = try readClip(at: directory.appendingPathComponent(name))
                record["text"] = try await engine.transcribe(clip, locale: locale).text
            } catch {
                record["error"] = error.localizedDescription
            }
            if let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
               let line = String(data: data, encoding: .utf8) {
                print(line)
                fflush(stdout)
            }
        }
    }

    static func report(_ outcomes: [Outcome]) -> String {
        var lines: [String] = []
        let matched = outcomes.filter(\.matches).count
        lines.append("=== Phase 6 corpus validation — production engine vs Phase 2.5 spike ===")
        lines.append("records: \(outcomes.count)   identical: \(matched)   differing: \(outcomes.count - matched)")
        lines.append("")

        for outcome in outcomes {
            let flag = outcome.matches ? "==" : "!="
            lines.append("[\(outcome.record.id)] \(outcome.record.locale) "
                         + "\(String(format: "%.1f", outcome.record.audioSeconds))s \(flag) "
                         + "(spike \(String(format: "%.0f", outcome.record.spikeFinalizeMs))ms → "
                         + "prod \(String(format: "%.0f", outcome.finalizeMs))ms, "
                         + "convert \(String(format: "%.2f", outcome.conversionMs))ms)")
            if !outcome.matches {
                lines.append("    spike: \(outcome.record.expected)")
                lines.append("    prod : \(outcome.produced)")
            }
            if outcome.isEmpty { lines.append("    ⚠️ EMPTY TRANSCRIPT") }
            if outcome.isSeverelyTruncated { lines.append("    ⚠️ SEVERELY TRUNCATED") }
        }

        let times = outcomes.map(\.finalizeMs).filter { $0 > 0 }.sorted()
        if !times.isEmpty {
            lines.append("")
            lines.append("batch transcribe (whole clip, not streaming): "
                         + "min \(String(format: "%.0f", times.first!)) ms, "
                         + "p50 \(String(format: "%.0f", times[times.count / 2])) ms, "
                         + "max \(String(format: "%.0f", times.last!)) ms")
            let conversions = outcomes.map(\.conversionMs).filter { $0 > 0 }.sorted()
            if !conversions.isEmpty {
                lines.append("WAV read + Int16→Float32: p50 \(String(format: "%.2f", conversions[conversions.count / 2])) ms")
            }
        }
        return lines.joined(separator: "\n")
    }
}
