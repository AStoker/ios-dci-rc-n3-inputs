# DUML protocol notes (extracted from source, not yet seen on an RC-N3)

What the open-source tools actually do, read from their source on 2026-10-12. Everything here is **HYPOTHESIS for the RC-N3** until it shows up in a probe log. The CRC routines are the exception: they're checked byte-for-byte against published packets (see "Verification").

## Sources read

| Repo (commit) | What it gave us |
|---|---|
| [IvanYaky/DJI_RC-N1_SIMULATOR_FLY_DCL](https://github.com/IvanYaky/DJI_RC-N1_SIMULATOR_FLY_DCL) `main.py` (1eb5fae, 2025-02) | `send_duml`, CRC8/CRC16 tables + seeds, simulator-mode command, stick offsets |
| [pverhaert/DJI_RCN1_for_drone_simulators](https://github.com/pverhaert/DJI_RCN1_for_drone_simulators) `dji.py` (53f45b6, 2025-07) | Hard-coded stick request bytes, read-after-write loop, 38-byte filter, timing stats |
| [ricardoneves93/DJIRemoteToFPVSimulator](https://github.com/ricardoneves93/DJIRemoteToFPVSimulator) `main.py` (72cabd4, 2023-12) | Same as IvanYaky (Mini 2 remote), normalisation to −1…1 |
| [Matsemann/mDjiController](https://github.com/Matsemann/mDjiController) `src/Main.cpp` (e3ba0dc) | Phantom 2 era, uses a different `55 aa 55 aa` framing. Not DUML v1, so not used |
| [samuelsadok/dji_protocol](https://github.com/samuelsadok/dji_protocol) `usb_mobile_protocol.md`, `video_out_mobile.py`, `lsusb/` (50c71b6, 2025-07) | **The iPhone USB link**: interface strings, `55 CC` envelope, port numbers, captured Goggles N3 packets |
| [o-gs/dji-firmware-tools](https://github.com/o-gs/dji-firmware-tools) `comm_dissector/wireshark/*.lua` (1956922, 2026-07) | Field names: device ids, command sets, RC command names, 06/05 push layout, 00/01 version layout |

## DUML v1 frame

```
off size field
0   1    0x55
1   2    LE16: bits 0-9 total length (incl. CRC16), bits 10-15 version (=1, so byte 2 is 0x04 for short frames)
3   1    CRC8 over bytes 0..2      seed 0x77, reflected poly 0x31 (table 0x00,0x5E,0xBC,...)
4   1    sender    (bits 0-4 type, 5-7 index)   PC = 0x0A, App = 0x02, RC = 0x06
5   1    receiver
6   2    LE16 sequence number
8   1    cmd type: bit7 = response, bits 5-6 ack (0x40 = "ack after exec"), bits 0-2 encryption
9   1    cmd set   (0x06 = Remote Control, 0x00 = General)
10  1    cmd id
11  n    payload
11+n 2   LE16 CRC16 over bytes 0..10+n   seed 0x3692, reflected poly 0x1021 (table 0x0000,0x1189,...)
```

The RC-N1 tools' header CRC is `chksum = table[(byte ^ chksum) & 0xFF]` from 0x77. The frame CRC is `v = (v >> 8) ^ table[(byte ^ v) & 0xFF]` from 0x3692 (their comment: "P3/P4/Mavic"; other seeds listed: 0x1012 Naza M, 0x1013 Phantom 2, 0x7000 Naza M V2).

## The stick request (exact bytes)

From `pverhaert/dji.py`, written after every received packet:

```
55 0d 04 33 0a 06 eb 34 40 06 01 74 24
│  └len 13, v1  │  │  │  └seq 0x34eb │  │  └CRC16 0x2474
│        CRC8 ──┘  │  └RC          │  └cmd id 0x01 "RC Channel Params Get"
│           PC ────┘               └cmd type 0x40, cmd set 0x06 (RC)
```

Sent once beforehand by IvanYaky and ricardoneves93. Their comment: "without this stick positions are sent very slow by RC".

```
55 0e 04 66 0a 06 eb 34 40 06 24 01 d9 ec      06/24 "RC Simulate Flight Mode Set", payload 01
```

(The tools reset the sequence to 0x34eb on every call, a bug that the remote evidently tolerates.)

## The stick response (RC-N1, per the tools)

They treat **a 38-byte frame** as a stick report and read LE16 values at frame offsets 13, 16, 19, 22, 25:

```
frame[11]           payload[0]   status (0 = ok, dissector convention)
frame[12 + 3k]      payload[1+3k] one byte per channel, meaning unknown ("tag" in the probe)
frame[13 + 3k ..]   payload[2+3k] LE16 channel value
```

| k | frame offset | RC-N1 meaning (tools) |
|---|---|---|
| 0 | 13 | right stick horizontal (roll) |
| 1 | 16 | right stick vertical (pitch) |
| 2 | 19 | left stick vertical (throttle) |
| 3 | 22 | left stick horizontal (yaw) |
| 4 | 25 | camera/gimbal dial |
| 5-7 | 28, 31, 34 | not used by any tool |

Range: **364 min, 1024 centre, 1684 max** (±660). The tools' parsers don't confirm the 3-byte stride or the 8-channel count. Those come from 38 = 11 + 1 + 8×3 + 2 and are a HYPOTHESIS.

## 06/05 "RC Parameter Push" (o-gs dissector, older remotes)

13-14 byte payload: LE16 aileron, elevator, throttle, rudder, gimbal; then `wheelInfo` (bit0 click, bits1-5 offset, bit6 negative, bit7 changed), `buttonsA` (bit3 RTH, bits4-5 mode switch, bits6-7 foot stool), `buttonsB` (bit3 C2, bit4 C1, bit5 playback, bit6 shutter, bit7 record), optional band width. This is the most button-rich layout on record, and the RC-N3 may push something like it to an iOS app.

## 00/01 Version Inquiry (o-gs dissector)

Empty request. Response payload: 2 unknown bytes, 16-byte ASCII hardware version, LE32 loader version, LE32 firmware version (`AA.BB.CC.DD` from the high byte down), LE32 flags. The probe uses it as a universal "is anyone listening" ping.

## The iPhone link (samuelsadok, sniffed DJI device ↔ iPhone)

- The DJI device starts as USB host, spots the Apple VID:PID, sends vendor request `0x51` and the two **swap roles**. After that the iPhone is host.
- Interfaces: `iAP Interface` (MFi auth) plus a vendor interface whose **name is the EA protocol string**:
  - Mavic Pro RC (2016): `com.dji.common`
  - Goggles N3 (2024): `com.dji.logiclink`
- Envelope `55 CC <port LE16> <len LE16> 00 00 <payload>`:
  - port 22345 (`49 57`): DUML phone→device (Goggles N3), DUML device→phone (Mavic Pro RC)
  - port 30000 (`30 75`): DUML device→phone (Goggles N3)
  - port 22346 (`4a 57`): H.264 video device→phone
- The Goggles N3 needs **both directions wrapped**. The Mavic Pro RC takes **raw DUML** from the phone.
- Goggles N3 frames from the iPhone use sender `0x02` (App).
- The doc mislabels the CRC. In both captured Goggles packets the real DUML CRC16 is the last 2 bytes *inside* the envelope length (`d0 93`, `58 a6`), and 2 more bytes follow (`92 3a`, `34 18`). Those aren't any CRC16-CCITT variant over the envelope (brute-forced all seeds). Meaning unknown. The probe sends envelopes exactly as long as their length field.

## Verification (desk, 2026-10-12)

`RCKit/Tests/RCKitTests/DUMLTests.swift` checks the Swift port against:
- the RC-N1 request `55 0d 04 33 … 74 24` (CRC8 and CRC16, and byte-exact re-encoding);
- both Goggles N3 captures (CRC8, CRC16 and envelope header);
- spot entries of both literal tables in the RC-N1 tools.

## Not used

- DJI Mobile SDK. Forum reports say MSDK v5 is Android-only and doesn't support iOS. Not pursued; see findings.
