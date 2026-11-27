"""End-to-end demo wiring catalog + orders."""
from catalog import Catalog
from models import Book
from orders import OrderService


def main():
    c = Catalog()
    c.add(Book("1", "Clean Code", "Robert Martin", 30.0))
    c.add(Book("2", "The Pragmatic Programmer", "Andy Hunt", 40.0))
    c.add(Book("3", "Design Patterns", "Gamma", 50.0))

    s = OrderService()
    o = s.place(c, "2", 2)
    print("TOTAL", o.total())
    print("SEARCH", [b.title for b in c.search("robert")])
    print("COUNT", len(s.orders))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
