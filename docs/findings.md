# Findings

Tags: **CONFIRMED** = seen on Andy's hardware (iPhone 16 Pro Max + RC-N3), with the log that shows it. **HYPOTHESIS** = from docs, other devices or reasoning; not yet seen on hardware.

Logs (iPhone17,2, iOS 27.2 build 24B5099f, aircraft off):
- **L1** = `rcn3-probe-2026-10-12_19-21-58.txt`: test 1, no step markers (actions matched by time).
- **L2** = `rcn3-probe-2026-10-12_19-46-31.txt`: test 2, `docs/hardware-test-2.md` with step markers 1-17.

## Summary

The RC-N3 is an External Accessory (`com.dji.logiclink`) speaking DUML inside `55 CC` envelopes. Two streams give us everything readable:
- **06/01 poll** (we ask, ~10 ms round trip): both sticks and the gimbal dial. 100 Hz sustained, and the remote refreshes the values at ~50-60 Hz.
- **06/05 push** (unprompted, ~7-9 Hz): sticks, gimbal, flight mode switch, Pause/RTH, Shutter/Record, Photo/Video.

The Fn (Customizable) button probably reports only short taps, as a ~0.13 s pulse of 06/05 byte 12 bit 0x10 (HYPOTHESIS; see below).

## Transport

| # | Claim | Status | Evidence |
|---|---|---|---|
| T1 | The RC-N3 shows up to iOS as an External Accessory | **CONFIRMED** | L1, L2: name `C5`, manufacturer `DJI`, model `RC151`, fw `v00.04.00.22`, hw `v02.00.00.06`, serial `123456789abcdef` (placeholder) |
| T2 | It advertises exactly one protocol: **`com.dji.logiclink`** | **CONFIRMED** | L1, L2 |
| T3 | `EASession` opens instantly with no MFi/app-store gate for a dev build | **CONFIRMED** | L1, L2: both streams open ~15-25 ms after connect |
| T4 | The RC-N3 isn't a `GCController` (nor keyboard or mouse) | **CONFIRMED** | L1, L2 |
| T5 | Device→phone: one `55 CC` envelope per USB transfer, port **22345**, zero-padded to 512 bytes | **CONFIRMED** | L2 report: 15.9 MB padding, 0 B unparsed |
| T6 | Phone→device must be a **`55 CC` envelope (port 22345) with sender App (0x02)**. Raw DUML or sender PC gets no replies | **CONFIRMED** | L1 sweep; L2: 23,372 replies |
| T7 | DJI Mobile SDK isn't a viable iOS path | HYPOTHESIS (moot) | Dronelink forum |
| T8 | DJI Fly installed or running: effect on the session | not yet tested | |
| T9 | Our app silences the remote's idle alert | not yet reported | |

## Protocol

| # | Claim | Status | Evidence |
|---|---|---|---|
| P1 | DUML v1 framing, CRC8 seed 0x77, CRC16 seed 0x3692 | **CONFIRMED** | L1 + L2: ~42,700 frames, all CRC-valid; unit test `rcN3PushFrameFromHardware` |
| P2 | Replies echo the request's sequence number | **CONFIRMED** | L1, L2 (latency matching relies on it) |
| P3 | 00/01 Version reply from RC: hw `rc151`, fw `00.01.03.39` | **CONFIRMED** | L1, L2 |
| P4 | 06/24 01 (simulator mode) is accepted (status 00) but changes nothing observable | **CONFIRMED** | L1 |
| P5 | 06/05 is push only (no reply to a request) | **CONFIRMED** | L1 |
| P6 | 06/01 reply comes from **HDLINK-GND (0x0e)**: 38 bytes, status + 8 × (tag, LE16); tags always 00 | **CONFIRMED** | L1, L2 |

## 06/01 polling performance (L2)

| Poll setting | Replies/s | Lost | Latency median / p95 / max | 06/05 push rate meanwhile |
|---|---|---|---|---|
| off | n/a | n/a | n/a | 9.1/s |
| 50 Hz fixed | 49.7 | 0.4-0.8% | 16 / 19 / 26 ms | 8.6/s |
| 100 Hz fixed | 99.2-100 | 0-0.8% | 12 / 18 / 27 ms | 6.9/s |
| 200 Hz fixed | 193-197 | 1.5-3% | 12 / 18 / 29 ms | 3.6/s |
| reply-driven | 68-97 (≈ 1 / latency) | 0-1.5% | 10 / 11-14 / 22 ms | ~7/s |

**CONFIRMED:**
- Fast polling **starves the 06/05 push**: it shares the remote's outbound link.
- The remote **refreshes stick values at ~50-60 Hz**. While moving, the gaps between new 06/01 values were 10 ms ×231, 20 ms ×338 and 30 ms ×29 (median 20 ms) while polling every ~11 ms (L2 steps 6-7).
- Conclusion: **100 Hz** catches every new value and keeps the push at ~7/s; 200 Hz gains nothing.

## Inputs

