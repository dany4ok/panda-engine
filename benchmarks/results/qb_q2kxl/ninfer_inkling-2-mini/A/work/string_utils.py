"""Small, dependency-free string helpers."""


def truncate(text, limit):
    """Return text cut to at most `limit` characters."""
    if len(text) <= limit:
        return text
    return text[:limit]


def slugify(text):
    """Return a URL-friendly slug. TODO: implement."""
    raise NotImplementedError
