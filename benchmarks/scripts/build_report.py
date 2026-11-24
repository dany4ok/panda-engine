#!/usr/bin/env python3
"""Build the comparative A/B report from metrics.json + eval.json.

No values are estimated: missing metrics stay 'n/a'. The main speed metric is
time-to-correct-and-verified, so an unfinished/failed task is NOT counted as fast.
"""
import argparse
import json
import pathlib
from statistics import mean


def load(p):
    try:
        return json.loads(pathlib.Path(p).read_text(encoding="utf-8-sig"))
    except Exception:
        return None


def fam(slug):
    s = slug.lower()
    if "gyro" in s:
        return "Gyro-S"
    if "minicpm" in s or "mini" in s:
        return "MiniCPM"
    return "unknown:" + slug


def fmt(v, suffix=""):
    if v is None:
        return "n/a"
    if isinstance(v, float):
        return f"{v:.1f}{suffix}"
    return f"{v}{suffix}"


def pct(a, b):
    """(b - a)/a * 100, None if a is 0/None."""
    if a in (None, 0) or b is None:
        return None
    return (b - a) / a * 100.0


def collect(root, batch):
    base = pathlib.Path(root) / "results" / batch
    rows = []
    for task_dir in sorted(base.glob("*/[A-F]")):
        m = load(task_dir / "metrics.json")
        e = load(task_dir / "eval.json")
        if not m:
            continue
        rows.append({
            "family": fam(task_dir.parent.name),
            "slug": task_dir.parent.name,
            "task": task_dir.name,
            "m": m,
            "e": e or {},
        })
    return rows


