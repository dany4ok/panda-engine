import unittest
from models import Book
from catalog import Catalog
from orders import OrderService

class T(unittest.TestCase):
    def test_total(self):
        from models import Order
        self.assertEqual(Order(1, [("a",2,10.0),("b",1,5.0)]).total(), 25.0)
    def test_search(self):
        c = Catalog(); c.add(Book("1","Alpha","Bob",1.0))
        self.assertEqual([b.title for b in c.search("BOB")], ["Alpha"])
    def test_place(self):
        c = Catalog(); c.add(Book("1","Alpha","Bob",2.0))
        self.assertEqual(OrderService().place(c,"1",3).total(), 6.0)
    def test_cancel(self):
        c = Catalog(); c.add(Book("1","Alpha","Bob",2.0))
        s = OrderService(); s.place(c,"1",1); self.assertIn(1, s.orders); s.cancel(1)
        self.assertNotIn(1, s.orders)
    def test_missing(self):
        with self.assertRaises(KeyError): OrderService().place(Catalog(), "x", 1)
