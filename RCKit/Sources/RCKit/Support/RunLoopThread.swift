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

    /// True when called from this thread.
    public var isCurrent: Bool { CFRunLoopGetCurrent() === runLoop }

    private final class Handoff: @unchecked Sendable {
        // Written by the new thread before `ready.signal()`, read by init after `ready.wait()`.
        var runLoop: CFRunLoop?
        let ready = DispatchSemaphore(value: 0)
    }
}

/// Carries a non-Sendable value to another thread when the design guarantees only one thread
/// uses it at a time (e.g. handing an `EASession` to the I/O thread, which owns it from then on).
struct UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
}
