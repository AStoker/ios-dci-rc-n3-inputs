# RC-N3 on iOS: research leads

Starting points gathered before coding. **Nothing here is confirmed on hardware.** Verify each item and move confirmed facts to `docs/findings.md`.

## Candidate transports, cheapest test first

### 1. Apple GameController framework (`GCController`)
- Cheap to rule in or out: log `GCController.controllers()`, connect notifications, `vendorName`, `productCategory` and every element of `physicalInputProfile`.
- Expectation: probably **not** how the RC-N3 appears, but the previous agent never actually checked. Check it.

### 2. External Accessory framework (`EAAccessoryManager` / `EASession`): strongest lead
- DJI's iOS Mobile SDK tells apps to declare these in `Info.plist` under `UISupportedExternalAccessoryProtocols`:
  - `com.dji.video`
  - `com.dji.protocol`
  - `com.dji.common`
  (Source: setup docs for DJI's iOS SDK, repeated in the Flutter `dji` package: https://pub.dev/packages/dji)
- First experiment: declare those protocols, then log `EAAccessoryManager.shared().connectedAccessories` with name, manufacturer, modelNumber, serialNumber, firmwareRevision, hardwareRevision and **protocolStrings**. The RC-N3's actual protocol strings are the key fact. If it lists others, add them.
- Then open an `EASession` per protocol and hex-dump whatever arrives on the input stream, both idle and while moving controls. Also try writing known DUML requests (below) to the output stream.
- Notes: an app can only talk to protocols declared in its Info.plist. App Store distribution of EA apps needs the accessory maker's MFi approval, but development builds on Andy's own device are fine for this lab.
- iOS shows a system alert if no app supports the accessory. That alert, or DJI Fly launching, is itself a sign the remote is talking iAP2/EA.

### 3. DUML protocol (DJI's internal message protocol)
- On Windows, the remote shows up as a serial port named "DJI USB VCOM For Protocol". Open-source tools poll it with DUML packets to read the sticks:
  - https://github.com/IvanYaky/DJI_RC-N1_SIMULATOR_FLY_DCL (RC-N1 → virtual Xbox pad, Python, `main.py`)
  - https://github.com/pverhaert/DJI_RCN1_for_drone_simulators
  - https://github.com/ricardoneves93/DJIRemoteToFPVSimulator
  - https://github.com/Matsemann/mDjiController (older remotes; values are little-endian two's complement)
  - https://github.com/samuelsadok/dji_protocol (protocol notes)
- **Read the actual source** to get the exact request bytes, CRC8/CRC16 routines, response offsets and value ranges. Don't trust remembered values. General DUML frame shape (verify): `0x55` start byte, 10-bit length + 6-bit version, header CRC8, sender/receiver, sequence number, command type, command set, command id, payload, CRC16. The stick request in those tools is believed to use the RC command set (0x06) and command id 0x01. Verify this.
- Hypothesis: the same DUML traffic flows over the iOS EA session (likely `com.dji.protocol`). If so, the Windows tools' request/parse logic should port to Swift almost directly.
- Android context: SimuDrone on Android grabs the remote as a USB accessory, and DJI Fly can steal it as the default handler (https://www.darwinbiler.com/controller-not-detected/). That's the same pattern: raw access to the remote's USB interface, not the DJI SDK.

### 4. DJI Mobile SDK (fallback)
- Heavy: needs app key registration and may require a linked aircraft. Check whether a current MSDK supports iOS and the RC-N3 at all before investing. Use only if 2 and 3 dead-end.

## Open questions to answer on hardware
- What protocol strings does the RC-N3 advertise on iPhone 16?
- Does it send any data unprompted, or only when polled?
- Must it be linked/paired to an aircraft, or just powered on?
- Which controls besides the sticks are exposed (dial, mode switch, buttons)? What are their ranges and update rate?
- Does DJI Fly being installed interfere (auto-launch / accessory claim)?

## Reference
- RC-N3 user manual (control list): https://content.abt.com/documents/165459/dji-remote-CPRC0000003801-manual.pdf
- Apple EADemo sample: https://developer.apple.com/library/archive/samplecode/EADemo/Listings/README_md.html
- SimuDrone on the App Store: https://apps.apple.com/app/id1601657075
