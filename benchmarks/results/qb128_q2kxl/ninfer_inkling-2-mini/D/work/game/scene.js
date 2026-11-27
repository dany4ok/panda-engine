// Three.js rendering scene. Wire it to the mechanics in core.js.
import * as THREE from '../vendor/three.module.min.js';
import { Game, CONFIG } from './core.js';

const game = new Game();

const scene = new THREE.Scene();
scene.background = new THREE.Color(0x0b0b12);

const camera = new THREE.PerspectiveCamera(60, window.innerWidth / window.innerHeight, 0.1, 1000);
camera.position.set(0, 300, 300);
camera.lookAt(0, 0, 0);

const renderer = new THREE.WebGLRenderer({ antialias: true });
renderer.setSize(window.innerWidth, window.innerHeight);
renderer.setPixelRatio(window.devicePixelRatio);
document.body.appendChild(renderer.domElement);

const ambient = new THREE.AmbientLight(0xffffff, 0.6);
scene.add(ambient);
const dir = new THREE.DirectionalLight(0xffffff, 1.0);
dir.position.set(100, 200, 100);
scene.add(dir);

const floor = new THREE.Mesh(
  new THREE.PlaneGeometry(2000, 2000),
  new THREE.MeshStandardMaterial({ color: 0x14141f })
);
floor.rotation.x = -Math.PI / 2;
scene.add(floor);

const playerMesh = new THREE.Mesh(
  new THREE.SphereGeometry(10, 16, 16),
  new THREE.MeshStandardMaterial({ color: 0x4ade80 })
);
playerMesh.position.set(0, 10, 0);
scene.add(playerMesh);

const enemyMeshes = new Map();

function syncEnemyMeshes() {
  const seen = new Set();
  for (const e of game.enemies) {
    seen.add(e.id);
    let mesh = enemyMeshes.get(e.id);
    if (!mesh) {
      mesh = new THREE.Mesh(
        new THREE.BoxGeometry(8, 8, 8),
        new THREE.MeshStandardMaterial({ color: 0xef4444 })
      );
      scene.add(mesh);
      enemyMeshes.set(e.id, mesh);
    }
    mesh.position.set(e.x, 4, e.y);
  }
  for (const [id, mesh] of enemyMeshes) {
    if (!seen.has(id)) {
      scene.remove(mesh);
      mesh.geometry.dispose();
      mesh.material.dispose();
      enemyMeshes.delete(id);
    }
  }
  playerMesh.position.set(game.player.x, 10, game.player.y);
}

const hpEl = document.getElementById('hp');
const xpEl = document.getElementById('xp');
const lvEl = document.getElementById('lv');

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
  syncEnemyMeshes();
  updateHud();
  renderer.render(scene, camera);
  requestAnimationFrame(loop);
}

console.log('scene boot', CONFIG.waveInterval, game.player.hp);
requestAnimationFrame(loop);
