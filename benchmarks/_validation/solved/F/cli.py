import sys
from report import summarize

def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    if "--help" in argv:
        print("usage: report_tool <numbers...>")
        return 0
    nums = [float(x) for x in argv]
    print(sum(nums))
    return 0
