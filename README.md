# RC-N3 Input Lab (iOS)

An iPhone app that connects to a DJI RC-N3 remote over USB-C and shows every input iOS exposes. Step 1 of a DJI flight simulator for iPhone.

**Status: Milestone 1, the probe.** It works on hardware: the RC-N3 is an External Accessory (`com.dji.logiclink`) speaking DUML, and every stick, the dial, the mode switch and the buttons are readable (see `docs/findings.md`). 06/01 polling sustains 100 Hz at ~10 ms latency. Next: the clean input API (`docs/input-api-design.md`, awaiting review).

## Layout

```
RCN3Probe.xcodeproj    Xcode project (open this)
RCN3Probe/             SwiftUI dashboard app (Overview · Streams · DUML · Log)
RCKit/                 Local Swift package, the reusable input layer (no UI)
  DUML/                frame codec, CRCs, 55 CC envelope, stream scanner, RC decoders
  ExternalAccessory/   EASession on a dedicated I/O run-loop thread
  GameController/      GCController/keyboard/mouse element probe
  Diagnostics/         log, per-stream analyzer, byte-diff tracker, network/env probes
docs/
  running-on-device.md     signing + first run
  hardware-test-script.md  test 1: what to do with the remote, step by step
  hardware-test-2.md       test 2: poll rate and control confirmation
  hardware-test-3.md       test 3: Customizable button, idle alert, DJI Fly interplay
  input-api-design.md      proposal for the RCKit public API
  duml-protocol-notes.md   protocol facts pulled from the open-source tools
  findings.md              CONFIRMED vs HYPOTHESIS
```

## Build

- Xcode 27, iOS 18+, iPhone (USB-C) with the remote. The Simulator runs the UI but can't see accessories.
- Tests: `cd RCKit && swift test`, or ⌘U in Xcode.
