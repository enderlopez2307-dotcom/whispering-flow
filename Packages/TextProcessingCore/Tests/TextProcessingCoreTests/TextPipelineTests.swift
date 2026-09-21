import Testing
@testable import TextProcessingCore

/// Minimal stages used only to prove the pipeline contract. The real stages
/// arrive in Phase 8.
private struct UppercaseStage: TextStage {
    let id = StageID("test.uppercase")
    func apply(_ input: String, context: ProcessingContext) -> String { input.uppercased() }
}

private struct SuffixStage: TextStage {
    let id = StageID("test.suffix")
    let suffix: String
    func apply(_ input: String, context: ProcessingContext) -> String { input + suffix }
}

@Suite("TextPipeline")
struct TextPipelineTests {

    private let context = ProcessingContext(locale: .english)

    @Test("An empty pipeline returns its input unchanged")
    func emptyPipelineIsIdentity() {
        let pipeline = TextPipeline(stages: [])
        #expect(pipeline.process("hello", context: context) == "hello")
    }

    @Test("Stages apply in order")
    func stagesApplyInOrder() {
        let pipeline = TextPipeline(stages: [UppercaseStage(), SuffixStage(suffix: "!")])
        #expect(pipeline.process("hi", context: context) == "HI!")
    }

    @Test("Order is data — reordering the same stages changes the result")
    func orderIsData() {
        let a = TextPipeline(stages: [UppercaseStage(), SuffixStage(suffix: "abc")])
        let b = TextPipeline(stages: [SuffixStage(suffix: "abc"), UppercaseStage()])
        #expect(a.process("x", context: context) == "Xabc")
        #expect(b.process("x", context: context) == "XABC")
    }

    @Test("Trace reports each stage's intermediate output")
    func traceReportsIntermediates() {
        let pipeline = TextPipeline(stages: [UppercaseStage(), SuffixStage(suffix: "!")])
        let steps = pipeline.trace("hi", context: context)
        #expect(steps.count == 2)
        #expect(steps[0].stage == StageID("test.uppercase"))
        #expect(steps[0].output == "HI")
        #expect(steps[1].output == "HI!")
    }
}

@Suite("ProcessingContext")
struct ProcessingContextTests {

    @Test("Context carries the target bundle id for Phase 12, unused for now")
    func carriesTargetBundleIdentifier() {
        let context = ProcessingContext(locale: .spanish, targetBundleIdentifier: "com.apple.Terminal")
        #expect(context.targetBundleIdentifier == "com.apple.Terminal")
        #expect(context.locale == .spanish)
    }

    @Test("Trailing suffix literals")
    func suffixLiterals() {
        #expect(ProcessingOptions.TrailingSuffix.none.literal == "")
        #expect(ProcessingOptions.TrailingSuffix.space.literal == " ")
        #expect(ProcessingOptions.TrailingSuffix.newline.literal == "\n")
    }
}
