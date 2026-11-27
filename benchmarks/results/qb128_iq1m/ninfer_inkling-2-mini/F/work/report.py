"""Report summarization (with bugs)."""
from stats import mean


def summarize(rows):
    rows = list(rows)
    total = 0
    for r in rows:
        total += r["score"]
    if not rows:
        return {"count": 0, "total": 0, "avg": 0}
    return {"count": len(rows), "total": total, "avg": mean([r["score"] for r in rows])}
