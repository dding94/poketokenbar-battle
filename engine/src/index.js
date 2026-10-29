import {Battle, State, Dex} from '@pkmn/sim';
import {validateConfig, fail, keys} from './input.js';
import {sha256} from './hash.js';
import {view, visibleLog, normalized} from './views.js';
const VERSION={engine:'@pkmn/sim@0.10.12',adapter:'1',rules:'gen9-notera-noitems-v1'};
const battles=new Map();let serial=0;
const get=id=>battles.get(id)||fail('unknown_battle');
const sideIndex=s=>s==='p1'?0:s==='p2'?1:fail('invalid_side');
const viewer=v=>v==='spectator'?v:(sideIndex(v),v);
function createBattle(config) {
  const sets=validateConfig(config);if(battles.size>=64)fail('battle_limit');
  const battle=new Battle({formatid:'gen9customgame@@@Terastal Clause',seed:config.seed});
  battle.reportExactHP=false;
  battle.setPlayer('p1',{name:'p1',team:[sets[0]]});battle.setPlayer('p2',{name:'p2',team:[sets[1]]});
  if(battle.sides[0].activeRequest?.teamPreview){battle.choose('p1','team 1');battle.choose('p2','team 1');}
  const id=`b${++serial}`;battles.set(id,{battle,config,choices:[],cursors:{p1:0,p2:0,spectator:0}});
  return {ok:true,id};
}
function request(id,side) {
  const b=get(id).battle;const s=b.sides[sideIndex(side)];
  if(b.ended)return {kind:'none',moves:[]};
  if(s.isChoiceDone()||!s.activeRequest?.active)return {kind:'wait',moves:[]};
  const moves=s.activeRequest.active[0].moves.map((m,i)=>({slot:i+1,id:m.id,name:m.move,
    type:Dex.moves.get(m.id).type||'Normal',pp:m.pp??1,maxpp:m.maxpp??1,disabled:!!m.disabled}));
  return {kind:moves.length===1&&['recharge','struggle'].includes(moves[0].id)?'forced':'move',moves};
}
function autoChoice(id,side) {
  const moves=request(id,side).moves.filter(m=>!m.disabled&&m.pp>0);
  if(!moves.length)fail('rejected');return {slot:moves[0].slot}; // PR 03 replaces this baseline.
}
function choose(id,side,choice) {
  const rec=get(id);sideIndex(side);
  if(!keys(choice,['type','slot'])||!['auto','move'].includes(choice.type))fail('invalid_choice');
  if(choice.type==='auto'&&Object.keys(choice).length!==1)fail('invalid_choice');
  const slot=choice.type==='auto'?autoChoice(id,side).slot:choice.slot;
  if(!Number.isInteger(slot)||slot<1||slot>4)fail('invalid_choice');
  const req=request(id,side);const move=req.moves.find(m=>m.slot===slot);
  if(!move||move.disabled)fail('rejected');
  const turn=rec.battle.turn;
  if(!rec.battle.choose(side,`move ${slot}`))fail('rejected');
  rec.choices.push({side,choice:{type:'move',slot}});
  if(rec.battle.turn>200&&!rec.battle.ended)rec.battle.forceWin();
  return {ok:true,resolved:rec.battle.ended||rec.battle.turn!==turn};
}
function result(id) {
  const r=get(id);const b=r.battle;
  return {ended:b.ended,winner:b.ended?(b.winner||null):null,turns:Math.min(b.turn,200),
    logHash:sha256(normalized(b.log).join('\n')),inputLog:{version:1,config:r.config,choices:r.choices}};
}
function destroy(id){const r=get(id);r.battle.destroy();battles.delete(id);return {ok:true};}
function replay(log) {
  if(!keys(log,['version','config','choices'])||log.version!==1||!Array.isArray(log.choices)||log.choices.length>400)fail('invalid_replay');
  const {id}=createBattle(log.config);
  try {
    for(const token of log.choices){if(!keys(token,['side','choice']))fail('invalid_replay');choose(id,token.side,token.choice);}
    const r=result(id);return {winner:r.winner,logHash:r.logHash};
  } finally {destroy(id);}
}
const api={version:()=>VERSION,createBattle,request,choose,autoChoice,
  state:(id,v)=>view(get(id).battle,viewer(v)),
  drainLog:(id,v)=>{viewer(v);const r=get(id);const lines=visibleLog(r.battle.log.slice(r.cursors[v]),v);r.cursors[v]=r.battle.log.length;return lines;},
  result,replay,destroy};
export function roundTrip(id){const r=get(id);const old=r.battle;r.battle=State.deserializeBattle(JSON.stringify(State.serializeBattle(old)));old.destroy();}
export const engine=Object.fromEntries(Object.entries(api).map(([name,fn])=>[name,(...args)=>{
  try {let values;try{values=args.map(JSON.parse);}catch{fail('invalid_json');}return JSON.stringify(fn(...values));}
  catch(e){return JSON.stringify({ok:false,error:/^(invalid_|unknown_|battle_limit|rejected)/.test(e.message)?e.message:'engine_failure'});}
}]));
globalThis.PTBEngine=engine;
