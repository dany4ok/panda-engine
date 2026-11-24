from stats import mean

def summarize(rows):
    rows = list(rows)
    if not rows:
        return {"count": 0, "total": 0, "avg": 0}
    total = sum(r["score"] for r in rows)
    return {"count": len(rows), "total": total, "avg": mean([r["score"] for r in rows])}
