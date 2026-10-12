# POSTMORTEM: Drone-Flight-Simulator (retired)

Date: 2026-10-12  
Repo: `Drone-Flight-Simulator`  
Status: retired, replacement planned from scratch.

This document is intentionally blunt. Claims are tagged:
- **VERIFIED** = proven by artifacts in repo or explicit logs in prior context
- **OBSERVED** = present in code/config but never proven on hardware/runtime
- **ASSUMED** = plausible but not evidenced here

---

## 1) Goal and outcome

### Goal
Build an iOS drone flight simulator with:
- DJI RC-N3 (screenless) as primary input on iPhone
- on-screen touch joysticks as fallback
- camera pan up/down
- simple world (ground + one tree)

**Status:** **OBSERVED** in design intent and code comments.

### Outcome
A SceneKit-based prototype exists with:
- a basic 3D scene (`SCNFloor`, grid, one tree, sky/fog, lights)
- a physics-driven drone node with FPV camera and gimbal pitch
- input abstraction combining virtual sticks and `GameController`
- HUD overlay and virtual joystick UI

But there is **no evidence in repo** that RC-N3 input was actually read on a physical iPhone.  
**Outcome assessment:** prototype-level rendering + controls, controller integration unresolved/untested.  
**Status:** **OBSERVED** (features in code), **ASSUMED** (real RC-N3 functionality).

### Main reasons it stalled/failed

#### Root causes
1. **Controller strategy started from assumption, not hardware proof**: input pipeline was built before proving RC-N3 appears as usable `GCController` on iOS.  
   **Status:** **OBSERVED** (code architecture), **ASSUMED** (device behavior).
2. **Scope mixed platform risk with simulation build**: RC connectivity, 3D engine migration, physics, HUD, and touch UX all moved in parallel; no early risk gate.  
   **Status:** **OBSERVED**.
3. **No instrumentation/test harness for controller packets/events**: no logging module or capture artifacts committed.  
   **Status:** **VERIFIED** (repo lacks logs/tests/tools for this).
4. **Strict concurrency/tooling friction consumed time**: render-thread vs MainActor crash had to be patched mid-stream.  
   **Status:** **VERIFIED** (error context + code annotations).

#### Symptoms
- Runtime class-cast failures during SpriteKit->SceneKit transition (`UIView`/`SKView`/`SCNView` mismatch).  
  **Status:** **VERIFIED** (prior error strings in conversation).
- Crash on render thread (`EXC_BREAKPOINT`) due to actor isolation mismatch.  
  **Status:** **VERIFIED** (prior error strings + code changes).
- "Controller connected" HUD text is optimistic and not tied to RC-specific capability checks.  
  **Status:** **OBSERVED** (`HUDView.swift`, `InputManager.swift`).

---

## 2) DJI RC-N3 controller interfacing (most important)

This section distinguishes what is in code from what was actually demonstrated.

### Approaches attempted

#### A) Apple `GameController` framework (`GCController`, extended gamepad)
- Evidence:
  - `InputManager` observes `.GCControllerDidConnect/.DidDisconnect`, reads `extendedGamepad` sticks/triggers.
  - `Info.plist` has `GCSupportsControllerUserInteraction = true`.
- Files:
  - `Drone-Flight-Simulator/InputManager.swift`
  - `Drone-Flight-Simulator/Info.plist`
- How far it got:
  - App-level plumbing exists; mappings implemented.
  - No committed runtime logs showing RC-N3 enumerated, vendor name, profile, or per-axis updates.
- Errors/limits hit:
  - None RC-specific recorded.
  - Connection state is binary (`controllerConnected` true/false), no product filtering.
- Confidence: **OBSERVED** (implementation), **ASSUMED** (RC-N3 compatibility in practice).

Verbatim snippet (`Drone-Flight-Simulator/InputManager.swift`):
```swift
connectObserver = NotificationCenter.default.addObserver(
    forName: .GCControllerDidConnect,
    object: nil,
    queue: .main
) { [weak self] note in
    guard let controller = note.object as? GCController else { return }
    self?.configureController(controller)
}
...
guard let gamepad = controller.extendedGamepad else { return }
gamepad.leftThumbstick.valueChangedHandler = { [weak self] _, xValue, yValue in
    self?.hwLeftX = xValue
    self?.hwLeftY = yValue
}
```

#### B) DJI Mobile SDK
- No DJI SDK dependency, no app-key registration, no bridging headers, no DJI imports.
- Confidence: **VERIFIED not attempted** in this repo.

#### C) External Accessory (`EAAccessory`, `EASession`, MFi protocol strings)
- No `ExternalAccessory` usage.
- `Info.plist` has no `UISupportedExternalAccessoryProtocols`.
- Confidence: **VERIFIED not attempted**.

#### D) USB/HID direct reading
- No `IOHID*` APIs or lower-level USB stack code.
- Confidence: **VERIFIED not attempted**.

