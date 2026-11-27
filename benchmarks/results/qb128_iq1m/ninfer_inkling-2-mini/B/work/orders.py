"""Order placement and cancellation."""
from models import Order


class OrderService:
    def __init__(self):
        self.orders = {}
        self._next = 1

    def place(self, catalog, isbn, qty):
        book = catalog.get(isbn)
        if book is None:
            raise KeyError(isbn)
        if qty <= 0:
            raise ValueError("qty must be > 0")
        order = Order(id=self._next, items=[(isbn, qty, book.price)])
        self._next += 1
        self.orders[order.id] = order
        return order

    def cancel(self, order_id):
        if order_id not in self.orders:
            raise KeyError(order_id)
        return self.orders.pop(order_id)
