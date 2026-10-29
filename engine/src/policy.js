import {Dex} from '@pkmn/sim';
export const POLICY_VERSION='auto-v2';
function statusScore(move,own,foe,battle) {
  if(move.heal||move.id==='rest')return own.hp<own.maxhp?1:0;
  if(move.status) {
    if(foe.status||!Dex.getImmunity(move.status,foe))return 0;
    if(move.flags.powder&&!Dex.getImmunity('powder',foe))return 0;
    return 1;
  }
  if(move.boosts) {
    const self=move.target==='self';const target=self?own:foe;
    return Object.entries(move.boosts).some(([stat,delta])=>self?(delta>0&&target.boosts[stat]<2):(delta<0&&target.boosts[stat]>-2))?1:0;
  }
  if(move.volatileStatus){const target=move.target==='self'?own:foe;return target.volatiles[move.volatileStatus]?0:1;}
  if(move.weather)return battle.field.weather===move.weather?0:1;
  if(move.pseudoWeather)return battle.field.pseudoWeather[move.pseudoWeather]?0:1;
  if(move.sideCondition){const side=move.target==='allySide'?own.side:foe.side;return side.sideConditions[move.sideCondition]?0:1;}
  // Unmodelled utility gets one low-priority attempt, not an endless preference over damage.
  return battle.log.some(line=>line.startsWith(`|move|${own.side.id}a:`)&&Dex.moves.get(line.split('|')[3]).id===move.id)?0:1;
}
// auto-v1's score: expected damage (power × STAB × type, immune = 0) × accuracy, or 0/1 for a status move.
// `type` and `accuracy` may reshape the type multiplier and the hit chance (0-1); auto-v1 takes both as they are.
function score(c,move,{type=x=>x,accuracy=x=>x}={}) {
  if(move.category==='Status')return statusScore(move,c.own,c.foe,c.battle);
  const factor=Dex.getImmunity(move.type,c.foe)?type(2**Dex.getEffectiveness(move.type,c.foe)):0;
  return move.basePower*(c.own.getTypes().includes(move.type)?1.5:1)*factor*(move.accuracy===true?1:accuracy(move.accuracy/100));
}
// The highest score wins; a tie goes to the policy-seed draw (auto-v1).
function highest(moves,value,draw) {
  let top=-1,best=[];
  for(const m of moves){const s=value(m.move);if(s>top){top=s;best=[m.slot];}else if(s===top)best.push(m.slot);}
  return best[draw%best.length];
}
// A status condition for the foe or a raise of the user's own stats.
const setup=move=>move.category==='Status'&&(!!move.status||move.target==='self'&&!!move.boosts);
// auto-v1's "would still work" check, plus the move's own type immunity (Thunder Wave cannot touch Ground).
const useful=(c,move)=>statusScore(move,c.own,c.foe,c.battle)>0&&(move.ignoreImmunity||Dex.getImmunity(move.type,c.foe));
// Restores the user's HP at once.
const heal=move=>move.target==='self'&&(!!move.heal||['rest','moonlight','morningsun','synthesis'].includes(move.id));
const setupsUsed=c=>c.battle.log.filter(line=>line.startsWith(`|move|${c.own.side.id}a:`)&&setup(Dex.moves.get(line.split('|')[3]))).length;
// Murmur3's finalizer: the draw's bits spread evenly, for a weighted pick.
const spread=r=>{r^=r>>>16;r=Math.imul(r,0x85ebca6b);r^=r>>>13;r=Math.imul(r,0xc2b2ae35);return (r^r>>>16)>>>0;};
const policies={
  // auto-v1: the highest expected damage; a status move scores 1 while it would still work, so only when no attack scores more.
  standard:(c,moves,draw)=>highest(moves,m=>score(c,m),draw),
  // Power first: power × STAB, type only as immunity (0); accuracy weighs a quarter (a 70% move keeps 92.5%).
  aggressive:(c,moves,draw)=>highest(moves,m=>score(c,m,{type:()=>1,accuracy:a=>0.75+a/4}),draw),
  // At half HP or more, a working status or stat-raising move first (twice a battle); below half, a heal; else standard.
  tactical:(c,moves,draw)=>{
    const first=c.own.hp*2>=c.own.maxhp?(setupsUsed(c)<2?moves.filter(m=>setup(m.move)&&useful(c,m.move)):[]):moves.filter(m=>heal(m.move));
    return policies.standard(c,first.length?first:moves,draw);
  },
  // A random move weighted by its auto-v1 score, never one scoring 0; auto-v1 when nothing scores.
  erratic:(c,moves,draw)=>{
    const scored=moves.map(m=>({slot:m.slot,s:score(c,m.move)})).filter(m=>m.s>0);
    if(!scored.length)return policies.standard(c,moves,draw);
    let left=spread(draw)/0x100000000*scored.reduce((sum,m)=>sum+m.s,0);
    return (scored.find(m=>(left-=m.s)<0)||scored[scored.length-1]).slot;
  },
};
export const POLICIES=Object.keys(policies);
export function pickMove(record,side,legal) {
  const battle=record.battle;const own=battle.sides[side==='p1'?0:1].active[0];const foe=battle.sides[side==='p1'?1:0].active[0];
  // One draw per policy seed, turn and side, never from the battle RNG (auto-v1's tie-break).
  let draw=(record.config.policySeed ^ Math.imul(battle.turn,0x9e3779b9) ^ (side==='p1'?0:0x85ebca6b))>>>0;
  draw^=draw<<13;draw^=draw>>>17;draw^=draw<<5;
  const moves=legal.map(m=>({slot:m.slot,move:Dex.moves.get(m.id)}));
  return {slot:policies[record.config[side].policy||'standard']({battle,own,foe},moves,draw>>>0)};
}
