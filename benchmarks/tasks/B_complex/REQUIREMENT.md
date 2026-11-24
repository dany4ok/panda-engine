# Sarcina B — programare complexa (multi-modul + teste)

Proiectul are 4 module: `models.py`, `catalog.py`, `orders.py`, `demo.py`.
Implementeaza TODO-urile si asigura integrarea cap-coada.

Cerinte exacte:
1. `Order.total()` -> suma `qty * unit_price` pentru toate itemii; 0 pentru comanda goala.
2. `Catalog.search(query)` -> lista de `Book` al caror titlu SAU autor contine
   `query` ca substring case-insensitive; results sortate crescator dupa `title`;
   lista goala daca nu e nicio potrivire. `query=""` returneaza toate cartile sortate.
3. `OrderService.place(catalog, isbn, qty)` -> verifica_book (KeyError daca isbn lipseste),
   valideaza `qty > 0` (ValueError altfel), creeaza `Order` cu id secvential
   (1, 2, 3...), il stocheaza in `self.orders` dupa id si il returneaza.
   Fiecare item e tuple `(isbn, qty, unit_price)`.
4. `OrderService.cancel(order_id)` -> elimina si returneaza comanda; KeyError daca lipseste.
5. `demo.py` trebuie sa ruleze: `python demo.py` cu exit code 0 si output care
   contine `TOTAL 80.0`, `SEARCH ['Clean Code']`, `COUNT 1`.
6. Scrie cel putin 5 teste `unittest` intr-un fisier `test_*.py` care acopera
   search, place, cancel si total. Ruleaza `python -m unittest discover -v`.
   Toate testele (ale tale si cele ascunse) trebuie sa treaca.

Nu schimba semnaturile publice si nu adauga dependente externe.
