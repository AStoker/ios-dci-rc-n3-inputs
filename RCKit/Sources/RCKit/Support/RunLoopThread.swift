import Foundation

/// A dedicated thread running its own RunLoop.
///
/// Foundation streams (`InputStream`/`OutputStream`, which `EASession` hands us) deliver events on
/// whatever run loop they are scheduled on. Web analogy: a Worker with its own event loop. Giving the
/// streams their own run loop keeps byte I/O off the main thread, so a busy UI can't stall reads
/// and a flood of bytes can't stall the UI.
public final class RunLoopThread: @unchecked Sendable {
    // Safety: `runLoop` is assigned once in init (before init returns) and only read after that.
    // CFRunLoopPerformBlock and CFRunLoopWakeUp are documented as thread-safe.
    private let runLoop: CFRunLoop
    private let thread: Thread

    public init(name: String, qos: QualityOfService = .userInitiated) {
        let handoff = Handoff()
        thread = Thread {
            handoff.runLoop = CFRunLoopGetCurrent()
            // A run loop with no input sources returns immediately. An idle port keeps it alive.
            RunLoop.current.add(Port(), forMode: .default)
            handoff.ready.signal()
            while true {
                autoreleasepool {
                    _ = RunLoop.current.run(mode: .default, before: .distantFuture)
                }
            }
        }
        thread.name = name
        thread.qualityOfService = qos
        thread.start()
        handoff.ready.wait()
        runLoop = handoff.runLoop!
    }

    /// Runs `block` on this thread, asynchronously, in FIFO order.
    public func perform(_ block: @escaping @Sendable () -> Void) {
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, block)
        CFRunLoopWakeUp(runLoop)
    }

    /// Runs `block` on this thread and waits for it to finish. Runs inline if already on this thread.
    public func performAndWait(_ block: @escaping @Sendable () -> Void) {
        if isCurrent {
            block()
            return
        }
        let done = DispatchSemaphore(value: 0)
        perform {
            block()
            done.signal()
        }
        done.wait()
    }

    /// Calls `block` on this thread every `interval` seconds until the returned timer is invalidated.
    public func scheduleRepeating(interval: Double, _ block: @escaping @Sendable () -> Void) -> RunLoopTimer {
        let token = RunLoopTimer(thread: self)
        perform {
            let timer = Timer(timeInterval: interval, repeats: true) { _ in block() }
            timer.tolerance = 0
            RunLoop.current.add(timer, forMode: .default)
            token.attach(timer)
        }
        return token
    }

    /// True when called from this thread.
    public var isCurrent: Bool { CFRunLoopGetCurrent() === runLoop }

    private final class Handoff: @unchecked Sendable {
        // Written by the new thread before `ready.signal()`, read by init after `ready.wait()`.
        var runLoop: CFRunLoop?
        let ready = DispatchSemaphore(value: 0)
    }
}

/// A repeating timer on a `RunLoopThread`. Invalidate from any thread.
public final class RunLoopTimer: @unchecked Sendable {
    // Safety: `timer` is only touched on `thread` (set in the scheduling block, cleared in invalidate).
    private var timer: Timer?
    private let thread: RunLoopThread

    init(thread: RunLoopThread) {
        self.thread = thread
    }

    func attach(_ timer: Timer) {
        self.timer = timer
    }

    public func invalidate() {
        thread.perform { [self] in
            timer?.invalidate()
            timer = nil
        }
    }
}

/// Carries a non-Sendable value to another thread when the design guarantees only one thread
/// uses it at a time (e.g. handing an `EASession` to the I/O thread, which owns it from then on).
package struct UncheckedSendableBox<Value>: @unchecked Sendable {
    package let value: Value

    package init(value: Value) {
        self.value = value
    }
}
