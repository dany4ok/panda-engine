// Pure game-mechanics core. No rendering, no DOM -> fully testable in Node.
// TODO markers must be implemented according to REQUIREMENT.md.

export const CONFIG = {
  xpBase: 10,
  xpStep: 5,
  attackCooldown: 0.5,
  waveInterval: 30,
  attackRange: 150,
  hitRange: 15,
};

export function xpNeeded(level) {
  return CONFIG.xpBase + (level - 1) * CONFIG.xpStep;
}

export class Player {
  constructor() {
    this.hp = 100;
    this.maxHp = 100;
    this.x = 0;
    this.y = 0;
    this.xp = 0;
    this.level = 1;
    this.damage = 10;
    this.speed = 200;
  }

  gainXp(n) {
    this.xp += n;
    let ups = 0;
    while (this.xp >= xpNeeded(this.level)) {
      this.xp -= xpNeeded(this.level);
      this.level += 1;
      ups += 1;
    }
    return ups;
  }

  takeDamage(n) {
    this.hp = Math.max(0, this.hp - n);
    return this.hp;
  }
}

export class Enemy {
  constructor(id, hp, speed) {
    this.id = id;
    this.hp = hp;
    this.speed = speed;
    this.x = 0;
    this.y = 0;
  }

  update(dt, px, py) {
    const dx = px - this.x;
    const dy = py - this.y;
    const dist = Math.hypot(dx, dy);
    if (dist === 0) return;
    const step = this.speed * dt;
    this.x += (dx / dist) * step;
    this.y += (dy / dist) * step;
  }
}

export function spawnWave(n) {
  const arr = [];
  for (let i = 0; i < n; i++) {
    const e = new Enemy(`e${n}_${i}`, 10 + 2 * n, 50 + n);
    e.x = 200 + i * 20;
    e.y = 100 + i * 10;
    arr.push(e);
  }
  return arr;
}

export function nearestEnemy(enemies, px, py) {
  let best = null;
  let bestD = Infinity;
  for (const e of enemies) {
    const d = (e.x - px) ** 2 + (e.y - py) ** 2;
    if (d < bestD) { bestD = d; best = e; }
  }
  return best;
}

export function tryAttack(now, last, cooldown) {
  return now - last >= cooldown;
}

export const UPGRADES = ['damage', 'speed', 'maxhp'];

export function applyUpgrade(player, name) {
  if (!UPGRADES.includes(name)) throw new Error(`Unknown upgrade: ${name}`);
  if (name === 'damage') player.damage += 5;
  else if (name === 'speed') player.speed += 20;
  else { player.maxHp += 20; player.hp += 20; }
  return player;
}

export class Game {
  constructor() {
    this.player = new Player();
    this.time = 0;
    this.wave = 0;
    this.enemies = [];
    this.lastAttack = 0;
    this.events = [];
  }

  update(dt) {
    this.time += dt;
    if (this.time >= (this.wave + 1) * CONFIG.waveInterval) {
      this.wave += 1;
      this.enemies.push(...spawnWave(this.wave));
      this.events.push(`wave:${this.wave}`);
    }
    for (const e of this.enemies) e.update(dt, this.player.x, this.player.y);
    for (let i = this.enemies.length - 1; i >= 0; i--) {
      const e = this.enemies[i];
      const d = Math.hypot(e.x - this.player.x, e.y - this.player.y);
      if (d < CONFIG.hitRange) {
        this.player.takeDamage(1);
        this.enemies.splice(i, 1);
        this.events.push('hit');
      }
    }
    if (tryAttack(this.time, this.lastAttack, CONFIG.attackCooldown)) {
      const target = nearestEnemy(this.enemies, this.player.x, this.player.y);
      if (target) {
        const d = Math.hypot(target.x - this.player.x, target.y - this.player.y);
        if (d <= CONFIG.attackRange) {
          target.hp -= this.player.damage;
          this.lastAttack = this.time;
          this.events.push('attack');
        }
      }
    }
    for (let i = this.enemies.length - 1; i >= 0; i--) {
      const e = this.enemies[i];
      if (e.hp <= 0) {
        this.enemies.splice(i, 1);
        this.player.gainXp(5);
        this.events.push('kill');
      }
    }
  }
}
