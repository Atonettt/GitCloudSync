import Foundation

/// Serialises work per repository and caps how many repositories sync at once.
public actor SyncCoordinator {
    private var running: Set<UUID> = []
    private var activeSlots = 0
    private var maxConcurrent: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(maxConcurrent: Int = 2) {
        self.maxConcurrent = max(1, maxConcurrent)
    }

    public func setMaxConcurrent(_ value: Int) {
        maxConcurrent = max(1, value)
        while activeSlots < maxConcurrent, !waiters.isEmpty {
            activeSlots += 1
            waiters.removeFirst().resume()
        }
    }

    public func isRunning(_ id: UUID) -> Bool { running.contains(id) }

    public var runningCount: Int { running.count }

    /// Runs `operation` unless the same repository is already queued or running,
    /// in which case it returns nil immediately.
    public func run<T: Sendable>(id: UUID, _ operation: @Sendable () async -> T) async -> T? {
        guard running.insert(id).inserted else { return nil }
        await acquireSlot()
        let result = await operation()
        releaseSlot()
        running.remove(id)
        return result
    }

    private func acquireSlot() async {
        if activeSlots < maxConcurrent {
            activeSlots += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func releaseSlot() {
        if !waiters.isEmpty, activeSlots <= maxConcurrent {
            // Hand the slot straight to the next waiter.
            waiters.removeFirst().resume()
        } else {
            activeSlots -= 1
        }
    }
}
