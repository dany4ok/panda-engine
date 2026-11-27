// Frames: 0 = idle, 1 = run right, 2 = run left, 3 = hurt.
const state = { hp: 100, maxHp: 100, xp: 0, level: 1 };
let mode = 'idle';
let hurtUntil = 0;
let runFlip = false;
let lastAnim = 0;
let currentFrame = 0;

const canvas = document.getElementById('stage');
const ctx = canvas.getContext('2d');
const img = new Image();
img.src = './assets/atlas.png';

function updateHud() {
  document.getElementById('hp').textContent = state.hp;
  document.getElementById('xp').textContent = state.xp;
  document.getElementById('lv').textContent = state.level;
  document.getElementById('hpbar').style.width = (100 * state.hp / state.maxHp) + '%';
  document.getElementById('xpbar').style.width = (Math.min(100, state.xp % 100)) + '%';
}

function frameFor(now) {
  if (mode === 'hurt') return 3;
  if (mode === 'run') {
    if (now - lastAnim > 150) { runFlip = !runFlip; lastAnim = now; }
    return runFlip ? 2 : 1;
  }
  return 0;
}

function draw(now) {
  currentFrame = frameFor(now);
  ctx.clearRect(0, 0, canvas.width, canvas.height);
  if (img.complete && img.naturalWidth) {
    const scale = canvas.height / 16;
    ctx.drawImage(img, currentFrame * 16, 0, 16, 16, (canvas.width - 16 * scale) / 2, 0, 16 * scale, 16 * scale);
  }
  updateHud();
  if (mode === 'hurt' && now >= hurtUntil) mode = 'idle';
  requestAnimationFrame(draw);
}

document.getElementById('run').addEventListener('click', () => {
  mode = mode === 'run' ? 'idle' : 'run';
  runFlip = false;
  lastAnim = performance.now();
});
document.getElementById('hurt').addEventListener('click', () => {
  mode = 'hurt';
  hurtUntil = performance.now() + 300;
});

updateHud();
requestAnimationFrame(draw);
