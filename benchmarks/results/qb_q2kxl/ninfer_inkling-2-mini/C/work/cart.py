"""Shopping cart with intentionally introduced bugs. See SPEC.md for correct behavior."""


class Cart:
    def __init__(self, items=None):
        self.items = items or []
        self.coupon = False

    def add(self, name, qty=1):
        if qty <= 0:
            raise ValueError("qty must be positive")
        self.items.append((name, qty))

    def remove(self, name):
        for i, (n, q) in enumerate(self.items):
            if n is name:
                del self.items[i]
                return q
        return 0

    def count(self):
        return len(self.items)

    def total(self, price_fn):
        subtotal = sum(q * price_fn(n) for n, q in self.items)
        if subtotal > 100:
            subtotal *= 0.9
        if self.coupon:
            subtotal -= 0.10
        return subtotal

    def apply_coupon(self, code):
        if code in ("SAVE10",):
            self.coupon = True
        else:
            raise ValueError("bad coupon")

    def clear(self):
        self.items = []

    def entries(self):
        return self.items
