"""Order placement and cancellation."""
from models import Order


class OrderService:
    def __init__(self):
        self.orders = {}
        self._next = 1

    def place(self, catalog, isbn, qty):
        """TODO: implement (see REQUIREMENT.md)."""
        raise NotImplementedError

    def cancel(self, order_id):
        """TODO: implement (see REQUIREMENT.md)."""
        raise NotImplementedError
