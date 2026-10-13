# Converts a probe log's 06/01 replies and 06/05 pushes into an RCKit recording (JSON Lines),
# mirroring RCN3InputAssembler's rules (RCKit/Sources/RCKit/Input/RCN3InputAssembler.swift).
# The probe log rate-limits DUML lines, so the result is sparser than a live RCRecorder capture.
#
# usage: python3 tools/log2rec.py <probe-log.txt> <out.jsonl> <start-seconds> <end-seconds>
import json, re, sys
src, dst, t0, t1 = sys.argv[1], sys.argv[2], float(sys.argv[3]), float(sys.argv[4])
rx = re.compile(r"^\+\s*([\d.]+) DUML\s+\S+ ← (06/01 rsp|06/05 req) \S+ seq \w+ len \d+ \[55CC:\d+\] payload (.*)$")
def norm(v): return max(-1.0, min(1.0, (v - 1024) / 660))
out = [json.dumps({"format": "rckit-recording", "version": 1, "startedAt": "2026-10-12T23:46:31Z",
                   "note": "Converted from hardware test 2 log (stick circles, mode switch, buttons)"}, sort_keys=True, separators=(",", ":"))]
push = None; poll = None; poll_t = -1e9; idx = 0
def emit(ch, t, source):
    global idx
    a = push[11] if push else 0; b = push[12] if push else 0
    mode = {2: "C", 1: "N", 0: "S"}.get((a & 0x30) >> 4, "?") if push else "?"
    buttons = (1 if a & 0x08 else 0) | (2 if b & 0x40 else 0) | (4 if b & 0x01 else 0)
    raw = {"leftX": ch[3], "leftY": ch[2], "rightX": ch[0], "rightY": ch[1], "gimbal": ch[4], "flagsA": a, "flagsB": b}
    s = {"time": t, "index": idx, "leftStick": {"x": norm(ch[3]), "y": norm(ch[2])}, "rightStick": {"x": norm(ch[0]), "y": norm(ch[1])},
         "gimbalDial": norm(ch[4]), "flightMode": mode, "buttons": buttons, "raw": raw, "source": source}
    idx += 1; out.append(json.dumps(s, sort_keys=True, separators=(",", ":")))
for L in open(src, encoding="utf-8", errors="replace"):
    m = rx.match(L.rstrip("\n"))
    if not m: continue
    t = float(m.group(1))
    if not (t0 <= t < t1): continue
    p = bytes.fromhex(m.group(3).replace(" ", ""))
    if m.group(2) == "06/05 req":
        prev = push; push = p
        u = lambda i: p[i] | p[i+1] << 8
        if t - poll_t < 0.25 and poll:
            if prev is None or prev[11:13] != p[11:13]: emit(poll, t, "push")
        else: emit([u(0), u(2), u(4), u(6), u(8)], t, "push")
    else:
        if p[0] != 0: continue
        ch = [p[2 + 3*k] | p[3 + 3*k] << 8 for k in range(5)]
        poll_t = t
        if poll == ch and idx: continue
        poll = ch; emit(ch, t, "poll")
open(dst, "w").write("\n".join(out) + "\n")
print(f"{idx} samples, {t1 - t0:.0f} s window")
