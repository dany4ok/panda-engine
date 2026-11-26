#!/usr/bin/env python3
"""Aggregate the A-F quantization benchmark into a comparison table."""
import json, pathlib, statistics, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SLUGS = {
    "iq1m":  ("Inkling IQ1_M", 8.18),
    "q2kxl": ("Inkling Q2_K_XL", 9.39),
    "q3kxl": ("Inkling Q3_K_XL", 13.49),
    "iq4xs": ("Inkling IQ4_XS", 15.46),
    "apex":  ("Inkling APEX-I MiniPlus V2.1", 12.89),
}
TASKS = ["A", "B", "C", "D", "E", "F"]

loads = {}
lp = ROOT / "swaps_inkling.jsonl"
if lp.exists():
    for line in lp.read_text(encoding="utf-8").splitlines():
        try:
            r = json.loads(line)
            loads[r["artifact"]] = r
        except Exception:
            pass

rows = []
for slug, (label, gib) in SLUGS.items():
    base = ROOT / "results" / ("qb_" + slug) / "ninfer_inkling-2-mini"
    scores, walls, outs, tools, vrams, bugs = [], [], [], [], [], []
    timeouts = 0
    missing = []
    for t in TASKS:
        d = base / t
        mp, ep = d / "metrics.json", d / "eval.json"
        if not mp.exists():
            missing.append(t)
            continue
        m = json.loads(mp.read_text(encoding="utf-8"))
        walls.append(m.get("wall_ms", 0) / 1000.0)
        outs.append((m.get("tokens") or {}).get("output", 0))
        tools.append(m.get("tool_calls", 0))
        if m.get("vram_max_mib"):
            vrams.append(m["vram_max_mib"])
        if m.get("timed_out"):
            timeouts += 1
        if ep.exists():
            e = json.loads(ep.read_text(encoding="utf-8"))
            scores.append(e.get("score", 0))
            bugs.append(e.get("bugs_remaining", 0) + e.get("bugs_new", 0))
        else:
            scores.append(0)
            bugs.append(0)
    if not walls:
        continue
    load = loads.get(next((a for a in loads if slug in a.lower().replace("_", "-")), ""), {})
    rows.append({
        "slug": slug, "label": label, "file_GiB": gib,
        "tasks": len(walls), "missing": missing,
        "pass": sum(1 for s in scores if s >= 1.0),
        "avg_score": round(statistics.mean(scores), 3),
        "total_s": round(sum(walls), 1),
        "tok_s": round(sum(outs) / max(sum(walls), 1), 1),
        "tools": sum(tools), "bugs": sum(bugs),
        "vram_max": int(max(vrams)) if vrams else None,
        "load_s": round(load.get("load_ms", 0) / 1000.0, 1) if load else None,
        "timeouts": timeouts,
    })

rows.sort(key=lambda r: (-r["avg_score"], r["total_s"]))
print("| Model | File GiB | Tasks pass | Avg score | Total time s | Out tok/s | Tool calls | Bugs | VRAM max MiB | Load s |")
print("|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
for r in rows:
    print("| {label} | {file_GiB} | {pass}/{tasks} | {avg_score} | {total_s} | {tok_s} | {tools} | {bugs} | {vram_max} | {load_s} |".format(**r))
(ROOT / "quant-comparison.json").write_text(json.dumps(rows, indent=2), encoding="utf-8")
print("\nSaved:", ROOT / "quant-comparison.json")
