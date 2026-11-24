"""Report summarization (with bugs)."""
from stats import mean


def summarize(rows):
    rows = list(rows)
    total = 0
    for r in rows:
        total += r["value"]
    return {"count": len(rows), "total": total, "avg": mean([r["value"] for r in rows])}
