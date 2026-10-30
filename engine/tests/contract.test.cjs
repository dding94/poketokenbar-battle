const {test} = require('node:test');
const assert = require('node:assert/strict');
const {readFileSync} = require('node:fs');
const vm = require('node:vm');
const ctx = vm.createContext({});
vm.runInContext(readFileSync('dist/battle-engine.js', 'utf8'), ctx);
const call = (method, ...args) => JSON.parse(ctx.PTBEngine[method](...args.map(JSON.stringify)));
const set = (speciesNum = 25, ability = 'static', moves = ['thunderbolt']) => ({speciesNum,
  form: null, level: 50, gender: 'male', nature: 'hardy', ability, moves,
  ivs: {hp:31, attack:31, defense:31, 'special-attack':31, 'special-defense':31, speed:31}, shiny:false});
const config = () => ({seed:[1,2,3,4], policySeed:42,
  p1:{name:'연습', set:set()}, p2:{name:'상대', set:set(129, 'swift-swim', ['splash'])}});
const create = (c = config()) => {const r=call('createBattle',c); assert.equal(r.ok,true,JSON.stringify(r));return r.id;};
const round = id => {assert.equal(call('choose',id,'p1',{type:'auto'}).ok,true);assert.equal(call('choose',id,'p2',{type:'auto'}).ok,true);};

