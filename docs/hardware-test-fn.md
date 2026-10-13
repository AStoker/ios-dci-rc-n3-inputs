# Hardware test: the Fn button (~2 minutes)

**Done 2026-10-13** (logs L3, L4): tap = bit 0x10 pulse, double tap = bit 0x08 pulse, long press and combos not reported. See `findings.md`.

Install the new build (⌘R). Remote plugged in and on, **Input** tab, engine **Input API**. Tap **Reset press counts**.

1. **Tap Fn** quickly 10 times, about a second apart. Watch the **Fn** count under Controls (the chip itself only flashes for ~0.13 s).
2. **Hold Fn** for 2 s, three times. Does the count go up?
3. **Double-tap Fn** twice.
4. For comparison, tap Photo/Video 5 times.

Tell me the counts, then **Log › Copy report** and **Share log file**. Every button change is now logged as a `BUTTONS A … B …` line, never rate-limited.
