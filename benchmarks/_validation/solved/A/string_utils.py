"""Small, dependency-free string helpers."""


def truncate(text, limit):
    if len(text) <= limit:
        return text
    return text[:limit]


def slugify(text):
    out = []
    prev_alnum = False
    for ch in text:
        if ch.isalnum():
            out.append(ch.lower())
            prev_alnum = True
        else:
            if prev_alnum:
                out.append("-")
                prev_alnum = False
    return "".join(out).strip("-")
