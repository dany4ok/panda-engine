import test from 'node:test';
import assert from 'node:assert';
import { xpNeeded, Player, Enemy, spawnWave, nearestEnemy, tryAttack, applyUpgrade, Game } from './game/core.js';

test('xpNeeded', () => {
  assert.equal(xpNeeded(1), 10);
  assert.equal(xpNeeded(3), 20);
});

test('gainXp levels up', () => {
  const p = new Player();
  assert.equal(p.gainXp(10), 1);
  assert.equal(p.level, 2);
  assert.equal(p.xp, 0);
});

test('takeDamage clamps', () => {
  const p = new Player();
  assert.equal(p.takeDamage(50), 50);
  assert.equal(p.takeDamage(1000), 0);
});

test('Enemy.update moves toward target', () => {
  const e = new Enemy('a', 10, 100);
  e.update(0.1, 100, 0);
  assert.ok(e.x > 0);
});

test('spawnWave', () => {
  const w = spawnWave(2);
  assert.equal(w.length, 2);
  assert.equal(w[0].id, 'e2_0');
  assert.equal(w[0].hp, 14);
});

test('nearestEnemy', () => {
  const enemies = spawnWave(1);
  assert.equal(nearestEnemy(enemies, 200, 100), enemies[0]);
  assert.equal(nearestEnemy([], 0, 0), null);
});

test('tryAttack', () => {
  assert.equal(tryAttack(1.0, 0.5, 0.5), true);
  assert.equal(tryAttack(0.6, 0.5, 0.5), false);
});

test('applyUpgrade', () => {
  const p = new Player();
  applyUpgrade(p, 'damage'); assert.equal(p.damage, 15);
  applyUpgrade(p, 'speed'); assert.equal(p.speed, 220);
  applyUpgrade(p, 'maxhp'); assert.equal(p.maxHp, 120); assert.equal(p.hp, 120);
  assert.throws(() => applyUpgrade(p, 'bad'));
});

test('Game.update emits wave event', () => {
  const g = new Game();
  g.update(31);
  assert.ok(g.events.includes('wave:1'));
  assert.equal(g.enemies.length, 1);
});
