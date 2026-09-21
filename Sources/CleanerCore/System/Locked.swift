import os

/// A value guarded by an unfair lock. Same shape as `Synchronization.Mutex`,
/// which needs macOS 15; this works back to macOS 13.
public struct Locked<Value>: @unchecked Sendable {
    private let lock: OSAllocatedUnfairLock<Value>

    public init(_ value: Value) {
        lock = OSAllocatedUnfairLock(uncheckedState: value)
    }

    public func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        try lock.withLockUnchecked(body)
    }
}
