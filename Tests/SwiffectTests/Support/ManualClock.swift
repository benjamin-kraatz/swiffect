import Synchronization
@testable import Swiffect

/// A minimal manually advanced clock for deterministic time tests.
final class ManualClock: ClockService {
    private struct Sleeper {
        let id: Int
        let deadline: Duration
        let wake: @Sendable () -> Void
    }

    private let state = Mutex<(now: Duration, nextID: Int, sleepers: [Sleeper])>((.zero, 0, []))

    func currentTimeNanosUnsafe() -> Int64 {
        let now = state.withLock { $0.now }
        return now.components.seconds * 1_000_000_000 + now.components.attoseconds / 1_000_000_000
    }

    func monotonicNowUnsafe() -> Duration {
        state.withLock { $0.now }
    }

    func sleep(for duration: Duration) -> Effect<Void, Never> {
        .callback { resume in
            let id = self.state.withLock { state in
                state.nextID += 1
                state.sleepers.append(Sleeper(id: state.nextID, deadline: state.now + duration, wake: { resume(.void) }))
                return state.nextID
            }
            return .sync { self.state.withLock { $0.sleepers.removeAll { $0.id == id } } }
        }
    }

    var sleeperCount: Int { state.withLock { $0.sleepers.count } }

    /// Moves time forward and wakes every sleeper whose deadline has passed.
    func advance(by duration: Duration) {
        let due = state.withLock { state in
            state.now += duration
            let now = state.now
            let due = state.sleepers.filter { $0.deadline <= now }
            state.sleepers.removeAll { $0.deadline <= now }
            return due
        }
        for sleeper in due { sleeper.wake() }
    }

    /// Waits until `count` fibers are sleeping on this clock.
    func waitForSleepers(_ count: Int) async {
        while sleeperCount < count { await Task.yield() }
    }
}
