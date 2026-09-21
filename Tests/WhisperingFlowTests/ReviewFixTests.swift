import AppKit
import Foundation
import Testing
@testable import WhisperingFlowKit

@Suite("Review fixes")
@MainActor
struct ReviewFixTests {

    @Test("Dictated text on the pasteboard carries the do-not-keep markers")
    func pasteboardIsTransient() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("wf.test.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }

        let count = ClipboardPasteInserter.writeTransient("hello world", to: pasteboard)

        #expect(pasteboard.string(forType: .string) == "hello world")
        for type in ClipboardPasteInserter.transientTypes {
            #expect(pasteboard.types?.contains(type) == true, "missing \(type.rawValue)")
        }
        #expect(pasteboard.changeCount == count)
    }

    @Test("The recovery copy carries the same do-not-keep markers as insertion")
    func recoveryCopyIsTransient() {
        // The paste inserter was given the markers but this second writer was
        // not, and it is the more sensitive of the two: it is reached when
        // insertion was refused, and it leaves the text on the clipboard
        // indefinitely rather than for ~120 ms.
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("wf.test.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let recovery = TranscriptRecovery()
        let id = recovery.record(text: "my banking password is hunter2", locale: "en-US")

        #expect(recovery.copyToPasteboard(id, to: pasteboard))

        #expect(pasteboard.string(forType: .string) == "my banking password is hunter2")
        for type in ClipboardPasteInserter.transientTypes {
            #expect(pasteboard.types?.contains(type) == true, "missing \(type.rawValue)")
        }
    }

    @Test("The diagnostic log rolls over past its limit and keeps one previous file")
    func logRotation() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wf-log-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("t.log")
        let previous = DiagnosticTranscriptLog.previousURL(for: log)

        try Data(repeating: 65, count: 100).write(to: log)
        DiagnosticTranscriptLog.rotateIfNeeded(at: log, limit: 1000)
        #expect(FileManager.default.fileExists(atPath: log.path), "under the limit: untouched")
        #expect(!FileManager.default.fileExists(atPath: previous.path))

        try Data(repeating: 66, count: 2000).write(to: log)
        DiagnosticTranscriptLog.rotateIfNeeded(at: log, limit: 1000)
        #expect(!FileManager.default.fileExists(atPath: log.path), "over the limit: rolled")
        #expect(try Data(contentsOf: previous).count == 2000)

        // A second roll replaces the old previous file, never accumulates.
        try Data(repeating: 67, count: 3000).write(to: log)
        DiagnosticTranscriptLog.rotateIfNeeded(at: log, limit: 1000)
        #expect(try Data(contentsOf: previous).count == 3000)
    }
}
