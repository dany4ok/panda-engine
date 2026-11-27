"""Report summarization (with bugs)."""
from stats import mean


def summarize(rows):
    rows = list(rows)
    total = 0
    for r in rows:
        total += r["score"]
    return {"count": len(rows), "total": total, "avg": (total / len(rows)) if rows else 0}