test('reports the pinned engine and gen9 rule contract', () => {
  assert.deepEqual(call('version'),{engine:'@pkmn/sim@0.10.12',adapter:'1',rules:'gen9-notera-noitems-v1'});
});
test('fixed seed has the independently calculated winner and normalized hash', () => {
  const id=create(); round(id); const r=call('result',id);
  assert.equal(r.ended,true);assert.equal(r.winner,'p1');assert.equal(r.turns,1);
  assert.equal(r.logHash,'cffaf9acfe3a04e3a23205cd46c4adbbbdfb540efc86ac5eef03e47e5d216e41');
  assert.deepEqual(call('replay',r.inputLog),{winner:r.winner,logHash:r.logHash});
  const again=create();round(again);assert.equal(call('result',again).logHash,r.logHash);
});
test('request exposes only legal move tokens, then waits after submission', () => {
  const id=create(); const r=call('request',id,'p1');
  assert.equal(r.kind,'move'); assert.deepEqual(r.moves,[{slot:1,id:'thunderbolt',name:'Thunderbolt',type:'Electric',pp:24,maxpp:24,disabled:false}]);
  assert.deepEqual(call('choose',id,'p1',{type:'move',slot:1}),{ok:true,resolved:false});
  assert.equal(call('request',id,'p1').kind,'wait');
  assert.deepEqual(call('choose',id,'p1',{type:'move',slot:1}),{ok:false,error:'rejected'});
  assert.deepEqual(call('choose',id,'p2',{type:'move',slot:1}),{ok:true,resolved:true});
});
for (const [field,value,error] of [['speciesNum',99999,'invalid_species'],['form','mega','invalid_form'],
  ['moves',['not-a-move'],'invalid_moves'],['ability','unknown','invalid_ability'],
  ['nature','unknown','invalid_nature'],['level',101,'invalid_level'],['level',0,'invalid_level'],
  ['moves',[],'invalid_moves'],['gender','unknown','invalid_gender'],['item','leftovers','invalid_set']]) {
  test(`rejects ${field}=${JSON.stringify(value)}`,()=>{const c=config();c.p1.set[field]=value;
    assert.deepEqual(call('createBattle',c),{ok:false,error});});
}
test('rejects malformed JSON and forged seeds without escaping exceptions',()=>{
  assert.deepEqual(JSON.parse(ctx.PTBEngine.createBattle('{')),{ok:false,error:'invalid_json'});
  for (const seed of [null,[1,2,3],[-1,2,3,4],[1,2,3,65536]]) {
    const c=config();c.seed=seed;assert.deepEqual(call('createBattle',c),{ok:false,error:'invalid_seed'});
  }
});
test('a player may name an opponent temperament; anything else is invalid_policy',()=>{
  for (const policy of ['standard','aggressive','tactical','erratic']) {
    const c=config();c.p2.policy=policy;const id=create(c);round(id);const r=call('result',id);
    assert.equal(r.inputLog.policyVersion,'auto-v2');assert.equal(r.inputLog.config.p2.policy,policy);
    assert.equal('policy' in r.inputLog.config.p1,false);
    assert.deepEqual(call('replay',r.inputLog),{winner:r.winner,logHash:r.logHash});call('destroy',id);
  }
  for (const policy of ['chaotic','Standard','',null,0,['erratic'],{}]) for (const side of ['p1','p2']) {
    const c=config();c[side].policy=policy;
    assert.deepEqual(call('createBattle',c),{ok:false,error:'invalid_policy'},`${side} ${JSON.stringify(policy)}`);
  }
  const c=config();c.p2.temperament='erratic';assert.deepEqual(call('createBattle',c),{ok:false,error:'invalid_player'});
});
test('replay runs only auto-v2 logs and validates the policies they carry',()=>{
  const c=config();c.p1.policy='tactical';c.p2.policy='erratic';const id=create(c);round(id);
  const log=call('result',id).inputLog;call('destroy',id);
  assert.deepEqual(call('replay',{...log,policyVersion:'auto-v1'}),{ok:false,error:'invalid_replay'});
  assert.deepEqual(call('replay',{...log,config:{...log.config,p2:{...log.config.p2,policy:'reckless'}}}),{ok:false,error:'invalid_policy'});
});
test('a player may start at 1..max HP (describeSet stats.hp); anything else is invalid_hp, never clamped',()=>{
  const max={p1:call('describeSet',set()).stats.hp,p2:call('describeSet',set(129,'swift-swim',['splash'])).stats.hp};
  assert.deepEqual(max,{p1:110,p2:95});
  for (const side of ['p1','p2']) {
    for (const hp of [1,max[side]]) {const c=config();c[side].hp=hp;call('destroy',create(c));}
    for (const hp of [0,-1,max[side]+1,1.5,'50',null,true,[50],{}]) {
      const c=config();c[side].hp=hp;
      assert.deepEqual(call('createBattle',c),{ok:false,error:'invalid_hp'},`${side} ${JSON.stringify(hp)}`);
    }
  }
  const c=config();c.p1.set=set(292,'wonder-guard',['scratch']);c.p1.hp=1;call('destroy',create(c));   // Shedinja: max HP 1
  c.p1.hp=2;assert.deepEqual(call('createBattle',c),{ok:false,error:'invalid_hp'});
});
test('a starting HP shows exactly to its side and as the HP bar percentage to everyone else',()=>{
  for (const [hp,bar] of [[37,34],[109,99],[1,1]]) {   // ceil(100 x hp / 110), and 99 until full
    const c=config();c.p1.hp=hp;const id=create(c);
    const own=call('state',id,'p1').p1;assert.deepEqual([own.hp,own.maxhp],[hp,110]);
    for (const viewer of ['p2','spectator']) {const seen=call('state',id,viewer).p1;assert.deepEqual([seen.hp,seen.maxhp],[bar,100],viewer);}
    const full=create();assert.deepEqual(call('request',id,'p1'),call('request',full,'p1'));
    call('destroy',id);call('destroy',full);
  }
});
test('a starting HP changes nothing in any view but the HP on the switch-in line',()=>{
  const full=create(),c=config();c.p1.hp=37;const hurt=create(c);
  for (const [viewer,before,after] of [['p1','110/110','37/110'],['p2','100/100','34/100'],['spectator','100/100','34/100']]) {
    const a=call('drainLog',full,viewer),b=call('drainLog',hurt,viewer);
    assert.equal(b.length,a.length,viewer);
    assert.deepEqual(a.map((line,i)=>[line,b[i]]).filter(([x,y])=>x!==y),
      [[`|switch|p1a: Pikachu|Pikachu, L50, M|${before}`,`|switch|p1a: Pikachu|Pikachu, L50, M|${after}`]],viewer);
  }
  call('destroy',full);call('destroy',hurt);
});
test('a starting HP stays in the input log, decides the battle and replays exactly',()=>{
  const c=config();c.p2.set=set(53,'limber',['tackle']);   // Persian outspeeds Pikachu
  const full=create(c);round(full);assert.equal(call('result',full).ended,false);
  c.p1.hp=1;const id=create(c);round(id);const r=call('result',id);
  assert.deepEqual([r.ended,r.winner,r.turns,r.inputLog.config.p1.hp],[true,'p2',1,1]);
  assert.deepEqual(call('replay',r.inputLog),{winner:r.winner,logHash:r.logHash});
  const forged={...r.inputLog,config:{...r.inputLog.config,p1:{...r.inputLog.config.p1,hp:111}}};
  assert.deepEqual(call('replay',forged),{ok:false,error:'invalid_hp'});
  call('destroy',full);call('destroy',id);
});
test('starting at max HP is the same battle as leaving hp out',()=>{
  const c=config();c.p2.set=set(53,'limber',['tackle']);const omitted=create(c);
  c.p1.hp=110;c.p2.hp=call('describeSet',c.p2.set).stats.hp;const named=create(c);
  for (let i=0;i<10&&call('request',omitted,'p1').kind!=='none';i++){round(omitted);round(named);}
  assert.equal(call('result',omitted).ended,true);assert.equal(call('result',named).logHash,call('result',omitted).logHash);
  call('destroy',omitted);call('destroy',named);
});
test('rejects raw commands, tera, noninteger slots and out of range slots',()=>{
  const id=create();
  for (const choice of ['move 1', '>eval globalThis.hacked=true', {type:'move',slot:1,tera:true},
    {type:'move',slot:0},{type:'move',slot:5},{type:'move',slot:1.5},{type:'switch',slot:1}]) {
    assert.equal(call('choose',id,'p1',choice).ok,false);
  }
  assert.equal(call('replay','>eval globalThis.hacked=true').ok,false);
  assert.equal(ctx.hacked,undefined);
});
test('prebattle views and logs do not leak opponent moves, ability or exact HP',()=>{
  const id=create();const state=call('state',id,'p1');
  assert.equal(state.p1.maxhp,110);assert.equal(state.p2.maxhp,100);
  assert.deepEqual(state.p2.moves,[]);assert.equal(state.p2.ability,null);
  const lines=call('drainLog',id,'p1');assert.ok(lines.some(x=>x.includes('100/100')));
  assert.ok(!lines.some(x=>x.includes('95/95')||x.startsWith('|t:|')));
  assert.deepEqual(call('drainLog',id,'p1'),[]);
  assert.ok(call('drainLog',id,'p2').some(x=>x.includes('95/95')));
});
test('destroy releases battle and unknown sides/viewers are rejected',()=>{
  const id=create();assert.equal(call('request',id,'p3').ok,false);
  assert.equal(call('state',id,'omniscient').ok,false);
  assert.deepEqual(call('destroy',id),{ok:true});assert.equal(call('result',id).error,'unknown_battle');
});


