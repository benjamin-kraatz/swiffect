import Testing
@testable import Swiffect

@Suite(.timeLimit(.minutes(1))) struct InterruptionTests {
    @Test func interruptWakesSuspendedFiberAndRecordsInterruptor() async throws {
        let program: Effect<(Exit<Never, Never>, FiberID), Never> = .gen { bind in
            let fiber = try await bind(Effect.never.forkChild)
            try await bind(Effect.yieldNow)
            try await bind(fiber.interrupt)
            return (try await bind(fiber.await), bind.fiber.id)
        }
        let (exit, parentID) = try await program.run()
        #expect(exit.cause?.hasInterruptsOnly == true)
        #expect(exit.cause?.interruptors == [parentID])
    }

    @Test func uninterruptibleRegionDefersInterruption() async throws {
        let started = Latch(), gate = Latch(), log = Recorder()
        let region = started.openEffect.andThen(gate.wait).andThen(log.log("region done")).uninterruptible
        let child = region.andThen(log.log("after region"))
        let fiber = child.runFork()
        await started.waitAsync()
        fiber.unsafeInterrupt()
        gate.open()
        let exit = await fiber.exit
        #expect(exit.isInterrupted)
        #expect(log.all == ["region done"])
    }

    @Test func restoreMakesInnerEffectInterruptible() async throws {
        let started = Latch(), log = Recorder()
        let effect = Effect<Void, Never>.uninterruptibleMask { restore in
            restore(started.openEffect.andThen(Effect.never)).ensuring(log.log("cleanup"))
        }
        let fiber = effect.runFork()
        await started.waitAsync()
        fiber.unsafeInterrupt()
        #expect(await fiber.exit.isInterrupted)
        #expect(log.all == ["cleanup"])
    }

    @Test func interruptibleInsideUninterruptibleCanBeInterrupted() async throws {
        let started = Latch()
        let fiber = started.openEffect.andThen(Effect<Void, Never>.never).interruptible.uninterruptible.runFork()
        await started.waitAsync()
        fiber.unsafeInterrupt()
        #expect(await fiber.exit.isInterrupted)
    }

    @Test func recoveryCannotCatchOwnInterruption() async throws {
        let started = Latch(), log = Recorder()
        let effect = started.openEffect.andThen(Effect<Int, Never>.never)
            .catchCause { _ in log.log("caught").as(1) }
            .exit.map { _ in 2 }
        let fiber = effect.runFork()
        await started.waitAsync()
        fiber.unsafeInterrupt()
        #expect(await fiber.exit.isInterrupted)
        #expect(log.all.isEmpty)
    }

    @Test func selfInterruptIsAnOrdinaryFailureCause() async throws {
        let recovered = Effect<Int, Never>.interrupt.catchCause { cause in .succeed(cause.hasInterruptsOnly ? 1 : 0) }
        #expect(try await recovered.run() == 1)
    }

    @Test func finalizersRunUninterruptibly() async throws {
        let started = Latch(), finalizerStarted = Latch(), gate = Latch(), log = Recorder()
        let finalizer = finalizerStarted.openEffect.andThen(gate.wait).andThen(log.log("finalized"))
        let fiber = started.openEffect.andThen(Effect<Void, Never>.never).ensuring(finalizer).runFork()
        await started.waitAsync()
        fiber.unsafeInterrupt()
        await finalizerStarted.waitAsync()
        fiber.unsafeInterrupt()  // a second interrupt must not abort the finalizer
        #expect(fiber.unsafePoll() == nil)
        gate.open()
        #expect(await fiber.exit.isInterrupted)
        #expect(log.all == ["finalized"])
    }

    @Test func onInterruptReceivesInterruptors() async throws {
        let started = Latch(), log = Recorder()
        let effect = started.openEffect.andThen(Effect<Void, Never>.never)
            .onInterrupt { ids in log.log("interrupted by \(ids.count)") }
        let fiber = effect.runFork()
        await started.waitAsync()
        fiber.unsafeInterrupt(by: FiberID(rawValue: 999_999))
        _ = await fiber.exit
        #expect(log.all == ["interrupted by 1"])
    }

    @Test func pendingInterruptStopsAtNextBoundary() async throws {
        let counter = Counter()
        let busy = counter.incrementEffect.forever
        let fiber = busy.runFork()
        while counter.current < 10 { await Task.yield() }
        fiber.unsafeInterrupt()
        #expect(await fiber.exit.isInterrupted)
    }
}

@Suite(.timeLimit(.minutes(1))) struct CancellationBridgeTests {
    @Test func cancellingRunExitInterruptsTheRootFiber() async throws {
        let started = Latch(), log = Recorder()
        let effect = started.openEffect.andThen(Effect<Void, Never>.never).onInterrupt(log.log("interrupted"))
        let task = Task { await effect.runExit() }
        await started.waitAsync()
        task.cancel()
        let exit = await task.value
        #expect(exit.isInterrupted)
        #expect(log.all == ["interrupted"])
    }

    @Test func interruptingTheFiberCancelsTheBridgedTask() async throws {
        let started = Latch(), cancelled = Latch()
        let effect = Effect { () async -> Void in
            started.open()
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                cancelled.open()
            }
        }
        let fiber = effect.runFork()
        await started.waitAsync()
        fiber.unsafeInterrupt()
        #expect(await fiber.exit.isInterrupted)
        await cancelled.waitAsync()
    }
}
