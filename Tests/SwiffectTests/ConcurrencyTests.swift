import Synchronization
import Testing
@testable import Swiffect

/// Tracks how many effects run at the same time.
private final class Gauge: Sendable {
    private let state = Mutex<(current: Int, max: Int)>((0, 0))

    func track<A: Sendable, E: Error>(_ effect: Effect<A, E>) -> Effect<A, E> {
        Effect<Void, E>.sync { self.state.withLock { $0.current += 1; $0.max = Swift.max($0.max, $0.current) } }
            .andThen(Effect<Void, E>.yieldNow)
            .andThen(effect)
            .ensuring(.sync { self.state.withLock { $0.current -= 1 } })
    }

    var max: Int { state.withLock { $0.max } }
}

@Suite(.timeLimit(.minutes(1))) struct ForEachTests {
    @Test func sequentialForEachKeepsOrder() async throws {
        let log = Recorder()
        let result = try await Effect.forEach(1...5) { i in log.log("\(i)").as(i * i) }.run()
        #expect(result == [1, 4, 9, 16, 25])
        #expect(log.all == ["1", "2", "3", "4", "5"])
    }

    @Test func boundedConcurrencyRespectsLimitAndReturnsResultsByIndex() async throws {
        let gauge = Gauge()
        let result = try await Effect.forEach(0..<20, concurrency: .bounded(3)) { i in
            gauge.track(Effect.succeed(i))
        }.run()
        #expect(result == Array(0..<20))
        #expect(gauge.max <= 3)
    }

    @Test func failureInterruptsAndAwaitsInFlightSiblings() async throws {
        let log = Recorder(), started = Counter(), siblingsStarted = TestLatch()
        let effect = Effect<[Int], TestError>.forEach(0..<3, concurrency: .unbounded) { i in
            if i == 0 {
                return siblingsStarted.wait.widen().andThen(Effect<Int, TestError>.fail(TestError(1)))
            }
            return Effect<Void, TestError>.sync {
                if started.increment() == 2 { siblingsStarted.open() }
            }.andThen(Effect<Int, TestError>.never)
                .onInterrupt(log.log("sibling \(i) interrupted"))
        }
        let exit = await effect.runExit()
        #expect(exit.cause?.failures == [TestError(1)])
        #expect(exit.cause?.hasInterrupts == false)
        #expect(Set(log.all) == ["sibling 1 interrupted", "sibling 2 interrupted"])
    }

    @Test func interruptingParentInterruptsConcurrentChildren() async throws {
        let log = Recorder(), started = Counter(), allStarted = TestLatch()
        let effect = Effect<Void, Never>.forEachDiscarding(0..<4, concurrency: .unbounded) { i in
            Effect<Void, Never>.sync { if started.increment() == 4 { allStarted.open() } }
                .andThen(Effect<Void, Never>.never)
                .onInterrupt(log.log("\(i)"))
        }
        let fiber = effect.runFork()
        await allStarted.waitAsync()
        fiber.unsafeInterrupt()
        #expect(await fiber.exit.isInterrupted)
        #expect(log.all.count == 4)
    }

    @Test func allSupportsArraysAndHeterogeneousTuples() async throws {
        let array = try await Effect.all([Effect.succeed(1), .succeed(2)], concurrency: .unbounded).run()
        #expect(array == [1, 2])
        let (a, b, c) = try await Effect.all(Effect.succeed(1), Effect.succeed("two"), Effect.succeed(3.0), concurrency: .unbounded).run()
        #expect(a == 1 && b == "two" && c == 3.0)
        let zipped = try await Effect.succeed(2).zipWith(Effect.succeed(5), concurrent: true, *).run()
        #expect(zipped == 10)
    }

    @Test func validateCollectsEveryFailure() async throws {
        let exit = await Effect<[Int], TestError>.validate(1...5, concurrency: .unbounded) { i in
            i.isMultiple(of: 2) ? .fail(TestError(i)) : .succeed(i)
        }.runExit()
        #expect(exit.cause?.failures == [TestError(2), TestError(4)])
        let ok = try await Effect<[Int], TestError>.validate(1...3) { .succeed($0) }.run()
        #expect(ok == [1, 2, 3])
    }

    @Test func partitionReduceFilterFindFirst() async throws {
        let (failures, successes) = try await Effect.partition(1...6) { (i: Int) -> Effect<Int, TestError> in
            i.isMultiple(of: 3) ? .fail(TestError(i)) : .succeed(i)
        }.run()
        #expect(failures == [TestError(3), TestError(6)])
        #expect(successes == [1, 2, 4, 5])

        #expect(try await Effect.reduce(1...4, 0) { acc, i in .succeed(acc + i) }.run() == 10)
        #expect(try await Effect.filter(1...10, concurrency: 4) { .succeed($0.isMultiple(of: 5)) }.run() == [5, 10])

        let tested = Recorder()
        let first = try await Effect.findFirst(1...10) { i in tested.log("\(i)").as(i > 2) }.run()
        #expect(first == 3)
        #expect(tested.all == ["1", "2", "3"])
    }

    @Test func replicateEffectRunsNTimes() async throws {
        let counter = Counter()
        let values = try await counter.incrementEffect.replicateEffect(5, concurrency: .unbounded).run()
        #expect(values.sorted() == [1, 2, 3, 4, 5])
    }

    @Test func largeSequentialForEachIsStackSafe() async throws {
        let sum = try await Effect.forEach(0..<100_000) { Effect.succeed($0) }.map { $0.reduce(0, +) }.run()
        #expect(sum == 4_999_950_000)
    }
}

