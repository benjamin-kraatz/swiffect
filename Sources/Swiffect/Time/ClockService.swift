#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// The source of time for effects: wall-clock time, monotonic time and sleeping.
///
/// All time-based operators (``Effect/sleep(_:)``, ``Effect/timeout(_:)``, ``Effect/delay(_:)``,
/// ``Effect/timed``, ...) go through the clock found in the fiber's context under
/// ``CurrentClock``. Replacing it, e.g. with a test clock, changes how time passes for the
/// whole program:
///
/// ```swift
/// let result = try await program.provideService(CurrentClock.self, testClock).run()
/// ```
///
/// Implementations must be thread-safe.
public protocol ClockService: Sendable {
    /// Wall-clock time in nanoseconds since the Unix epoch.
    func currentTimeNanosUnsafe() -> Int64

    /// Monotonic time elapsed since an arbitrary, fixed origin. Use it to measure durations.
    func monotonicNowUnsafe() -> Duration

    /// An effect that completes after `duration` has elapsed on this clock.
    ///
    /// The effect must be interruptible while waiting: interrupting the sleeping fiber must
    /// end the sleep immediately (``Effect/callback(_:)`` gives this for free).
    func sleep(for duration: Duration) -> Effect<Void, Never>
}

extension ClockService {
    /// Wall-clock time in milliseconds since the Unix epoch.
    public func currentTimeMillisUnsafe() -> Int64 {
        currentTimeNanosUnsafe() / 1_000_000
    }
}

/// The context reference holding the fiber's ``ClockService``. Defaults to ``LiveClock``.
public enum CurrentClock: ReferenceKey {
    /// The clock is stored as an existential so any implementation can be provided.
    public typealias Value = any ClockService

    /// The live system clock.
    public static var defaultValue: any ClockService { LiveClock() }
}

/// The clock backed by the system: `CLOCK_REALTIME` for wall-clock time, `ContinuousClock` for
/// monotonic time and `Task.sleep` for sleeping.
public struct LiveClock: ClockService {
    /// Creates the live clock.
    public init() {}

    /// Reads `CLOCK_REALTIME`.
    public func currentTimeNanosUnsafe() -> Int64 {
        var spec = timespec()
        clock_gettime(CLOCK_REALTIME, &spec)
        return Int64(spec.tv_sec) * 1_000_000_000 + Int64(spec.tv_nsec)
    }

    /// Time elapsed on `ContinuousClock` since the process first used the live clock.
    public func monotonicNowUnsafe() -> Duration {
        ContinuousClock.now - monotonicOrigin
    }

    /// Sleeps with `Task.sleep` on a child task that is cancelled when the fiber is
    /// interrupted. Non-positive durations just yield.
    public func sleep(for duration: Duration) -> Effect<Void, Never> {
        guard duration > .zero else { return .yieldNow }
        return .callback { resume in
            let task = Task {
                try? await Task.sleep(for: duration)
                resume(.void)
            }
            resume.onInterrupt { task.cancel() }
        }
    }
}

private let monotonicOrigin = ContinuousClock.now
