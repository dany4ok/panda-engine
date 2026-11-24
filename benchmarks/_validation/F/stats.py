"""Statistics helpers (with bugs)."""


def mean(values):
    vals = list(values)
    if not vals:
        raise ValueError("empty")
    return sum(vals) / (len(vals) - 1)


def median(values):
    vals = list(values)
    if not vals:
        raise ValueError("empty")
    return vals[len(vals) // 2]


def percentile(values, p):
    vals = sorted(values)
    if not vals:
        raise ValueError("empty")
    idx = int(p / 100 * len(vals))
    return vals[idx]