#### E) DUML or reverse-engineered protocol
- No parsers, packet structs, or byte-level transport code.
- Confidence: **VERIFIED not attempted**.

#### F) Bluetooth direct (CoreBluetooth custom profile)
- No `CoreBluetooth` usage.
- Confidence: **VERIFIED not attempted**.

### Info.plist / entitlements / registration details
- Present:
  - `GCSupportsControllerUserInteraction` = true  
    (`Drone-Flight-Simulator/Info.plist`)
- Missing:
  - `UISupportedExternalAccessoryProtocols` (none)
  - DJI app key / SDK registration settings (none)
  - special entitlements for EA/MFi (none visible)
- Confidence: **VERIFIED**.

### Any input actually read (sticks/buttons/ranges/rates/mapping)

#### Mapping in code (not hardware-validated)
- Left stick X -> yaw
- Left stick Y -> throttle
- Right stick X -> roll
- Right stick Y -> pitch
- Left/Right trigger -> cameraPitch (-/+)
- Deadzone: 0.08 with rescaling
- Virtual joystick fallback when no controller

Files:
- `Drone-Flight-Simulator/InputManager.swift`
- `Drone-Flight-Simulator/DroneFlightController.swift`

Confidence:
- **OBSERVED** (mapping logic exists)
- **ASSUMED** (RC-N3 channel semantics match this)

#### Raw captures / packet layouts / update rate
- None in repo.
- Confidence: **VERIFIED unknown**.

### Pairing/power mode requirements for RC-N3 stick data
- Not documented/tested in repo.
- Confidence: **VERIFIED unknown**.

---

## 3) Rendering and 3D

### Frameworks used/considered
- Current implementation uses SceneKit (`SCNView`, `SCNScene`, `SCNNode`).
- Prior context indicates project started as SpriteKit template and migrated.
- No RealityKit/Metal/Unity/Unreal integration in repo.
- Confidence: **VERIFIED** (SceneKit code present), **VERIFIED** (no others present).

### Performance data (real device)
- FPS/thermal/memory metrics: none committed.
- `showsStatistics` is false in `GameViewController`.
- Confidence: **VERIFIED unknown**.

### Terrain/sky/lighting/LOD/assets
- Ground: `SCNFloor` with green material and helper grid boxes.
- Tree: procedural trunk + 3 cone canopy layers.
- Lighting: directional + ambient.
- Sky/fog: solid color + fog distances.
- LOD: none.
- Asset loading pipeline: none (all procedural primitives, no model files).
- Asset licenses: N/A (no external assets committed).
- Confidence: **OBSERVED**.

Key file:
- `Drone-Flight-Simulator/FlightScene.swift`

---

## 4) Flight physics

### Flight model implemented
- Simplified force/torque model in SceneKit physics:
  - vertical force = hover compensation + throttle term
  - yaw torque
  - forward/strafe forces in world-space directions from node transform
  - visual tilt interpolation
  - camera pitch integration with clamp
- This is not DJI GPS/position-hold behavior; closer to arcade stabilized model.
- Confidence: **OBSERVED**.

### Stick mapping and parameters
- Parameters from `DroneFlightController`:
  - `thrustForce = 18`
  - `hoverCompensation = 9.81`
  - `yawTorque = 3`
  - `pitchForce = 12`
  - `rollForce = 12`
  - `maxTiltAngle = 0.35 rad`
- No expo/rates profile, no mode switch behavior.
- Confidence: **OBSERVED**.

### What felt right/wrong
- No test notes or pilot evaluation data in repo.
- Confidence: **VERIFIED unknown**.

### Camera/gimbal model
- Separate `gimbalNode` with pitch clamp to +-pi/2.
- Trigger/slider control path exists.
- Confidence: **OBSERVED**.

Key file:
- `Drone-Flight-Simulator/DroneNode.swift`

---

## 5) Project and tooling

### Toolchain and platform
- Xcode project exists (`Drone-Flight-Simulator.xcodeproj`).
- SceneDelegate/AppDelegate UIKit lifecycle used.
- `Info.plist` scene manifest points to `Main.storyboard`.
- Prior context references Swift strict concurrency/actor isolation issues.
- Exact Xcode app version and Swift language version not explicitly recorded in repo docs.
- Confidence: **OBSERVED** / **ASSUMED** (for version specifics).

### Min iOS / dependencies
- No third-party SPM packages in repo.
- XCTest boilerplate files exist; no meaningful simulator logic tests.
- Confidence: **VERIFIED**.

### Signing/provisioning issues
- No explicit records in repo.
- Confidence: **VERIFIED unknown**.

### Build/runtime issues encountered
- Class-cast issues due to storyboard view class mismatch during migration.
- Render-thread `EXC_BREAKPOINT` from actor isolation mismatch.
- Confidence: **VERIFIED** from prior error context.

### What requires physical device
- RC-N3 input validation (all of it) requires physical iPhone + controller.
- Confidence: **VERIFIED** (practical platform requirement).

---

## 6) Dead ends to skip

