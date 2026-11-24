#!/usr/bin/env python3
"""Independent deterministic evaluator for task D (game mechanics + wiring)."""
import argparse
import json
import pathlib
import shutil
import subprocess
import sys

TASK = pathlib.Path(__file__).resolve().parent


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--work", required=True)
    ap.add_argument("--seed", required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    work = pathlib.Path(a.work)
    checks = []

    # hidden mechanics tests
    shutil.copy(TASK / "hidden_test.mjs", work / "__hidden_test.mjs")
    try:
        p = subprocess.run(["node", "__hidden_test.mjs"], cwd=work, capture_output=True, text=True, timeout=90)
        data = {}
        rp = work / "__hidden_results.json"
        if rp.exists():
            data = json.loads(rp.read_text(encoding="utf-8"))
        for r in data.get("results", []):
            checks.append({"name": "mech_" + r["name"], "passed": bool(r["passed"]),
                           **({"error": r["error"]} if r.get("error") else {})})
        if not data:
            checks.append({"name": "hidden_test_ran", "passed": False,
                           "error": (p.stderr or p.stdout).strip()[:500]})
    except Exception as ex:
        checks.append({"name": "hidden_test_ran", "passed": False, "error": str(ex)})
    finally:
        for f in ("__hidden_test.mjs", "__hidden_results.json"):
            try:
                (work / f).unlink()
            except Exception:
                pass

    # visual wiring checks (static; screenshot done separately by orchestrator)
    html = (work / "index.html").read_text(encoding="utf-8", errors="ignore") if (work / "index.html").exists() else ""
    scene = (work / "game" / "scene.js").read_text(encoding="utf-8", errors="ignore") if (work / "game" / "scene.js").exists() else ""
    static = {
        "html_loads_scene": "./game/scene.js" in html,
        "html_has_hud": all(f'id="{k}"' in html for k in ("hp", "xp", "lv")),
        "scene_imports_three": "THREE" in scene,
        "scene_uses_game": "new Game" in scene,
        "scene_loop": "requestAnimationFrame" in scene,
        "scene_renders": "renderer.render" in scene,
        "scene_updates_hud": "getElementById('hp')" in scene or 'getElementById("hp")' in scene,
        "vendor_intact": (work / "vendor" / "three.module.min.js").exists(),
    }
    for k, v in static.items():
        checks.append({"name": "visual_" + k, "passed": bool(v)})

    passed = sum(1 for c in checks if c["passed"])
    result = {
        "task": "D", "checks": checks, "passed": passed, "total": len(checks),
        "score": round(passed / len(checks), 4) if checks else 0,
        "bugs_remaining": sum(1 for c in checks if c["name"].startswith("mech_") and not c["passed"]),
        "bugs_new": sum(1 for c in checks if c["name"].startswith("visual_") and not c["passed"]),
        "changed_files": [], "new_files": [],
        "notes": "12 hidden mechanics checks + 8 static rendering-wiring checks. "
                 "Screenshot verification is performed separately and NOT implied by static checks.",
    }
    pathlib.Path(a.out).write_text(json.dumps(result, indent=2, ensure_ascii=False), encoding="utf-8")
    print(f"D: {passed}/{len(checks)}")


if __name__ == "__main__":
    main()
