# Hardware test script: Milestone 1 probe

Goal: find out what iOS exposes when the RC-N3 is plugged in, and capture enough raw data to map every control.

## Before you start

- Charge the RC-N3. Leave the aircraft **off** (or tell me if it's on).
- Cable: the end **with the remote controller logo** stays in the remote; the other end goes into the iPhone (RC-N3 manual §1).
- Note: iOS version, whether **DJI Fly** is installed right now, and the RC-N3 firmware version if you know it.
- In the probe's **Log** tab, the big **Mark step N** button writes a marker into the log. Before every numbered step below, set the stepper to that step number and tap it. That lets me line up your actions with the bytes. The optional note field is for anything surprising.
- iOS may ask **"Allow accessory to connect?"**. Tap **Allow**, and tell me it asked.

## A. Baseline (DJI Fly as it is now; force-quit it in the app switcher first)

1. Nothing plugged in. Open the probe. **Mark 1**. Wait 5 s.
2. Plug in the remote **powered off**. **Mark 2**. Wait 10 s. Note any iOS pop-up (e.g. "Accessory not supported", "Open DJI Fly?", App Store suggestion) and screenshot it.
3. Power the remote **on** (press, then press and hold). **Mark 3**. Wait 15 s. On **Overview**, note:
   - EA accessories count, the accessory's name, model, firmware, **protocol strings**;
   - each session's state (open / FAILED);
   - GameController devices count;
   - whether the remote **beeps** (its idle alert). The manual says it alerts when it's not connected to an aircraft or DJI Fly, so it stopping would be a clue.
4. Don't touch anything for 30 s. **Mark 4**. On **Streams**, note bytes/s and DUML/s per session.
5. **DUML** tab › **Run sweep**. **Mark 5** first. Wait until it finishes. Screenshot the sweep results.
6. If any sweep row shows **replies** (green), set Framing and Send-as to that row's values. Then tap **Enable simulator mode** and switch **Poll sticks** on. If nothing replied, switch Poll sticks on anyway with the defaults. The remote may push data on its own.
7. **Log › Copy report** and paste it to me now, before the long control tests. If something important already shows, I may adjust the plan.

## B. Every control (Poll sticks on; one at a time; back to neutral between; Mark before each)

8. **Left stick**: full up, hold 2 s, release; full down, release; full left, release; full right, release.
9. **Left stick**: two slow full circles.
10. **Right stick**: same as step 8.
11. **Right stick**: two slow full circles.
12. **Gimbal dial**: roll fully one way, hold 2 s, release; then the other way.
13. **Flight Mode Switch**: C → N → S → N → C, pausing 2 s at each.
14. **Flight Pause/RTH button**: 3 short presses; then press and hold 3 s.
15. **Customizable button**: 3 short presses; then hold 2 s.
16. **Shutter/Record button**: 3 short presses; then hold 2 s.
17. **Photo/Video button**: 3 short presses.
18. **Power button**: one short press (shows the battery LEDs; don't hold it).
19. Sticks centred, hands off, 20 s (noise floor).
20. While doing 8-18 you can watch **Streams › (busiest DUML frame type) › Changed bytes** if you like, but it's not required. The log captures it. Afterwards: **Copy report** and paste it, and **Share log file** › AirDrop to your Mac › attach it here.

## C. Connect / disconnect behaviour

21. App open, remote on: power the remote **off**. **Mark 21**. Wait 10 s. Power it **on**. **Mark**. Wait 15 s.
22. Unplug the cable (remote stays on). **Mark 22**. Wait 5 s. Plug it back in. **Mark**. Wait 15 s.
23. Leave the app (swipe up to Home) for 10 s, then come back. **Mark 23**.
24. **Copy report** and paste.

## D. DJI Fly interplay (run in the state you didn't start with)

If DJI Fly is installed:

25. Unplug the remote. Open **DJI Fly**, plug in and power on the remote, let DJI Fly see it. Then switch to the probe **without** closing DJI Fly. **Mark 25**. Do sessions open, or show "EASession init returned nil"?
26. Force-quit DJI Fly. In the probe's Overview tap **Open** on each failed protocol. **Mark 26**. Do they open now?
27. Offload DJI Fly (Settings › General › iPhone Storage › DJI Fly › **Offload App**; keeps its data). Unplug and replug the remote. **Mark 27**. Note any pop-ups, then repeat steps 3 and 8 (left stick only).
28. **Copy report** and paste. Reinstall DJI Fly afterwards by tapping its icon, if you want it back.

If DJI Fly is **not** installed: run A and B as above, then install DJI Fly and do steps 25-26.

## E. Optional, if time allows

29. Power the aircraft on (if you have it linked) and repeat steps 3-4. Does more data appear, e.g. video on a `com.dji.video` session or 55 CC port 22346?
30. Connect the iPhone to the remote's **charging USB-C port** (bottom, manual item 11) with an ordinary USB-C cable instead of the phone cable. **Mark 30**. Note Overview and Network interfaces (anything NEW?).

## What to send back

- The pasted reports (steps 7, 20, 24, 28), the log file from step 20, screenshots of any iOS pop-ups.
- Anything the remote did: beeps, LED changes, auto power-off.
