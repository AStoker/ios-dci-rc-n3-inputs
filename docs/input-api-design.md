# RCKit input API: design proposal (for review, not implemented)

Based on hardware logs L1 and L2 (see `findings.md`). Test 2 settled the open question: 06/01 polling sustains 100 Hz with ~10 ms latency, and the remote refreshes stick values at ~50-60 Hz.

## Goals

- The simulator gets **one timestamped sample type** and never sees DUML, EA or threads.
- Reading the latest input from a render loop is **non-blocking and thread-agnostic**. The previous attempt crashed when actor-isolated state was touched from SceneKit's render thread.
- **Record/replay**: a recorded session plays back through the same interface as the live remote.
- The probe keeps working; diagnostics move to their own library so the simulator doesn't link them.

## Public types

```swift
/// One reading of every RC-N3 input.
public struct RCInputSample: Sendable, Equatable, Codable {
    public var time: Double              // monotonic seconds (arrival of the bytes)
    public var index: UInt64             // increases by 1 per sample
    public var leftStick: RCStick        // physical sticks, not mode-mapped
    public var rightStick: RCStick
    public var gimbalDial: Double        // -1…1, spring return
    public var flightMode: RCFlightMode  // .cine / .normal / .sport / .unknown
    public var buttons: RCButtons        // currently held
    public var raw: RCRawInput           // 364…1684 axis values + flag bytes, for exact replay
    public var source: RCSampleSource    // .push (06/05), .poll (06/01), .replay
}

public struct RCStick: Sendable, Equatable, Codable { public var x, y: Double } // -1…1, +x right, +y up

public struct RCButtons: OptionSet, Sendable, Codable {
    public static let pauseRTH, shutterRecord, photoVideo: RCButtons   // Customizable isn't reported (L2)
}

public enum RCConnectionState: Sendable, Equatable {
    case waitingForAccessory
    case connecting(AccessoryInfo)
    case streaming(AccessoryInfo, sampleRate: Double)
    case failed(String)
}

/// Anything that produces samples: the live remote, a replay, a touch-stick fallback later.
public protocol RCInputSource: AnyObject, Sendable {
    /// Latest sample. Lock-protected and cheap: safe to call every frame from any thread.
    var latest: RCInputSample? { get }
    /// Every sample, for UI, recorders and button-edge detection.
    func samples() -> AsyncStream<RCInputSample>
    func connectionStates() -> AsyncStream<RCConnectionState>
    func start()
    func stop()
}

public final class RCN3Remote: RCInputSource { … }      // EA com.dji.logiclink + DUML
public final class RCReplaySource: RCInputSource { … }  // plays a recording in real time
public final class RCRecorder { … }                     // writes samples as JSON Lines

/// Mode 1/2/3 mapping from physical sticks to flight axes (RC-N3 manual §4.3).
public enum RCStickMode { case mode1, mode2, mode3
    public func axes(_ s: RCInputSample) -> (throttle: Double, yaw: Double, pitch: Double, roll: Double)
}
```

## Inside `RCN3Remote`

- Watches `EAAccessoryManager` and opens `com.dji.logiclink` (T2). Reconnects on unplug/replug and when the app returns to the foreground.
- All stream I/O stays on the existing `RunLoopThread` (no actors, no main thread).
- Outbound: DUML in a `55 CC` envelope, port 22345, sender App (T6). Sends a version ping first to confirm the link.
- Inbound: `DUMLStreamScanner` (handles the 512-byte padded transfers).
- **Input sources, merged into one sample stream:**
  - 06/01 poll at **100 Hz** from a timer on the I/O thread: sticks + gimbal. Every reply whose values changed produces a sample (≈ 50-60 samples/s, matching the remote's own refresh rate, ~10 ms after the request).
  - 06/05 push (~7/s while polling): flight mode switch and buttons, carried into the next sample. A button edge also produces a sample immediately.
  - If polling stops getting replies (e.g. another app takes the remote), fall back to 06/05 sticks at ~9 Hz and report it in `RCConnectionState`.
- Button presses shorter than one push interval (~140 ms) can be missed. That's a hardware limit of the push rate; the API exposes held state, not guaranteed edges.
- `latest` lives behind a `Mutex`. `samples()` fans out to `AsyncStream` continuations (buffering newest-only for slow consumers).

## Package layout

```
RCKit        (library)  public API above + DUML codec. What the simulator imports.
RCKitProbe   (library)  StreamAnalyzer, ByteDiffTracker, ProbeLog, sweep, GameController/network probes.
RCN3Probe    (app)      the dashboard, built on RCKitProbe + RCKit.
```

## Decisions for Andy (still open)

1. **Physical sticks** in the sample plus an `RCStickMode` helper (recommended), or mode-mapped throttle/yaw/pitch/roll as the primary fields?
2. **Recording format**: JSON Lines (readable, diffable, ~10 KB/s at 100 Hz; recommended) or compact binary?
3. **Normalisation**: RCKit reports linear −1…1 with no deadzone/expo, leaving shaping to the simulator (recommended), or should RCKit own deadzone/expo?
4. Split the diagnostics into `RCKitProbe` now (recommended), or keep one library until the simulator exists?
