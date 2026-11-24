"""Create reference solutions to validate the evaluators. Not used by the benchmark agents."""
import pathlib
import shutil

ROOT = pathlib.Path(__file__).resolve().parent
SRC = ROOT.parent / "tasks"
DST = ROOT / "solved"

FILES = {
    "A": {
        "string_utils.py": '''"""Small, dependency-free string helpers."""


def truncate(text, limit):
    if len(text) <= limit:
        return text
    return text[:limit]


def slugify(text):
    out = []
    prev_alnum = False
    for ch in text:
        if ch.isalnum():
            out.append(ch.lower())
            prev_alnum = True
        else:
            if prev_alnum:
                out.append("-")
                prev_alnum = False
    return "".join(out).strip("-")
''',
    },
    "B": {
        "models.py": '''from dataclasses import dataclass, field

@dataclass
class Book:
    isbn: str
    title: str
    author: str
    price: float

@dataclass
class Order:
    id: int
    items: list = field(default_factory=list)

    def total(self):
        return sum(q * p for _, q, p in self.items)
''',
        "catalog.py": '''from models import Book

class Catalog:
    def __init__(self):
        self._books = {}
    def add(self, book):
        self._books[book.isbn] = book
    def get(self, isbn):
        return self._books.get(isbn)
    def all(self):
        return list(self._books.values())
    def remove(self, isbn):
        return self._books.pop(isbn, None)
    def search(self, query):
        q = query.lower()
        return sorted(
            [b for b in self._books.values()
             if q in b.title.lower() or q in b.author.lower()],
            key=lambda b: b.title,
        )
''',
        "orders.py": '''from models import Order

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
''',
        "test_app.py": '''import unittest
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
''',
    },
    "C": {
        "cart.py": '''class Cart:
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
        if code.lower() == "save10":
            self.coupon = True
        else:
            raise ValueError("bad coupon")

    def clear(self):
        self.items = []
        self.coupon = False

    def entries(self):
        return list(self.items)
''',
    },
    "D": {
        "game/core.js": '''export const CONFIG = {
  xpBase: 10, xpStep: 5, attackCooldown: 0.5,
  waveInterval: 30, attackRange: 150, hitRange: 15,
};
export function xpNeeded(level) { return CONFIG.xpBase + (level - 1) * CONFIG.xpStep; }
export class Player {
  constructor() { this.hp=100; this.maxHp=100; this.x=0; this.y=0; this.xp=0; this.level=1; this.damage=10; this.speed=200; }
  gainXp(n) { let ups=0; this.xp+=n; while(this.xp>=xpNeeded(this.level)){ this.xp-=xpNeeded(this.level); this.level++; ups++; } return ups; }
  takeDamage(n) { this.hp=Math.max(0,this.hp-n); return this.hp; }
}
export class Enemy {
  constructor(id,hp,speed){ this.id=id; this.hp=hp; this.speed=speed; this.x=0; this.y=0; }
  update(dt,px,py){ const dx=px-this.x, dy=py-this.y, d=Math.hypot(dx,dy); if(d>0){ this.x+=dx/d*this.speed*dt; this.y+=dy/d*this.speed*dt; } }
}
export function spawnWave(n){ const out=[]; for(let i=0;i<n;i++) out.push(new Enemy(`e${n}_${i}`,10+2*n,50+n)); for(let i=0;i<out.length;i++){out[i].x=200+i*20;out[i].y=100+i*10;} return out; }
export function nearestEnemy(enemies,px,py){ let best=null,bd=Infinity; for(const e of enemies){const d=(e.x-px)**2+(e.y-py)**2; if(d<bd){bd=d;best=e;}} return best; }
export function tryAttack(now,last,cooldown){ return now-last>=cooldown; }
export const UPGRADES=['damage','speed','maxhp'];
export function applyUpgrade(player,name){
  if(name==='damage') player.damage+=5;
  else if(name==='speed') player.speed+=20;
  else if(name==='maxhp'){ player.maxHp+=20; player.hp+=20; }
  else throw new Error('unknown upgrade');
}
export class Game {
  constructor(){ this.player=new Player(); this.time=0; this.wave=0; this.enemies=[]; this.lastAttack=0; this.events=[]; }
  update(dt){
    this.time+=dt;
    if(this.time>=(this.wave+1)*CONFIG.waveInterval){ this.wave++; this.enemies.push(...spawnWave(this.wave)); this.events.push('wave:'+this.wave); }
    const p=this.player;
    for(const e of this.enemies) e.update(dt,p.x,p.y);
    this.enemies=this.enemies.filter(e=>{ const d=Math.hypot(e.x-p.x,e.y-p.y); if(d<CONFIG.hitRange){ p.takeDamage(1); this.events.push('hit'); return false; } return true; });
    if(tryAttack(this.time,this.lastAttack,CONFIG.attackCooldown)){
      const t=nearestEnemy(this.enemies,p.x,p.y);
      if(t && Math.hypot(t.x-p.x,t.y-p.y)<=CONFIG.attackRange){ t.hp-=p.damage; this.lastAttack=this.time; this.events.push('attack'); }
    }
    this.enemies=this.enemies.filter(e=>{ if(e.hp<=0){ p.gainXp(5); this.events.push('kill'); return false; } return true; });
  }
}
''',
        "game/scene.js": '''import * as THREE from '../vendor/three.module.min.js';
import { Game, CONFIG } from './core.js';
const game = new Game();
const scene = new THREE.Scene();
const camera = new THREE.PerspectiveCamera(60, 1, 0.1, 1000);
camera.position.z = 300;
const renderer = new THREE.WebGLRenderer();
document.body.appendChild(renderer.domElement);
const playerMesh = new THREE.Mesh(new THREE.BoxGeometry(20,20,20), new THREE.MeshBasicMaterial({color:0x44aa88}));
scene.add(playerMesh);
const hp = document.getElementById('hp');
const xp = document.getElementById('xp');
const lv = document.getElementById('lv');
let last = performance.now();
function frame(now){
  const dt = Math.min(0.1, (now-last)/1000); last = now;
  game.update(dt);
  playerMesh.position.set(game.player.x, game.player.y, 0);
  hp.textContent = game.player.hp; xp.textContent = game.player.xp; lv.textContent = game.player.level;
  renderer.render(scene, camera);
  requestAnimationFrame(frame);
}
requestAnimationFrame(frame);
console.log('scene boot', CONFIG.waveInterval, game.player.hp);
''',
    },
    "E": {
        "hud.js": '''const state = { hp: 100, maxHp: 100, xp: 0, level: 1 };
let mode = 'idle';
const canvas = document.getElementById('stage');
const ctx = canvas.getContext('2d');
const atlas = new Image();
atlas.src = './assets/atlas.png';
const hpEl = document.getElementById('hp');
const xpEl = document.getElementById('xp');
const lvEl = document.getElementById('lv');
const hpbar = document.getElementById('hpbar');
const xpbar = document.getElementById('xpbar');
const runBtn = document.getElementById('run');
const hurtBtn = document.getElementById('hurt');
runBtn.addEventListener('click', () => { mode = (mode === 'run') ? 'idle' : 'run'; });
hurtBtn.addEventListener('click', () => { mode = 'hurt'; setTimeout(() => { mode = 'idle'; }, 300); });
let tick = 0;
function frame(){
  tick++;
  let f = 0;
  if (mode === 'run') f = (tick % 2 === 0) ? 1 : 2;
  else if (mode === 'hurt') f = 3;
  else f = 0;
  ctx.clearRect(0,0,canvas.width,canvas.height);
  ctx.drawImage(atlas, f*16, 0, 16, 16, 100, 100, 48, 48);
  hpEl.textContent = state.hp; xpEl.textContent = state.xp; lvEl.textContent = state.level;
  hpbar.style.width = (state.hp/state.maxHp*100) + '%';
  xpbar.style.width = (state.xp%100) + '%';
  requestAnimationFrame(frame);
}
requestAnimationFrame(frame);
''',
    },
    "F": {
        "stats.py": '''def mean(values):
    vals = list(values)
    if not vals: raise ValueError("empty")
    return sum(vals) / len(vals)

def median(values):
    vals = sorted(values)
    if not vals: raise ValueError("empty")
    return vals[len(vals) // 2]

def percentile(values, p):
    vals = sorted(values)
    if not vals: raise ValueError("empty")
    idx = int(p / 100 * (len(vals) - 1))
    return vals[idx]
''',
        "report.py": '''from stats import mean

def summarize(rows):
    rows = list(rows)
    if not rows:
        return {"count": 0, "total": 0, "avg": 0}
    total = sum(r["score"] for r in rows)
    return {"count": len(rows), "total": total, "avg": mean([r["score"] for r in rows])}
''',
        "cli.py": '''import sys
from report import summarize

def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    if "--help" in argv:
        print("usage: report_tool <numbers...>")
        return 0
    nums = [float(x) for x in argv]
    print(sum(nums))
    return 0
''',
        "FIXES.md": '''Root causes identified and fixed:

- mean: divisor was len(vals)-1 (sample mean) instead of len(vals) -> population mean.
- median: returned the middle element of the unsorted input; now sorts first.
- percentile: index used len(vals) causing off-by-one and out-of-range at 100; now len(vals)-1.
- report: summarize read the wrong key "value" instead of "score"; empty input now returns zeros.
- cli: parsing skipped argv[0] with argv[1:], dropping the first number.
- help: --help was not handled; now prints usage and returns 0.
''',
    },
}

MAP = {"A": "A_simple", "B": "B_complex", "C": "C_debug", "D": "D_game", "E": "E_assets", "F": "F_agent"}

for letter, files in FILES.items():
    task = SRC / MAP[letter]
    work = DST / letter
    if work.exists():
        shutil.rmtree(work)
    shutil.copytree(task / "seed", work)
    shutil.copy(task / "REQUIREMENT.md", work / "REQUIREMENT.md")
    for rel, content in files.items():
        dest = work / rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text(content, encoding="utf-8")
    print("solved", letter)
