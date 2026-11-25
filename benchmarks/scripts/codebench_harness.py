import sys
import importlib.util

def load(path):
    spec = importlib.util.spec_from_file_location("submitted", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod

def run_cases(fn, cases, transform=None):
    ok = 0
    for args, expected in cases:
        try:
            got = fn(*args)
            if transform:
                got = transform(got)
            if got == expected:
                ok += 1
        except Exception:
            pass
    return ok, len(cases)

def tests(task, m):
    if task == 1:
        return run_cases(m.is_prime, [((0,), False), ((1,), False), ((2,), True), ((3,), True),
                                      ((4,), False), ((9,), False), ((17,), True),
                                      ((25,), False), ((7919,), True)])
    if task == 2:
        return run_cases(m.fib, [((0,), 0), ((1,), 1), ((2,), 1), ((5,), 5), ((10,), 55), ((20,), 6765)])
    if task == 3:
        return run_cases(m.valid_parentheses, [(("",), True), (("()",), True), (("((",), False),
                                                ((")(",), False), (("()()",), True),
                                                (("([{}])",), True), (("([)]",), False), (("(()",), False)])
    if task == 4:
        return run_cases(m.two_sum, [(([2,7,11,15],9), {0,1}), (([3,2,4],6), {1,2}), (([3,3],6), {0,1})],
                         transform=lambda v: set(v) if v is not None else None)
    if task == 5:
        return run_cases(m.reverse_words, [(("hello world",), "world hello"), (("  a  b ",), "b a"),
                                           (("one",), "one"), (("",), "")])
    if task == 6:
        return run_cases(m.longest_common_prefix, [((["flower","flow","flight"],), "fl"),
                                                    ((["dog","racecar","car"],), ""),
                                                    ((["abc"],), "abc"), (([],), "")])
    if task == 7:
        return run_cases(m.calculate_average, [(([1,2,3],), 2.0), (([],), 0.0), (([5],), 5.0), (([-1,1],), 0.0)])
    if task == 8:
        return run_cases(m.remove_dupes, [(([1,2,2,3],), [1,2,3]), (("a b a".split(),), ["a","b"]), (([],), [])])
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
