import Foundation
import Synchronization

/// Anything that produces `RCInputSample`s: the live remote (`RCN3Remote`), a recording
/// (`RCReplaySource`), and later perhaps on-screen touch sticks.
///
/// Reading `latest` is the intended hot path for a render loop: it's a lock-protected copy, cheap
/// and safe from any thread, with no actor hop (the previous attempt crashed when a render-thread
/// callback touched main-actor state). Use `samples()` when every sample matters (recording,
/// button-edge detection).
public protocol RCInputSource: AnyObject, Sendable {
    /// The most recent sample, or nil before the first one.
    var latest: RCInputSample? { get }
    var connectionState: RCConnectionState { get }
    /// Every sample from now on. Buffers the newest 1024 if the consumer falls behind.
    func samples() -> AsyncStream<RCInputSample>
    /// Connection changes, starting with the current state.
    func connectionStates() -> AsyncStream<RCConnectionState>
    @MainActor func start()
    @MainActor func stop()
}

/// Fan-out of values to any number of `AsyncStream` subscribers, plus the latest value.
final class Broadcaster<Value: Sendable & Equatable>: Sendable {
    private struct State {
        var latest: Value?
        var continuations: [UUID: AsyncStream<Value>.Continuation] = [:]
    }

    private let state: Mutex<State>
    private let bufferSize: Int
    private let replaysLatest: Bool

    init(initial: Value? = nil, bufferSize: Int, replaysLatest: Bool) {
        state = Mutex(State(latest: initial))
        self.bufferSize = bufferSize
        self.replaysLatest = replaysLatest
    }

    var latest: Value? { state.withLock { $0.latest } }

    func stream() -> AsyncStream<Value> {
        let (stream, continuation) = AsyncStream.makeStream(of: Value.self, bufferingPolicy: .bufferingNewest(bufferSize))
        let id = UUID()
        state.withLock { s in
            if replaysLatest, let latest = s.latest { continuation.yield(latest) }
            s.continuations[id] = continuation
        }
        continuation.onTermination = { [weak self] _ in
            _ = self?.state.withLock { $0.continuations.removeValue(forKey: id) }
        }
        return stream
    }

    /// Publishes `value`. With `onlyIfChanged`, skips values equal to the latest. Returns whether it was published.
    @discardableResult
    func publish(_ value: Value, onlyIfChanged: Bool = false) -> Bool {
        let targets: [AsyncStream<Value>.Continuation]? = state.withLock { s in
            if onlyIfChanged, s.latest == value { return nil }
            s.latest = value
            return Array(s.continuations.values)
        }
        guard let targets else { return false }
        for continuation in targets { continuation.yield(value) }
        return true
    }
}
