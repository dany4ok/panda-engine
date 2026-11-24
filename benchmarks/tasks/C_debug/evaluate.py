#!/usr/bin/env python3
"""Independent deterministic evaluator for task C. 9 planted bugs + regressions."""
import argparse
import hashlib
import importlib.util
import json
import pathlib


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
    bug_checks, regression_checks = [], []

    spec = importlib.util.spec_from_file_location("cart_under_test", work / "cart.py")
    mod = importlib.util.module_from_spec(spec)
    try:
        spec.loader.exec_module(mod)
        Cart = mod.Cart
        loaded = True
    except Exception as ex:
        loaded = False
        checks.append({"name": "module_imports", "passed": False, "error": str(ex)})

    def add(name, fn, kind):
        try:
            ok = bool(fn())
            err = None
        except Exception as ex:
            ok, err = False, str(ex)
        checks.append({"name": name, "passed": ok, **({"error": err} if err else {})})
        (bug_checks if kind == "bug" else regression_checks).append(ok)

    if loaded:
        def no_alias():
            src = [("a", 1)]
            c = Cart(src)
            c.add("b", 1)
            return src == [("a", 1)]
        add("bug01_no_alias_init", no_alias, "bug")

        def aggregates():
            c = Cart()
            c.add("x", 2); c.add("x", 3)
            return c.entries() == [("x", 5)]
        add("bug02_add_aggregates", aggregates, "bug")

        def by_value():
            name = "".join(["a", "b"])
            c = Cart()
            c.items = [(name, 1)]
            return c.remove("ab") == 1
        add("bug03_remove_by_value", by_value, "bug")

        def total_qty():
            c = Cart()
            c.add("a", 2); c.add("b", 3)
            return c.count() == 5
        add("bug04_count_total_qty", total_qty, "bug")

        def coupon_lower():
            c = Cart()
            c.apply_coupon("save10")
            c.add("x", 1)
            return abs(c.total(lambda n: 50) - 45.0) < 1e-9
        add("bug05_coupon_case_insensitive", coupon_lower, "bug")

        def boundary():
            c = Cart()
            c.add("x", 1)
            return abs(c.total(lambda n: 100) - 90.0) < 1e-9
        add("bug06_boundary_ge_100", boundary, "bug")

        def coupon_pct():
            c = Cart()
            c.apply_coupon("SAVE10")
            c.add("x", 1)
            return abs(c.total(lambda n: 50) - 45.0) < 1e-9
        add("bug07_coupon_is_10pct", coupon_pct, "bug")

        def clear_coupon():
            c = Cart()
            c.apply_coupon("SAVE10")
            c.clear()
            c.add("x", 1)
            return abs(c.total(lambda n: 50) - 50.0) < 1e-9
        add("bug08_clear_resets_coupon", clear_coupon, "bug")

        def entries_copy():
            c = Cart(); c.add("a", 1)
            e = c.entries(); e.append(("z", 9))
            return c.count() == 1
        add("bug09_entries_copies", entries_copy, "bug")

        # regressions -> newly introduced bugs
        def basic():
            c = Cart(); c.add("a", 2)
            return c.remove("a") == 2 and c.total(lambda n: 3) == 0
        add("reg_basic_add_remove_total", basic, "reg")

        def qty_validation():
            c = Cart()
            try:
                c.add("a", 0); return False
            except ValueError:
                return True
        add("reg_qty_validation", qty_validation, "reg")

        def bad_coupon():
            c = Cart()
            try:
                c.apply_coupon("NOPE"); return False
            except ValueError:
                return True
        add("reg_bad_coupon_raises", bad_coupon, "reg")

        def no_discount():
            c = Cart(); c.add("a", 1)
            return abs(c.total(lambda n: 50) - 50.0) < 1e-9
        add("reg_no_discount", no_discount, "reg")

        def remove_missing():
            return Cart().remove("nope") == 0
        add("reg_remove_missing", remove_missing, "reg")

    sm, wm = file_map(seed), file_map(work)
    changed = sorted(k for k in set(sm) & set(wm) if sm[k] != wm[k])
    new_files = sorted(k for k in set(wm) - set(sm))
    unexpected = [f for f in new_files if not f.startswith("__hidden") and not f.startswith("test_")]
    checks.append({"name": "no_unexpected_files", "passed": not unexpected, "unexpected": unexpected})

    passed = sum(1 for c in checks if c["passed"])
    bugs_remaining = len(bug_checks) - sum(bug_checks)
    bugs_new = (len(regression_checks) - sum(regression_checks)) + len(unexpected)
    result = {
        "task": "C", "checks": checks, "passed": passed, "total": len(checks),
        "score": round(passed / len(checks), 4) if checks else 0,
        "bugs_remaining": bugs_remaining, "bugs_new": bugs_new,
        "planted_bugs_total": 9, "planted_bugs_fixed": sum(bug_checks),
        "changed_files": changed, "new_files": new_files,
        "notes": "9 planted bugs (SPEC.md) + 5 regressions + file audit.",
    }
    pathlib.Path(a.out).write_text(json.dumps(result, indent=2, ensure_ascii=False), encoding="utf-8")
    print(f"C: {passed}/{len(checks)} fixed={sum(bug_checks)}/9")


if __name__ == "__main__":
    main()
