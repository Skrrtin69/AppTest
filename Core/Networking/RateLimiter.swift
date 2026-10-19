import Foundation

/// Token bucket shared by every request of one adapter.
/// `rate` tokens are added per second, up to `burst`; each request takes one token and
/// waits (without blocking a thread) when the bucket is empty.
actor RateLimiter {
    private var rate: Double
    private let burst: Double
    private var tokens: Double
    private var last: Date

    init(ratePerSecond: Double) {
        let r = max(ratePerSecond, 0.05)
        rate = r
        burst = max(1, min(r, 5))
        tokens = burst
        last = Date()
    }

    func setRate(_ r: Double) {
        rate = max(r, 0.05)
    }

    func acquire() async {
        while true {
            refill()
            if tokens >= 1 {
                tokens -= 1
                return
            }
            let wait = (1 - tokens) / rate
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        }
    }

    private func refill() {
        let now = Date()
        tokens = min(burst, tokens + now.timeIntervalSince(last) * rate)
        last = now
    }
}
