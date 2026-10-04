import Testing
@testable import Swiffect

@Suite(.timeLimit(.minutes(1))) struct FiberTests {
    @Test func joinReturnsValueAndPropagatesFailure() async throws {
        let ok: Effect<Int, TestError> = .gen { bind in
            let fiber = try await bind(Effect<Int, TestError>.succeed(21).map { $0 * 2 }.forkChild)
            return try await bind(fiber.join)
        }
        #expect(try await ok.run() == 42)

        let failing: Effect<Int, TestError> = .gen { bind in
            let fiber = try await bind(Effect<Int, TestError>.fail(TestError(3)).forkChild)
            return try await bind(fiber.join)
        }
        #expect(await failing.runExit().cause?.failures == [TestError(3)])
    }

    @Test func pollReflectsCompletion() async throws {
        let gate = Latch()
        let fiber = gate.wait.as(5).runFork()
        #expect(fiber.unsafePoll() == nil)
        gate.open()
        _ = await fiber.exit
        #expect(fiber.unsafePoll()?.value == 5)
    }

    @Test func parentInterruptsAndAwaitsChildrenBeforeCompleting() async throws {
        let childStarted = Latch(), log = Recorder()
        let child = childStarted.openEffect.andThen(Effect<Void, Never>.never)
            .onInterrupt(Effect.yieldNow.andThen(log.log("child finalized")))
        let parent = child.forkChild.andThen(childStarted.wait).andThen(log.log("parent done"))
        let fiber = parent.runFork()
        let exit = await fiber.exit
        log.record("parent exit observed")
        #expect(exit.isSuccess)
        #expect(log.all == ["parent done", "child finalized", "parent exit observed"])
    }

    @Test func detachedFiberOutlivesParent() async throws {
        let gate = Latch(), finished = Latch()
        let parent: Effect<Fiber<Void, Never>, Never> = gate.wait.andThen(finished.openEffect).forkDetach
        let detached = try await parent.run()
        gate.open()
        await finished.waitAsync()
        #expect(await detached.exit.isSuccess)
    }

    @Test func childrenSeeSnapshotOfParentContext() async throws {
        enum Name: ReferenceKey { static var defaultValue: String { "default" } }
        let program: Effect<String, Never> = .gen { bind in
            let fiber = try await bind(Effect.service(Name.self).forkChild)
            return try await bind(fiber.join)
        }
        #expect(try await program.provideService(Name.self, "parent").run() == "parent")
    }

    @Test func interruptAllAndAwaitAll() async throws {
        let program: Effect<[Exit<Never, Never>], Never> = .gen { bind in
            var fibers: [Fiber<Never, Never>] = []
            for _ in 0..<5 { fibers.append(try await bind(Effect.never.forkChild)) }
            try await bind(Fiber.interruptAll(fibers))
            return try await bind(Fiber.awaitAll(fibers))
        }
        let exits = try await program.run()
        #expect(exits.count == 5)
        #expect(exits.allSatisfy { $0.isInterrupted })
    }

    @Test func joinAllCollectsValues() async throws {
        let program: Effect<[Int], Never> = .gen { bind in
            var fibers: [Fiber<Int, Never>] = []
            for i in 0..<4 { fibers.append(try await bind(Effect.succeed(i).forkChild)) }
            return try await bind(Fiber.joinAll(fibers))
        }
        #expect(try await program.run() == [0, 1, 2, 3])
    }

    @Test func awaitingIsInterruptibleWithoutAffectingTheTarget() async throws {
        let gate = Latch(), waiting = Latch()
        let target = gate.wait.as(1).runFork()
        let waiter = waiting.openEffect.andThen(target.await).runFork()
        await waiting.waitAsync()
        waiter.unsafeInterrupt()
        #expect(await waiter.exit.isInterrupted)
        #expect(target.unsafePoll() == nil)
        gate.open()
        #expect(await target.exit.value == 1)
    }
}
