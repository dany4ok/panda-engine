"""Domain models for the mini library app."""
from dataclasses import dataclass, field


@dataclass
class Book:
    isbn: str
    title: str
    author: str
    price: float


@dataclass
class Order:
    id: int
    # each item is (isbn, qty, unit_price)
    items: list = field(default_factory=list)

    def total(self):
        return sum(qty * unit_price for _isbn, qty, unit_price in self.items)
