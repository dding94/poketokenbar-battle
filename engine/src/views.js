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
export function revealEvents(log) {
  const seen=new Set(),events=[];let turn=0;
  const add=(kind,side,value)=>{const id=toID(value);const key=`${kind}/${side}/${id}`;
    if(!['p1','p2'].includes(side)||!id||seen.has(key))return;
    seen.add(key);events.push({kind,side,id,turn});};
  for(const line of log) {
    const p=line.split('|');const side=p[2]?.slice(0,2);const of=p.find(x=>x.startsWith('[of] '))?.slice(5,7);
    if(p[1]==='turn'){turn=Number(p[2]);continue;}
    if(p[1]==='move')add('move',side,p[3]);
    const from=p.find(x=>x.startsWith('[from] ability: '));
    if(p[1]==='-ability') {
      if(from){const source=from.slice(16);add('ability',toID(source)==='trace'?side:(of||side),source);}
      add('ability',side,p[3]);
      if(from?.endsWith('Trace')||p.includes('[from] move: Role Play'))add('ability',of,p[3]);
    } else {
      if(from)add('ability',of||side,from.slice(16));
      const direct=p.find(x=>x.startsWith('ability: '));
      if(direct)add('ability',p[1]==='-block'?(of||side):side,direct.slice(9));
      if(p[1]==='-activate'&&p[3]==='Skill Swap'){
        add('ability',side,p[4]);add('ability',of,p[5]);
      }
    }
  }
  return events;
}
export function view(battle,viewer) {
  const events=revealEvents(visibleLog(battle.log,viewer));const out={turn:Math.min(battle.turn,200),ended:battle.ended};
  for(const side of battle.sides) {
    const p=side.active[0]||side.pokemon[0];const own=side.id===viewer;
    const health=(own?p.getHealth().secret:p.getHealth().shared).split(' ')[0].split('/');
    out[side.id]={speciesNum:p.species.num,species:p.species.name,level:p.level,types:p.getTypes(),
      hp:Number(health[0]),maxhp:own?p.maxhp:100,status:p.status,
      moves:own?p.moves:events.filter(e=>e.side===side.id&&e.kind==='move').map(e=>e.id),
      ability:own||events.some(e=>e.side===side.id&&e.kind==='ability'&&e.id===p.ability)?p.ability:null};
  }
  return out;
}
