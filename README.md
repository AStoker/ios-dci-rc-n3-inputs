# RC-N3 Input Lab (iOS)

An iPhone app that connects to a DJI RC-N3 remote over USB-C and shows every input iOS exposes. Step 1 of a DJI flight simulator for iPhone.

**Status: Milestone 1, the probe.** It reports what iOS exposes (GameController, External Accessory, network interfaces), streams raw bytes, decodes DUML and logs everything for export. The clean input API comes after hardware results.

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
  hardware-test-script.md  what to do with the remote, step by step
  duml-protocol-notes.md   protocol facts pulled from the open-source tools
  findings.md              CONFIRMED vs HYPOTHESIS
```

## Build

- Xcode 27, iOS 18+, iPhone (USB-C) with the remote. The Simulator runs the UI but can't see accessories.
- Tests: `cd RCKit && swift test`, or ⌘U in Xcode.
