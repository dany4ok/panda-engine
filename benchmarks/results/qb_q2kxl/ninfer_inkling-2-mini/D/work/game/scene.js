// Three.js rendering scene. Wire it to the mechanics in core.js.
import * as THREE from '../vendor/three.module.min.js';
import { Game, CONFIG } from './core.js';

const game = new Game();

// TODO: create scene, camera, WebGLRenderer, player mesh, HUD refs,
// resize handler, animation loop with requestAnimationFrame calling
// game.update(dt) and renderer.render(scene, camera).
// Keep enemy meshes in sync with game.enemies (create/remove as needed).

console.log('scene boot', CONFIG.waveInterval, game.player.hp);
