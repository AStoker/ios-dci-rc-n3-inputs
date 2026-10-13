# Hardware test 2: poll rate and control confirmation (~10 minutes)

Install the new build (⌘R). Plug in the remote and power it on; the `com.dji.logiclink` session opens by itself. The DUML tab now defaults to **55 CC envelope + App**, the combination that got replies in test 1.

**Use the markers this time:** before each step, set the Log tab's stepper to the step number and tap **Mark step N**. Short of that, a quick note in the field works too.

## Poll rate (DUML tab › Stick polling)

1. Tap **Version ping**. The line under it should turn green with "reply status 00 · ~13 ms".
2. Mode **Fixed rate**, **50 Hz**, toggle **Poll sticks** on. Hands off for 10 s. Note **Replies /s** and **Latency avg / p95**.
3. Change the rate to **100 Hz**. 10 s. Note both again.
4. Change it to **200 Hz**. 10 s. Note both.
5. Mode **As fast as replies**. 10 s. Note the rate, latency and timeouts.

## Controls (keep polling on in whichever mode gave the most replies/s)

6. Left stick: two slow full circles. In **Decoded**, do the 06/01 sticks (top pair) move more smoothly than the 06/05 ones?
7. Right stick: two slow full circles.
8. Gimbal dial: fully one way, hold 2 s; then the other way.
9. Flight mode switch to **C**, hold 3 s. Note the "Flight mode switch" value.
10. Switch to **N**, 3 s, then note the value.
11. Switch to **S**, 3 s, then note the value.
12. **Pause/RTH**: press and hold about 1 s, release. Twice. (Under 2 s, so it doesn't start the RTH alert.)
13. **Customizable**: press and hold about 1 s, twice.
14. **Shutter/Record**: a short press, then a 3 s hold.
15. **Photo/Video**: press and hold about 1 s, twice.
16. Turn **Poll sticks** off and wait 10 s with hands off.

## Also tell me

- Did the remote beep or power itself off at any point while the probe was open?
- Then **Log › Copy report** and paste it, and **Share log file** (AirDrop) as before.