| Control | Source & location | Range / values | Status | Evidence |
|---|---|---|---|---|
| Right stick X | 06/05 bytes 0-1; 06/01 ch0 | 364 left … 1024 … 1684 right | **CONFIRMED** | L1, L2 steps 6-7 |
| Right stick Y | 06/05 bytes 2-3; 06/01 ch1 | 364 down … 1684 up | **CONFIRMED** | L1, L2 |
| Left stick Y | 06/05 bytes 4-5; 06/01 ch2 | 364 down … 1684 up | **CONFIRMED** | L1, L2 |
| Left stick X | 06/05 bytes 6-7; 06/01 ch3 | 364 left … 1684 right | **CONFIRMED** | L1, L2 |
| Gimbal dial | 06/05 bytes 8-9; 06/01 ch4 | 364 … 1684, spring return to 1024 | **CONFIRMED** | L1, L2 step 8 |
| Flight mode switch | 06/05 byte 11 bits 4-5 | **C = 2, N = 1, S = 0** | **CONFIRMED** | L2 steps 9-11 (switched 0.2-6 s after each marker) |
| Pause/RTH button | 06/05 byte 11 bit 3 (0x08) | held = 1 | **CONFIRMED** | L1; L2 step 12 |
| (RTH long press) | 00/f1 RC→APP payload `10 00 00 00` | appears during ~2 s holds | **CONFIRMED** association | L1; L2 269.0-274.6 s |
| Shutter/Record button | 06/05 byte 12 bit 6 (0x40) | short and long press look the same | **CONFIRMED** | L1; L2 step 14 |
| Photo/Video button | 06/05 byte 12 bit 0 (0x01) | held = 1 | **CONFIRMED** | L1; L2 step 15 |
| Fn / Customizable button | 06/05 byte 12 bit 4 (0x10), the dissector's "custom1" | a one-message pulse (~0.13 s) on a short tap; nothing on a 1 s hold | HYPOTHESIS | L1 299.43 s: one push with B = 0x10. L2 step 13: two ~1 s holds, nothing in any frame (only the last few DUML lines per second were dropped, too few to hide a hold). Earlier "not reported" was too strong. |
| Power button | not reported | | **CONFIRMED** | L1 |
| 06/01 ch5-7 | constant 1024 | | **CONFIRMED** | L2 |

Polarity was confirmed by the L1 script order (up, down, left, right) and matches 06/01 exactly in L2.

## Other frames seen (all inside port-22345 envelopes)

| Frame | Rate | Payload | Guess |
|---|---|---|---|
| 51/29 HDLINK-GND→HDLINK-GND#7 | 9-10/s | mostly fixed; every ~1 s a longer one containing an ASCII serial number | link keep-alive / device info |
| 00/0e HDLINK-GND→APP | 3/s | empty | heartbeat |
| 06/84, 09/43, 09/08, 09/75, 09/36, 19/67 HDLINK-GND→APP | 0.5-2/s | static | link status |
| 09/30 HDLINK-GND→APP | rare | ASCII like `SFN=330110` | link info |
| 06/1e RC→APP | ~1/s | e.g. `88 08 00 00 54 00` | remote battery: LE32 ≈ mAh remaining (2184 of 2600), then % (84) (HYPOTHESIS, consistent across L1/L2) |
| 00/f1 RC→APP | ~1/s | `00 00 00 00`; `10 00 00 00` during RTH holds | alert/beep state (HYPOTHESIS) |

## RC-N3 controls (from the DJI RC-N3 User Manual, 2024, §3-4)

The manual's parts list, with inputs that might be readable in **bold**: 1 **Power Button**, 2 **Flight Mode Switch** (C Cine / N Normal / S Sport), 3 **Flight Pause/Return to Home (RTH) Button** (press = brake, hold = RTH), 4 Battery Level LEDs, 5 **Control Sticks** (Mode 2 default: left = throttle/yaw, right = pitch/roll), 6 **Customizable Button** (default: recenter gimbal / point down), 7 **Photo/Video Button**, 8 Remote Controller Cable, 9 Mobile Device Holder, 10 Antennas, 11 USB-C Port (charging; used with DJI Assistant 2 on a computer), 12 Control Stick Storage Slots, 13 **Gimbal Dial**, 14 **Shutter/Record Button**, 15 Mobile Device Slot.

Manual §6: the remote sounds an idle alert and powers itself off if it's "not connected to the aircraft or the DJI Fly app on the mobile device".

## Open questions

1. Fn button: confirm the short-tap pulse (`hardware-test-fn.md`). If it doesn't show, is it reported elsewhere: only once DJI Fly assigns it a function, only with the aircraft on, or via a request (06/4c, 06/50, 06/2e)?
2. DJI Fly installed or running: does it take the session? (T8)
3. Does the remote stay awake (no idle alert) while only our app is connected? (T9)
4. If the stick mode is changed in DJI Fly, does the remote re-map its channels (06/19 "RC Control Mode Set" exists)? `RCStickMode` assumes the physical default (Mode 2).