def aggregate(rows, family):
    rs = [r for r in rows if r["family"] == family]
    ev = [r["e"] for r in rs if r["e"]]
    completed = [r for r in rs if r["e"] and r["e"].get("score") == 1]
    ok_wall = [r["m"].get("wall_ms") for r in completed if r["m"].get("wall_ms") is not None]
    all_wall = [r["m"].get("wall_ms") for r in rs if r["m"].get("wall_ms") is not None]
    tok_out = [r["m"].get("tokens", {}).get("output") for r in rs]
    tok_out = [t for t in tok_out if isinstance(t, (int, float))]
    tok_in = [r["m"].get("tokens", {}).get("input") for r in rs]
    tok_in = [t for t in tok_in if isinstance(t, (int, float))]
    tools = [r["m"].get("tool_calls") for r in rs if r["m"].get("tool_calls") is not None]
    repairs = [r["m"].get("repair_attempts_heuristic") for r in rs if r["m"].get("repair_attempts_heuristic") is not None]
    vram = [r["m"].get("vram_max_mib") for r in rs if r["m"].get("vram_max_mib") is not None]
    fails = [r for r in rs if r["e"] and r["e"].get("score") != 1]
    timeouts = [r for r in rs if r["m"].get("timed_out")]
    bad_exit = [r for r in rs if r["m"].get("exit_code") not in (None, 0)]

    # tokens/s for successful tasks only (output tokens / wall seconds)
    tps = []
    for r in completed:
        out = r["m"].get("tokens", {}).get("output")
        wall = r["m"].get("wall_ms")
        if isinstance(out, (int, float)) and wall:
            tps.append(out / (wall / 1000.0))

    return {
        "probes": len(rs),
        "completed_correct": f"{len(completed)}/{len(rs)}",
        "tests_passed": sum(int(e.get("passed", 0)) for e in ev),
        "tests_total": sum(int(e.get("total", 0)) for e in ev),
        "bugs_remaining": sum(int(e.get("bugs_remaining", 0)) for e in ev),
        "bugs_new": sum(int(e.get("bugs_new", 0)) for e in ev),
        "duration_total_s": round(sum(all_wall) / 1000.0, 1) if all_wall else None,
        "duration_to_correct_s": round(sum(ok_wall) / 1000.0, 1) if ok_wall else None,
        "tokens_per_s": round(mean(tps), 2) if tps else None,
        "input_tokens": int(sum(tok_in)) if tok_in else None,
        "output_tokens": int(sum(tok_out)) if tok_out else None,
        "cache_read_tokens": int(sum(r["m"].get("tokens", {}).get("cache_read") or 0 for r in rs)) if rs else None,
        "tool_calls": int(sum(tools)) if tools else None,
        "repairs": int(sum(repairs)) if repairs else None,
        "errors_loops": len(fails) + len(timeouts) + len(bad_exit),
        "vram_max_mib": round(mean(vram), 1) if vram else None,
        "failed_tasks": ", ".join(r["task"] for r in fails) or "-",
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=r"C:\Users\x1p\AppData\Local\Temp\opencode\gyro-mini-bench")
    ap.add_argument("--batch", default="batch1")
    args = ap.parse_args()

    rows = collect(args.root, args.batch)
    g = aggregate(rows, "Gyro-S")
    n = aggregate(rows, "MiniCPM")

    keys = [
        ("Sarcini finalizate corect", "completed_correct", None),
        ("Teste trecute", "tests_passed", "tests_total"),
        ("Buguri ramase", "bugs_remaining", None),
        ("Buguri introduse (noi)", "bugs_new", None),
        ("Durata totala (s)", "duration_total_s", None),
        ("Durata pana la rezultat corect (s)", "duration_to_correct_s", None),
        ("Viteza tokeni/s (pe sarcini reusite)", "tokens_per_s", None),
        ("Input tokens", "input_tokens", None),
        ("Output tokens", "output_tokens", None),
        ("Cache-read tokens", "cache_read_tokens", None),
        ("Apeluri instrumente", "tool_calls", None),
        ("Reparatii necesare", "repairs", None),
        ("Sarcini eșuate / timeout / exit≠0", "errors_loops", None),
        ("Consum VRAM mediu max (MiB)", "vram_max_mib", None),
    ]

    out = []
    out.append("=" * 78)
    out.append(f"BENCHMARK A/B — Gyro-S vs MiniCPM-V ca agent principal (batch: {args.batch})")
    out.append("=" * 78)
    out.append(f"Probe gasite: Gyro-S={g['probes']}, MiniCPM={n['probes']}")
    out.append("Delta % = (MiniCPM - Gyro-S) / Gyro-S * 100. Valorile lipsa raman n/a.")
    out.append("Durata pana la corect include DOAR sarcinile verifyate; sarcinile esuate")
    out.append("NU sunt considerate mai rapide pentru ca modelul s-a oprit devreme.")
    out.append("")
    out.append("| Metrică | Gyro-S | MiniCPM | Δ% |")
    out.append("|---|---|---|---|")
    for label, key, extra in keys:
        gv = g.get(key)
        nv = n.get(key)
        if extra:
            gs, ns = g.get(extra), n.get(extra)
            gcell = f"{fmt(gv)}/{fmt(gs)}"
            ncell = f"{fmt(nv)}/{fmt(ns)}"
        else:
            gcell, ncell = fmt(gv), fmt(nv)
        numeric = isinstance(gv, (int, float)) and isinstance(nv, (int, float))
        d = pct(gv, nv) if numeric else None
        dcell = fmt(round(d, 1), "%") if d is not None else "n/a"
        out.append(f"| {label} | {gcell} | {ncell} | {dcell} |")

    out.append("")
    out.append(f"Sarcini esuate Gyro-S: {g['failed_tasks']}")
    out.append(f"Sarcini esuate MiniCPM: {n['failed_tasks']}")
    out.append("")
    out.append("Verdict (de completat dupa verificarea independenta):")
    for q in [
        "Care e mai bun pentru programare zilnica?",
        "Care e mai bun pentru jocuri?",
        "Care e mai bun la debugging?",
        "Care e mai rapid pana la rezultat corect?",
        "Care lucreaza mai autonom?",
        "Care e mai fiabil pe sesiuni lungi?",
        "Merita diferenta de timp pentru modelul mai bun calitativ?",
    ]:
        out.append(f"  - {q} [DE COMPLETAT]")
    out.append("")
    out.append("NOTA: acest tabel e generat automat; claim-urile modelelor nu sunt")
    out.append("acceptate ca dovada. Verdictul final se scrie doar dupa ce evaluatorul")
    out.append("determinist si review-ul independent confirma rezultatele.")

    text = "\n".join(out) + "\n"
    dest = pathlib.Path(args.root) / f"REPORT_{args.batch}.txt"
    dest.write_text(text, encoding="utf-8")
    print(text)
    print(f"\nSaved: {dest}")


if __name__ == "__main__":
    main()
