import Testing
@testable import Swiffect

@Suite struct CauseTests {
    @Test func combineConcatenatesReasons() {
        let cause = Cause<TestError>.fail(TestError(1)) + .die(RuntimeError("boom")) + .interrupt(FiberID(rawValue: 7))
        #expect(cause.reasons.count == 3)
        #expect(cause.failures == [TestError(1)])
        #expect(cause.hasDies)
        #expect(cause.interruptors == [FiberID(rawValue: 7)])
        #expect(!cause.hasInterruptsOnly)
        #expect(Cause<TestError>.empty.combine(.interrupt()).hasInterruptsOnly)
    }

    @Test func stripFailuresKeepsDefectsAndInterrupts() {
        let cause = Cause<TestError>.fail(TestError(1)) + .die(RuntimeError("x")) + .interrupt()
        let stripped = cause.stripFailures()
        #expect(stripped.reasons.count == 2)
        #expect(!stripped.hasFails)
    }

    @Test func prettyPrintsEveryReason() {
        let cause = Cause<TestError>.fail(TestError(3)) + .die(RuntimeError("boom")) + .interrupt(FiberID(rawValue: 2))
        let lines = cause.pretty.split(separator: "\n").map(String.init)
        #expect(lines == [
            "Fail: TestError(code: 3)",
            "Die: RuntimeError: boom",
            "Interrupt: interrupted by fiber #2",
        ])
        #expect(Cause<Never>.empty.pretty == "Empty")
    }

    @Test func exitGetThrowsTypedFailureOrFiberFailure() {
        #expect(throws: TestError(1)) { try Exit<Int, TestError>.fail(TestError(1)).get() }
        #expect(throws: FiberFailure.self) { try Exit<Int, TestError>.die(RuntimeError("x")).get() }
        #expect(throws: FiberFailure.self) {
            try Exit<Int, TestError>.failure(.fail(TestError(1)) + .interrupt()).get()
        }
    }
}
