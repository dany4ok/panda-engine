"""Small, dependency-free string helpers."""

import re


def truncate(text, limit):
    """Return text cut to at most `limit` characters."""
    if len(text) <= limit:
        return text
    return text[:limit]


def slugify(text):
    """Return a URL-friendly slug."""
    if not text:
        return ""
    text = text.lower()
    text = re.sub(r"[^\w]+|_", "-", text)
    return re.sub(r"-+", "-", text).strip("-")