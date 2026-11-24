"""Hidden extra checks for task F, copied into the work dir at eval time."""
import contextlib
import io
import json

from stats import mean, percentile
from report import summarize
from cli import main

results = []


def raises(fn):
    try:
        fn()
        return False
    except Exception:
        return True


def t(name, fn):
    try:
        results.append({"name": name, "passed": bool(fn())})
    except Exception as ex:
        results.append({"name": name, "passed": False, "error": str(ex)})


def cli_out(args):
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        rc = main(args)
    return rc, buf.getvalue().strip()


t("mean_empty_raises", lambda: raises(lambda: mean([])))
t("percentile_0", lambda: percentile([1, 2, 3], 0) == 1)
t("percentile_100", lambda: percentile([1, 2, 3], 100) == 3)
t("summarize_empty", lambda: summarize([]) == {"count": 0, "total": 0, "avg": 0})
t("cli_single", lambda: cli_out(["5"]) == (0, "5.0"))
t("cli_negative", lambda: cli_out(["-1", "2"]) == (0, "1.0"))
t("cli_help_usage", lambda: "usage" in cli_out(["--help"])[1].lower())

with open("__hidden_extra.json", "w", encoding="utf-8") as f:
    json.dump({"results": results}, f)
