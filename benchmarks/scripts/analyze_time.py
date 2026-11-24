#!/usr/bin/env python3
"""Find where wall time was spent inside an opencode run event stream."""
import json
import pathlib
import sys

p = pathlib.Path(sys.argv[1])
raw = p.read_bytes()
text = raw.decode("utf-16le") if raw[:2] == b"\xff\xfe" else raw.decode("utf-8")
ev = []
for line in text.splitlines():
    if line.strip():
        try:
            ev.append(json.loads(line))
        except Exception:
            pass

ts = lambda e: e.get("timestamp")
print(f"file={p.name} events={len(ev)}")
if not ev:
    raise SystemExit

t0, t1 = ts(ev[0]), ts(ev[-1])
print(f"span_s={(t1-t0)/1000:.1f}")

gaps = []
for a, b in zip(ev, ev[1:]):
    d = (ts(b) - ts(a)) / 1000.0
    if d >= 20:
        gaps.append((d, a.get("type"), b.get("type"),
                     (a.get("part") or {}).get("tool"),
                     (b.get("part") or {}).get("tool")))
gaps.sort(reverse=True)
print("top gaps >=20s (sec, from_type, to_type, from_tool, to_tool):")
for g in gaps[:12]:
    print("  %.1f  %-14s -> %-14s  %s -> %s" % g)

# per-tool elapsed: tool_use start until the next step_finish
tools = {}
active = None
for e in ev:
    typ = e.get("type")
    part = e.get("part") or {}
    if typ == "tool_use":
        active = (part.get("tool") or "?", ts(e))
    elif typ == "step_finish" and active:
        name, start = active
        rec = tools.setdefault(name, {"n": 0, "s": 0.0})
        rec["n"] += 1
        rec["s"] += (ts(e) - start) / 1000.0
        active = None
print("tool time (name: calls / total_s / avg_s):")
for k, v in sorted(tools.items(), key=lambda x: -x[1]["s"]):
    print("  %-12s %3d / %9.1f / %7.1f" % (k, v["n"], v["s"], v["s"] / v["n"]))

# reasoning/output tokens per step
reasons = []
for e in ev:
    if e.get("type") == "step_finish":
        tok = (e.get("part") or {}).get("tokens") or {}
        reasons.append((tok.get("reasoning", 0), tok.get("output", 0)))
print("steps=%d reasoning_sum=%d output_sum=%d max_reasoning_per_step=%d" %
      (len(reasons), sum(x[0] for x in reasons), sum(x[1] for x in reasons),
       max([x[0] for x in reasons] or [0])))
