"""Statistics helpers (with bugs)."""


def mean(values):
    vals = list(values)
    if not vals:
        raise ValueError("empty")
    return sum(vals) / len(vals)


def median(values):
    vals = list(values)
    if not vals:
        raise ValueError("empty")
    vals = sorted(vals)
    n = len(vals)
    if n % 2:
        return vals[n // 2]
    return (vals[n // 2 - 1] + vals[n // 2]) / 2


def percentile(values, p):
    vals = sorted(values)
    if not vals:
        raise ValueError("empty")
    idx = int(p / 100 * (len(vals) - 1))
    return vals[idx]
