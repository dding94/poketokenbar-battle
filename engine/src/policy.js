import {Dex} from '@pkmn/sim';
export const POLICY_VERSION='auto-v1';
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
export function pickMove(record,side,legal) {
  const b=record.battle;const own=b.sides[side==='p1'?0:1].active[0];const foe=b.sides[side==='p1'?1:0].active[0];
  let highest=-1,best=[];
  for(const candidate of legal) {
    const move=Dex.moves.get(candidate.id);let score;
    if(move.category==='Status')score=statusScore(move,own,foe,b);
    else {
      const factor=Dex.getImmunity(move.type,foe)?2**Dex.getEffectiveness(move.type,foe):0;
      score=move.basePower*(own.getTypes().includes(move.type)?1.5:1)*factor*(move.accuracy===true?1:move.accuracy/100);
    }
    if(score>highest){highest=score;best=[candidate.slot];}else if(score===highest)best.push(candidate.slot);
  }
  let random=(record.config.policySeed ^ Math.imul(b.turn,0x9e3779b9) ^ (side==='p1'?0:0x85ebca6b))>>>0;
  random^=random<<13;random^=random>>>17;random^=random<<5;
  return {slot:best[(random>>>0)%best.length]};
}
