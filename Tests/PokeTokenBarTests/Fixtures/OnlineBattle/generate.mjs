// Run from repository root after bundling the server's battle-relay.ts as an ESM module.
// node Tests/PokeTokenBarTests/Fixtures/OnlineBattle/generate.mjs /absolute/path/to/battle-relay.mjs
import {readFileSync, writeFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
import vm from 'node:vm';
import {pathToFileURL} from 'node:url';
import assert from 'node:assert/strict';
const {journalBytes}=await import(pathToFileURL(process.argv[2]));
const context=vm.createContext({});
vm.runInContext(readFileSync('engine/dist/battle-engine.js','utf8'),context);
const call=(name,...args)=>{const r=JSON.parse(context.PTBEngine[name](...args.map(JSON.stringify)));if(r.ok===false)throw Error(r.error);return r;};
const hash=s=>createHash('sha256').update(s).digest('hex');
const set=(speciesNum,moves,ability='pressure')=>({speciesNum,form:null,level:50,gender:'genderless',nature:'hardy',ability,moves,ivs:{hp:31,attack:31,defense:31,'special-attack':31,'special-defense':31,speed:31},shiny:false});
const specs=[
 ['manual',set(25,['thunderbolt','quick-attack'],'static'),set(242,['tackle','splash']), n=>[{kind:'move',slot:n%2+1},{kind:'move',slot:1}]],
 ['auto',set(25,['thunderbolt'],'static'),set(27,['scratch'],'sand-veil'),()=>[{kind:'policy'},{kind:'policy'}]],
 ['timeout',set(151,['psybeam']),set(242,['pound']),n=>[{kind:n%2?'timeout':'move',...(n%2?{}:{slot:1})},{kind:'timeout'}]],
 ['recharge',set(151,['hyper-beam','splash']),set(242,['splash']),()=>[{kind:'move',slot:1},{kind:'move',slot:1}]],
 ['pp',set(151,['recover']),set(242,['recover']),()=>[{kind:'move',slot:4},{kind:'move',slot:1}]],
 ['imprison',set(151,['imprison','tackle']),set(242,['tackle','splash']),()=>[{kind:'move',slot:1},{kind:'move',slot:1}]],
 ['draw',set(151,['splash','growl','tail-whip','leer'],'synchronize'),set(151,['splash','growl','tail-whip','leer'],'synchronize'),()=>[{kind:'policy'},{kind:'policy'}]],
];
const fixtures=[];
for(const [name,p1set,p2set,tokens] of specs){
 const battleId=`fixture-${name}`, readyToken=`ready-${name}`;
 const snapshot=(s,i)=>{const info=call('describeSet',s);return{instanceId:i,set:s,public:info,hp:info.stats.hp};};
 const p1=snapshot(p1set,'instance-one'),p2=snapshot(p2set,'instance-two');
 if(name==='draw'){p1.hp=100;p2.hp=75;}
 const engineConfig={seed:[1,2,3,4],policySeed:42,p1:{name:'p1',set:p1set,hp:p1.hp,policy:'standard'},p2:{name:'p2',set:p2set,hp:p2.hp,policy:'standard'}};
 const config={readyToken,engineHash:readFileSync('engine/dist/battle-engine.sha256','utf8').split(/\s/)[0],rulesVersion:'gen9-notera-noitems-v1',policyVersion:'auto-v2',relayVersion:'relay-v1',...engineConfig};
 const {id}=call('createBattle',engineConfig),journal=[];
 let rejectionCount=0,forcedCount=0;
 for(let n=1;n<=200&&!call('result',id).ended;n++){
  const [a,b]=tokens(n),pair={roundSeq:n,p1:a,p2:b,releasedAt:1000+n*30000};
  for(const side of ['p1','p2']){
   let request=call('request',id,side);if(['none','wait'].includes(request.kind))continue;
   let token=pair[side];if(request.kind==='forced'){forcedCount++;token={kind:'policy'};}
   let accepted=false;
   for(let attempt=0;attempt<6;attempt++){
    const slot=attempt===0&&token.kind==='move'?token.slot:call('autoChoice',id,side).slot;
    try{call('choose',id,side,{type:'move',slot});accepted=true;break;}
    catch(e){assert.equal(e.message,'rejected');rejectionCount++;request=call('request',id,side);}
   }
   assert.equal(accepted,true);
  }
  journal.push(pair);
 }
 const r=call('result',id);assert.equal(r.ended,true);
 const bytes=journalBytes(battleId,readyToken,journal);
 const report={readyToken,engineHash:config.engineHash,terminalSeq:journal.length,winner:r.winner??'draw',logHash:r.logHash,journalHash:hash(bytes),finalHp:{p1:call('state',id,'p1').p1.hp,p2:call('state',id,'p2').p2.hp}};
 const battle={battleId,state:'COMPLETED',revision:2,mode:name==='auto'||name==='draw'?'auto':'manual',p1:{trainerId:'trainer-one',snapshot:p1},p2:{trainerId:'trainer-two',snapshot:p2},createdAt:0,expiresAt:86400000,startedAt:1,reportedAt:100,confirmed:true,config,roundSeq:journal.length,deadline:null,ownChoice:null,journal,result:report,reason:null,rematchOf:null};
 fixtures.push({name,battle,journalBytes:bytes,inputLog:r.inputLog,rejectionCount,forcedCount});call('destroy',id);
}
writeFileSync('Tests/PokeTokenBarTests/Fixtures/OnlineBattle/golden.json','[\n'+fixtures.map(x=>JSON.stringify(x)).join(',\n')+'\n]\n');
console.log(fixtures.map(x=>({name:x.name,rounds:x.battle.journal.length,winner:x.battle.result.winner,rejections:x.rejectionCount,forced:x.forcedCount})));
