import Testing
@testable import Swiffect

@Suite(.timeLimit(.minutes(1))) struct TimeTests {
    @Test func sleepGoesThroughTheClockService() async throws {
        let clock = ManualClock()
        let fiber = Effect.sleep(.seconds(10)).as(1).provideService(CurrentClock.self, clock).runFork()
        await clock.waitForSleepers(1)
        #expect(fiber.unsafePoll() == nil)
        clock.advance(by: .seconds(10))
        #expect(await fiber.exit.value == 1)
    }

    @Test func timeoutFailsAndInterruptsTheEffect() async throws {
        let clock = ManualClock(), log = Recorder()
        let slow = Effect<Int, Never>.never.onInterrupt(log.log("interrupted"))
        let fiber = slow.timeout(.seconds(5)).provideService(CurrentClock.self, clock).runFork()
        await clock.waitForSleepers(1)
        clock.advance(by: .seconds(5))
        let exit = await fiber.exit
        #expect(exit.cause?.failures == [TimeoutError(duration: .seconds(5))])
        #expect(log.all == ["interrupted"])
    }

    @Test func timeoutVariantsWhenEffectWins() async throws {
        let fast = Effect.succeed(1)
        #expect(try await fast.timeout(.seconds(30)).run() == 1)
        #expect(try await fast.timeoutOption(.seconds(30)).run() == 1)
    }

    @Test func timeoutOrElseAndOption() async throws {
        let clock = ManualClock()
        let fiber = Effect<Int, Never>.never
            .timeoutOrElse(.seconds(1)) { .succeed(-1) }
            .zip(Effect<Int, Never>.never.timeoutOption(.seconds(2)))
            .provideService(CurrentClock.self, clock)
            .runFork()
        await clock.waitForSleepers(1)
        clock.advance(by: .seconds(1))
        await clock.waitForSleepers(1)
        clock.advance(by: .seconds(2))
        let exit = await fiber.exit
        #expect(exit.value?.0 == -1)
        #expect(exit.value?.1 == Int?.none)
    }

    @Test func timedAndDelayMeasureClockTime() async throws {
        let clock = ManualClock()
        let fiber = Effect.succeed("done").delay(.seconds(3)).timed
            .provideService(CurrentClock.self, clock).runFork()
        await clock.waitForSleepers(1)
        clock.advance(by: .seconds(3))
        let result = await fiber.exit.value
        #expect(result?.duration == .seconds(3))
        #expect(result?.value == "done")
    }

    @Test func currentTimeComesFromTheClock() async throws {
        let clock = ManualClock()
        clock.advance(by: .milliseconds(1500))
        let millis = try await Effect.currentTimeMillis.provideService(CurrentClock.self, clock).run()
        #expect(millis == 1500)
        let live = try await Effect.currentTimeMillis.run()
        #expect(live > 1_600_000_000_000)
    }

    @Test func liveSleepCompletesAndIsInterruptible() async throws {
        try await Effect.sleep(.milliseconds(1)).run()
        let fiber = Effect.sleep(.seconds(60)).runFork()
        await Task.yield()
        fiber.unsafeInterrupt()
        #expect(await fiber.exit.isInterrupted)
    }
}
