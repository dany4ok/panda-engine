import unittest

from catalog import Catalog
from models import Book
from orders import OrderService


def make_catalog():
    c = Catalog()
    c.add(Book("1", "Clean Code", "Robert Martin", 30.0))
    c.add(Book("2", "The Pragmatic Programmer", "Andy Hunt", 40.0))
    c.add(Book("3", "Design Patterns", "Gamma", 50.0))
    return c


class TestSearch(unittest.TestCase):
    def test_search_title_match(self):
        c = make_catalog()
        self.assertEqual([b.title for b in c.search("clean")], ["Clean Code"])

    def test_search_author_match_case_insensitive(self):
        c = make_catalog()
        self.assertEqual([b.title for b in c.search("ROBERT")], ["Clean Code"])

    def test_search_empty_query_returns_all_sorted(self):
        c = make_catalog()
        titles = [b.title for b in c.search("")]
        self.assertEqual(titles, sorted(titles))

    def test_search_no_match(self):
        c = make_catalog()
        self.assertEqual(c.search("zzzzz"), [])


class TestOrders(unittest.TestCase):
    def test_place_and_total(self):
        c = make_catalog()
        s = OrderService()
        o = s.place(c, "2", 2)
        self.assertEqual(o.total(), 80.0)
        self.assertEqual(s.orders[1], o)

    def test_place_missing_isbn_raises_key_error(self):
        c = make_catalog()
        s = OrderService()
        with self.assertRaises(KeyError):
            s.place(c, "999", 1)

    def test_place_invalid_qty_raises_value_error(self):
        c = make_catalog()
        s = OrderService()
        with self.assertRaises(ValueError):
            s.place(c, "1", 0)

    def test_cancel_removes_order(self):
        c = make_catalog()
        s = OrderService()
        o = s.place(c, "1", 1)
        removed = s.cancel(o.id)
        self.assertEqual(removed, o)
        self.assertNotIn(o.id, s.orders)

    def test_cancel_missing_raises_key_error(self):
        s = OrderService()
        with self.assertRaises(KeyError):
            s.cancel(42)

    def test_order_total_empty(self):
        from models import Order
        self.assertEqual(Order(1, []).total(), 0)


if __name__ == "__main__":
    unittest.main()
