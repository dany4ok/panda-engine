// Sprite animation state machine + HUD updates.
// Frames: 0 = idle, 1 = run right, 2 = run left, 3 = hurt.
const state = { hp: 100, maxHp: 100, xp: 0, level: 1 };
let mode = 'idle'; // idle | run | hurt
let hurtUntil = 0;
const hurtDuration = 300; // ms

const stage = document.getElementById('stage');
const ctx = stage.getContext('2d');
const atlas = new Image();
atlas.src = './assets/atlas.png';

function frameFor(m, t) {
  if (m === 'idle') return 0;
  if (m === 'run') return (Math.floor(t / 120) % 2 === 0) ? 1 : 2;
  if (m === 'hurt') return 3;
  return 0;
}

function updateHud() {
  document.getElementById('hp').textContent = state.hp;
  document.getElementById('xp').textContent = state.xp;
  document.getElementById('lv').textContent = state.level;
  const hpPct = Math.max(0, Math.min(1, state.hp / state.maxHp)) * 100;
  document.getElementById('hpbar').style.width = hpPct + '%';
  const xpPct = Math.max(0, Math.min(1, state.xp)) * 100;
  document.getElementById('xpbar').style.width = xpPct + '%';
}

function draw(t) {
  ctx.clearRect(0, 0, stage.width, stage.height);
  // keep last hurt timing: hurt mode lasts ~0.3s then back to idle
  if (mode === 'hurt' && t >= hurtUntil) mode = 'idle';
  const f = frameFor(mode, t);
  const scale = 8;
  const w = 16 * scale, h = 16 * scale;
  const x = (stage.width - w) / 2, y = (stage.height - h) / 2;
  ctx.imageSmoothingEnabled = false;
  ctx.drawImage(atlas, f * 16, 0, 16, 16, x, y, w, h);
  updateHud();
  requestAnimationFrame(draw);
}

document.getElementById('run').addEventListener('click', () => {
  if (mode !== 'hurt') mode = (mode === 'run') ? 'idle' : 'run';
});
document.getElementById('hurt').addEventListener('click', () => {
  mode = 'hurt';
  hurtUntil = performance.now() + hurtDuration;
});

updateHud();
requestAnimationFrame(draw);
