import sys
import importlib.util

def load(path):
    spec = importlib.util.spec_from_file_location("submitted", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod

def run_cases(fn, cases):
    ok = 0
    for args, expected in cases:
        try:
            if fn(*args) == expected:
                ok += 1
        except Exception:
            pass
    return ok, len(cases)

def tests(task, m):
    if task == 9:
        return run_cases(m.validate_ipv4, [(("192.168.0.1",), True), (("255.255.255.255",), True),
                                            (("256.1.1.1",), False), (("01.1.1.1",), False),
                                            (("1.2.3",), False), (("1.2.3.4.5",), False),
                                            (("0.0.0.0",), True), (("abc",), False), (("1.2.3.-1",), False)])
    if task == 10:
        return run_cases(m.flatten, [(([1,[2,[3,4]],5],), [1,2,3,4,5]), (([],), []),
                                     (([[[]]],), []), (([1,[],2],), [1,2])])
    if task == 11:
        return run_cases(m.max_subarray_sum, [(([-2,1,-3,4,-1,2,1,-5,4],), 6), (([1],), 1),
                                              (([-1,-2],), -1), (([5,-1,5],), 9), (([0],), 0)])
    if task == 12:
        return run_cases(m.roman_to_int, [(("III",), 3), (("IV",), 4), (("IX",), 9),
                                          (("LVIII",), 58), (("MCMXCIV",), 1994), (("XL",), 40)])
    if task == 13:
        return run_cases(m.merge_intervals, [(([[1,3],[2,6],[8,10],[15,18]],), [[1,6],[8,10],[15,18]]),
                                             (([[1,4],[4,5]],), [[1,5]]), (([[1,4],[0,4]],), [[0,4]]),
                                             (([],), [])])
    if task == 14:
        ok, total = run_cases(m.add_item, [(([1],), [1]), (([2],), [2])])
        try:
            a = m.add_item(1); a.append(9)
            if m.add_item(3) == [3]:
                ok += 1
        except Exception:
            pass
        return ok, total + 1
    if task == 15:
        return run_cases(m.remove_negatives, [(([1,-2,3,-4],), [1,3]), (([-1,-2],), []), (([1,2,3],), [1,2,3])])
    raise ValueError("unknown task")

def main():
    task = int(sys.argv[1])
    try:
        m = load(sys.argv[2])
        ok, total = tests(task, m)
        print(("PASS " if ok == total else "FAIL ") + f"{ok}/{total}")
    except Exception as e:
        print("ERROR " + type(e).__name__ + ": " + str(e)[:120])

if __name__ == "__main__":
    main()
