// Hidden deterministic test for the game core. Copied into the work dir at eval time.
import { writeFileSync } from 'node:fs';
import { xpNeeded, Player, Enemy, spawnWave, nearestEnemy, tryAttack, applyUpgrade, Game } from './game/core.js';

const results = [];
function t(name, fn) {
  try { results.push({ name, passed: !!fn() }); }
  catch (e) { results.push({ name, passed: false, error: String(e) }); }
}

t('xpNeeded_1', () => xpNeeded(1) === 10);
t('xpNeeded_3', () => xpNeeded(3) === 20);
t('gainXp_one', () => { const p = new Player(); return p.gainXp(10) === 1 && p.level === 2 && p.xp === 0; });
t('gainXp_two', () => { const p = new Player(); return p.gainXp(25) === 2 && p.level === 3 && p.xp === 0; });
t('takeDamage', () => { const p = new Player(); return p.takeDamage(30) === 70 && p.takeDamage(1000) === 0; });
t('enemy_move', () => { const e = new Enemy('x', 10, 10); e.update(1, 100, 0); return Math.abs(e.x - 10) < 1e-6 && Math.abs(e.y) < 1e-6; });
t('spawnWave', () => {
  const w = spawnWave(2);
  return w.length === 2 && w[0].hp === 14 && w[0].speed === 52 &&
    w[0].id === 'e2_0' && w[1].id === 'e2_1' && w[0].x === 200 && w[0].y === 100;
});
t('nearest', () => {
  const a = new Enemy('a', 1, 0), b = new Enemy('b', 1, 0);
  a.x = 50; a.y = 0; b.x = 5; b.y = 0;
  return nearestEnemy([a, b], 0, 0) === b && nearestEnemy([], 0, 0) === null;
});
t('tryAttack', () => tryAttack(1, 0, 0.5) === true && tryAttack(0.4, 0, 0.5) === false);
t('upgrades', () => {
  const p = new Player();
  applyUpgrade(p, 'damage'); applyUpgrade(p, 'speed'); applyUpgrade(p, 'maxhp');
  let ok = p.damage === 15 && p.speed === 220 && p.maxHp === 120 && p.hp === 120;
  try { applyUpgrade(p, 'bogus'); ok = false; } catch (_) {}
  return ok;
});
t('game_wave', () => {
  const g = new Game();
  for (let i = 0; i < 30; i++) g.update(1);
  // wave 1 spawns spawnWave(1) -> exactly 1 enemy (per REQUIREMENT.md)
  return g.wave === 1 && g.enemies.length === 1 && g.events.includes('wave:1');
});
t('game_kill_xp', () => {
  const g = new Game();
  const e = new Enemy('t', 5, 0); e.x = 40; e.y = 0;
  g.enemies = [e];
  g.update(0.6);
  return g.events.includes('attack') && g.events.includes('kill') && g.player.xp === 5 && g.enemies.length === 0;
});

writeFileSync('__hidden_results.json', JSON.stringify({ results }, null, 2));
