#!/usr/bin/env python3
"""Independent deterministic evaluator for task A. Does not trust model claims."""
import argparse
import hashlib
import importlib.util
import json
import pathlib
import sys


def file_map(root):
    out = {}
    for f in pathlib.Path(root).rglob("*"):
        if not f.is_file():
            continue
        rel = str(f.relative_to(root)).replace("\\", "/")
        if "__pycache__" in rel or rel.startswith(".opencode/") or rel == "REQUIREMENT.md":
            continue
        if rel.startswith("__hidden"):
            continue
        out[rel] = hashlib.sha256(f.read_bytes()).hexdigest()
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--work", required=True)
    ap.add_argument("--seed", required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()

    work, seed = pathlib.Path(a.work), pathlib.Path(a.seed)
    checks = []
    bugs = {"remaining": 0, "new": 0}

    spec = importlib.util.spec_from_file_location("su_under_test", work / "string_utils.py")
    mod = importlib.util.module_from_spec(spec)
    try:
        spec.loader.exec_module(mod)
        loaded = True
    except Exception as ex:
        loaded = False
        checks.append({"name": "module_imports", "passed": False, "error": str(ex)})

    cases = [
        ("basic", "Hello, World!", "hello-world"),
        ("spaces", "  Multe   spatii!!  ", "multe-spatii"),
        ("unicode", "ăâîșț GPS", "ăâîșț-gps"),
        ("trim", "---trim---", "trim"),
        ("empty", "", ""),
        ("separators", "a_b/c\\d", "a-b-c-d"),
        ("digits", "123 456", "123-456"),
        ("unicode_upper", "Über Café", "über-café"),
        ("operators", "C++ & C#", "c-c"),
        ("plain", "abc", "abc"),
    ]
    if loaded:
        for name, inp, expected in cases:
            try:
                got = mod.slugify(inp)
                ok = got == expected
                detail = None if ok else {"expected": expected, "got": got}
            except Exception as ex:
                ok, detail = False, {"error": str(ex)}
            if not ok:
                bugs["remaining"] += 1
            checks.append({"name": "slugify_" + name, "passed": ok, **(detail or {})})

        # regression: existing helper must be untouched
        try:
            ok = mod.truncate("abcdef", 3) == "abc" and mod.truncate("ab", 3) == "ab"
            if not ok:
                bugs["new"] += 1
            checks.append({"name": "regression_truncate", "passed": ok})
        except Exception as ex:
            bugs["new"] += 1
            checks.append({"name": "regression_truncate", "passed": False, "error": str(ex)})

    sm, wm = file_map(seed), file_map(work)
    changed = sorted(k for k in set(sm) & set(wm) if sm[k] != wm[k])
    new_files = sorted(k for k in set(wm) - set(sm))
    unexpected = [f for f in new_files if not f.startswith("__hidden")]
    if unexpected:
        bugs["new"] += len(unexpected)
    checks.append({"name": "no_unnecessary_new_files", "passed": not unexpected, "files": unexpected})
    checks.append({"name": "only_target_file_modified", "passed": changed in ([], ["string_utils.py"]), "changed": changed})

    passed = sum(1 for c in checks if c["passed"])
    result = {
        "task": "A",
        "checks": checks,
        "passed": passed,
        "total": len(checks),
        "score": round(passed / len(checks), 4) if checks else 0,
        "bugs_remaining": bugs["remaining"],
        "bugs_new": bugs["new"],
        "changed_files": changed,
        "new_files": new_files,
        "notes": "slugify cases + truncate regression + unnecessary-change audit.",
    }
    pathlib.Path(a.out).write_text(json.dumps(result, indent=2, ensure_ascii=False), encoding="utf-8")
    print(f"A: {passed}/{len(checks)}")


if __name__ == "__main__":
    main()
