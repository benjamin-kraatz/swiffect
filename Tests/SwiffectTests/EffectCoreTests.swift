import Testing
@testable import Swiffect

@Suite struct EffectCoreTests {
    @Test func effectsAreLazyAndRerunnable() async throws {
        let counter = Counter()
        let effect = counter.incrementEffect.map { $0 * 10 }
        #expect(counter.current == 0)
        #expect(try await effect.run() == 10)
        #expect(try await effect.run() == 20)
    }

    @Test func failureShortCircuitsFlatMap() async {
        let counter = Counter()
        let effect = Effect<Int, TestError>.fail(TestError(1))
            .flatMap { _ in counter.incrementEffect.widen(to: TestError.self) }
        let exit = await effect.runExit()
        #expect(exit.cause?.failures == [TestError(1)])
        #expect(counter.current == 0)
    }

    @Test func mixingInfallibleAndFallibleEffects() async throws {
        let fallible: Effect<Int, TestError> = .succeed(1)
        let infallible = Effect.succeed(2)
        let combined = fallible.flatMap { a in infallible.map { a + $0 } }
        let fromNever = infallible.flatMap { b in Effect<Int, TestError>.succeed(b * 3) }
        #expect(try await combined.run() == 3)
        #expect(try await fromNever.run() == 6)
    }

    @Test func runThrowsTypedFailure() async {
        await #expect(throws: TestError(4)) {
            try await Effect<Int, TestError>.fail(TestError(4)).run()
        }
        await #expect(throws: FiberFailure.self) {
            try await Effect<Int, TestError>.die(message: "boom").run()
        }
    }

    @Test func attemptUsesTypedThrows() async {
        let effect = Effect.attempt { () throws(TestError) -> Int in throw TestError(9) }
        #expect(await effect.runExit().cause?.failures == [TestError(9)])
        let mapped = Effect<Int, TestError>.attempt({ () throws(CancellationError) -> Int in
            throw CancellationError()
        }, catch: { _ in TestError(1) })
        #expect(await mapped.runExit().cause?.failures == [TestError(1)])
    }

    @Test func asyncInitBridgesSwiftConcurrency() async throws {
        let value = Effect { () async -> Int in
            await Task.yield()
            return 5
        }
        #expect(try await value.run() == 5)
        let failing = Effect { () async throws(TestError) -> Int in throw TestError(2) }
        #expect(await failing.runExit().cause?.failures == [TestError(2)])
    }

    @Test func callbackResumesFromAnotherThread() async throws {
        let effect = Effect<Int, Never>.callback { resume in
            Task.detached { resume(.succeed(42)) }
        }
        #expect(try await effect.run() == 42)
    }

    @Test func callbackIgnoresSecondResume() async throws {
        let effect = Effect<Int, Never>.callback { resume in
            resume(.succeed(1))
            resume(.succeed(2))
        }
        #expect(try await effect.run() == 1)
    }

    @Test func zipFlipAndFlatten() async throws {
        #expect(try await Effect.succeed(Effect.succeed(3)).flatten().run() == 3)
        let flipped = Effect<TestError, TestError>.fail(TestError(7)).flip
        #expect(try await flipped.run() == TestError(7))
        let fromOptional = Effect.fromOptional(Int?.none)
        #expect(await fromOptional.runExit().cause?.firstFailure == NoSuchElementError())
    }
}

@Suite struct GenTests {
    @Test func genSequencesEffects() async throws {
        let program: Effect<Int, TestError> = .gen { bind in
            let a = try await bind(Effect<Int, TestError>.succeed(1))
            let b = try await bind(Effect.succeed(2))
            return a + b
        }
        #expect(try await program.run() == 3)
    }

    @Test func genPropagatesTypedFailureAndThrownFailure() async {
        let propagated: Effect<Int, TestError> = .gen { bind in
            try await bind(Effect<Int, TestError>.fail(TestError(1)))
        }
        #expect(await propagated.runExit().cause?.failures == [TestError(1)])

        let thrown: Effect<Int, TestError> = .gen { _ in throw TestError(2) }
        #expect(await thrown.runExit().cause?.failures == [TestError(2)])
    }

    @Test func genPreservesDefectsAndTurnsForeignErrorsIntoDefects() async {
        let defect: Effect<Int, TestError> = .gen { bind in
            try await bind(Effect<Int, Never>.die(RuntimeError("boom")))
        }
        let defectCause = await defect.runExit().cause
        #expect(defectCause?.defects.first as? RuntimeError == RuntimeError("boom"))

        let foreign: Effect<Int, TestError> = .gen { _ in throw CancellationError() }
        #expect(await foreign.runExit().cause?.defects.first is CancellationError)
    }

    @Test func genCanCatchTypedFailures() async throws {
        let program: Effect<Int, TestError> = .gen { bind in
            do {
                return try await bind(Effect<Int, TestError>.fail(TestError(1)))
            } catch let error as TestError {
                return error.code + 10
            }
        }
        #expect(try await program.run() == 11)
    }
}

@Suite struct StackSafetyTests {
    @Test func deepRecursiveFlatMap() async throws {
        @Sendable func loop(_ n: Int) -> Effect<Int, Never> {
            n == 0 ? .succeed(0) : Effect.succeed(n).flatMap { _ in loop(n - 1) }.map { $0 + 1 }
        }
        #expect(try await loop(100_000).run() == 100_000)
    }

    @Test func deepRecursiveSuspend() async throws {
        @Sendable func count(_ n: Int, _ acc: Int) -> Effect<Int, Never> {
            .suspend { n == 0 ? .succeed(acc) : count(n - 1, acc + 1) }
        }
        #expect(try await count(100_000, 0).run() == 100_000)
    }

    @Test func deepGenRecursion() async throws {
        @Sendable func sum(_ n: Int) -> Effect<Int, Never> {
            .gen { bind in n == 0 ? 0 : try await bind(sum(n - 1)) + n }
        }
        #expect(try await sum(20_000).run() == 20_000 * 20_001 / 2)
    }
}