@Suite(.timeLimit(.minutes(1))) struct RaceTests {
    @Test func raceReturnsFirstSuccessAndInterruptsAndAwaitsLoser() async throws {
        let log = Recorder()
        let loser = Effect<Int, Never>.never.onInterrupt(Effect.yieldNow.andThen(log.log("loser interrupted")))
        let result = try await Effect.succeed(1).race(loser).run()
        #expect(result == 1)
        #expect(log.all == ["loser interrupted"])
    }

    @Test func raceIgnoresFailuresUntilASuccess() async throws {
        let gate = TestLatch()
        let failing = Effect<Int, TestError>.fail(TestError(1)).ensuring(gate.openEffect)
        let winner = gate.wait.widen(to: TestError.self).as(2)
        #expect(try await failing.race(winner).run() == 2)
    }

    @Test func raceAllFailsWithAllCausesWhenEveryEffectFails() async {
        let exit = await Effect<Int, TestError>.raceAll([.fail(TestError(1)), .fail(TestError(2))]).runExit()
        #expect(Set(exit.cause?.failures.map(\.code) ?? []) == [1, 2])
    }

    @Test func raceFirstAcceptsTheFirstFailure() async {
        let exit = await Effect<Int, TestError>.fail(TestError(1)).raceFirst(.never).runExit()
        #expect(exit.cause?.failures == [TestError(1)])
    }
}

@Suite(.timeLimit(.minutes(1))) struct CombinatorTests {
    @Test func firstSuccessOfAndEventually() async throws {
        let first = Effect<Int, TestError>.firstSuccessOf([.fail(TestError(1)), .succeed(2), .succeed(3)])
        #expect(try await first.run() == 2)

        let attempts = Counter()
        let flaky = Effect<Int, TestError>.suspend {
            attempts.increment() < 3 ? .fail(TestError(0)) : .succeed(attempts.current)
        }
        #expect(try await flaky.eventually.run() == 3)
    }

    @Test func filterOrFailAndWhen() async throws {
        let filtered = Effect<Int, TestError>.succeed(3).filterOrFail({ $0 > 5 }, orFailWith: { TestError($0) })
        #expect(await filtered.runExit().cause?.failures == [TestError(3)])
        let counter = Counter()
        #expect(try await counter.incrementEffect.when(false).run() == nil)
        #expect(try await counter.incrementEffect.when(Effect.succeed(true)).run() == 1)
    }

    @Test func errorHandlingOperators() async throws {
        let failing = Effect<Int, TestError>.fail(TestError(1))
        #expect(try await failing.catchAll { .succeed($0.code + 1) }.run() == 2)
        #expect(try await failing.catchIf({ $0.code == 1 }) { _ in .succeed(5) }.run() == 5)
        #expect(await failing.catchIf({ $0.code == 2 }) { _ in .succeed(5) }.runExit().isFailure)
        #expect(try await failing.orElseSucceed(9).run() == 9)
        #expect(try await failing.option.run() == nil)
        #expect(try await failing.mapError { TestError($0.code + 10) }.result.run() == .failure(TestError(11)))
        #expect(await failing.orDie.runExit().cause?.defects.first as? TestError == TestError(1))
        #expect(try await failing.match(onFailure: { -$0.code }, onSuccess: { $0 }).run() == -1)

        let dying = Effect<Int, TestError>.die(RuntimeError("bug"))
        #expect(try await dying.catchDefect { _ in .succeed(7) }.run() == 7)
        #expect(await dying.catchAll { _ in .succeed(0) }.runExit().cause?.hasDies == true)
        #expect(try await dying.sandbox.catchAll { cause in .succeed(cause.defects.count) }.run() == 1)

        let log = Recorder()
        _ = await failing.tapError { log.log("error \($0.code)").widen() }
            .tapCause { _ in log.log("cause").widen() }
            .runExit()
        #expect(log.all == ["error 1", "cause"])
    }

    @Test func cachedRunsOnce() async throws {
        let counter = Counter()
        let program: Effect<[Int], Never> = .gen { bind in
            let cached = try await bind(counter.incrementEffect.cached)
            return try await bind(Effect.all([cached, cached, cached], concurrency: .unbounded))
        }
        #expect(try await program.run() == [1, 1, 1])
        #expect(counter.current == 1)
    }
}
