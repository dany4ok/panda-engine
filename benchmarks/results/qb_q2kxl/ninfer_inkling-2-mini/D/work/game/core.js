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
  // TODO
  throw new Error('TODO xpNeeded');
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
    // TODO: return number of level-ups
    throw new Error('TODO gainXp');
  }

  takeDamage(n) {
    // TODO
    throw new Error('TODO takeDamage');
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
    // TODO: move toward (px, py) by speed*dt
    throw new Error('TODO Enemy.update');
  }
}

export function spawnWave(n) {
  // TODO
  throw new Error('TODO spawnWave');
}

export function nearestEnemy(enemies, px, py) {
  // TODO
  throw new Error('TODO nearestEnemy');
}

export function tryAttack(now, last, cooldown) {
  // TODO
  throw new Error('TODO tryAttack');
}

export const UPGRADES = ['damage', 'speed', 'maxhp'];

export function applyUpgrade(player, name) {
  // TODO
  throw new Error('TODO applyUpgrade');
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
    // TODO: see REQUIREMENT.md, steps 1-5
    throw new Error('TODO Game.update');
  }
}
