# Findings

Tags: **CONFIRMED** = seen on Andy's hardware (iPhone 16 Pro Max + RC-N3), with the log that shows it. **HYPOTHESIS** = from docs, other devices or reasoning; not yet seen on hardware.

## Transport

| # | Claim | Status | Evidence |
|---|---|---|---|
| T1 | The RC-N3 shows up to iOS as an External Accessory (iAP2) | HYPOTHESIS | DJI iOS SDK docs; samuelsadok captures of other DJI ground devices |
| T2 | Its EA protocol string is one of `com.dji.common` / `com.dji.logiclink` / `com.dji.protocol` / `com.dji.video` | HYPOTHESIS | Interface names in samuelsadok lsusb dumps; DJI SDK setup docs |
| T3 | The RC-N3 does **not** show up as a `GCController` | HYPOTHESIS | Never tested; the previous attempt only assumed it would |
| T4 | DUML flows over the EA session, possibly inside `55 CC` envelopes | HYPOTHESIS | samuelsadok (Goggles N3, Mavic Pro RC) |
| T5 | DJI Mobile SDK isn't a viable iOS path for the RC-N3 | HYPOTHESIS | Dronelink forum reports: MSDK v5 has no iOS support |

## Protocol

| # | Claim | Status | Evidence |
|---|---|---|---|
| P1 | DUML CRC8 seed 0x77 / CRC16 seed 0x3692 | HYPOTHESIS for RC-N3 (verified against RC-N1 and Goggles N3 packets) | `docs/duml-protocol-notes.md`, unit tests |
| P2 | 06/01 returns sticks as 8 × (tag, LE16) records, 364…1024…1684 | HYPOTHESIS | RC-N1 tools |
| P3 | 06/24 01 is needed for a fast update rate | HYPOTHESIS | RC-N1 tools' comment |

## RC-N3 controls (from the DJI RC-N3 User Manual, 2024, §3-4)

The manual's parts list, with inputs that might be readable in **bold**: 1 **Power Button**, 2 **Flight Mode Switch** (C Cine / N Normal / S Sport), 3 **Flight Pause/Return to Home (RTH) Button** (press = brake, hold = RTH), 4 Battery Level LEDs, 5 **Control Sticks** (Mode 2 default: left = throttle/yaw, right = pitch/roll), 6 **Customizable Button** (default: recenter gimbal / point down), 7 **Photo/Video Button**, 8 Remote Controller Cable, 9 Mobile Device Holder, 10 Antennas, 11 USB-C Port (charging; used with DJI Assistant 2 on a computer), 12 Control Stick Storage Slots, 13 **Gimbal Dial**, 14 **Shutter/Record Button**, 15 Mobile Device Slot.

Manual §6: the remote sounds an idle alert and powers itself off if it's "not connected to the aircraft or the DJI Fly app on the mobile device". If our app silences that, the remote considers our app connected.

## Hardware results

_Nothing yet. Fill in from probe logs: date, iOS version, RC-N3 firmware, DJI Fly installed y/n, what was seen._
