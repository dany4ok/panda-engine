"""Catalog of books."""
from models import Book


class Catalog:
    def __init__(self):
        self._books = {}

    def add(self, book):
        self._books[book.isbn] = book

    def get(self, isbn):
        return self._books.get(isbn)

    def all(self):
        return list(self._books.values())

    def remove(self, isbn):
        return self._books.pop(isbn, None)

    def search(self, query):
        """TODO: implement (see REQUIREMENT.md)."""
        q = query.lower()
        return sorted([b for b in self._books.values() if q in b.title.lower() or q in b.author.lower()], key=lambda b: b.title)
