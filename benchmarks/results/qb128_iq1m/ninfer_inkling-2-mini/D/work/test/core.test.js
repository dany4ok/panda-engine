import { test } from 'node:test';
import assert from 'node:assert';
import { xpNeeded, Player, Enemy, spawnWave, nearestEnemy, tryAttack, applyUpgrade, Game } from '../game/core.js';

test('xpNeeded', () => {
  assert.equal(xpNeeded(1), 10);
  assert.equal(xpNeeded(3), 20);
});

test('gainXp level-ups', () => {
  const p = new Player();
  assert.equal(p.gainXp(10), 1);
  assert.equal(p.level, 2);
  assert.equal(p.xp, 0);
  assert.equal(p.gainXp(15), 1); // 15 -> level 2 -> needs 15
  assert.equal(p.xp, 0); assert.equal(p.level, 3);
});

test('takeDamage clamps at 0', () => {
  const p = new Player();
  assert.equal(p.takeDamage(150), 0);
});

test('Enemy.update moves toward target', () => {
  const e = new Enemy('e', 10, 50);
  e.update(1, 30, 40); // dist 50, speed 50 -> step 50
  assert.ok(Math.hypot(e.x - 30, e.y - 40) < 0.001);
});

test('spawnWave', () => {
  const w = spawnWave(2);
  assert.equal(w.length, 2);
  assert.equal(w[0].id, 'e2_0');
  assert.equal(w[0].hp, 14);
  assert.equal(w[0].speed, 52);
  assert.equal(w[1].x, 220);
  assert.equal(w[1].y, 110);
});

test('nearestEnemy', () => {
  const es = [new Enemy('a', 1, 1), new Enemy('b', 1, 1)];
  es[0].x = 100; es[0].y = 0;
  es[1].x = 1; es[1].y = 1;
  assert.equal(nearestEnemy(es, 0, 0).id, 'b');
  assert.equal(nearestEnemy([], 0, 0), null);
});

test('tryAttack', () => {
  assert.ok(tryAttack(1.0, 0.5, 0.5));
  assert.ok(!tryAttack(0.9, 0.5, 0.5));
});

test('applyUpgrade', () => {
  const p = new Player();
  applyUpgrade(p, 'damage');
  assert.equal(p.damage, 15);
  applyUpgrade(p, 'speed');
  assert.equal(p.speed, 220);
  applyUpgrade(p, 'maxhp');
  assert.equal(p.maxHp, 120);
  assert.equal(p.hp, 120);
  assert.throws(() => applyUpgrade(p, 'bogus'));
});

test('Game.update wave and hit logic', () => {
  const g = new Game();
  g.update(31); // time=31 >= 30 -> wave 1 spawned
  assert.equal(g.wave, 1);
  assert.equal(g.events.filter(e => e === 'wave:1').length, 1);
  assert.equal(g.enemies.length, 1);
});
