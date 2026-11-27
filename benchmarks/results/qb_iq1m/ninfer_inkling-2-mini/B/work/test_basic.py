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
        self.assertEqual(Order(1).total(), 0)

    def test_total_multiple_items(self):
        o = Order(1)
        o.items.append(("1", 2, 30.0))
        o.items.append(("3", 1, 50.0))
        self.assertEqual(o.total(), 110.0)


class TestSearch(unittest.TestCase):
    def test_search_by_title_case_insensitive(self):
        res = make_catalog().search("clean")
        self.assertEqual([b.title for b in res], ["Clean Code"])

    def test_search_by_author(self):
        res = make_catalog().search("robert")
        self.assertEqual([b.title for b in res], ["Clean Code"])

    def test_search_sorted_by_title(self):
        res = make_catalog().search("a")
        titles = [b.title for b in res]
        self.assertEqual(titles, sorted(titles))

    def test_search_empty_query_returns_all_sorted(self):
        res = make_catalog().search("")
        self.assertEqual([b.title for b in res],
                         ["Clean Code", "Design Patterns", "The Pragmatic Programmer"])

    def test_search_no_match_returns_empty(self):
        self.assertEqual(make_catalog().search("zzzz"), [])


class TestOrderService(unittest.TestCase):
    def test_place_returns_order_and_stores(self):
        s = OrderService()
        o = s.place(make_catalog(), "2", 2)
        self.assertEqual(o.id, 1)
        self.assertEqual(o.items, [("2", 2, 40.0)])
        self.assertEqual(s.orders[1], o)

    def test_place_missing_isbn_raises_keyerror(self):
        s = OrderService()
        with self.assertRaises(KeyError):
            s.place(make_catalog(), "missing", 1)

    def test_place_zero_qty_raises_valueerror(self):
        s = OrderService()
        with self.assertRaises(ValueError):
            s.place(make_catalog(), "1", 0)

    def test_cancel_removes_and_returns(self):
        s = OrderService()
        c = make_catalog()
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
