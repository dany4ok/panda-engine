import * as THREE from '../vendor/three.module.min.js';
import { Game, CONFIG } from './core.js';
const game = new Game();
const scene = new THREE.Scene();
const camera = new THREE.PerspectiveCamera(60, 1, 0.1, 1000);
camera.position.z = 300;
const renderer = new THREE.WebGLRenderer();
document.body.appendChild(renderer.domElement);
const playerMesh = new THREE.Mesh(new THREE.BoxGeometry(20,20,20), new THREE.MeshBasicMaterial({color:0x44aa88}));
scene.add(playerMesh);
const hp = document.getElementById('hp');
const xp = document.getElementById('xp');
const lv = document.getElementById('lv');
let last = performance.now();
function frame(now){
  const dt = Math.min(0.1, (now-last)/1000); last = now;
  game.update(dt);
  playerMesh.position.set(game.player.x, game.player.y, 0);
  hp.textContent = game.player.hp; xp.textContent = game.player.xp; lv.textContent = game.player.level;
  renderer.render(scene, camera);
  requestAnimationFrame(frame);
}
requestAnimationFrame(frame);
console.log('scene boot', CONFIG.waveInterval, game.player.hp);
