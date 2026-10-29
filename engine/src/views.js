import {toID} from '@pkmn/sim';
export const normalized = log => log.filter(line=>!line.startsWith('|t:|'));
export function visibleLog(log,viewer) {
  const out=[];
  for(let i=0;i<log.length;i++) {
    if(log[i].startsWith('|split|')) {out.push(log[i+1+(log[i].slice(7)!==viewer?1:0)]);i+=2;}
    else out.push(log[i]);
  }
  return normalized(out.filter(line=>typeof line==='string'));
}
export function revealed(log) {
  const seen={p1:{moves:[],ability:null},p2:{moves:[],ability:null}};
  for(const line of log) {
    const p=line.split('|');const side=p[2]?.slice(0,2);
    if(p[1]==='move'&&seen[side]&&!seen[side].moves.includes(toID(p[3])))seen[side].moves.push(toID(p[3]));
    if(p[1]==='-ability'&&seen[side])seen[side].ability=toID(p[3]);
    const source=p.find(x=>x.startsWith('[from] ability: '));
    const of=p.find(x=>x.startsWith('[of] '));
    const owner=of?of.slice(5,7):side;
    if(source&&seen[owner])seen[owner].ability=toID(source.slice(16));
  }
  return seen;
}
export function view(battle,viewer) {
  const known=revealed(visibleLog(battle.log,viewer));const out={turn:Math.min(battle.turn,200),ended:battle.ended};
  for(const side of battle.sides) {
    const p=side.active[0]||side.pokemon[0];const own=side.id===viewer;
    const health=(own?p.getHealth().secret:p.getHealth().shared).split(' ')[0].split('/');
    out[side.id]={speciesNum:p.species.num,species:p.species.name,level:p.level,types:p.getTypes(),
      hp:Number(health[0]),maxhp:own?p.maxhp:100,status:p.status,
      moves:own?p.moves:known[side.id].moves,ability:own?p.ability:known[side.id].ability};
  }
  return out;
}
