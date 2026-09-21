import Foundation

/// An ordered list of stages. Order is *data*, not control flow, so stages can
/// be reordered or individually disabled in a test without editing the pipeline.
public struct TextPipeline: Sendable {
    public let stages: [any TextStage]

    public init(stages: [any TextStage]) {
        self.stages = stages
    }

    public func process(_ raw: String, context: ProcessingContext) -> String {
        stages.reduce(raw) { $1.apply($0, context: context) }
    }

    /// Per-stage intermediate output. Used by tests and the diagnostics view to
    /// see exactly which stage changed what.
    public func trace(_ raw: String, context: ProcessingContext) -> [(stage: StageID, output: String)] {
        var current = raw
        var steps: [(StageID, String)] = []
        for stage in stages {
            current = stage.apply(current, context: context)
            steps.append((stage.id, current))
        }
        return steps
    }
}
