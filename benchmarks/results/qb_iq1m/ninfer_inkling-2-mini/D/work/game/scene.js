// Three.js rendering scene. Wire it to the mechanics in core.js.
import * as THREE from '../vendor/three.module.min.js';
import { Game, CONFIG } from './core.js';

const game = new Game();

const scene = new THREE.Scene();
scene.background = new THREE.Color(0x0b0b12);

const camera = new THREE.PerspectiveCamera(60, window.innerWidth / window.innerHeight, 0.1, 1000);
camera.position.set(0, 300, 200);
camera.lookAt(0, 0, 0);

const renderer = new THREE.WebGLRenderer({ antialias: true });
renderer.setSize(window.innerWidth, window.innerHeight);
renderer.setPixelRatio(window.devicePixelRatio);
document.body.appendChild(renderer.domElement);

scene.add(new THREE.AmbientLight(0xffffff, 0.7));
const dir = new THREE.DirectionalLight(0xffffff, 0.8);
dir.position.set(50, 100, 50);
scene.add(dir);

const ground = new THREE.Mesh(
  new THREE.PlaneGeometry(2000, 2000),
  new THREE.MeshStandardMaterial({ color: 0x1a1a2e })
);
ground.rotation.x = -Math.PI / 2;
ground.position.y = -5;
scene.add(ground);

const playerMesh = new THREE.Mesh(
  new THREE.CylinderGeometry(10, 10, 20, 16),
  new THREE.MeshStandardMaterial({ color: 0x4ade80, emissive: 0x1a3a1a })
);
playerMesh.position.set(0, 10, 0);
scene.add(playerMesh);

const enemyGeo = new THREE.SphereGeometry(8, 12, 12);
const enemyMat = new THREE.MeshStandardMaterial({ color: 0xf87171, emissive: 0x3a1a1a });
const enemyMeshes = new Map();

const hpEl = document.getElementById('hp');
const xpEl = document.getElementById('xp');
const lvEl = document.getElementById('lv');

window.addEventListener('resize', () => {
  camera.aspect = window.innerWidth / window.innerHeight;
  camera.updateProjectionMatrix();
  renderer.setSize(window.innerWidth, window.innerHeight);
});

let last = performance.now();

function loop(now) {
  requestAnimationFrame(loop);
  const dt = Math.min((now - last) / 1000, 0.1);
  last = now;
  game.update(dt);

  playerMesh.position.set(game.player.x, 10, game.player.y);
  const seen = new Set();
  for (const e of game.enemies) {
    seen.add(e.id);
    let mesh = enemyMeshes.get(e.id);
    if (!mesh) {
      mesh = new THREE.Mesh(enemyGeo, enemyMat);
      scene.add(mesh);
      enemyMeshes.set(e.id, mesh);
    }
    mesh.position.set(e.x, 8, e.y);
  }
  for (const [id, mesh] of enemyMeshes) {
    if (!seen.has(id)) {
      scene.remove(mesh);
      enemyMeshes.delete(id);
    }
  }

  hpEl.textContent = String(game.player.hp);
  xpEl.textContent = String(game.player.xp);
  lvEl.textContent = String(game.player.level);

  renderer.render(scene, camera);
}

requestAnimationFrame(loop);
console.log('scene boot', CONFIG.waveInterval, game.player.hp);
