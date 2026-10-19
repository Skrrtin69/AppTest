import Foundation

/// Counting semaphore for async code whose limit can change at runtime
/// (driven by the concurrency sliders in Settings).
actor AsyncSemaphore {
    private var limit: Int
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = max(1, limit) }

    func setLimit(_ n: Int) {
        limit = max(1, n)
        resumeWaiters()
    }

    func wait() async {
        if running < limit {
            running += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func signal() {
        running = max(0, running - 1)
        resumeWaiters()
    }

    private func resumeWaiters() {
        while running < limit, !waiters.isEmpty {
            running += 1
            waiters.removeFirst().resume()
        }
    }

    /// Runs `work` while holding a slot.
    func run<T>(_ work: @escaping () async throws -> T) async rethrows -> T {
        await wait()
        defer { signal() }
        return try await work()
    }
}
