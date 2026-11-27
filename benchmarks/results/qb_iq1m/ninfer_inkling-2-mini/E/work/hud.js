// Sprite animation state machine + HUD updates.
// Frames: 0 = idle, 1 = run right, 2 = run left, 3 = hurt.
const state = { hp: 100, maxHp: 100, xp: 0, level: 1 };
let mode = 'idle'; // 'idle' | 'run' | 'hurt'
let hurtUntil = 0;
const ANIM_INTERVAL = 120; // ms per frame

const canvas = document.getElementById('stage');
const ctx = canvas.getContext('2d');
const atlas = new Image();
atlas.src = './assets/atlas.png';

function frameFor(m, t) {
  if (m === 'idle') return 0;
  if (m === 'hurt') return 3;
  return Math.floor(t / ANIM_INTERVAL) % 2 === 0 ? 1 : 2;
}

function updateHud() {
  document.getElementById('hp').textContent = state.hp;
  const maxHpEl = document.getElementById('maxhp');
  if (maxHpEl) maxHpEl.textContent = state.maxHp;
  document.getElementById('xp').textContent = state.xp;
  document.getElementById('lv').textContent = state.level;
  document.getElementById('hpbar').style.width = (state.hp / state.maxHp * 100) + '%';
  const xpMax = state.level * 100;
  document.getElementById('xpbar').style.width = Math.min(100, state.xp / xpMax * 100) + '%';
}

function draw(t) {
  ctx.imageSmoothingEnabled = false;
  ctx.clearRect(0, 0, canvas.width, canvas.height);
  if (atlas.complete && atlas.naturalWidth > 0) {
    const f = frameFor(mode, t);
    ctx.drawImage(atlas, f * 16, 0, 16, 16, 0, 0, canvas.width, canvas.height);
  }
}

function loop(t) {
  if (mode === 'hurt' && t >= hurtUntil) mode = 'idle';
  draw(t);
  updateHud();
  requestAnimationFrame(loop);
}

document.getElementById('run').addEventListener('click', () => {
  mode = mode === 'run' ? 'idle' : 'run';
});
document.getElementById('hurt').addEventListener('click', () => {
  mode = 'hurt';
  hurtUntil = performance.now() + 300;
});

updateHud();
requestAnimationFrame(loop);
