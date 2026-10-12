# RC-N3 Input Lab (iOS)

A small iPhone app that connects to a **DJI RC-N3** remote controller over USB-C and shows a live dashboard of **every input we can read**. This is step 1 of a larger project: a high-fidelity DJI drone flight simulator for iPhone. The input code built here will be reused in that simulator, so build it as a reusable module.

## Who you're working with

Andy is a senior UI engineer and designer (10+ years of web/SaaS, Aurelia framework contributor) who is **new to native iOS**. He wants to learn as we go:
- When you introduce an iOS/Swift concept (SwiftUI state, actors, Info.plist, entitlements, signing, run loops, `Data`/byte handling), give a short explanation and compare it to the web equivalent where that helps. Keep it brief and don't lecture.
- Explain *why* when a decision is iOS-specific.
- Andy has the hardware and must do every physical test. You can't touch the sticks, so give clear "do this, then tell me X" test steps.

## Hard facts

- Target device: **iPhone 16 or newer** (USB-C). Physical device only; the Simulator can't see accessories.
- Remote: DJI RC-N3, connected to the iPhone by its phone cable (USB-C to USB-C).
- **It is possible.** SimuDrone (App Store id1601657075) reads DJI RC-N-series remotes on iOS. Our job is to find out how, not whether.
- Use current Apple tech: latest Xcode/Swift, SwiftUI, Swift concurrency.

## Previous attempt: treat it as unreliable

`docs/previous-attempt-postmortem.md` comes from a failed earlier project built by another agent. **Andy doesn't trust it.** Use it only as a reference for what was *tried*. Never treat a "doesn't work" or "unknown" in it as a conclusion. Its main finding: it only ever tried Apple's GameController framework, never confirmed it on hardware, and never tried External Accessory, DUML or the DJI SDK. Don't copy its code.

## Strategy: evidence first

1. **Probe before you build.** The first milestone is a diagnostics app that reports what iOS actually exposes when the RC-N3 is plugged in, and logs raw data. Only then design the clean input API.
2. Make every finding reproducible. Logs must be exportable (share sheet / copy to clipboard) so Andy can paste them back into the chat.
3. Record findings in `docs/findings.md` as they're confirmed on hardware, tagged CONFIRMED (seen on device) or HYPOTHESIS.

See `docs/rc-n3-research-leads.md` for the starting research on transports and protocols.

## Dashboard requirements (end goal of this repo)

- Connection panel: which transport, accessory metadata, protocol strings, update rate (Hz), last-packet age.
- Both sticks: 2D position visual plus numeric raw and normalized values.
- Every other control the RC-N3 has: gimbal dial, flight mode switch (Cine/Normal/Sport), Flight Pause/RTH, shutter/record, photo/video toggle, customizable button(s), anything else. Check the full list against the RC-N3 user manual; don't guess.
- Raw view: live hex stream, plus a "changed bytes" view that highlights which bytes change when a control moves. This is the main reverse-engineering tool.
- Log recording and export.

## Architecture guidance

- Put the input layer in a local Swift package (e.g. `RCKit`) with no UI dependencies. The app target is just the dashboard.
- Model the output as a timestamped `RCInputSample` (sticks, dials, switches, buttons, raw frame) so it can later feed the simulator and support record/replay.
- Keep stream I/O off the main actor. Swift 6 strict concurrency caused crashes in the last attempt, so be deliberate about isolation.
- Keep it simple. No third-party dependencies unless they clearly earn their place.
