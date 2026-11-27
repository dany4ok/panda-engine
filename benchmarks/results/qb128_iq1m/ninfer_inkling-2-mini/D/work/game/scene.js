// Three.js rendering scene. Wire it to the mechanics in core.js.
import * as THREE from '../vendor/three.module.min.js';
import { Game, CONFIG } from './core.js';

const game = new Game();

const scene = new THREE.Scene();
scene.background = new THREE.Color(0x0b0b12);

const camera = new THREE.PerspectiveCamera(60, window.innerWidth / window.innerHeight, 0.1, 1000);
camera.position.set(0, 0, 300);
camera.lookAt(0, 0, 0);

const renderer = new THREE.WebGLRenderer({ antialias: true });
renderer.setSize(window.innerWidth, window.innerHeight);
renderer.setPixelRatio(window.devicePixelRatio);
document.body.appendChild(renderer.domElement);

const ambient = new THREE.AmbientLight(0xffffff, 0.6);
scene.add(ambient);
const dir = new THREE.DirectionalLight(0xffffff, 0.8);
dir.position.set(100, 200, 200);
scene.add(dir);

const playerMesh = new THREE.Mesh(
  new THREE.SphereGeometry(12, 16, 16),
  new THREE.MeshStandardMaterial({ color: 0x4cd964 })
);
scene.add(playerMesh);

const enemyMeshMap = new Map();

function getEnemyMesh(e) {
  let m = enemyMeshMap.get(e.id);
  if (!m) {
    m = new THREE.Mesh(
      new THREE.BoxGeometry(14, 14, 14),
      new THREE.MeshStandardMaterial({ color: 0xe74c3c })
    );
    scene.add(m);
    enemyMeshMap.set(e.id, m);
  }
  return m;
}

const hpEl = document.getElementById('hp');
const xpEl = document.getElementById('xp');
const lvEl = document.getElementById('lv');

function syncMeshes() {
  const ids = new Set(game.enemies.map(e => e.id));
  for (const [id, m] of enemyMeshMap) {
    if (!ids.has(id)) {
      scene.remove(m);
      enemyMeshMap.delete(id);
    }
  }
  for (const e of game.enemies) {
    const m = getEnemyMesh(e);
    m.position.set(e.x, e.y, 0);
  }
  playerMesh.position.set(game.player.x, game.player.y, 0);
}

function updateHud() {
  hpEl.textContent = String(game.player.hp);
  xpEl.textContent = String(game.player.xp);
  lvEl.textContent = String(game.player.level);
}

window.addEventListener('resize', () => {
  camera.aspect = window.innerWidth / window.innerHeight;
  camera.updateProjectionMatrix();
  renderer.setSize(window.innerWidth, window.innerHeight);
});

let last = performance.now();
function loop(now) {
  const dt = Math.min((now - last) / 1000, 0.1);
  last = now;
  game.update(dt);
  syncMeshes();
  updateHud();
  renderer.render(scene, camera);
  requestAnimationFrame(loop);
}
requestAnimationFrame(loop);

console.log('scene boot', CONFIG.waveInterval, game.player.hp);
