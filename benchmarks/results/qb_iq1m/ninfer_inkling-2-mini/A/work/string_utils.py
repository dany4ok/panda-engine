"""Small, dependency-free string helpers."""


def truncate(text, limit):
    """Return text cut to at most `limit` characters."""
    if len(text) <= limit:
        return text
    return text[:limit]


def slugify(text):
    """Return a URL-friendly slug."""
    if not text:
        return ""
    parts = []
    for ch in text.lower():
        if ch.isalnum():
            parts.append(ch)
        else:
            if parts and parts[-1] != "-":
                parts.append("-")
    return "".join(parts).strip("-")
