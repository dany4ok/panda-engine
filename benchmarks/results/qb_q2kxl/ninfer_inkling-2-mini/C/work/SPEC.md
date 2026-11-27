# Comportamentul CORECT al lui Cart (sursa adevarului)

API public (nu se modifica): `__init__(items=None)`, `add(name, qty=1)`,
`remove(name)`, `count()`, `total(price_fn)`, `apply_coupon(code)`,
`clear()`, `entries()`.

- `__init__(items=None)`: daca `items` e furnizat, Cart NU trebuie sa aliasseze
  lista apelantului (modificarile ulterioare ale Cart nu o schimba).
- `add(name, qty=1)`: `qty > 0` (ValueError altfel). Daca `name` exista deja,
  creste cantitatea cu `qty`; altfel adauga `(name, qty)`.
- `remove(name)`: elimina intrarea si returneaza cantitatea; 0 daca lipseste.
  Comparatia se face dupa VALOARE (`==`), nu dupa identitate.
- `count()`: suma tuturor cantitatilor (NU numarul de nume distincte).
- `total(price_fn)`: `subtotal = sum(qty * price_fn(name))`. Daca
  `subtotal >= 100` SAU cupon activ, subtotalul se inmulteste cu `0.9`
  (O SINGURA data, nu de doua ori). Altfel ramane nemodificat.
- `apply_coupon(code)`: `"SAVE10"` (case-insensitive, ex. `"save10"`) activeaza
  reducerea de 10%. Orice alt cod -> ValueError.
- `clear()`: elimina toate itemii SI reseteaza cuponul.
- `entries()`: returneaza o COPIE a listei de tuple `(name, qty)`.
