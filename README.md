# RC-N3 Input Lab (iOS)

An iPhone app that connects to a DJI RC-N3 remote over USB-C and shows every input iOS exposes. Step 1 of a DJI flight simulator for iPhone.

**Status: Milestone 1 done.** The RC-N3 talks to iOS as an External Accessory (`com.dji.logiclink`) speaking DUML. Every stick, the gimbal dial, the flight-mode switch and three of the buttons are readable at ~50-60 Hz with ~10 ms latency (`docs/findings.md`). The clean input API is in RCKit (`docs/input-api-design.md`), and the app's Input tab runs on it.

## Layout

```
RCN3Probe.xcodeproj    Xcode project (open this)
RCN3Probe/             SwiftUI dashboard app (Input · Overview · Streams · DUML · Log)
RCKit/                 Local Swift package
  Sources/RCKit/       the input layer the simulator imports: RCN3Remote, RCInputSample,
                       RCStickMode, RCRecorder/RCReplaySource, DUML codec, AccessoryConnection
  Sources/RCKitProbe/  reverse-engineering diagnostics: StreamAnalyzer, byte diffs, probe log,
                       raw EA sessions + sweep, GameController/network probes, RemoteDiagnosticsTap
  Tests/               RCKitTests (incl. a real-hardware recording fixture), RCKitProbeTests
tools/log2rec.py       turns a probe log into a replayable recording
docs/
  running-on-device.md     signing, first run, launch arguments
  input-api-design.md      the RCKit input API (how to use it, how samples are made)
  findings.md              CONFIRMED vs HYPOTHESIS, with log references
  duml-protocol-notes.md   protocol facts from the open-source tools + RC-N3 specifics
  hardware-test-script.md  test 1 (transport discovery)
  hardware-test-2.md       test 2 (poll rate, control mapping)
  hardware-test-3.md       test 3 (optional leftovers: Customizable, idle alert, DJI Fly)
  hardware-test-4.md       test 4 (the clean API on hardware)
```

## Build

- Xcode 27, iOS 18+, iPhone (USB-C) with the remote. The Simulator runs the UI but can't see accessories.
- Tests: `cd RCKit && swift test`, or ⌘U in Xcode.
