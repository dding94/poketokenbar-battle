const {test}=require('node:test');const assert=require('node:assert/strict');
const {readFileSync}=require('node:fs');const vm=require('node:vm');
const context=vm.createContext({});vm.runInContext(readFileSync('dist/battle-engine.js','utf8'),context);
const call=(name,...args)=>JSON.parse(context.PTBEngine[name](...args.map(JSON.stringify)));
const set=(speciesNum,moves,ability='pressure')=>({speciesNum,form:null,level:50,gender:'genderless',nature:'hardy',ability,moves,
  ivs:{hp:31,attack:31,defense:31,'special-attack':31,'special-defense':31,speed:31},shiny:false});
const battle=(p1,p2=set(242,['splash']),policySeed=42)=>{
  const r=call('createBattle',{seed:[1,2,3,4],policySeed,p1:{name:'p1',set:p1},p2:{name:'p2',set:p2}});assert.equal(r.ok,true);return r.id;
};
const pick=(id,side='p1')=>call('autoChoice',id,side).slot;
const move=(id,side,slot)=>call('choose',id,side,{type:'move',slot});
const round=(id,a=1,b=1)=>{assert.equal(move(id,'p1',a).ok,true);assert.equal(move(id,'p2',b).ok,true);};

test('policy prefers damage, STAB and accuracy over an ineffective status move',()=>{
  assert.equal(pick(battle(set(25,['splash','thunderbolt'],'static'))),2);
  assert.equal(pick(battle(set(25,['thunder','thunderbolt'],'static'))),2);
});
test('policy scores a type immunity as zero',()=>{
  assert.equal(pick(battle(set(25,['thunderbolt','quick-attack'],'static'),set(27,['splash'],'sand-veil'))),2);
});
test('boosts stop at +2 and existing status is not reapplied',()=>{
  const boost=battle(set(151,['swords-dance','splash']));round(boost);
  assert.equal(pick(boost),2);
  const status=battle(set(151,['glare','splash']));round(status);
  assert.equal(pick(status),2);
});
test('ties use policy seed without consuming battle RNG or changing a repeated answer',()=>{
  const slots=new Set();
  for(let seed=1;seed<=8;seed++){
    const id=battle(set(25,['tackle','scratch'],'static'),undefined,seed);
    const before=call('result',id).logHash;const slot=pick(id);slots.add(slot);
    assert.equal(pick(id),slot);assert.equal(call('result',id).logHash,before);call('destroy',id);
  }
  assert.equal(slots.size,2);
});
test('PP exhaustion and recharge are legal forced choices',()=>{
  const id=battle(set(151,['recover']),set(242,['recover']));
  for(let i=0;i<8;i++)round(id);
  assert.equal(call('request',id,'p1').moves[0].id,'struggle');assert.equal(pick(id),1);
  const recharge=battle(set(151,['hyper-beam']));round(recharge);
  assert.equal(call('request',recharge,'p1').kind,'forced');assert.equal(pick(recharge),1);
});
test('hidden Imprison rejection refreshes the request and can be retried deterministically',()=>{
  const id=battle(set(151,['imprison','tackle']),set(242,['tackle','splash']));round(id);
  assert.deepEqual(move(id,'p2',1),{ok:false,error:'rejected'});
  assert.equal(call('request',id,'p2').moves[0].disabled,true);
  assert.equal(pick(id,'p2'),2);assert.equal(move(id,'p2',2).ok,true);assert.equal(move(id,'p1',1).ok,true);
  const r=call('result',id);assert.deepEqual(call('replay',r.inputLog),{winner:r.winner,logHash:r.logHash});
});
test('moves and activated abilities are revealed only once per viewer',()=>{
  const id=battle(set(25,['ember'],'static'),set(37,['splash'],'flash-fire'));
  assert.deepEqual(call('state',id,'p1').p2.moves,[]);assert.equal(call('state',id,'p1').p2.ability,null);
  round(id);const events=call('drainEvents',id,'p1');
  assert.ok(events.some(e=>e.kind==='move'&&e.side==='p1'&&e.id==='ember'));
  assert.ok(events.some(e=>e.kind==='ability'&&e.side==='p2'&&e.id==='flashfire'));
  assert.deepEqual(call('drainEvents',id,'p1'),[]);
  assert.ok(call('drainEvents',id,'p2').length>=events.length);
  round(id);assert.deepEqual(call('drainEvents',id,'p1'),[]);
  assert.equal(call('state',id,'p1').p2.ability,'flashfire');
});
test('entry abilities are revealed and replay policy versions are explicit',()=>{
  const id=battle(set(151,['tackle']));
  assert.ok(call('drainEvents',id,'spectator').some(e=>e.kind==='ability'&&e.id==='pressure'));
  const r=call('result',id);assert.equal(r.inputLog.policyVersion,'auto-v1');assert.equal(r.inputLog.version,2);
  r.inputLog.policyVersion='future-policy';assert.equal(call('replay',r.inputLog).error,'invalid_replay');
});
test('a rejected input is not an ended draw',()=>{
  const id=battle(set(151,['tackle']));assert.equal(move(id,'p1',5).ok,false);
  assert.equal(call('result',id).ended,false);assert.equal(call('result',id).winner,null);
});
test('Trace and Skill Swap reveal the correct current ability owner',()=>{
  const trace=battle(set(233,['tackle'],'trace'),set(25,['splash'],'static'));
  const traced=call('state',trace,'spectator');
  assert.equal(traced.p1.ability,'static');assert.equal(traced.p2.ability,'static');
  assert.ok(call('drainEvents',trace,'spectator').some(e=>e.side==='p1'&&e.id==='trace'));
  const swap=battle(set(151,['skill-swap']),set(242,['splash'],'natural-cure'));round(swap);
  const swapped=call('state',swap,'spectator');
  assert.equal(swapped.p1.ability,'naturalcure');assert.equal(swapped.p2.ability,'pressure');
});
test('equal speed resolution uses only the battle seed and replays exactly',()=>{
  const config=set(25,['quick-attack'],'static');
  const a=battle(config,config,7),b=battle(config,config,123);
  for(let i=0;i<20&&call('request',a,'p1').kind!=='none';i++){round(a);round(b);}
  const x=call('result',a),y=call('result',b);
  assert.equal(x.ended,true);assert.equal(x.logHash,y.logHash);
  assert.deepEqual(call('replay',x.inputLog),{winner:x.winner,logHash:x.logHash});
});
