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