- **Assuming RC-N3 == generic gamepad before hardware proof** - high risk; gate this first.
- **Mixing storyboard view classes during engine migration** - caused avoidable runtime casts.
- **Building full sim loop before controller observability/logging** - no evidence of RC data path correctness.
- **Relying on HUD "connected" text as proof** - not a capability test.
- **Ignoring concurrency model early** - SceneKit render callbacks and MainActor default can conflict.

All reasons: **OBSERVED**; failure impact: **VERIFIED** for two runtime errors.

---

## 7) What to keep

These are the few pieces worth porting, with caveats.

1. `Drone-Flight-Simulator/VirtualJoystickView.swift`  
   Reason: self-contained, usable touch-stick component with normalized output and spring return.  
   Confidence: **OBSERVED**.

2. `Drone-Flight-Simulator/HUDView.swift`  
   Reason: lightweight overlay pattern for telemetry and a camera pitch control.  
   Caveat: layout and rotated slider hit-testing should be revalidated.  
   Confidence: **OBSERVED**.

3. `Drone-Flight-Simulator/InputManager.swift` (partial)  
   Reason: good abstraction boundary (hardware + virtual merge, deadzone).  
   Caveat: RC-N3 assumptions unproven; needs product/profile checks + logs + thread safety review.  
   Confidence: **OBSERVED**.

4. `Drone-Flight-Simulator/FlightScene.swift` (as prototype only)  
   Reason: fast procedural scene bootstrap for early iteration.  
   Caveat: not scalable for production content/performance targets.  
   Confidence: **OBSERVED**.

---

## 8) Unanswered questions

1. **Does RC-N3 enumerate as `GCController` on iPhone in the required connection mode?**  
   Status: unknown.  
   Next experiment: ship a tiny "controller probe" app that logs controller list, `vendorName`, profile type, every element value at timestamped intervals to file.

2. **If RC-N3 does not expose extended gamepad, what transport is available on iOS?**  
   Status: unknown.  
   Next experiment: test External Accessory eligibility with known protocol strings (if any from vendor docs), inspect attached accessory metadata, and document whether iOS exposes anything without DJI SDK.

3. **Are non-stick controls (C1/C2/Fn/photo/video/pause/mode) exposed through any Apple API?**  
   Status: unknown.  
   Next experiment: event matrix test while actuating each control, persist raw element identifiers and value changes.

4. **What latency and update rate are achievable end-to-end?**  
   Status: unknown.  
   Next experiment: timestamp input callbacks + render frame application, compute distribution on physical device.

5. **Can this architecture stay stable under strict concurrency defaults?**  
   Status: uncertain.  
   Next experiment: isolate render-loop state in non-main actor or lock-free data model; run Thread Sanitizer and stress tests.

All: **VERIFIED unknown** unless otherwise noted.

---

## 9) If starting over (recommended)

Order of work to de-risk controller input first:

1. **Build RC-N3 probe app first, no simulator rendering.**
   - Single screen with raw input table + logging export.
   - Hard acceptance criteria: sticks + at least one auxiliary control visible with stable ranges and update rate.
   - If this fails, stop and reassess SDK/transport path.

2. **Decide input stack based on probe evidence, not assumptions.**
   - Path A: `GameController` works -> continue.
   - Path B: requires DJI SDK / unsupported on iOS consumer APIs -> redesign goals early.

3. **Define a deterministic input contract module.**
   - `InputSample` with timestamps, source type, confidence.
   - Record/replay harness so flight/UX can iterate without live hardware.

4. **Stand up minimal 3D runtime only after input is proven.**
   - SceneKit for fast MVP is acceptable.
   - Keep render loop and UI strictly separated from input collection thread model.

5. **Add instrumentation before features.**
   - FPS, frame time, input latency, dropped-frame counters, thermal state logging.
   - Commit sample logs to repo with each milestone.

6. **Then implement flight model in phases.**
   - Phase 1: arcade stabilized (like current)
   - Phase 2: tuned rates/expo
   - Phase 3: optional DJI-style assisted modes if product requires

7. **Only then add assets/content.**
   - Keep procedural placeholders until controls and frame budget are stable.

Confidence of recommendation: **ASSUMED** (best-practice guidance), based on verified failures above.

---

## Appendix: concrete code references supporting claims

- Controller observation + mapping: `Drone-Flight-Simulator/InputManager.swift`
- Deadzone logic: `Drone-Flight-Simulator/InputManager.swift` lines near `applyDeadzone`
- Flight force model: `Drone-Flight-Simulator/DroneFlightController.swift`
- Scene setup (ground/tree/lights/fog): `Drone-Flight-Simulator/FlightScene.swift`
- HUD connection text: `Drone-Flight-Simulator/HUDView.swift`
- SceneKit host + render callback: `Drone-Flight-Simulator/GameViewController.swift`
- Only relevant plist key present: `Drone-Flight-Simulator/Info.plist` (`GCSupportsControllerUserInteraction`)
