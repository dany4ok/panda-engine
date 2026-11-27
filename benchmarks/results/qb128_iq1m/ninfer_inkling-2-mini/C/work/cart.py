"""Shopping cart with intentionally introduced bugs. See SPEC.md for correct behavior."""


class Cart:
    def __init__(self, items=None):
        self.items = list(items) if items is not None else []
        self.coupon = False

    def add(self, name, qty=1):
        if qty <= 0:
            raise ValueError("qty must be positive")
        for i, (n, q) in enumerate(self.items):
            if n == name:
                self.items[i] = (n, q + qty)
                return
        self.items.append((name, qty))

    def remove(self, name):
        for i, (n, q) in enumerate(self.items):
            if n == name:
                del self.items[i]
                return q
        return 0

    def count(self):
        return sum(q for _, q in self.items)

    def total(self, price_fn):
        subtotal = sum(q * price_fn(n) for n, q in self.items)
        if subtotal >= 100 or self.coupon:
            subtotal *= 0.9
        return subtotal

    def apply_coupon(self, code):
        if isinstance(code, str) and code.upper() == "SAVE10":
            self.coupon = True
        else:
            raise ValueError("bad coupon")

    def clear(self):
        self.items = []
        self.coupon = False

    def entries(self):
        return list(self.items)
