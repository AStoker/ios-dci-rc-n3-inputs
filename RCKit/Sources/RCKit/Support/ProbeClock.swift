import Foundation

/// Monotonic time in seconds (since device boot). Like `performance.now()`: it never jumps when
/// the wall clock changes, so it's safe for rates and packet ages.
public enum ProbeClock {
    public static func now() -> Double { ProcessInfo.processInfo.systemUptime }
}

/// Events (or bytes) per second over a sliding one-second window, in ten 100 ms buckets.
public struct RateMeter: Sendable {
    private var buckets = [Double](repeating: 0, count: 10)
    private var currentBucket = 0

    public init() {}

    public mutating func add(_ amount: Double = 1, at time: Double) {
        advance(to: time)
        buckets[currentBucket % 10] += amount
    }

    /// Total over the last second.
    public mutating func rate(at time: Double) -> Double {
        advance(to: time)
        return buckets.reduce(0, +)
    }

    private mutating func advance(to time: Double) {
        let bucket = Int(time * 10)
        guard bucket > currentBucket else { return }
        let steps = min(bucket - currentBucket, 10)
        for i in 1...steps { buckets[(currentBucket + i) % 10] = 0 }
        currentBucket = bucket
    }
}
