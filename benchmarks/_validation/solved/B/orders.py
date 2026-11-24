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
            raise ValueError("qty")
        o = Order(self._next, [(isbn, qty, book.price)])
        self.orders[o.id] = o
        self._next += 1
        return o
    def cancel(self, order_id):
        return self.orders.pop(order_id)
