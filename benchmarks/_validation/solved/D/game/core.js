export const CONFIG = {
  xpBase: 10, xpStep: 5, attackCooldown: 0.5,
  waveInterval: 30, attackRange: 150, hitRange: 15,
};
export function xpNeeded(level) { return CONFIG.xpBase + (level - 1) * CONFIG.xpStep; }
export class Player {
  constructor() { this.hp=100; this.maxHp=100; this.x=0; this.y=0; this.xp=0; this.level=1; this.damage=10; this.speed=200; }
  gainXp(n) { let ups=0; this.xp+=n; while(this.xp>=xpNeeded(this.level)){ this.xp-=xpNeeded(this.level); this.level++; ups++; } return ups; }
  takeDamage(n) { this.hp=Math.max(0,this.hp-n); return this.hp; }
}
export class Enemy {
  constructor(id,hp,speed){ this.id=id; this.hp=hp; this.speed=speed; this.x=0; this.y=0; }
  update(dt,px,py){ const dx=px-this.x, dy=py-this.y, d=Math.hypot(dx,dy); if(d>0){ this.x+=dx/d*this.speed*dt; this.y+=dy/d*this.speed*dt; } }
}
export function spawnWave(n){ const out=[]; for(let i=0;i<n;i++) out.push(new Enemy(`e${n}_${i}`,10+2*n,50+n)); for(let i=0;i<out.length;i++){out[i].x=200+i*20;out[i].y=100+i*10;} return out; }
export function nearestEnemy(enemies,px,py){ let best=null,bd=Infinity; for(const e of enemies){const d=(e.x-px)**2+(e.y-py)**2; if(d<bd){bd=d;best=e;}} return best; }
export function tryAttack(now,last,cooldown){ return now-last>=cooldown; }
export const UPGRADES=['damage','speed','maxhp'];
export function applyUpgrade(player,name){
  if(name==='damage') player.damage+=5;
  else if(name==='speed') player.speed+=20;
  else if(name==='maxhp'){ player.maxHp+=20; player.hp+=20; }
  else throw new Error('unknown upgrade');
}
export class Game {
  constructor(){ this.player=new Player(); this.time=0; this.wave=0; this.enemies=[]; this.lastAttack=0; this.events=[]; }
  update(dt){
    this.time+=dt;
    if(this.time>=(this.wave+1)*CONFIG.waveInterval){ this.wave++; this.enemies.push(...spawnWave(this.wave)); this.events.push('wave:'+this.wave); }
    const p=this.player;
    for(const e of this.enemies) e.update(dt,p.x,p.y);
    this.enemies=this.enemies.filter(e=>{ const d=Math.hypot(e.x-p.x,e.y-p.y); if(d<CONFIG.hitRange){ p.takeDamage(1); this.events.push('hit'); return false; } return true; });
    if(tryAttack(this.time,this.lastAttack,CONFIG.attackCooldown)){
      const t=nearestEnemy(this.enemies,p.x,p.y);
      if(t && Math.hypot(t.x-p.x,t.y-p.y)<=CONFIG.attackRange){ t.hp-=p.damage; this.lastAttack=this.time; this.events.push('attack'); }
    }
    this.enemies=this.enemies.filter(e=>{ if(e.hp<=0){ p.gainXp(5); this.events.push('kill'); return false; } return true; });
  }
}
