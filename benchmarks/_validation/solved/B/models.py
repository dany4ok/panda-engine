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
    items: list = field(default_factory=list)

    def total(self):
        return sum(q * p for _, q, p in self.items)
