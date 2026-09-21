import Foundation

public struct StageID: Sendable, Hashable, RawRepresentable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

/// One deterministic transformation. Pure: same input always yields same output.
///
/// A future LLM polish pass (ADR-010) and context-aware formatting (ADR-009)
/// are additional `TextStage` values appended to the pipeline — which is the
/// entire reason this is a protocol rather than one `clean()` function.
public protocol TextStage: Sendable {
    var id: StageID { get }
    func apply(_ input: String, context: ProcessingContext) -> String
}
