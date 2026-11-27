"""Tiny CLI (with bugs)."""
import sys
from report import summarize


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    if "--help" in argv:
        print("Usage: report_tool <numbers>")
        return 0
    nums = [float(x) for x in argv]
    print(sum(nums))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
