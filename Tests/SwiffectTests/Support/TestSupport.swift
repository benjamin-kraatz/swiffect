import Synchronization
@testable import Swiffect

struct TestError: Error, Equatable {
    let code: Int
    init(_ code: Int = 0) { self.code = code }
}

/// Thread-safe, append-only event log for asserting ordering.
final class Recorder: Sendable {
    private let events = Mutex<[String]>([])

    func record(_ event: String) {
        events.withLock { $0.append(event) }
    }

    func log(_ event: String) -> Effect<Void, Never> {
        .sync { self.record(event) }
    }

    var all: [String] { events.withLock { $0 } }
}

/// A one-shot gate: fibers awaiting it are released once it is opened.
final class TestLatch: Sendable {
    private let state = Mutex<(open: Bool, waiters: [@Sendable () -> Void])>((false, []))

    func open() {
        let waiters = state.withLock { state in
            state.open = true
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter() }
    }

    var openEffect: Effect<Void, Never> { .sync { self.open() } }

    /// Suspends (interruptibly) until the latch is opened.
    var wait: Effect<Void, Never> {
        Effect<Void, Never>.callback { resume in
            let ready = self.state.withLock { state -> Bool in
                if state.open { return true }
                state.waiters.append { resume(.void) }
                return false
            }
            if ready { resume(.void) }
        }
    }

    /// Plain async wait for use from test bodies.
    func waitAsync() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let ready = state.withLock { state -> Bool in
                if state.open { return true }
                state.waiters.append { continuation.resume() }
                return false
            }
            if ready { continuation.resume() }
        }
    }
}

final class Counter: Sendable {
    private let value = Atomic<Int>(0)

    @discardableResult
    func increment() -> Int { value.wrappingAdd(1, ordering: .relaxed).newValue }

    var current: Int { value.load(ordering: .relaxed) }

    var incrementEffect: Effect<Int, Never> { .sync { self.increment() } }
}