test('public set description uses gen9 stats, nature and EV zero without secrets',()=>{
  const s=set();const info=call('describeSet',s);
  assert.deepEqual(info,{speciesNum:25,species:'Pikachu',level:50,types:['Electric'],
    stats:{hp:110,atk:75,def:60,spa:70,spd:70,spe:110}});
  s.nature='adamant';assert.equal(call('describeSet',s).stats.atk,82);
  assert.equal(call('describeSet',s).stats.spa,63);
});
test('form mapping explicitly covers base starts, distinct forms, Shedinja and Ditto',()=>{
  for(const [num,form,ability,species] of [[386,'speed','pressure','Deoxys-Speed'],
    [479,'wash','levitate','Rotom-Wash'],[487,'origin','pressure','Giratina'],
    [493,'fire','multitype','Arceus'],[649,'douse','download','Genesect'],
    [351,'sunny','forecast','Castform'],[555,'zen','zen-mode','Darmanitan'],
    [648,'pirouette','serene-grace','Meloetta'],[132,null,'limber','Ditto']]) {
    assert.equal(call('describeSet',{...set(num,ability,['tackle']),form}).species,species);
  }
  assert.equal(call('describeSet',set(292,'wonder-guard',['scratch'])).stats.hp,1);
});
test('aliases cannot smuggle a duplicate move into the set',()=>{
  assert.deepEqual(call('describeSet',set(25,'static',['vice-grip','vise-grip'])),{ok:false,error:'invalid_moves'});
});
test('describes moves from gen9 data for decision hints and rejects unknown ids',()=>{
  const r=call('describeMoves',['thunderbolt','quick-attack','vice-grip','swift']);
  assert.deepEqual(r.moves[0],{id:'thunderbolt',name:'Thunderbolt',type:'Electric',category:'Special',basePower:90,accuracy:100,priority:0,pp:15,fixedDamage:false,variableType:false});
  assert.equal(r.moves[1].priority,1);assert.equal(r.moves[2].id,'visegrip');assert.equal(r.moves[3].accuracy,null);
  for(const bad of [['not-a-move'],[],['Thunderbolt!'],'thunderbolt',Array(9).fill('tackle')])
    assert.deepEqual(call('describeMoves',bad),{ok:false,error:'invalid_moves'});
});
test('type chart is type-only over the 18 gen9 types (no Stellar, no abilities)',()=>{
  const c=call('typeChart');
  assert.equal(c.types.length,18);assert.ok(c.types.includes('Fairy'));assert.ok(!c.types.includes('Stellar'));
  assert.equal(c.damage.Electric.Ground,0);assert.equal(c.damage.Electric.Water,2);assert.equal(c.damage.Normal.Ghost,0);
  assert.equal(c.damage.Fire.Grass,2);assert.equal(c.damage.Fire.Water,0.5);assert.equal(c.damage.Dragon.Fairy,0);
  assert.equal(c.damage.Steel.Fairy,2);assert.equal(c.damage.Ground.Flying,0);
});
test('describeMoves flags moves whose damage ignores type matchups or whose type varies',()=>{
  const by=Object.fromEntries(call('describeMoves',['night-shade','dragon-rage','super-fang','counter','guillotine','sheer-cold','hidden-power','weather-ball']).moves.map(m=>[m.id,m]));
  for(const id of ['nightshade','dragonrage','superfang','counter','guillotine','sheercold'])assert.equal(by[id].fixedDamage,true,id);
  for(const id of ['hiddenpower','weatherball'])assert.deepEqual([by[id].variableType,by[id].fixedDamage],[true,false],id);
  assert.equal(by.nightshade.variableType,false);
});
