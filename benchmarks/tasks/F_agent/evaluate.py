#!/usr/bin/env python3
"""Independent deterministic evaluator for task F (multi-step agent task)."""
import argparse
import hashlib
import json
import pathlib
import re
import shutil
import subprocess
import sys

TASK = pathlib.Path(__file__).resolve().parent


def sha(p):
    return hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--work", required=True)
    ap.add_argument("--seed", required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    work, seed = pathlib.Path(a.work), pathlib.Path(a.seed)
    checks = []
    bugs = {"remaining": 0, "new": 0}

    # 1) the project's own test suite must be green
    try:
        p = subprocess.run([sys.executable, "-m", "unittest", "discover", "-v"],
                           cwd=work, capture_output=True, text=True, timeout=120)
        blob = p.stdout + p.stderr
        m = re.search(r"Ran (\d+) tests?", blob)
        n = int(m.group(1)) if m else 0
        f = re.search(r"FAILED \(failures=(\d+)(?:, errors=(\d+))?", blob)
        failures = (int(f.group(1)) + int(f.group(2) or 0)) if f else (0 if p.returncode == 0 else 1)
        bugs["remaining"] = failures
        checks.append({"name": "suite_green", "passed": p.returncode == 0 and n >= 6,
                       "tests": n, "failures": failures, "tail": blob.strip()[-800:]})
    except Exception as ex:
        bugs["remaining"] += 1
        checks.append({"name": "suite_green", "passed": False, "error": str(ex)})

    # 2) tests must NOT have been modified
    test_files = sorted(f.relative_to(seed).as_posix() for f in (seed / "tests").glob("*.py"))
    changed_tests = [t for t in test_files if not (work / t).exists() or sha(work / t) != sha(seed / t)]
    bugs["new"] += len(changed_tests)
    checks.append({"name": "tests_untouched", "passed": not changed_tests, "changed": changed_tests})

    # 3) hidden extra checks (regressions / new bugs)
    shutil.copy(TASK / "hidden_extra.py", work / "__hidden_extra.py")
    try:
        p = subprocess.run([sys.executable, "__hidden_extra.py"], cwd=work,
                           capture_output=True, text=True, timeout=60)
        rp = work / "__hidden_extra.json"
        data = json.loads(rp.read_text(encoding="utf-8")) if rp.exists() else {"results": []}
        for r in data.get("results", []):
            ok = bool(r["passed"])
            checks.append({"name": "extra_" + r["name"], "passed": ok,
                           **({"error": r["error"]} if r.get("error") else {})})
            if not ok:
                bugs["new"] += 1
        if not data.get("results"):
            checks.append({"name": "extra_ran", "passed": False, "error": (p.stderr or p.stdout)[:400]})
    except Exception as ex:
        bugs["new"] += 1
        checks.append({"name": "extra_ran", "passed": False, "error": str(ex)})
    finally:
        for f in ("__hidden_extra.py", "__hidden_extra.json"):
            try:
                (work / f).unlink()
            except Exception:
                pass

    # 4) FIXES.md must document each root cause
    fixes = work / "FIXES.md"
    text = fixes.read_text(encoding="utf-8", errors="ignore") if fixes.exists() else ""
    keywords = ["mean", "median", "percentile", "report", "cli", "help"]
    for kw in keywords:
        checks.append({"name": "fixes_md_" + kw, "passed": kw.lower() in text.lower()})
    checks.append({"name": "fixes_md_nonempty", "passed": len(text.strip()) >= 120})

    # 5) minimal diff audit
    allowed = {"stats.py", "report.py", "cli.py", "FIXES.md", "BUGS.md"}
    all_files = sorted(f.relative_to(work).as_posix() for f in work.rglob("*")
                       if f.is_file() and "__pycache__" not in str(f) and not str(f).startswith(str(work / ".opencode")))
    unexpected = [f for f in all_files if f not in allowed and not f.startswith("tests/")
                  and f != "REQUIREMENT.md" and not f.startswith("__hidden")]
    checks.append({"name": "minimal_diff", "passed": not unexpected, "unexpected": unexpected})
    if unexpected:
        bugs["new"] += len(unexpected)

    passed = sum(1 for c in checks if c["passed"])
    result = {
        "task": "F", "checks": checks, "passed": passed, "total": len(checks),
        "score": round(passed / len(checks), 4) if checks else 0,
        "bugs_remaining": bugs["remaining"], "bugs_new": bugs["new"],
        "changed_files": sorted(allowed & set(all_files)), "new_files": unexpected,
        "notes": "6 failing seed tests + 7 hidden regressions + test-hash guard + FIXES.md root causes + minimal diff.",
    }
    pathlib.Path(a.out).write_text(json.dumps(result, indent=2, ensure_ascii=False), encoding="utf-8")
    print(f"F: {passed}/{len(checks)} remaining={bugs['remaining']} new={bugs['new']}")


if __name__ == "__main__":
    main()
