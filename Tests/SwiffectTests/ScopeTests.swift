import Testing
@testable import Swiffect

@Suite(.timeLimit(.minutes(1))) struct ScopeTests {
    @Test func finalizersRunInReverseOrderAndOnlyOnce() async throws {
        let log = Recorder()
        let scope = Scope()
        let program = scope.addFinalizer(log.log("first"))
            .andThen(scope.addFinalizer(log.log("second")))
            .andThen(scope.close(.success(())))
            .andThen(scope.close(.success(())))
        try await program.run()
        #expect(log.all == ["second", "first"])
        #expect(scope.isClosed)
    }

    @Test func addingToClosedScopeRunsFinalizerImmediately() async throws {
        let log = Recorder()
        let scope = Scope()
        let program = scope.close(.failure(.interrupt()))
            .andThen(scope.addFinalizer { exit in log.log("late: \(exit.isInterrupted)") })
        try await program.run()
        #expect(log.all == ["late: true"])
    }

    @Test func parallelStrategyRunsFinalizersConcurrently() async throws {
        let a = TestLatch(), b = TestLatch(), log = Recorder()
        let scope = Scope(strategy: .parallel)
        // Each finalizer waits for the other one: this only completes if they run concurrently.
        let program = scope.addFinalizer(a.openEffect.andThen(b.wait).andThen(log.log("a")))
            .andThen(scope.addFinalizer(b.openEffect.andThen(a.wait).andThen(log.log("b"))))
            .andThen(scope.close(.success(())))
        try await program.run()
        #expect(Set(log.all) == ["a", "b"])
    }

    @Test func childScopeClosesWithParentAndDetachesWhenClosedFirst() async throws {
        let log = Recorder()
        let parent = Scope()
        let program: Effect<Void, Never> = .gen { bind in
            let child = try await bind(parent.fork())
            try await bind(child.addFinalizer(log.log("child")))
            try await bind(parent.addFinalizer(log.log("parent")))
            try await bind(parent.close(.success(())))
            let early = try await bind(Scope().fork())
            try await bind(early.close(.success(())))
        }
        try await program.run()
        #expect(log.all == ["parent", "child"])
    }

    @Test func scopedReleasesResourcesWithTheExit() async throws {
        let log = Recorder()
        let resource = Effect<String, TestError>.acquireRelease(log.log("acquire").as("r").widen()) { value, exit in
            log.log("release \(value) success=\(exit.isSuccess)")
        }
        try await resource.flatMap { value in log.log("use \(value)").widen() }.scoped.run()
        let failed = await resource.andThen(Effect<Void, TestError>.fail(TestError(1))).scoped.runExit()
        #expect(failed.cause?.failures == [TestError(1)])
        #expect(log.all == [
            "acquire", "use r", "release r success=true",
            "acquire", "release r success=false",
        ])
    }

    @Test func acquireUseReleaseReleasesOnInterruption() async throws {
        let started = TestLatch(), log = Recorder()
        let effect = Effect<Void, Never>.acquireUseRelease(
            log.log("acquire"),
            use: { _ in started.openEffect.andThen(Effect.never) },
            release: { _, exit in log.log("release interrupted=\(exit.isInterrupted)") }
        )
        let fiber = effect.runFork()
        await started.waitAsync()
        fiber.unsafeInterrupt()
        #expect(await fiber.exit.isInterrupted)
        #expect(log.all == ["acquire", "release interrupted=true"])
    }

    @Test func forkScopedFiberIsInterruptedWhenScopeCloses() async throws {
        let started = TestLatch(), log = Recorder()
        let worker = started.openEffect.andThen(Effect<Void, Never>.never).onInterrupt(log.log("worker interrupted"))
        let program = worker.forkScoped.andThen(started.wait).andThen(log.log("scope body done")).scoped
        try await program.run()
        #expect(log.all == ["scope body done", "worker interrupted"])
    }

    @Test func missingScopeIsADefect() async {
        let exit = await Effect<Void, Never>.addFinalizer { _ in .void }.runExit()
        #expect(exit.cause?.defects.first is MissingServiceError)
    }

    @Test func dyingFinalizerIsAddedToTheCause() async {
        let exit = await Effect<Int, TestError>.fail(TestError(1))
            .ensuring(.die(RuntimeError("finalizer")))
            .runExit()
        #expect(exit.cause?.failures == [TestError(1)])
        #expect(exit.cause?.defects.first as? RuntimeError == RuntimeError("finalizer"))
    }
}
