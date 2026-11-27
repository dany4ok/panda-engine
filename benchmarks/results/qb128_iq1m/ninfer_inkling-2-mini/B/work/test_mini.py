import unittest

from catalog import Catalog
from models import Book, Order
from orders import OrderService


def make_catalog():
    c = Catalog()
    c.add(Book("1", "Clean Code", "Robert Martin", 30.0))
    c.add(Book("2", "The Pragmatic Programmer", "Andy Hunt", 40.0))
    c.add(Book("3", "Design Patterns", "Gamma", 50.0))
    return c


class TestTotal(unittest.TestCase):
    def test_total_empty(self):
        self.assertEqual(Order(id=1, items=[]).total(), 0)

    def test_total_sums_qty_times_price(self):
        o = Order(id=1, items=[("1", 2, 30.0), ("2", 1, 40.0)])
        self.assertEqual(o.total(), 100.0)


class TestSearch(unittest.TestCase):
    def test_search_title_case_insensitive(self):
        c = make_catalog()
        self.assertEqual([b.title for b in c.search("clean")], ["Clean Code"])

    def test_search_author_substring(self):
        c = make_catalog()
        self.assertEqual([b.title for b in c.search("robert")], ["Clean Code"])

    def test_search_sorted_by_title(self):
        c = make_catalog()
        c.add(Book("4", "Design Patterns", "A", 1.0))
        c.add(Book("5", "Design Document", "B", 1.0))
        titles = [b.title for b in c.search("design")]
        self.assertEqual(titles, sorted(titles))

    def test_search_no_match_empty(self):
        c = make_catalog()
        self.assertEqual(c.search("zzz"), [])

    def test_search_empty_query_returns_all_sorted(self):
        c = make_catalog()
        titles = [b.title for b in c.search("")]
        self.assertEqual(titles, [b.title for b in sorted(make_catalog().all(), key=lambda b: b.title)])


class TestPlaceCancel(unittest.TestCase):
    def test_place_creates_order_and_stores(self):
        c = make_catalog()
        s = OrderService()
        o = s.place(c, "2", 2)
        self.assertEqual(o.id, 1)
        self.assertEqual(o.items, [("2", 2, 40.0)])
        self.assertEqual(s.orders[1], o)
        self.assertEqual(o.total(), 80.0)

    def test_place_sequential_ids(self):
        c = make_catalog()
        s = OrderService()
        o1 = s.place(c, "1", 1)
        o2 = s.place(c, "3", 1)
        self.assertEqual((o1.id, o2.id), (1, 2))

    def test_place_missing_isbn_raises_keyerror(self):
        c = make_catalog()
        s = OrderService()
        with self.assertRaises(KeyError):
            s.place(c, "nope", 1)

    def test_place_invalid_qty_raises_valueerror(self):
        c = make_catalog()
        s = OrderService()
        with self.assertRaises(ValueError):
            s.place(c, "1", 0)

    def test_cancel_removes_and_returns(self):
        c = make_catalog()
        s = OrderService()
        o = s.place(c, "1", 1)
        cancelled = s.cancel(o.id)
        self.assertEqual(cancelled, o)
        self.assertNotIn(o.id, s.orders)

    def test_cancel_missing_raises_keyerror(self):
        s = OrderService()
        with self.assertRaises(KeyError):
            s.cancel(999)


if __name__ == "__main__":
    unittest.main()
