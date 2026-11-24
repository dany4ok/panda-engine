// TODO: implement sprite animation state machine + HUD updates.
// Frames: 0 = idle, 1 = run right, 2 = run left, 3 = hurt.
const state = { hp: 100, maxHp: 100, xp: 0, level: 1 };
let mode = 'idle';

// TODO: load ./assets/atlas.png, draw current frame on #stage,
// update #hp/#xp/#lv/#hpbar/#xpbar from state,
// requestAnimationFrame loop, #run toggle, #hurt -> 0.3s hurt then idle.

console.log('hud boot', state.hp, mode);
