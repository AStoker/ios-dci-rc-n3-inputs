# RCKit input API

**Status: implemented** (2026-10-12), based on hardware logs L1-L2 (`findings.md`). Decisions agreed with Andy:
1. Samples carry **physical sticks**; `RCStickMode` maps them to flight axes.
2. Recordings are **JSON Lines**.
3. Values are **linear −1…1**, with no deadzone or expo; shaping belongs to the simulator.
4. Diagnostics live in a separate library, **RCKitProbe**; the simulator imports only **RCKit**.

## Using it from the simulator

```swift
import RCKit

let remote = RCN3Remote()          // defaults: com.dji.logiclink, 06/01 polled at 100 Hz
remote.start()                     // main actor; connects whenever the remote is plugged in

// Render loop, any thread, every frame. A lock-protected copy, no actor hop:
if let input = remote.latest {
    let axes = RCStickMode.mode2.axes(input)   // throttle, yaw, pitch, roll in -1…1
    let gimbal = input.gimbalDial
    let mode = input.flightMode                 // .cine / .normal / .sport / .unknown
}

// Button edges, connection changes:
Task {
    var previous: RCButtons = []
    for await sample in remote.samples() {
        let pressed = sample.buttons.subtracting(previous)
        previous = sample.buttons
        if pressed.contains(.pauseRTH) { /* brake */ }
    }
}
Task { for await state in remote.connectionStates() { /* show status */ } }

// On returning to the foreground (iOS drops EA sessions for suspended apps):
remote.refresh()
```

Recording and replay use the same interface:

```swift
let recorder = try RCRecorder(url: url, header: RCRecordingHeader(accessory: remote.connectionState.accessory))
recorder.record(from: remote)      // …later: recorder.stop()

let replay = try RCReplaySource(url: url, loops: true)
replay.start()                     // replay.latest / replay.samples() behave like the remote
```

## Types

| Type | What it is |
|---|---|
| `RCInputSample` | `time` (monotonic s), `index`, `leftStick`/`rightStick` (`RCStick` x,y −1…1, +x right, +y up), `gimbalDial` −1…1, `flightMode`, `buttons`, `raw` (`RCRawInput`: wire values 364…1684 + the two 06/05 flag bytes), `source` (`.poll` / `.push` / `.replay`) |
| `RCButtons` | OptionSet: `.pauseRTH`, `.shutterRecord`, `.photoVideo` (held states) and `.customizable` (Fn: probably a brief pulse on a short tap only; HYPOTHESIS). Power isn't reported |
| `RCFlightMode` | `.cine` (C), `.normal` (N), `.sport` (S), `.unknown` until the first 06/05 push |
| `RCConnectionState` | `.stopped`, `.waitingForAccessory`, `.connecting(AccessoryInfo?)` (opening, or no data for over 1 s), `.streaming(AccessoryInfo)`, `.failed(String)` (e.g. another app holds the remote; retried every 2 s), `.replaying(String)` |
| `RCInputSource` | Protocol: `latest`, `connectionState`, `samples()`, `connectionStates()`, `start()`, `stop()` |
| `RCN3Remote` | The live remote. Also `stats` (sample/poll/push rates, latency, remote version), `refresh()`, and `sendDiagnostic(_:note:frame:)` plus a `diagnostics` callback for tools |
| `RCStickMode` | `.mode1/.mode2/.mode3` → `Axes(throttle, yaw, pitch, roll)` |
| `RCRecorder`, `RCRecording`, `RCReplaySource` | JSON Lines capture, load, real-time playback |

## How samples are made (`RCN3InputAssembler`)

- **06/01 reply** (polled every 10 ms): sticks + gimbal. A reply whose values changed becomes a `.poll` sample (~50-60/s, the remote's own refresh rate). Unchanged replies are dropped.
- **06/05 push** (~7/s while polling): mode switch and buttons, carried into later samples. While polling is fresh, a push only creates a `.push` sample when the mode or buttons changed. If no poll reply arrived for 250 ms, pushes drive the sticks too (~9 samples/s fallback).
- Button presses shorter than one push interval (~140 ms) can be missed. That's a limit of the remote's push rate.

## Threading

- EA notifications and `EASession` creation: main actor (`start`, `stop`, `refresh`).
- Stream I/O, the 100 Hz poll timer, the stall watchdog and sample assembly: a private `RunLoopThread`.
- Shared state: `Mutex`. Samples are published from the I/O thread. `latest` is safe from any thread.
- `AccessoryConnection` is the only `EASession` I/O implementation. RCKitProbe's diagnostic sessions use it too.

## Recording format

```
{"format":"rckit-recording","note":"…","startedAt":"2026-10-12T23:46:31Z","version":1,"accessory":{…}}
{"buttons":0,"flightMode":"N","gimbalDial":0,"index":0,"leftStick":{"x":0,"y":0},"raw":{…},"rightStick":{"x":0,"y":0},"source":"poll","time":175.004}
…
```

Keys are sorted; one sample per line; ~265 bytes per sample (about 16 KB/s at 60 samples/s). `RCKit/Tests/RCKitTests/Fixtures/hw-test-2-demo.jsonl` is real hardware motion (converted from log L2 with `tools/log2rec.py`).

## Package layout

```
RCKit        DUML codec, AccessoryConnection, RCN3Remote, samples, stick modes, record/replay
RCKitProbe   StreamAnalyzer, ByteDiffTracker, ProbeLog, probe sessions/sweep, GameController & network probes,
             RemoteDiagnosticsTap (RCN3Remote traffic → analyzer + log)
RCN3Probe    the dashboard app (Input, Overview, Streams, DUML, Log)
```

## Open

- Does changing the stick mode in DJI Fly make the remote re-map its channels (06/19 "RC Control Mode Set" exists)? `RCStickMode` assumes physical channels (default Mode 2).
- Fn button: short-tap pulse unconfirmed (`hardware-test-fn.md`). Because it's a ~0.13 s pulse, poll `latest` and you may miss it; watch `samples()` for the edge.
