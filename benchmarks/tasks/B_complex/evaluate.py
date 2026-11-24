#!/usr/bin/env python3
"""Independent deterministic evaluator for task B (multi-module integration)."""
import argparse
import hashlib
import json
import pathlib
import re
import subprocess
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

    checks, bugs = [], {"remaining": 0, "new": 0}

    def add(name, fn, bug_class=None):
        try:
            ok = bool(fn())
        except Exception as ex:
            ok = False
            if bug_class:
                bugs[bug_class] += 1
            checks.append({"name": name, "passed": False, "error": str(ex)})
            return
        if not ok and bug_class:
            bugs[bug_class] += 1
        checks.append({"name": name, "passed": ok})

    sys.path.insert(0, str(work))
    try:
        from models import Book, Order
        from catalog import Catalog
        from orders import OrderService
        loaded = True
    except Exception as ex:
        loaded = False
        checks.append({"name": "modules_import", "passed": False, "error": str(ex)})

    def cat():
        c = Catalog()
        for isbn, title, author, price in [
            ("3", "Zebra", "bob", 10.0),
            ("1", "Alpha", "Alice", 20.0),
            ("2", "Beta", "BOB", 30.0),
        ]:
            c.add(Book(isbn, title, author, price))
        return c

    if loaded:
        add("total_sum", lambda: Order(1, [("a", 2, 10.0), ("b", 1, 5.0)]).total() == 25.0, "remaining")
        add("total_empty", lambda: Order(2).total() == 0, "remaining")
        add("search_author_ci", lambda: [b.title for b in cat().search("BOB")] == ["Beta", "Zebra"], "remaining")
        add("search_title_ci", lambda: [b.title for b in cat().search("alpha")] == ["Alpha"], "remaining")
        add("search_sorted", lambda: [b.title for b in cat().search("")] == ["Alpha", "Beta", "Zebra"], "remaining")
        add("search_no_match", lambda: cat().search("zzz") == [], "remaining")

        def place_ok():
            s = OrderService()
            o = s.place(cat(), "1", 3)
            return o.id == 1 and o.total() == 60.0 and s.orders[1] is o and s._next == 2
        add("place_ok", place_ok, "remaining")

        def place_missing():
            s = OrderService()
            try:
                s.place(cat(), "NOPE", 1)
                return False
            except KeyError:
                return True
        add("place_missing_raises", place_missing, "remaining")

        def place_bad_qty():
            s = OrderService()
            for q in (0, -1):
                try:
                    s.place(cat(), "1", q)
                    return False
                except ValueError:
                    pass
            return True
        add("place_qty_raises", place_bad_qty, "remaining")

        def cancel_ok():
            s = OrderService()
            o = s.place(cat(), "1", 1)
            return s.cancel(1) is o and 1 not in s.orders
        add("cancel_ok", cancel_ok, "remaining")

        def cancel_missing():
            s = OrderService()
            try:
                s.cancel(99)
                return False
            except KeyError:
                return True
        add("cancel_missing_raises", cancel_missing, "remaining")

    # end-to-end wiring
    try:
        p = subprocess.run([sys.executable, "demo.py"], cwd=work, capture_output=True, text=True, timeout=60)
        out = p.stdout
        ok = p.returncode == 0 and "TOTAL 80.0" in out and "SEARCH ['Clean Code']" in out and "COUNT 1" in out
        checks.append({"name": "demo_end_to_end", "passed": ok, "stdout": out.strip(), "stderr": p.stderr.strip()})
        if not ok:
            bugs["remaining"] += 1
    except Exception as ex:
        bugs["remaining"] += 1
        checks.append({"name": "demo_end_to_end", "passed": False, "error": str(ex)})

    # model-written tests: must exist and pass
    test_files = sorted(str(f.relative_to(work)).replace("\\", "/") for f in work.rglob("test_*.py"))
    if test_files:
        try:
            p = subprocess.run([sys.executable, "-m", "unittest", "discover", "-q"], cwd=work,
                               capture_output=True, text=True, timeout=120)
            m = re.search(r"Ran (\d+) tests?", p.stdout + p.stderr)
            n = int(m.group(1)) if m else 0
            ok = p.returncode == 0 and n >= 5
            checks.append({"name": "model_tests_ge5_and_pass", "passed": ok, "test_files": test_files, "tests": n})
            if not ok:
                bugs["new"] += 1
        except Exception as ex:
            bugs["new"] += 1
            checks.append({"name": "model_tests_ge5_and_pass", "passed": False, "error": str(ex)})
    else:
        bugs["new"] += 1
        checks.append({"name": "model_tests_exist", "passed": False, "error": "no test_*.py found"})

    sm, wm = file_map(seed), file_map(work)
    changed = sorted(k for k in set(sm) & set(wm) if sm[k] != wm[k])
    new_files = sorted(k for k in set(wm) - set(sm))
    allowed_change = {"models.py", "catalog.py", "orders.py", "demo.py"}
    unexpected = [f for f in changed + new_files if f not in allowed_change and not f.startswith("test_")]
    if unexpected:
        bugs["new"] += len(unexpected)
    checks.append({"name": "no_unexpected_files", "passed": not unexpected, "unexpected": unexpected})

    passed = sum(1 for c in checks if c["passed"])
    result = {
        "task": "B", "checks": checks, "passed": passed, "total": len(checks),
        "score": round(passed / len(checks), 4) if checks else 0,
        "bugs_remaining": bugs["remaining"], "bugs_new": bugs["new"],
        "changed_files": changed, "new_files": new_files,
        "notes": "11 hidden integration/edge checks + demo end-to-end + >=5 model tests.",
    }
    pathlib.Path(a.out).write_text(json.dumps(result, indent=2, ensure_ascii=False), encoding="utf-8")
    print(f"B: {passed}/{len(checks)}")


if __name__ == "__main__":
    main()
