import test from 'node:test';
import assert from 'node:assert';
import { xpNeeded, Player, Enemy, spawnWave, nearestEnemy, tryAttack, applyUpgrade, Game } from './core.js';

test('xpNeeded', () => {
  assert.equal(xpNeeded(1), 10);
  assert.equal(xpNeeded(2), 15);
  assert.equal(xpNeeded(3), 20);
});

test('gainXp level-ups', () => {
  const p = new Player();
  assert.equal(p.gainXp(10), 1);
  assert.equal(p.level, 2);
  assert.equal(p.xp, 0);
  assert.equal(p.gainXp(25), 1);
  assert.equal(p.level, 3);
});

test('takeDamage floors at 0', () => {
  const p = new Player();
  assert.equal(p.takeDamage(150), 0);
  assert.equal(p.hp, 0);
});

test('Enemy.update moves toward target', () => {
  const e = new Enemy('x', 10, 100);
  e.update(0.5, 30, 40);
  assert.equal(e.x, 30); // 50 units toward target, dist=50
  assert.equal(e.y, 40);
});

test('spawnWave', () => {
  const es = spawnWave(2);
  assert.equal(es.length, 2);
  assert.equal(es[0].id, 'e2_0');
  assert.equal(es[0].hp, 14);
  assert.equal(es[1].speed, 52);
  assert.equal(es[1].x, 220);
  assert.equal(es[1].y, 110);
});

test('nearestEnemy', () => {
  const es = [new Enemy('a', 1, 1), new Enemy('b', 1, 1)];
  es[0].x = 10; es[0].y = 0;
  es[1].x = 0; es[1].y = 10;
  assert.equal(nearestEnemy(es, 1, 0), es[0]);
  assert.equal(nearestEnemy([], 0, 0), null);
});

test('tryAttack', () => {
  assert.equal(tryAttack(10, 9.5, 0.5), true);
  assert.equal(tryAttack(10, 9.9, 0.5), false);
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
  assert.throws(() => applyUpgrade(p, 'foo'));
});

test('Game.update wave spawn', () => {
  const g = new Game();
  g.update(30);
  assert.equal(g.wave, 1);
  assert.ok(g.events.includes('wave:1'));
});
