const {test}=require('node:test');const assert=require('node:assert/strict');
const {readFileSync}=require('node:fs');const vm=require('node:vm');const path=require('node:path');
const {createHash}=require('node:crypto');
const context=vm.createContext({});vm.runInContext(readFileSync('dist/battle-engine.js','utf8'),context);
const callIn=(ctx,name,...args)=>JSON.parse(ctx.PTBEngine[name](...args.map(JSON.stringify)));
const call=(name,...args)=>callIn(context,name,...args);
const set=(speciesNum,moves,ability='pressure')=>({speciesNum,form:null,level:50,gender:'genderless',nature:'hardy',ability,moves,
  ivs:{hp:31,attack:31,defense:31,'special-attack':31,'special-defense':31,speed:31},shiny:false});
// policy = {p1:'tactical'}: a side left out runs the default (standard).
const battle=(p1,p2=set(242,['splash']),policySeed=42,policy={})=>{
  const player=(name,s)=>policy[name]?{name,set:s,policy:policy[name]}:{name,set:s};
  const r=call('createBattle',{seed:[1,2,3,4],policySeed,p1:player('p1',p1),p2:player('p2',p2)});assert.equal(r.ok,true,JSON.stringify(r));return r.id;
};
const pick=(id,side='p1')=>call('autoChoice',id,side).slot;
const move=(id,side,slot)=>call('choose',id,side,{type:'move',slot});
const round=(id,a=1,b=1)=>{assert.equal(move(id,'p1',a).ok,true);assert.equal(move(id,'p2',b).ok,true);};
const TEMPERAMENTS=['standard','aggressive','tactical','erratic'];
// Both sides automatic to the end; a hidden rejection (Imprison) is retried as the corpus does.
function playAuto(ctx,config) {
  const created=callIn(ctx,'createBattle',config);assert.equal(created.ok,true,JSON.stringify(created));
  const id=created.id;
  try {
    for(let n=0;n<402&&callIn(ctx,'request',id,'p1').kind!=='none';n++)for(const side of ['p1','p2']) {
      if(['none','wait'].includes(callIn(ctx,'request',id,side).kind))continue;
      let r;for(let retry=0;retry<5;retry++){r=callIn(ctx,'choose',id,side,{type:'auto'});if(r.ok||r.error!=='rejected')break;}
      assert.equal(r.ok,true,JSON.stringify(r));
    }
    const r=callIn(ctx,'result',id);assert.equal(r.ended,true);return r;
  } finally {callIn(ctx,'destroy',id);}
}
// Corpus-style battles: any species with any four gen 1-5 moves, so status and boost branches come up often.
// Levels within 3 of each other, as in practice, so battles run long enough to reach boosted and statused states.
function randomConfigs(count) {
  const {Dex}=require('@pkmn/sim');
  let s=0x5eed;const rand=n=>{s=(Math.imul(s,1664525)+1013904223)>>>0;return Math.floor(s/0x100000000*n);};
  const species=Dex.species.all().filter(x=>x.num>0&&x.num<=649&&!x.forme);
  const moves=Dex.moves.all().filter(m=>m.num>0&&m.gen<=5&&!m.isZ&&!m.isMax).map(m=>m.id);
  const natures=Dex.natures.all().map(n=>n.id);
  const mon=level=>{const sp=species[rand(species.length)];const known=new Set();while(known.size<4)known.add(moves[rand(moves.length)]);
    return {speciesNum:sp.num,form:null,level,gender:'genderless',nature:natures[rand(natures.length)],
      ability:Dex.abilities.get(Object.values(sp.abilities)[0]).id,moves:[...known],
      ivs:Object.fromEntries(['hp','attack','defense','special-attack','special-defense','speed'].map(k=>[k,rand(32)])),shiny:false};};
  return Array.from({length:count},()=>{const level=5+rand(96);
    return {seed:[rand(65536),rand(65536),rand(65536),rand(65536)],policySeed:rand(0x100000000),
      p1:{name:'p1',set:mon(level)},p2:{name:'p2',set:mon(Math.min(100,Math.max(1,level+rand(7)-3)))}};});
}

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
  const r=call('result',id);assert.equal(r.inputLog.policyVersion,'auto-v2');assert.equal(r.inputLog.version,2);
  for(const old of ['auto-v1','future-policy'])
    assert.deepEqual(call('replay',{...r.inputLog,policyVersion:old}),{ok:false,error:'invalid_replay'});
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
test('standard, named or omitted, picks exactly what auto-v1 picked across random battles',async()=>{
  // The reference is src/policy.js as shipped with auto-v1 (cb3b36f, bundle 99313880), kept unedited.
  const V1='tests/reference/policy-auto-v1.js';
  assert.equal(createHash('sha256').update(readFileSync(V1)).digest('hex'),'425c25217603234788a7b41c9ae3e9d0807ae548f8615e33ae8d3ec8dcb6dbe0');
  const {options}=await import('../scripts/options.mjs');const base=options();
  const swap={name:'auto-v1-policy',setup:b=>b.onResolve({filter:/^\.\/policy\.js$/},a=>
    a.importer.endsWith(path.join('src','index.js'))?{path:path.resolve(V1)}:undefined)};
  const built=await require('esbuild').build({...base,plugins:[...base.plugins,swap],entryPoints:['src/index.js'],write:false});
  const v1=vm.createContext({});vm.runInContext(built.outputFiles[0].text,v1);
  let decisions=0;
  for(const [i,config] of randomConfigs(400).entries()) {
    const expected=playAuto(v1,config);assert.equal(expected.inputLog.policyVersion,'auto-v1');
    decisions+=expected.inputLog.choices.length;
    for(const policy of [undefined,'standard']) {
      const named=JSON.parse(JSON.stringify(config));if(policy)named.p1.policy=named.p2.policy=policy;
      const actual=playAuto(context,named);
      assert.deepEqual(actual.inputLog.choices,expected.inputLog.choices,`battle ${i}, policy ${policy??'omitted'}`);
      assert.equal(actual.logHash,expected.logHash);
    }
  }
  assert.ok(decisions>=2500,`only ${decisions} decisions compared`);
});
test('aggressive puts power before accuracy and matchups but still scores an immune move zero',()=>{
  const thunder=set(25,['thunder','thunderbolt'],'static');
  assert.equal(pick(battle(thunder)),2);   // standard: 110 x 70% < 90
  assert.equal(pick(battle(thunder,undefined,42,{p1:'aggressive'})),1);
  const ember=set(4,['ember','scratch'],'blaze'),squirtle=set(7,['splash'],'torrent');
  assert.equal(pick(battle(ember,squirtle)),2);   // standard: resisted Ember 40 x 1.5 x 0.5 < Scratch 40
  assert.equal(pick(battle(ember,squirtle,42,{p1:'aggressive'})),1);
  assert.equal(pick(battle(set(25,['thunder','quick-attack'],'static'),set(27,['splash'],'sand-veil'),42,{p1:'aggressive'})),2);
});
test('tactical sets up at most twice while healthy and only with moves that still work',()=>{
  const id=battle(set(151,['tackle','harden','growth']),undefined,42,{p1:'tactical'});const picks=[];
  for(let i=0;i<3;i++){picks.push(pick(id));round(id,picks[i]);}
  assert.notEqual(picks[0],1);assert.notEqual(picks[1],1);assert.equal(picks[2],1,JSON.stringify(picks));
  assert.equal(pick(battle(set(151,['tackle','harden','growth']))),1);   // standard attacks at once
  const glare=battle(set(151,['glare','tackle']),undefined,42,{p1:'tactical'});
  assert.equal(pick(glare),1);round(glare,1);assert.equal(call('state',glare,'p1').p2.status,'par');
  assert.equal(pick(glare),2);   // already paralysed: Glare would do nothing
  const sandshrew=set(27,['splash'],'sand-veil');
  assert.equal(pick(battle(set(151,['thunder-wave','tackle']),sandshrew,42,{p1:'tactical'})),2);   // Electric cannot touch Ground
  assert.equal(pick(battle(set(151,['thunder-wave','tackle']),undefined,42,{p1:'tactical'})),1);
});
test('tactical heals below half HP and attacks above it',()=>{
  const tosser={...set(242,['seismic-toss']),level:100};
  const run=policy=>{const id=battle(set(151,['recover','tackle']),tosser,42,policy);
    const first=pick(id);round(id,first);const own=call('state',id,'p1').p1;
    assert.ok(own.hp*2<own.maxhp,`${own.hp}/${own.maxhp}`);return [first,pick(id)];};
  assert.deepEqual(run({p1:'tactical'}),[2,1]);
  assert.deepEqual(run({}),[2,2]);
});
test('erratic draws in proportion to score, never a zero score, and is auto-v1 when nothing scores',()=>{
  const sandshrew=set(27,['splash'],'sand-veil');const mixed=set(25,['thunderbolt','tackle','body-slam'],'static');
  assert.equal(pick(battle(mixed,sandshrew)),3);
  const counts=[0,0,0,0];
  for(let seed=1;seed<=200;seed++){const id=battle(mixed,sandshrew,seed,{p1:'erratic'});counts[pick(id)]++;call('destroy',id);}
  assert.equal(counts[1],0);assert.ok(counts[3]>counts[2]&&counts[2]>0,JSON.stringify(counts));
  const slots=new Set();
  for(let seed=1;seed<=16;seed++){const pair=[set(25,['thunderbolt','thunder-shock'],'static'),sandshrew];
    const a=battle(...pair,seed,{p1:'erratic'}),b=battle(...pair,seed);
    assert.equal(pick(a),pick(b));slots.add(pick(a));call('destroy',a);call('destroy',b);}
  assert.equal(slots.size,2);
});
test('every temperament repeats its picks for a seed without touching the battle RNG',()=>{
  const pair=[set(151,['psychic','thunder-wave','recover','swords-dance']),{...set(68,['cross-chop','bulk-up','rock-slide','seismic-toss'],'guts'),level:55}];
  for(const policy of TEMPERAMENTS) {
    const play=()=>{const id=battle(...pair,7,{p1:policy,p2:policy});
      for(let i=0;i<200&&call('request',id,'p1').kind!=='none';i++) {
        const before=call('result',id).logHash;const a=pick(id),b=pick(id,'p2');
        assert.equal(pick(id),a);assert.equal(pick(id,'p2'),b);assert.equal(call('result',id).logHash,before);round(id,a,b);
      }
      const r=call('result',id);call('destroy',id);return r;};
    const x=play(),y=play();assert.equal(x.ended,true,policy);assert.deepEqual(y,x);
    assert.deepEqual(call('replay',x.inputLog),{winner:x.winner,logHash:x.logHash});
  }
});
