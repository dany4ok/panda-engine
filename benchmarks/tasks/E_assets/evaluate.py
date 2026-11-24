#!/usr/bin/env python3
"""Independent deterministic evaluator for task E (asset integrity + UI wiring)."""
import argparse
import hashlib
import json
import pathlib
import subprocess
import sys

TASK = pathlib.Path(__file__).resolve().parent


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--work", required=True)
    ap.add_argument("--seed", required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    work, seed = pathlib.Path(a.work), pathlib.Path(a.seed)
    checks = []

    # atlas integrity + identical to the shared test asset
    atlas = work / "assets" / "atlas.png"
    checker = work / "check_atlas.py"
    if checker.exists() and atlas.exists():
        try:
            p = subprocess.run([sys.executable, str(checker), str(atlas)], cwd=work,
                               capture_output=True, text=True, timeout=30)
            data = json.loads(p.stdout)
            for k, v in data.get("checks", {}).items():
                checks.append({"name": "atlas_" + k, "passed": bool(v)})
        except Exception as ex:
            checks.append({"name": "atlas_check_ran", "passed": False, "error": str(ex)})
    else:
        checks.append({"name": "atlas_present", "passed": False})

    def sha(p):
        return hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest()
    same = atlas.exists() and sha(atlas) == sha(seed / "assets" / "atlas.png")
    checks.append({"name": "atlas_unmodified_shared_asset", "passed": same})

    js = (work / "hud.js").read_text(encoding="utf-8", errors="ignore") if (work / "hud.js").exists() else ""
    static = {
        "uses_all_four_frames": all(str(i) in js for i in range(4)),
        "state_machine_idle": "'idle'" in js or '"idle"' in js,
        "state_machine_run": "'run'" in js or '"run"' in js,
        "state_machine_hurt": "'hurt'" in js or '"hurt"' in js,
        "raf_loop": "requestAnimationFrame" in js,
        "hud_hp": "getElementById('hp')" in js or 'getElementById("hp")' in js,
        "hud_xp": "getElementById('xp')" in js or 'getElementById("xp")' in js,
        "hud_lv": "getElementById('lv')" in js or 'getElementById("lv")' in js,
        "draws_canvas": "drawImage" in js,
        "buttons_wired": "hurt" in js and "run" in js,
    }
    for k, v in static.items():
        checks.append({"name": "ui_" + k, "passed": bool(v)})

    # protected files must be unchanged
    for f in ("index.html", "styles.css"):
        w, s = work / f, seed / f
        checks.append({"name": "unchanged_" + f, "passed": w.exists() and sha(w) == sha(s)})

    passed = sum(1 for c in checks if c["passed"])
    result = {
        "task": "E", "checks": checks, "passed": passed, "total": len(checks),
        "score": round(passed / len(checks), 4) if checks else 0,
        "bugs_remaining": sum(1 for c in checks if c["name"].startswith("atlas_") and not c["passed"]),
        "bugs_new": sum(1 for c in checks if (c["name"].startswith("ui_") or c["name"].startswith("unchanged_")) and not c["passed"]),
        "changed_files": [], "new_files": [],
        "notes": "Shared identical atlas for both models; no visual generation tool available. "
                 "Static wiring checks do NOT replace screenshot verification, done separately.",
    }
    pathlib.Path(a.out).write_text(json.dumps(result, indent=2, ensure_ascii=False), encoding="utf-8")
    print(f"E: {passed}/{len(checks)}")


if __name__ == "__main__":
    main()
